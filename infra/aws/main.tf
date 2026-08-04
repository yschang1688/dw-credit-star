# 預設 VPC 與其子網路。這個專案是「開起來跑完 ETL 就銷毀」的短命環境，
# 不自建 VPC——多開 NAT/IGW 只會增加成本與 destroy 時的殘留風險。
#
# 刻意不用 `data "aws_vpc" { default = true }`：它會呼叫 ec2:DescribeVpcAttribute，
# 而那不在本專案的最小權限 policy 裡。改從預設子網路反推 VPC id，
# 只需要 ec2:DescribeSubnets 一個唯讀權限。
data "aws_subnets" "default" {
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

data "aws_subnet" "first" {
  id = one(slice(sort(data.aws_subnets.default.ids), 0, 1))
}

# 密碼由 Terraform 產生，不經人手也不進版控。
# 值只存在本機 state（已 gitignore），要用時以 `terraform output` 取出。
resource "random_password" "master" {
  length  = 24
  special = true
  # RDS SQL Server 主密碼不接受 / @ " 與空白
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "aws_db_subnet_group" "this" {
  name       = "dw-credit-star"
  subnet_ids = data.aws_subnets.default.ids
}

resource "aws_security_group" "rds" {
  name        = "dw-credit-star-rds"
  description = "Allow SQL Server from a single operator IP"
  vpc_id      = data.aws_subnet.first.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "tds" {
  security_group_id = aws_security_group.rds.id
  description       = "TDS from operator only"
  cidr_ipv4         = var.allowed_cidr
  from_port         = 1433
  to_port           = 1433
  ip_protocol       = "tcp"
}

resource "aws_db_instance" "dw" {
  identifier     = "dw-credit-star"
  engine         = "sqlserver-ex"
  engine_version = var.engine_version
  license_model  = "license-included"
  instance_class = var.instance_class

  allocated_storage     = var.allocated_storage
  max_allocated_storage = 0 # 關閉 storage autoscaling——這是最容易在無人看管下長出費用的設定
  storage_type          = "gp3"
  storage_encrypted     = true

  username = var.master_username
  password = random_password.master.result
  port     = 1433

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = true # 從本機 ETL 直連；對外暴露面由 security group 收斂到單一 IP

  multi_az                = false
  backup_retention_period = 0 # 短命環境不留備份；也讓 destroy 不留 snapshot 計費
  skip_final_snapshot     = true
  deletion_protection     = false
  apply_immediately       = true

  auto_minor_version_upgrade   = false
  monitoring_interval          = 0 # 關閉 Enhanced Monitoring（額外收費）
  performance_insights_enabled = false
}
