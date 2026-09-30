mock_provider "aws" {
}

run "uppercase_name_is_rejected" {
  command = plan

  variables {
    name = "PlatformAPI"
  }

  expect_failures = [var.name]
}

run "single_character_name_is_rejected" {
  command = plan

  variables {
    name = "a"
  }

  expect_failures = [var.name]
}

run "unknown_image_tag_mutability_is_rejected" {
  command = plan

  variables {
    image_tag_mutability = "immutable"
  }

  expect_failures = [var.image_tag_mutability]
}

run "unknown_encryption_type_is_rejected" {
  command = plan

  variables {
    encryption_type = "aws:kms"
  }

  expect_failures = [var.encryption_type]
}

run "kms_key_without_kms_encryption_type_is_rejected" {
  command = plan

  variables {
    kms_key = "arn:aws:kms:us-east-1:123456789012:key/example"
  }

  expect_failures = [var.encryption_type]
}

run "zero_expire_untagged_after_days_is_rejected" {
  command = plan

  variables {
    expire_untagged_after_days = 0
  }

  expect_failures = [var.expire_untagged_after_days]
}

run "zero_max_image_count_is_rejected" {
  command = plan

  variables {
    max_image_count = 0
  }

  expect_failures = [var.max_image_count]
}

run "lifecycle_policy_alongside_generated_rules_is_rejected" {
  command = plan

  variables {
    lifecycle_policy           = "{\"rules\":[]}"
    expire_untagged_after_days = 14
  }

  expect_failures = [var.lifecycle_policy]
}

run "enable_repository_policy_without_policy_is_rejected" {
  command = plan

  variables {
    enable_repository_policy = true
  }

  expect_failures = [var.enable_repository_policy]
}

run "policy_without_enable_repository_policy_is_rejected" {
  command = plan

  variables {
    policy = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
  }

  expect_failures = [var.enable_repository_policy]
}

run "defaults_are_secure" {
  command = plan

  assert {
    condition     = aws_ecr_repository.resource.image_tag_mutability == "IMMUTABLE"
    error_message = "Tags should be immutable by default so a tag names exactly one image."
  }

  assert {
    condition     = one(aws_ecr_repository.resource.image_scanning_configuration).scan_on_push
    error_message = "Basic vulnerability scanning should run on push by default."
  }

  assert {
    condition     = one(aws_ecr_repository.resource.encryption_configuration).encryption_type == "AES256"
    error_message = "Encryption at rest should default to AES256, which costs nothing."
  }

  assert {
    condition     = aws_ecr_repository.resource.force_delete == false
    error_message = "force_delete should default to false so a destroy cannot silently discard images."
  }

  assert {
    condition     = length(aws_ecr_lifecycle_policy.resource) == 0
    error_message = "No lifecycle policy should be created until a retention rule is asked for."
  }

  assert {
    condition     = length(aws_ecr_repository_policy.resource) == 0
    error_message = "No repository policy should be created by default."
  }
}

run "name_generated_when_unset" {
  command = apply

  assert {
    condition     = aws_ecr_repository.resource.name == "repository-${random_uuid.resource.id}"
    error_message = "Leaving name unset should fall back to a prefixed random_uuid."
  }
}

run "name_explicit_overrides_generated" {
  command = plan

  variables {
    name = "platform/api"
  }

  assert {
    condition     = aws_ecr_repository.resource.name == "platform/api"
    error_message = "An explicit name should be used as-is instead of the generated one."
  }
}

run "kms_encryption_passes_the_key_through" {
  command = plan

  variables {
    encryption_type = "KMS"
    kms_key         = "arn:aws:kms:us-east-1:123456789012:key/example"
  }

  assert {
    condition     = one(aws_ecr_repository.resource.encryption_configuration).kms_key == "arn:aws:kms:us-east-1:123456789012:key/example"
    error_message = "An explicit kms_key should reach the encryption configuration unchanged."
  }
}

run "kms_encryption_without_a_key_is_allowed" {
  command = plan

  variables {
    encryption_type = "KMS"
  }

  assert {
    condition     = one(aws_ecr_repository.resource.encryption_configuration).encryption_type == "KMS"
    error_message = "encryption_type = 'KMS' without a kms_key should select the AWS managed key rather than fail."
  }
}

