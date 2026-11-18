locals {
  prefix = "${var.project_name}-${var.environment}"
}

# --- S3 Medallion Buckets ---
resource "aws_s3_bucket" "bronze" {
  bucket        = "${local.prefix}-bronze"
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "bronze" {
  bucket = aws_s3_bucket.bronze.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket" "silver" {
  bucket        = "${local.prefix}-silver"
  force_destroy = true
}

resource "aws_s3_bucket" "gold" {
  bucket        = "${local.prefix}-gold"
  force_destroy = true
}

# --- DynamoDB Idempotency & Audit Table ---
resource "aws_dynamodb_table" "control" {
  name         = "${local.prefix}-ingestion-control"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "file_id"

  attribute {
    name = "file_id"
    type = "S"
  }
}

# --- SQS Dead Letter Queue & Main Ingestion Queue ---
resource "aws_sqs_queue" "dlq" {
  name                      = "${local.prefix}-ingestion-dlq"
  message_retention_seconds = 1209600 # 14 days
}

resource "aws_sqs_queue" "ingestion" {
  name                       = "${local.prefix}-ingestion-queue"
  visibility_timeout_seconds = 60
  receive_wait_time_seconds  = 10

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 3
  })
}

resource "aws_sqs_queue_policy" "allow_s3" {
  queue_url = aws_sqs_queue.ingestion.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "s3.amazonaws.com" }
        Action    = "sqs:SendMessage"
        Resource  = aws_sqs_queue.ingestion.arn
        Condition = {
          ArnEquals = {
            "aws:SourceArn" = aws_s3_bucket.bronze.arn
          }
        }
      }
    ]
  })
}

# --- S3 Event Notification -> SQS ---
resource "aws_s3_bucket_notification" "bronze_upload" {
  bucket = aws_s3_bucket.bronze.id

  queue {
    queue_arn     = aws_sqs_queue.ingestion.arn
    events        = ["s3:ObjectCreated:*"]
    filter_prefix = "raw/"
    filter_suffix = ".jsonl"
  }

  depends_on = [aws_sqs_queue_policy.allow_s3]
}
