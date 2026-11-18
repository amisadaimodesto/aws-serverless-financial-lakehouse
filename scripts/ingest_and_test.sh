#!/usr/bin/env bash
set -euo pipefail

export AWS_ACCESS_KEY_ID="test"
export AWS_SECRET_ACCESS_KEY="test"
export AWS_DEFAULT_REGION="us-east-1"
ENDPOINT="http://localhost:4566"

BRONZE_BUCKET="fin-lakehouse-dev-bronze"
SILVER_BUCKET="fin-lakehouse-dev-silver"
GOLD_BUCKET="fin-lakehouse-dev-gold"
CONTROL_TABLE="fin-lakehouse-dev-ingestion-control"
SFN_ARN="arn:aws:states:us-east-1:000000000000:stateMachine:fin-lakehouse-dev-gold-workflow"

BATCH_FILE="/tmp/transactions_batch_001.jsonl"

cat << 'DATA' > "$BATCH_FILE"
{"transaction_id": "TXN-1001", "account_id": "ACC-901", "amount": 4500.50, "currency": "BRL", "status": "APPROVED", "timestamp": "2026-11-18T14:00:00Z"}
{"transaction_id": "TXN-1002", "account_id": "ACC-902", "amount": 18200.00, "currency": "BRL", "status": "APPROVED", "timestamp": "2026-11-18T14:02:10Z"}
{"transaction_id": "TXN-1003", "account_id": "ACC-903", "amount": 750.00, "currency": "BRL", "status": "DECLINED", "timestamp": "2026-11-18T14:05:30Z"}
{"transaction_id": "TXN-1004", "account_id": "ACC-904", "amount": 3200.00, "currency": "USD", "status": "APPROVED", "timestamp": "2026-11-18T14:08:00Z"}
{"transaction_id": "TXN-1005", "account_id": "ACC-905", "amount": 11500.75, "currency": "USD", "status": "PENDING", "timestamp": "2026-11-18T14:10:15Z"}
{"transaction_id": "TXN-BAD-1", "account_id": "ACC-998", "amount": -150.00, "currency": "BRL", "status": "APPROVED", "timestamp": "2026-11-18T14:12:00Z"}
{"transaction_id": "TXN-BAD-2", "account_id": "ACC-999", "amount": 900.00, "currency": "XYZ", "status": "APPROVED", "timestamp": "2026-11-18T14:15:00Z"}
DATA

echo "1) Uploading raw batch to Bronze S3..."
aws --endpoint-url="$ENDPOINT" s3 cp "$BATCH_FILE" "s3://${BRONZE_BUCKET}/raw/transactions_batch_001.jsonl"

echo "2) Waiting for SQS -> Lambda Silver execution..."
sleep 6

echo "3) Checking DynamoDB Ingestion Audit Table..."
aws --endpoint-url="$ENDPOINT" dynamodb scan --table-name "$CONTROL_TABLE" | jq '.Items'

echo "4) Listing Silver & Quarantine objects..."
aws --endpoint-url="$ENDPOINT" s3 ls "s3://${SILVER_BUCKET}" --recursive

echo "5) Triggering Step Functions Gold Workflow..."
EXEC_ARN=$(aws --endpoint-url="$ENDPOINT" stepfunctions start-execution \
  --state-machine-arn "$SFN_ARN" \
  --input '{"trigger": "manual-e2e-test"}' | jq -r '.executionArn')
echo "Execution ARN: $EXEC_ARN"

sleep 5
aws --endpoint-url="$ENDPOINT" stepfunctions describe-execution --execution-arn "$EXEC_ARN" | jq '{status, output}'

echo "6) Fetching Gold Layer KPI Summary..."
aws --endpoint-url="$ENDPOINT" s3 cp "s3://${GOLD_BUCKET}/kpis/financial_summary_latest.json" - | jq .
