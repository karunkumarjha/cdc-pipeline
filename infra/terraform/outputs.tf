output "ec2_public_ip" {
  description = "Public IP of the pipeline EC2 instance."
  value       = aws_instance.ec2.public_ip
}

output "ec2_public_dns" {
  description = "Public DNS of the pipeline EC2 instance."
  value       = aws_instance.ec2.public_dns
}

output "rds_endpoint" {
  description = "RDS Postgres host (no port)."
  value       = aws_db_instance.pg.address
}

output "rds_port" {
  description = "RDS Postgres port."
  value       = aws_db_instance.pg.port
}

output "s3_bucket" {
  description = "S3 bucket where the Debezium S3 sink writes CDC events."
  value       = aws_s3_bucket.events.bucket
}

output "ssh_command" {
  description = "Copy-paste SSH command once the instance is reachable."
  value       = "ssh -i ~/.ssh/cdc-pipeline.pem ec2-user@${aws_instance.ec2.public_ip}"
}

output "cdc_env_hints" {
  description = "Values to drop into ~/.cdc-env for the Phase 1 bootstrap script."
  value = {
    PG_HOST     = aws_db_instance.pg.address
    PG_PORT     = aws_db_instance.pg.port
    PG_DATABASE = var.db_name
    PG_USER     = var.db_master_user
    S3_BUCKET   = aws_s3_bucket.events.bucket
    AWS_REGION  = var.aws_region
  }
}
