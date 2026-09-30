variable "name" {
  default     = null
  description = "Name of the repository. ECR accepts 2 to 256 characters of lowercase alphanumeric segments joined by a period, underscore, hyphen, or forward slash, so 'platform/api' is valid and 'PlatformAPI' is not. If null, a unique name is generated."

  validation {
    condition     = var.name == null || (can(regex("^(?:[a-z0-9]+(?:[._-][a-z0-9]+)*/)*[a-z0-9]+(?:[._-][a-z0-9]+)*$", var.name)) && length(var.name) >= 2 && length(var.name) <= 256)
    error_message = "name must be 2 to 256 characters of lowercase alphanumeric segments joined by '.', '_', '-' or '/', such as 'platform/api'."
  }
}

variable "image_tag_mutability" {
  default     = "IMMUTABLE"
  description = "Whether an existing tag may be repointed at different image bytes ('IMMUTABLE' or 'MUTABLE'). Defaults to 'IMMUTABLE', so a tag names exactly one image for as long as the tag exists. A build pipeline that overwrites a floating tag such as 'latest' on every push needs 'MUTABLE' and gives up that guarantee."

  validation {
    condition     = contains(["IMMUTABLE", "MUTABLE"], var.image_tag_mutability)
    error_message = "image_tag_mutability must be 'IMMUTABLE' or 'MUTABLE'."
  }
}

variable "scan_on_push" {
  default     = true
  description = "Whether ECR runs a basic vulnerability scan against an image as it is pushed. Basic scanning costs nothing and reports findings against the operating system packages in the image. An account with Amazon Inspector enabled for ECR replaces this with continuous enhanced scanning, which is billed per image."
}

variable "encryption_type" {
  default     = "AES256"
  description = "How image layers are encrypted at rest ('AES256' or 'KMS'). 'AES256' is encryption ECR performs with keys it owns, at no charge and with nothing to administer. 'KMS' encrypts under a KMS key instead, which records every decryption in CloudTrail and can be disabled to cut off access to the images, and which bills for the key and for each request against it."

  validation {
    condition     = contains(["AES256", "KMS"], var.encryption_type)
    error_message = "encryption_type must be 'AES256' or 'KMS'."
  }

  validation {
    condition     = var.encryption_type == "KMS" || var.kms_key == null
    error_message = "kms_key only applies when encryption_type is 'KMS'. Set encryption_type to 'KMS', or leave kms_key null."
  }
}

variable "kms_key" {
  default     = null
  description = "ARN of the KMS key encrypting image layers at rest. Only applies when encryption_type is 'KMS'; left null there, ECR uses the AWS managed key 'aws/ecr', which cannot be disabled or given a key policy of your own. Feed terraform-aws-kms-key's arn output here for a customer managed key."
}

variable "expire_untagged_after_days" {
  default     = null
  description = "Days after which an untagged image is expired. Pushing a tag that already exists leaves the image it replaced untagged rather than deleting it, so a repository fed by a rebuild loop accumulates untagged layers indefinitely without this. Left null, no untagged-image rule is created."
  type        = number

  validation {
    condition     = var.expire_untagged_after_days == null || var.expire_untagged_after_days >= 1
    error_message = "expire_untagged_after_days must be at least 1."
  }
}

variable "max_image_count" {
  default     = null
  description = "Maximum number of images to retain in the repository; anything past that count is expired, oldest first. Applies to tagged and untagged images alike, so a count low enough to reach images a running task still references will break that task's next placement. Left null, no image-count rule is created."
  type        = number

  validation {
    condition     = var.max_image_count == null || var.max_image_count >= 1
    error_message = "max_image_count must be at least 1."
  }
}

variable "lifecycle_policy" {
  default     = null
  description = "A complete ECR lifecycle policy document (JSON), for retention rules the generated ones cannot express — expiring by tag prefix, for instance. Replaces the generated rules rather than adding to them, and so cannot be combined with expire_untagged_after_days or max_image_count."

  validation {
    condition     = var.lifecycle_policy == null || (var.expire_untagged_after_days == null && var.max_image_count == null)
    error_message = "lifecycle_policy replaces the generated rules entirely, so it cannot be set alongside expire_untagged_after_days or max_image_count."
  }
}

variable "force_delete" {
  default     = false
  description = "Whether destroying the repository also deletes the images left in it. Defaults to false, so a destroy against a repository that still holds images fails instead of discarding them — those images may be the only copy of something currently deployed. Set it to true only where the images are rebuildable from source on demand."
}

variable "enable_repository_policy" {
  default     = false
  description = "Whether the document in policy is attached to the repository. This is a separate switch because Terraform requires the decision to be known before it plans, and a policy naming a principal created in the same configuration is not — see the Design section."

  validation {
    condition     = !var.enable_repository_policy || var.policy != null
    error_message = "enable_repository_policy requires policy to hold the document being attached."
  }

  validation {
    condition     = var.policy == null || var.enable_repository_policy
    error_message = "policy is set but enable_repository_policy is false, so nothing would be attached. Set enable_repository_policy = true."
  }
}

variable "policy" {
  default     = null
  description = "Resource policy document (JSON) for the repository, granting principals outside this account permission to pull or push. Requires enable_repository_policy. A principal inside this account is granted access by an IAM policy on that principal instead, so a single-account deployment needs no repository policy at all. A statement whose Principal is '*' makes the repository readable by anyone on the internet."
}

variable "tags" {
  default     = null
  description = "A map of tags to assign to the repository."
}
