# Debezium needs logical replication; on RDS that means a custom parameter
# group with rds.logical_replication=1. Takes effect on instance reboot, which
# Terraform triggers automatically when the parameter group is first attached.
resource "aws_db_parameter_group" "pg" {
  name   = "${var.project}-pg16"
  family = "postgres16"

  parameter {
    name         = "rds.logical_replication"
    value        = "1"
    apply_method = "pending-reboot"
  }
}

resource "aws_db_subnet_group" "pg" {
  name       = "${var.project}-pg"
  subnet_ids = data.aws_subnets.default.ids
}

resource "aws_db_instance" "pg" {
  identifier = var.project

  engine         = "postgres"
  engine_version = var.db_engine_version
  instance_class = var.db_instance_class

  allocated_storage     = 20
  max_allocated_storage = 0
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = var.db_name
  username = var.db_master_user
  password = var.db_master_password
  port     = 5432

  vpc_security_group_ids = [aws_security_group.rds.id]
  db_subnet_group_name   = aws_db_subnet_group.pg.name
  parameter_group_name   = aws_db_parameter_group.pg.name
  publicly_accessible    = false
  multi_az               = false

  backup_retention_period  = 0
  skip_final_snapshot      = true
  delete_automated_backups = true
  apply_immediately        = true
}
