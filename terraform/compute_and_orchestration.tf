# --- Packaging Lambdas ---
data "archive_file" "silver_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../lambdas/silver_processor"
  output_path = "${path.module}/../dist/silver_processor.zip"
}

data "archive_file" "gold_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../lambdas/gold_aggregator"
  output_path = "${path.module}/../dist/gold_aggregator.zip"
}

# --- IAM Role & Policies for Lambdas ---
resource "aws_iam_role" "lambda_exec" {
  name = "${local.prefix}-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action    = "sts:AssumeRole"
        Effect    = "Allow"
        Principal = { Service = "lambda.amazonaws.com" }
      }
    ]
  })
}

resource "aws_iam_role_policy" "lambda_policy" {
  name = "${local.prefix}-lambda-policy"
  role = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"]
        Resource = [
          aws_s3_bucket.bronze.arn,
          "${aws_s3_bucket.bronze.arn}/*",
          aws_s3_bucket.silver.arn,
          "${aws_s3_bucket.silver.arn}/*",
          aws_s3_bucket.gold.arn,
          "${aws_s3_bucket.gold.arn}/*"
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
        Resource = [aws_sqs_queue.ingestion.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:GetItem"]
        Resource = [aws_dynamodb_table.control.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = ["arn:aws:logs:*:*:*"]
      }
    ]
  })
}

# --- Lambda Functions ---
resource "aws_lambda_function" "silver_processor" {
  function_name    = "${local.prefix}-silver-processor"
  role             = aws_iam_role.lambda_exec.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  timeout          = 30
  memory_size      = 256
  filename         = data.archive_file.silver_zip.output_path
  source_code_hash = data.archive_file.silver_zip.output_base64sha256

  environment {
    variables = {
      AWS_ENDPOINT_URL = var.internal_localstack_endpoint
      SILVER_BUCKET    = aws_s3_bucket.silver.bucket
      CONTROL_TABLE    = aws_dynamodb_table.control.name
    }
  }
}

resource "aws_lambda_event_source_mapping" "sqs_to_silver" {
  event_source_arn = aws_sqs_queue.ingestion.arn
  function_name    = aws_lambda_function.silver_processor.arn
  batch_size       = 5
  enabled          = true
}

resource "aws_lambda_function" "gold_aggregator" {
  function_name    = "${local.prefix}-gold-aggregator"
  role             = aws_iam_role.lambda_exec.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  timeout          = 30
  memory_size      = 256
  filename         = data.archive_file.gold_zip.output_path
  source_code_hash = data.archive_file.gold_zip.output_base64sha256

  environment {
    variables = {
      AWS_ENDPOINT_URL = var.internal_localstack_endpoint
      SILVER_BUCKET    = aws_s3_bucket.silver.bucket
      GOLD_BUCKET      = aws_s3_bucket.gold.bucket
    }
  }
}

# --- Step Functions State Machine (Gold Orchestration) ---
resource "aws_iam_role" "sfn_exec" {
  name = "${local.prefix}-sfn-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action    = "sts:AssumeRole"
        Effect    = "Allow"
        Principal = { Service = "states.amazonaws.com" }
      }
    ]
  })
}

resource "aws_iam_role_policy" "sfn_policy" {
  name = "${local.prefix}-sfn-policy"
  role = aws_iam_role.sfn_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction"]
        Resource = [aws_lambda_function.gold_aggregator.arn]
      }
    ]
  })
}

resource "aws_sfn_state_machine" "gold_workflow" {
  name     = "${local.prefix}-gold-workflow"
  role_arn = aws_iam_role.sfn_exec.arn

  definition = jsonencode({
    Comment = "Orchestrates Gold layer financial KPI aggregation"
    StartAt = "AggregateGoldKPIs"
    States = {
      AggregateGoldKPIs = {
        Type     = "Task"
        Resource = aws_lambda_function.gold_aggregator.arn
        Retry = [
          {
            ErrorEquals     = ["States.TaskFailed"]
            IntervalSeconds = 2
            MaxAttempts     = 2
            BackoffRate     = 2.0
          }
        ]
        End = true
      }
    }
  })
}
