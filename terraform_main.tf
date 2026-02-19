terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

############################
# S3 Data Lake Buckets
############################

resource "aws_kms_key" "data_lake" {
  description             = "KMS key for data lake S3 encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = {
    Project = "security-minded-data-lake"
  }
}

resource "aws_kms_alias" "data_lake" {
  name          = "alias/data-lake-key"
  target_key_id = aws_kms_key.data_lake.key_id
}

locals {
  bucket_name_prefix = var.bucket_name_prefix
}

resource "aws_s3_bucket" "raw" {
  bucket = "${local.bucket_name_prefix}-raw"
}

resource "aws_s3_bucket" "staging" {
  bucket = "${local.bucket_name_prefix}-staging"
}

resource "aws_s3_bucket" "curated" {
  bucket = "${local.bucket_name_prefix}-curated"
}

resource "aws_s3_bucket_server_side_encryption_configuration" "raw" {
  bucket = aws_s3_bucket.raw.id

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.data_lake.arn
      sse_algorithm     = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "staging" {
  bucket = aws_s3_bucket.staging.id

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.data_lake.arn
      sse_algorithm     = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "curated" {
  bucket = aws_s3_bucket.curated.id

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.data_lake.arn
      sse_algorithm     = "aws:kms"
    }
  }
}

############################
# IAM: Lock buckets to you
############################

data "aws_caller_identity" "current" {}

locals {
  # Principal that is allowed to access the buckets.
  # For a single IAM user, use their ARN. By default we use the current identity.
  landing_zone_principal_arn = coalesce(var.principal_arn, data.aws_caller_identity.current.arn)
}

data "aws_iam_policy_document" "bucket_policy" {
  statement {
    sid    = "AllowOnlyLandingZonePrincipal"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
    ]

    resources = [
      aws_s3_bucket.raw.arn,
      "${aws_s3_bucket.raw.arn}/*",
      aws_s3_bucket.staging.arn,
      "${aws_s3_bucket.staging.arn}/*",
      aws_s3_bucket.curated.arn,
      "${aws_s3_bucket.curated.arn}/*",
    ]

    condition {
      test     = "StringNotEquals"
      variable = "aws:PrincipalArn"

      values = [local.landing_zone_principal_arn]
    }
  }
}

resource "aws_s3_bucket_policy" "data_lake" {
  bucket = aws_s3_bucket.raw.id
  policy = data.aws_iam_policy_document.bucket_policy.json
}

############################
# Lambda + IAM
############################

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "data_lake_lambda_role" {
  name               = "${local.bucket_name_prefix}-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

data "aws_iam_policy_document" "data_lake_lambda_policy" {
  statement {
    sid    = "S3Access"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:ListBucket",
    ]
    resources = [
      aws_s3_bucket.raw.arn,
      "${aws_s3_bucket.raw.arn}/*",
      aws_s3_bucket.staging.arn,
      "${aws_s3_bucket.staging.arn}/*",
      aws_s3_bucket.curated.arn,
      "${aws_s3_bucket.curated.arn}/*",
    ]
  }

  statement {
    sid    = "KMSDecrypt"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:Encrypt",
      "kms:GenerateDataKey",
    ]
    resources = [aws_kms_key.data_lake.arn]
  }

  statement {
    sid    = "Logging"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["arn:aws:logs:*:*:*"]
  }
}

resource "aws_iam_policy" "data_lake_lambda_policy" {
  name   = "${local.bucket_name_prefix}-lambda-policy"
  policy = data.aws_iam_policy_document.data_lake_lambda_policy.json
}

resource "aws_iam_role_policy_attachment" "data_lake_lambda_attach" {
  role       = aws_iam_role.data_lake_lambda_role.name
  policy_arn = aws_iam_policy.data_lake_lambda_policy.arn
}

resource "aws_lambda_function" "ingest" {
  function_name = "${local.bucket_name_prefix}-ingest"
  role          = aws_iam_role.data_lake_lambda_role.arn
  handler       = "lambda_function.lambda_handler"
  runtime       = "python3.12"

  filename         = var.lambda_package_path
  source_code_hash = filebase64sha256(var.lambda_package_path)

  environment {
    variables = {
      RAW_BUCKET     = aws_s3_bucket.raw.bucket
      STAGING_BUCKET = aws_s3_bucket.staging.bucket
      CURATED_BUCKET = aws_s3_bucket.curated.bucket
      KMS_KEY_ARN    = aws_kms_key.data_lake.arn
    }
  }
}

resource "aws_s3_bucket_notification" "raw_notifications" {
  bucket = aws_s3_bucket.raw.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.ingest.arn
    events              = ["s3:ObjectCreated:*"]
  }

  depends_on = [
    aws_lambda_function.ingest,
    aws_lambda_permission.allow_s3_invoke,
  ]
}

resource "aws_lambda_permission" "allow_s3_invoke" {
  statement_id  = "AllowExecutionFromS3"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ingest.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.raw.arn
}

