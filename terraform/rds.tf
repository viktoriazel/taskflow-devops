# -----------------------------------------------------------------------------
# RDS PostgreSQL
# -----------------------------------------------------------------------------

resource "aws_db_subnet_group" "main" {
  name       = "${var.project_name}-${var.environment}-db-subnet-group"
  subnet_ids = [aws_subnet.private_db_1.id, aws_subnet.private_db_2.id]

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-db-subnet-group"
  })
}

# AWS RDS generates and manages the master password itself
# (manage_master_user_password = true). The password is stored in AWS
# Secrets Manager, not supplied by Terraform - no password input variable
# is used or needed here.
resource "aws_db_instance" "main" {
  identifier     = "${var.project_name}-${var.environment}-rds-postgres"
  engine         = "postgres"
  engine_version = "16"
  instance_class = "db.t3.micro"

  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  db_name                     = var.db_name
  username                    = var.db_username
  manage_master_user_password = true
  db_subnet_group_name        = aws_db_subnet_group.main.name

  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false

  # Learning-project trade-offs: no automated backups/PITR, no final
  # snapshot, and deletion protection disabled - so `terraform destroy`
  # cleans up RDS fully without manual steps. Not suitable for production.
  backup_retention_period = 0
  skip_final_snapshot     = true
  deletion_protection     = false
  multi_az                = false

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-rds-postgres"
  })
}
