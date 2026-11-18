variable "aws_region" {
  description = "AWS region for deployment"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Prefix used across all cloud resources"
  type        = string
  default     = "fin-lakehouse"
}

variable "environment" {
  description = "Deployment environment"
  type        = string
  default     = "dev"
}

variable "localstack_endpoint" {
  description = "LocalStack gateway URL"
  type        = string
  default     = "http://localhost:4566"
}

variable "internal_localstack_endpoint" {
  description = "Internal endpoint used by Lambda containers to reach LocalStack"
  type        = string
  default     = "http://localstack:4566"
}
