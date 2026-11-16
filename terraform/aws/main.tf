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

resource "aws_iam_role" "pfm_forecast_engine_irsa" {
  name = "pfm-forecast-engine-go-irsa-${var.environment}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
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
        Resource = ["arn:aws:kafka:*:*:topic/pfm-kafka/*/ledger.entry.committed"]
      },
      {
        Sid      = "ElastiCacheValkeyConnect"
        Effect   = "Allow"
        Action   = ["elasticache:Connect"]
        Resource = ["arn:aws:elasticache:*:*:replicationgroup:pfm-forecast-valkey-*"]
      }
    ]
  })
}