run "untagged_expiry_generates_one_rule" {
  command = plan

  variables {
    expire_untagged_after_days = 14
  }

  assert {
    condition     = length(jsondecode(aws_ecr_lifecycle_policy.resource[0].policy).rules) == 1
    error_message = "Setting only expire_untagged_after_days should generate exactly one rule."
  }

  assert {
    condition     = jsondecode(aws_ecr_lifecycle_policy.resource[0].policy).rules[0].selection.tagStatus == "untagged"
    error_message = "The generated untagged rule should select untagged images."
  }

  assert {
    condition     = jsondecode(aws_ecr_lifecycle_policy.resource[0].policy).rules[0].selection.countNumber == 14
    error_message = "The generated untagged rule should expire images after the configured number of days."
  }
}

run "max_image_count_rule_sorts_after_the_untagged_rule" {
  command = plan

  variables {
    expire_untagged_after_days = 14
    max_image_count            = 30
  }

  assert {
    condition     = length(jsondecode(aws_ecr_lifecycle_policy.resource[0].policy).rules) == 2
    error_message = "Both retention inputs together should generate two rules."
  }

  assert {
    condition     = jsondecode(aws_ecr_lifecycle_policy.resource[0].policy).rules[1].selection.tagStatus == "any"
    error_message = "ECR requires the rule selecting every tag status to carry the highest rulePriority, so it must come last."
  }

  assert {
    condition     = jsondecode(aws_ecr_lifecycle_policy.resource[0].policy).rules[1].rulePriority > jsondecode(aws_ecr_lifecycle_policy.resource[0].policy).rules[0].rulePriority
    error_message = "The image-count rule's priority should be higher than the untagged rule's."
  }
}

run "explicit_lifecycle_policy_replaces_the_generated_one" {
  command = plan

  variables {
    lifecycle_policy = "{\"rules\":[{\"rulePriority\":1,\"selection\":{\"tagStatus\":\"tagged\",\"tagPrefixList\":[\"pr-\"],\"countType\":\"sinceImagePushed\",\"countUnit\":\"days\",\"countNumber\":7},\"action\":{\"type\":\"expire\"}}]}"
  }

  assert {
    condition     = jsondecode(aws_ecr_lifecycle_policy.resource[0].policy).rules[0].selection.tagPrefixList[0] == "pr-"
    error_message = "An explicit lifecycle_policy should be attached verbatim."
  }
}

run "repository_policy_attached_when_enabled" {
  command = plan

  variables {
    enable_repository_policy = true
    policy                   = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
  }

  assert {
    condition     = length(aws_ecr_repository_policy.resource) == 1
    error_message = "Enabling the repository policy should create exactly one policy resource."
  }

  assert {
    condition     = aws_ecr_repository_policy.resource[0].repository == aws_ecr_repository.resource.name
    error_message = "The repository policy should attach to this module's repository."
  }
}

run "readme_minimal" {
  command = plan

  variables {
    name = "platform/api"
  }
}

run "readme_retention" {
  command = plan

  variables {
    name                       = "platform/api"
    expire_untagged_after_days = 14
    max_image_count            = 30
  }
}

run "readme_customer_managed_key" {
  command = plan

  variables {
    name            = "platform/api"
    encryption_type = "KMS"
    kms_key         = "arn:aws:kms:us-east-1:123456789012:key/example"
  }
}

run "readme_cross_account_pull" {
  command = plan

  variables {
    name                     = "platform/api"
    enable_repository_policy = true

    policy = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"AllowCrossAccountPull\",\"Effect\":\"Allow\",\"Principal\":{\"AWS\":\"arn:aws:iam::123456789012:root\"},\"Action\":[\"ecr:BatchGetImage\",\"ecr:GetDownloadUrlForLayer\",\"ecr:BatchCheckLayerAvailability\"]}]}"
  }
}

run "readme_mutable_tags" {
  command = plan

  variables {
    name                 = "platform/api"
    image_tag_mutability = "MUTABLE"
    force_delete         = true
  }
}
