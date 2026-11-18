import json
import os
import urllib.parse
from datetime import datetime, timezone
import boto3
from botocore.exceptions import ClientError

ENDPOINT_URL = os.environ.get("AWS_ENDPOINT_URL")
SILVER_BUCKET = os.environ["SILVER_BUCKET"]
CONTROL_TABLE = os.environ["CONTROL_TABLE"]

s3 = boto3.client("s3", endpoint_url=ENDPOINT_URL)
dynamodb = boto3.resource("dynamodb", endpoint_url=ENDPOINT_URL)
table = dynamodb.Table(CONTROL_TABLE)

REQUIRED_FIELDS = {"transaction_id", "account_id", "amount", "currency", "status", "timestamp"}


def validate_record(record: dict) -> tuple[bool, str]:
    missing = REQUIRED_FIELDS - set(record.keys())
    if missing:
        return False, f"Missing fields: {sorted(missing)}"
    try:
        amount = float(record["amount"])
        if amount <= 0:
            return False, "Amount must be greater than zero"
    except (ValueError, TypeError):
        return False, "Invalid numeric amount"
    if record["currency"] not in {"BRL", "USD", "EUR"}:
        return False, f"Unsupported currency: {record['currency']}"
    return True, "OK"


def lambda_handler(event, context):
    processed_files = 0

    for sqs_record in event.get("Records", []):
        body = json.loads(sqs_record["body"])
        for s3_event in body.get("Records", []):
            bucket = s3_event["s3"]["bucket"]["name"]
            key = urllib.parse.unquote_plus(s3_event["s3"]["object"]["key"])
            etag = s3_event["s3"]["object"].get("eTag", "no-etag")
            idempotency_key = f"{bucket}/{key}#{etag}"

            # Idempotency check in DynamoDB
            try:
                table.put_item(
                    Item={
                        "file_id": idempotency_key,
                        "status": "PROCESSING",
                        "updated_at": datetime.now(timezone.utc).isoformat(),
                    },
                    ConditionExpression="attribute_not_exists(file_id)",
                )
            except ClientError as e:
                if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
                    print(f"[SKIP] Already processed: {idempotency_key}")
                    continue
                raise

            obj = s3.get_object(Bucket=bucket, Key=key)
            raw_lines = obj["Body"].read().decode("utf-8").strip().splitlines()

            valid_records = []
            quarantine_records = []

            for idx, line in enumerate(raw_lines, start=1):
                try:
                    item = json.loads(line)
                except json.JSONDecodeError:
                    quarantine_records.append({"line": idx, "raw": line, "reason": "Malformed JSON"})
                    continue

                is_valid, reason = validate_record(item)
                if is_valid:
                    item["amount"] = round(float(item["amount"]), 2)
                    item["processed_at"] = datetime.now(timezone.utc).isoformat()
                    item["source_file"] = key
                    valid_records.append(item)
                else:
                    quarantine_records.append({"line": idx, "record": item, "reason": reason})

            base_name = os.path.basename(key).rsplit(".", 1)[0]
            date_partition = datetime.now(timezone.utc).strftime("year=%Y/month=%m/day=%d")

            if valid_records:
                silver_key = f"transactions/{date_partition}/{base_name}_clean.jsonl"
                silver_payload = "\n".join(json.dumps(r) for r in valid_records)
                s3.put_object(
                    Bucket=SILVER_BUCKET,
                    Key=silver_key,
                    Body=silver_payload.encode("utf-8"),
                    ContentType="application/x-ndjson",
                )

            if quarantine_records:
                quarantine_key = f"quarantine/{date_partition}/{base_name}_rejected.json"
                s3.put_object(
                    Bucket=SILVER_BUCKET,
                    Key=quarantine_key,
                    Body=json.dumps(quarantine_records, indent=2).encode("utf-8"),
                    ContentType="application/json",
                )

            table.update_item(
                Key={"file_id": idempotency_key},
                UpdateExpression="SET #s = :s, valid_count = :v, rejected_count = :r, updated_at = :u",
                ExpressionAttributeNames={"#s": "status"},
                ExpressionAttributeValues={
                    ":s": "COMPLETED",
                    ":v": len(valid_records),
                    ":r": len(quarantine_records),
                    ":u": datetime.now(timezone.utc).isoformat(),
                },
            )
            processed_files += 1
            print(f"[OK] {key} -> valid={len(valid_records)}, quarantine={len(quarantine_records)}")

    return {"statusCode": 200, "processed_files": processed_files}
