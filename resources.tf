locals {
  untagged_rule = {
    rulePriority = 1
    description  = "Expire untagged images once they reach the configured age."

    selection = {
      tagStatus   = "untagged"
      countType   = "sinceImagePushed"
      countUnit   = "days"
      countNumber = var.expire_untagged_after_days
    }

    action = {
      type = "expire"
    }
  }

  image_count_rule = {
    rulePriority = 2
    description  = "Expire the oldest images beyond the configured retention count."

    selection = {
      tagStatus   = "any"
      countType   = "imageCountMoreThan"
      countNumber = var.max_image_count
    }

    action = {
      type = "expire"
    }
  }

  lifecycle_policy = (
    var.lifecycle_policy != null ? var.lifecycle_policy :
    var.expire_untagged_after_days != null && var.max_image_count != null ? jsonencode({ rules = [local.untagged_rule, local.image_count_rule] }) :
    var.expire_untagged_after_days != null ? jsonencode({ rules = [local.untagged_rule] }) :
    var.max_image_count != null ? jsonencode({ rules = [local.image_count_rule] }) :
    null
  )
}

resource "random_uuid" "resource" {}

resource "aws_ecr_repository" "resource" {
  name = coalesce(var.name, "repository-${random_uuid.resource.id}")

  image_tag_mutability = var.image_tag_mutability
  force_delete         = var.force_delete

  image_scanning_configuration {
    scan_on_push = var.scan_on_push
  }

  encryption_configuration {
    encryption_type = var.encryption_type
    kms_key         = var.kms_key
  }

  tags = var.tags
}

resource "aws_ecr_lifecycle_policy" "resource" {
  count = local.lifecycle_policy != null ? 1 : 0

  repository = aws_ecr_repository.resource.name
  policy     = local.lifecycle_policy
}

resource "aws_ecr_repository_policy" "resource" {
  count = var.enable_repository_policy ? 1 : 0

  repository = aws_ecr_repository.resource.name
  policy     = var.policy
}

output "id" {
  description = "The ID of the repository, which is its name."
  value       = aws_ecr_repository.resource.id
}

output "arn" {
  description = "The ARN of the repository. Grant a pulling task's IAM role ecr:BatchGetImage and ecr:GetDownloadUrlForLayer on this ARN."
  value       = aws_ecr_repository.resource.arn
}

output "name" {
  description = "The name of the repository. Every ECR API call identifies a repository by this name rather than by its ARN."
  value       = aws_ecr_repository.resource.name
}

output "repository_url" {
  description = "The URL of the repository, without a tag. Append a tag or digest and feed the result to an ECS container definition's image or a Kubernetes pod spec's image."
  value       = aws_ecr_repository.resource.repository_url
}

output "registry_id" {
  description = "The account ID of the registry holding the repository. Authenticating Docker against the registry needs this rather than the repository name."
  value       = aws_ecr_repository.resource.registry_id
}
