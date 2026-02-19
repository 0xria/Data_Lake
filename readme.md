## Project Outline

**Problem Statement**
  - Define why a secure cloud data landing zone is needed.
  - Identify data sources, sensitivity levels, and compliance concerns.

### Architecture

**S3 Buckets**:
  - `<prefix>-raw`: initial landing zone for data.
  - `<prefix>-staging`: validated data after Lambda checks.
  - `<prefix>-curated`: (future) cleaned/ready-for-analytics data.
**KMS**:
  - Dedicated CMK (`alias/data-lake-key`) for S3 server-side encryption (SSE-KMS).
**IAM**:
  - Bucket policy denying access to everyone except your IAM ARN (Security+ principle of least privilege).
  - Lambda execution role limited to S3, KMS, and CloudWatch Logs.
**Lambda**:
  - Triggered on `ObjectCreated` in the RAW bucket.
  - Verifies objects are encrypted with your KMS key.
  - Copies validated objects into STAGING with enforced KMS encryption.

### Files in this repo

- `terraform_main.tf`: main AWS resources (S3, KMS, IAM, Lambda, notifications).
- `terraform_variables.tf`: Terraform variables (region, bucket prefix, principal ARN, Lambda package path).
- `lambda_function.py`: Python Lambda that validates encryption and moves data raw → staging.
- `main.py`: (placeholder for future CLI or utilities).

### How to deploy (Terraform)

1. **Prereqs**
   - Install Terraform.
   - Configure `aws` CLI with your credentials (`aws configure`).
2. **Package the Lambda**
   - Option A (simplest): rely on AWS’ built-in `boto3` in the Python runtime:
     - `zip lambda_package.zip lambda_function.py`
   - Option B: if you add third‑party libs, vendor them into the zip.
3. **Init and apply**
   - In this folder, run:
     - `terraform init`
     - `terraform apply -var="bucket_name_prefix=<your-unique-prefix>" -var="lambda_package_path=lambda_package.zip"`
   - Optionally, lock buckets to a specific IAM principal:
     - Add `-var="principal_arn=arn:aws:iam::<account-id>:user/<your-user>"`

### How this ties to Security+ concepts

- **Least privilege**: bucket policy denies everyone except your principal; Lambda role has minimal permissions.
- **Encryption at rest**: all S3 buckets enforce SSE-KMS with your KMS key, and Lambda re-encrypts on copy.
- **Defense in depth**: S3 default encryption + Lambda validation + IAM restrictions.
- **Auditing**: you can add CloudTrail and S3 access logs on top of this baseline.
