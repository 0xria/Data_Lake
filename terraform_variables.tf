variable "aws_region" {
  description = "AWS region to deploy the data lake into"
  type        = string
  default     = "us-east-1"
}

variable "bucket_name_prefix" {
  description = "Prefix for S3 bucket names (must be globally unique)"
  type        = string
}

variable "principal_arn" {
  description = "ARN of IAM user/role that should be the only human allowed to access data. Defaults to the current caller."
  type        = string
  default     = ""
}

variable "lambda_package_path" {
  description = "Path to the zipped Lambda deployment package"
  type        = string
}

