variable "project" {
  description = "Name prefix applied to every resource and to the Project tag."
  type        = string
  default     = "cdc-pipeline"
}

variable "aws_region" {
  description = "AWS region. Phase 1 used us-east-1; keep it here unless you know why."
  type        = string
  default     = "us-east-1"
}

variable "my_ip_cidr" {
  description = "Your public IP in CIDR form (e.g. 1.2.3.4/32). Grants SSH to the EC2 SG only."
  type        = string

  validation {
    condition     = can(regex("^[0-9.]+/32$", var.my_ip_cidr))
    error_message = "my_ip_cidr must be a single-host CIDR like 1.2.3.4/32."
  }
}

variable "public_key_path" {
  description = "Path to the SSH public key to register with EC2."
  type        = string
  default     = "~/.ssh/cdc-pipeline.pub"
}

variable "ec2_instance_type" {
  description = "EC2 instance type. t3.micro is free-tier eligible."
  type        = string
  default     = "t3.micro"
}

variable "db_instance_class" {
  description = "RDS instance class. db.t3.micro is free-tier eligible."
  type        = string
  default     = "db.t3.micro"
}

variable "db_engine_version" {
  description = "Postgres major version on RDS. Phase 1 used Postgres 16."
  type        = string
  default     = "16.4"
}

variable "db_name" {
  description = "Initial database created inside the RDS instance."
  type        = string
  default     = "cdc"
}

variable "db_master_user" {
  description = "RDS master username."
  type        = string
  default     = "postgres"
}

variable "db_master_password" {
  description = "RDS master password. Set via terraform.tfvars (gitignored)."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.db_master_password) >= 12
    error_message = "db_master_password must be at least 12 characters."
  }
}
