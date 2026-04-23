# Random suffix makes the bucket name globally unique on first apply.
resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "events" {
  bucket = "${var.project}-events-${random_id.bucket_suffix.hex}"

  # force_destroy lets `terraform destroy` remove the bucket even if objects
  # remain. Reasonable for a learning project; remove for any real use.
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "events" {
  bucket = aws_s3_bucket.events.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
