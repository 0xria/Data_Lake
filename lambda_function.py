import json
import logging
import os
from typing import Any, Dict

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

s3 = boto3.client("s3")
kms = boto3.client("kms")


RAW_BUCKET = os.environ["RAW_BUCKET"]
STAGING_BUCKET = os.environ["STAGING_BUCKET"]
CURATED_BUCKET = os.environ["CURATED_BUCKET"]
KMS_KEY_ARN = os.environ["KMS_KEY_ARN"]


def _validate_encryption(bucket: str, key: str) -> None:
  """
  Security+ mindset:
  - Ensure objects are encrypted with KMS before further processing.
  - Fail closed: if encryption is not as expected, stop and log.
  """
  head = s3.head_object(Bucket=bucket, Key=key)
  sse = head.get("ServerSideEncryption")
  kms_key = head.get("SSEKMSKeyId")

  if sse != "aws:kms" or not kms_key or not kms_key.endswith(KMS_KEY_ARN.split("/")[-1]):
    raise RuntimeError(
      f"Insecure object encryption for s3://{bucket}/{key}: "
      f"sse={sse}, kms_key={kms_key}"
    )


def _copy_to_staging(bucket: str, key: str) -> None:
  source = {"Bucket": bucket, "Key": key}
  dest_key = key

  s3.copy_object(
    Bucket=STAGING_BUCKET,
    Key=dest_key,
    CopySource=source,
    ServerSideEncryption="aws:kms",
    SSEKMSKeyId=KMS_KEY_ARN,
    MetadataDirective="COPY",
  )


def lambda_handler(event: Dict[str, Any], context: Any) -> Dict[str, Any]:
  """
  Triggered by S3 `ObjectCreated` events on the RAW bucket.
  - Verifies encryption
  - Copies validated objects to STAGING with enforced KMS encryption
  """
  logger.info("Received event: %s", json.dumps(event))

  for record in event.get("Records", []):
    bucket = record["s3"]["bucket"]["name"]
    key = record["s3"]["object"]["key"]

    if bucket != RAW_BUCKET:
      logger.warning("Ignoring event from unexpected bucket: %s", bucket)
      continue

    _validate_encryption(bucket, key)
    _copy_to_staging(bucket, key)

  return {"statusCode": 200, "body": "Processed records"}

