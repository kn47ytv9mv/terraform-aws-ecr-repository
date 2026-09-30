# terraform-aws-ecr-repository

Terraform module for a private Amazon ECR repository, with immutable tags,
push-time vulnerability scanning, and optional retention rules enabled out
of the box. A repository here is the registry every other workload module
in this family pulls from, rather than an unauthenticated public registry
that rate-limits by source address.

## Cost

Amazon ECR bills for the storage the images occupy, charged per gigabyte
per month across every repository in the region, and for data transferred
out of the region. A pull from a task or a node in the same region as the
repository moves no billable data; a pull from another region or from
outside AWS does. An empty repository costs nothing, so the bill follows
what is pushed and what is retained rather than how many repositories
exist — which is why the retention rules described below are the lever
that actually controls it.

Basic scanning on push costs nothing. `encryption_type = "KMS"` adds the
monthly charge for the key and a request charge for each layer encrypted
or decrypted under it. See AWS's
[ECR pricing](https://aws.amazon.com/ecr/pricing/) page for current rates.

## Design

### What this module bundles, and why

`aws_ecr_lifecycle_policy` and `aws_ecr_repository_policy` live inside this
module rather than beside it. Both are keyed solely by the repository they
belong to, AWS permits at most one of each per repository, and neither
carries an ARN or any identifier of its own — the provider's schema gives
each an `id` that is simply the repository name. Nothing outside this module
can therefore reference one of them specifically, and there is no second
instance for a caller to distinguish, so both conditions of the
bundle-versus-split test are satisfied on the bundle side. This is the same
shape as the versioning, encryption, public-access-block, and logging
companions bundled into `terraform-aws-s3`.

### Tag immutability

`image_tag_mutability` defaults to `IMMUTABLE`, which is not AWS's own
default. AWS defaults to `MUTABLE`, under which pushing a tag that already
exists silently repoints it at different bytes. A deployment that names an
image by tag then has no way to know which image it will actually receive,
and no way to reproduce what it received last week: the tag recorded in a
task definition, a manifest, or an audit log stops being evidence of
anything. `IMMUTABLE` makes a tag name exactly one image for as long as the
tag exists, so the tag in the deployment record is the artifact.

The cost is that a pipeline built around overwriting a floating tag such as
`latest` will fail its second push. That pipeline should tag by commit or
by build number instead, but where it cannot, `MUTABLE` is available and
the guarantee is deliberately given up.

### Scanning, and its relationship to Amazon Inspector

`scan_on_push` defaults to `true`. ECR basic scanning is free, runs against
the operating system packages in the image at the moment it is pushed, and
turns a vulnerability into a finding attached to an artifact that has not
been deployed yet. The same vulnerability found after the image is running
costs a rollback or an emergency rebuild instead.

Basic scanning is not continuous: it reports what was known when the image
was pushed, and a CVE published the following week against an already-pushed
image produces no new finding. `terraform-aws-inspector2-enabler` with `ECR`
in its `resource_types` replaces basic scanning for the whole account with
Amazon Inspector's enhanced scanning, which rescans existing images as new
vulnerabilities are published and also covers application-language
dependencies rather than only operating system packages. The two are not
additive and do not conflict: enabling Inspector for ECR supersedes the
basic scan configuration at the registry level, and leaving `scan_on_push`
at `true` here simply has no further effect once it is on. Enhanced scanning
is billed per image scanned, which is the reason this module defaults to the
free option rather than assuming the account has Inspector.

### Encryption at rest

Image layers are always encrypted. `encryption_type` defaults to `AES256`,
which is encryption ECR performs with keys it owns and manages: nothing to
administer, no key policy to get wrong, and no charge.

`encryption_type = "KMS"` with a `kms_key` from `terraform-aws-kms-key`
buys two things AES256 cannot offer. Every decryption is recorded in
CloudTrail against the key, so there is an audit trail of which principal
read which layers. And the key can be disabled, which revokes access to
every image in the repository at once without touching the repository — a
containment step available at the key rather than at the registry. What it
costs is the monthly key charge, a request charge per layer operation, and
the obligation to keep the key alive: scheduling the key for deletion makes
every image in the repository permanently unreadable, and ECR cannot
re-encrypt an existing repository under a different key, because
`encryption_configuration` is fixed at creation. Left as `KMS` with
`kms_key` null, ECR uses the AWS managed `aws/ecr` key, which gives the
CloudTrail trail but not a key policy or a disable switch of your own.

### Retention

A repository that is never pruned grows without limit, and the growth is
mostly invisible. Pushing a tag that already exists does not delete the
image it replaced; it leaves that image untagged and still stored, so a
rebuild loop adds a full set of layers on every run whether or not anything
in the image changed. `expire_untagged_after_days` addresses exactly that
case and is the single most useful retention input:
`expire_untagged_after_days = 14` deletes an untagged image two weeks after
it was pushed, which is long enough to roll back to and short enough to
bound the bill.

`max_image_count` caps the total instead, expiring the oldest images beyond
the count. It applies to tagged and untagged images alike, so a count low
enough to reach an image a running task still references will break that
task's next placement — ECR does not know what is deployed.

Set together, the two generate one policy with the untagged rule at
priority 1 and the count rule at priority 2. That ordering is required
rather than incidental: ECR evaluates rules in ascending priority and
insists that a rule selecting every tag status carries the highest priority
of any rule in the policy, so the count rule must come last.

`lifecycle_policy` takes a complete policy document for anything the
generated rules cannot express, such as expiring by tag prefix so that
pull-request builds are retained for days while release builds are kept
indefinitely. It replaces the generated rules rather than merging with
them, and setting it alongside either generator is rejected instead of
silently discarding one of them.

### Destroying a repository that still holds images

`force_delete` defaults to `false`, which means a `terraform destroy` against
a repository that still contains images fails and leaves the repository in
place. That is the honest default rather than the convenient one: the images
in a registry are frequently the only copy of what is currently deployed, and
a module that quietly deleted them on destroy would turn a mistaken target
into an unrecoverable one. Set `force_delete = true` for a repository whose
contents are rebuildable from source on demand, such as one holding
per-branch development images.

### Switches that look redundant, and are not

`enable_repository_policy` alongside `policy` reads like a switch you should
not have to remember. It exists because **Terraform decides how many
resources to create before it knows any value AWS computes.** Gating on
`policy != null` works only while the document is written entirely from
literals; a repository policy naming a principal created in the same
apply — an IAM role from `terraform-aws-iam-role`, an account in the same
organization — is an unknown string at plan time, and the plan then fails
outright with *"Invalid count argument ... cannot be determined until
apply"*, because Terraform cannot tell whether an unknown value is null. A
boolean the caller writes is always known at plan time, so the gate holds
wherever the document comes from. Supplying one without the other is
rejected in both directions rather than silently ignored.

The lifecycle policy needs no such switch. An ECR lifecycle policy document
selects images by tag status, tag prefix, age, and count, and names no ARN,
principal, or resource identifier, so it cannot become plan-unknown the way
a resource policy can.

Encryption is gated the same way for the same reason: the module decides on
`encryption_type`, a plan-known string, never on whether `kms_key` happens
to be null — a key ARN is very often produced by the same apply.

### Generated names

Left unset, `name` falls back to a random UUID prefixed with `repository-`.
The prefix is deliberate. ECR's own API pattern for a repository name accepts
a leading digit, but AWS's user-facing documentation states that the name must
begin with a letter, and a bare UUID begins with a hexadecimal digit roughly
five times in eight. Prefixing costs nothing and is valid under either
reading, which is the safer side of an ambiguity to be on.

The `name` validation is deliberately the more permissive of the two rules:
it enforces the API pattern, so a caller-supplied `2048-tiles` is accepted.
Rejecting a name AWS would have taken is a worse failure than generating one
it might not, so the module is conservative in what it generates and liberal
in what it accepts.

### Not covered

- **`image_tag_mutability_exclusion_filter`.** The provider supports
  `IMMUTABLE_WITH_EXCLUSION` and `MUTABLE_WITH_EXCLUSION`, which make
  mutability conditional on a tag pattern. Both require at least one filter
  block to be valid, so accepting the values without the filters would only
  produce apply-time failures; `image_tag_mutability` therefore accepts
  `IMMUTABLE` and `MUTABLE` only.
- **The delete `timeouts` block.** The provider's default is adequate, and a
  repository delete that exceeds it is a symptom of something this module
  cannot fix.
- **Registry-wide settings.** Replication, registry scanning configuration,
  and pull-through cache rules are properties of the registry rather than of
  one repository, and a module named for a repository should not reconfigure
  everything else in the account.
- **Image pushes.** Nothing here builds or pushes an image. That belongs to a
  build pipeline, not to a Terraform apply.

## Usage

```hcl
module "repository" {
  source = "kn47ytv9mv/ecr-repository/aws"

  name = "platform/api"
}
```

Or directly from this repository:

```hcl
module "repository" {
  source = "github.com/kn47ytv9mv/terraform-aws-ecr-repository"

  name = "platform/api"
}
```

Bounding what the repository stores, which is the configuration most
repositories should start from:

```hcl
module "repository" {
  source = "kn47ytv9mv/ecr-repository/aws"

  name = "platform/api"

  expire_untagged_after_days = 14
  max_image_count            = 30
}
```

Encrypting image layers under a customer managed key:

```hcl
module "repository" {
  source = "kn47ytv9mv/ecr-repository/aws"

  name = "platform/api"

  encryption_type = "KMS"
  kms_key         = module.images_key.arn
}
```

Letting another account pull from the repository:

```hcl
module "repository" {
  source = "kn47ytv9mv/ecr-repository/aws"

  name = "platform/api"

  enable_repository_policy = true

  policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Sid    = "AllowCrossAccountPull"
        Effect = "Allow"

        Principal = {
          AWS = "arn:aws:iam::123456789012:root"
        }

        Action = [
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchCheckLayerAvailability",
        ]
      },
    ]
  })
}
```

Accommodating a pipeline that overwrites a floating tag, in a repository
whose images are rebuildable:

```hcl
module "repository" {
  source = "kn47ytv9mv/ecr-repository/aws"

  name = "platform/api"

  image_tag_mutability = "MUTABLE"
  force_delete         = true
}
```

## Requirements

| Name | Version |
|---|---|
| terraform | >= 1.9 |
| aws | ~> 6.61 |
| random | ~> 3.9 |

## Providers

| Name | Version |
|---|---|
| aws | ~> 6.61 |
| random | ~> 3.9 |

## Inputs

| Name | Description | Default | Required |
|---|---|---|---|
| name | Name of the repository. ECR accepts 2 to 256 characters of lowercase alphanumeric segments joined by a period, underscore, hyphen, or forward slash, so `platform/api` is valid and `PlatformAPI` is not. If null, a unique name is generated. | `null` | no |
| image_tag_mutability | Whether an existing tag may be repointed at different image bytes (`'IMMUTABLE'` or `'MUTABLE'`). Defaults to `'IMMUTABLE'` — see Design. | `"IMMUTABLE"` | no |
| scan_on_push | Whether ECR runs a basic vulnerability scan against an image as it is pushed. Basic scanning costs nothing. An account with Amazon Inspector enabled for ECR supersedes it — see Design. | `true` | no |
| encryption_type | How image layers are encrypted at rest (`'AES256'` or `'KMS'`). Fixed at creation, and cannot be changed afterwards. | `"AES256"` | no |
| kms_key | ARN of the KMS key encrypting image layers at rest. Only applies when `encryption_type` is `'KMS'`; left null there, the AWS managed key `aws/ecr` is used. Feed `terraform-aws-kms-key`'s `arn` output here. | `null` | no |
| expire_untagged_after_days | Days after which an untagged image is expired. Left null, no untagged-image rule is created. | `null` | no |
| max_image_count | Maximum number of images to retain; anything past that count is expired, oldest first. Applies to tagged images too — see Design. | `null` | no |
| lifecycle_policy | A complete ECR lifecycle policy document (JSON), for retention rules the generated ones cannot express. Replaces them rather than adding to them, so it cannot be combined with `expire_untagged_after_days` or `max_image_count`. | `null` | no |
| force_delete | Whether destroying the repository also deletes the images left in it. Defaults to false, so a destroy against a non-empty repository fails rather than discarding them — see Design. | `false` | no |
| enable_repository_policy | Whether the document in `policy` is attached to the repository. Separate from the document because Terraform needs the decision known at plan time — see Design. | `false` | no |
| policy | Resource policy document (JSON) granting principals outside this account permission to pull or push. Requires `enable_repository_policy`. A principal inside this account is granted access by an IAM policy on that principal instead. | `null` | no |
| tags | A map of tags to assign to the repository. | `null` | no |

## Outputs

| Name | Description |
|---|---|
| id | The ID of the repository, which is its name. |
| arn | The ARN of the repository. Grant a pulling task's IAM role `ecr:BatchGetImage` and `ecr:GetDownloadUrlForLayer` on this ARN. |
| name | The name of the repository. Every ECR API call identifies a repository by this name rather than by its ARN. |
| repository_url | The URL of the repository, without a tag. Append a tag or digest and feed the result to an ECS container definition's `image` or a Kubernetes pod spec's `image`. |
| registry_id | The account ID of the registry holding the repository. Authenticating Docker against the registry needs this rather than the repository name. |

## License

MIT — see [LICENSE.md](LICENSE.md).
