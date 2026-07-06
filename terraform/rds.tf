# -----------------------------------------------------------------------------
# RDS PostgreSQL
# -----------------------------------------------------------------------------

resource "aws_db_subnet_group" "main" {
  name       = "${var.project_name}-${var.environment}-db-subnet-group"
  subnet_ids = [aws_subnet.private_db_1.id, aws_subnet.private_db_2.id]

  tags = {
    Name        = "${var.project_name}-${var.environment}-db-subnet-group"
    Project     = var.project_name
    Environment = var.environment
  }
}

# Master password is supplied via password_wo (write-only) + password_wo_version
# instead of a plain "password" argument, so the value is never written to
# terraform.tfstate or terraform plan output. db_password is declared
# ephemeral = true in variables.tf for the same reason. To rotate the
# password, change db_password and increment db_password_wo_version.
resource "aws_db_instance" "main" {
  identifier     = "${var.project_name}-${var.environment}-rds-postgres"
  engine         = "postgres"
  engine_version = "16"
  instance_class = "db.t3.micro"

  allocated_storage = 20
  storage_type      = "gp3"

  db_name              = var.db_name
  username             = var.db_username
  password_wo          = var.db_password
  password_wo_version  = var.db_password_wo_version
  db_subnet_group_name = aws_db_subnet_group.main.name

  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false

  # Learning-project trade-offs: no automated backups/PITR, no final
  # snapshot, and deletion protection disabled - so `terraform destroy`
  # cleans up RDS fully without manual steps. Not suitable for production.
  backup_retention_period = 0
  skip_final_snapshot     = true
  deletion_protection     = false
  multi_az                = false

  tags = {
    Name        = "${var.project_name}-${var.environment}-rds-postgres"
    Project     = var.project_name
    Environment = var.environment
  }
}
