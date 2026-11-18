terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

variable "environment" {
  type    = string
  default = "prod"
}

variable "aws_region" {
  type    = string
  default = "us-east-2"
}

variable "shared_state_bucket" {
  type        = string
  default     = "sorobanerp-pfm-tfstate-us-east-2-366476833548"
  description = "S3 bucket storing pfm-shared-infra remote state"
}

variable "oidc_provider_arn" {
  type        = string
  default     = ""
  description = "Optional override for EKS OIDC Provider ARN"
}

variable "oidc_issuer_url" {
  type        = string
  default     = ""
  description = "Optional override for EKS OIDC Issuer URL without https://"
}

provider "aws" {
  region = var.aws_region
}

data "terraform_remote_state" "shared" {
  backend = "s3"
  config = {
    bucket = var.shared_state_bucket
    key    = "pfm-shared-infra/terraform.tfstate"
    region = var.aws_region
  }
}

locals {
  oidc_provider_arn = coalesce(var.oidc_provider_arn, try(data.terraform_remote_state.shared.outputs.oidc_provider_arn, ""))
  oidc_issuer_url   = coalesce(var.oidc_issuer_url, try(data.terraform_remote_state.shared.outputs.oidc_issuer_url, ""))
}

resource "aws_iam_role" "pfm_forecast_engine_irsa" {
  name = "pfm-forecast-engine-go-irsa-${var.environment}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = local.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_issuer_url}:sub" = "system:serviceaccount:pfm-platform:pfm-forecast-engine-sa"
          "${local.oidc_issuer_url}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "pfm_forecast_engine_least_privilege" {
  name = "pfm-forecast-engine-kafka-valkey-policy"
  role = aws_iam_role.pfm_forecast_engine_irsa.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ConsumeLedgerEntryCommittedOnly"
        Effect   = "Allow"
        Action   = ["kafka-cluster:Connect", "kafka-cluster:DescribeTopic", "kafka-cluster:ReadData"]
        Resource = ["arn:aws:kafka:${var.aws_region}:*:topic/pfm-kafka/*/ledger.entry.committed"]
      },
      {
        Sid      = "ElastiCacheValkeyConnect"
        Effect   = "Allow"
        Action   = ["elasticache:Connect"]
        Resource = ["arn:aws:elasticache:${var.aws_region}:*:replicationgroup:pfm-forecast-valkey-*"]
      }
    ]
  })
}

output "irsa_role_arn" {
  description = "IAM Role ARN for pfm-forecast-engine-go ServiceAccount"
  value       = aws_iam_role.pfm_forecast_engine_irsa.arn
}
