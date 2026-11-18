output "bronze_bucket" {
  value = aws_s3_bucket.bronze.bucket
}

output "silver_bucket" {
  value = aws_s3_bucket.silver.bucket
}

output "gold_bucket" {
  value = aws_s3_bucket.gold.bucket
}

output "ingestion_queue_url" {
  value = aws_sqs_queue.ingestion.url
}

output "control_table_name" {
  value = aws_dynamodb_table.control.name
}

output "gold_state_machine_arn" {
  value = aws_sfn_state_machine.gold_workflow.arn
}
