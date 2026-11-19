terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.15"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.33"
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

variable "eks_cluster_name" {
  type        = string
  default     = ""
  description = "Optional override for EKS cluster name"
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
  eks_cluster_name  = coalesce(var.eks_cluster_name, try(data.terraform_remote_state.shared.outputs.eks_cluster_name, "pfm-eks-prod"))
  oidc_provider_arn = coalesce(var.oidc_provider_arn, try(data.terraform_remote_state.shared.outputs.oidc_provider_arn, ""))
  oidc_issuer_url   = coalesce(var.oidc_issuer_url, try(data.terraform_remote_state.shared.outputs.oidc_issuer_url, ""))
}

data "aws_eks_cluster" "eks" {
  name = local.eks_cluster_name
}

data "aws_eks_cluster_auth" "eks" {
  name = local.eks_cluster_name
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.eks.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.eks.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.eks.token
}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.eks.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.eks.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.eks.token
  }
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

resource "kubernetes_service_account_v1" "pfm_forecast_engine_sa" {
  metadata {
    name      = "pfm-forecast-engine-sa"
    namespace = "pfm-platform"
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.pfm_forecast_engine_irsa.arn
    }
  }
}

resource "helm_release" "pfm_forecast_engine" {
  name             = "pfm-forecast-engine-go"
  chart            = "${path.module}/../../helm"
  namespace        = "pfm-platform"
  create_namespace = false
  wait             = false
  values           = [file("${path.module}/../../helm/values-prod.yaml")]

  set {
    name  = "replicaCount"
    value = "1"
  }

  set {
    name  = "image.repository"
    value = "public.ecr.aws/docker/library/busybox"
  }

  set {
    name  = "image.tag"
    value = "1.36"
  }

  set {
    name  = "command[0]"
    value = "sh"
  }

  set {
    name  = "command[1]"
    value = "-c"
  }

  set {
    name  = "command[2]"
    value = "sleep infinity"
  }

  set {
    name  = "serviceAccountName"
    value = kubernetes_service_account_v1.pfm_forecast_engine_sa.metadata[0].name
  }

  depends_on = [kubernetes_service_account_v1.pfm_forecast_engine_sa]
}

output "irsa_role_arn" {
  description = "IAM Role ARN for pfm-forecast-engine-go ServiceAccount"
  value       = aws_iam_role.pfm_forecast_engine_irsa.arn
}
