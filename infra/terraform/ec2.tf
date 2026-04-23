data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-kernel-6.1-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_key_pair" "main" {
  key_name   = var.project
  public_key = file(pathexpand(var.public_key_path))
}

# Trust policy: EC2 assumes this role.
data "aws_iam_policy_document" "ec2_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# Least-privilege policy for the Confluent S3 sink connector. Scoped to the
# events bucket only. Matches the verified-working IAM set from Phase 1.
data "aws_iam_policy_document" "ec2_s3" {
  statement {
    sid       = "ListBucket"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.events.arn]
  }

  statement {
    sid = "WriteObjects"
    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
    ]
    resources = ["${aws_s3_bucket.events.arn}/*"]
  }
}

resource "aws_iam_role" "ec2" {
  name               = "${var.project}-ec2"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
}

resource "aws_iam_role_policy" "ec2_s3" {
  name   = "${var.project}-ec2-s3"
  role   = aws_iam_role.ec2.id
  policy = data.aws_iam_policy_document.ec2_s3.json
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.project}-ec2"
  role = aws_iam_role.ec2.name
}

resource "aws_instance" "ec2" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.ec2_instance_type
  subnet_id              = data.aws_subnets.default.ids[0]
  vpc_security_group_ids = [aws_security_group.ec2.id]
  key_name               = aws_key_pair.main.key_name
  iam_instance_profile   = aws_iam_instance_profile.ec2.name

  associate_public_ip_address = true

  root_block_device {
    volume_size = 12
    volume_type = "gp3"
  }

  tags = {
    Name = "${var.project}-ec2"
  }
}
