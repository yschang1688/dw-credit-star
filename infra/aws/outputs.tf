output "db_host" {
  description = "RDS 端點主機名，餵給 ETL 的 DW_HOST"
  value       = aws_db_instance.dw.address
}

output "db_port" {
  value = aws_db_instance.dw.port
}

output "db_username" {
  value = aws_db_instance.dw.username
}

output "db_password" {
  description = "以 `terraform output -raw db_password` 取出"
  value       = random_password.master.result
  sensitive   = true
}

output "etl_env" {
  description = "貼進 shell 即可讓 etl/run_etl.py 指向 RDS（密碼另外取）"
  value       = <<-EOT
    export DW_HOST=${aws_db_instance.dw.address}
    export DW_PORT=${aws_db_instance.dw.port}
    export DW_USER=${aws_db_instance.dw.username}
    export DW_PASSWORD="$(terraform -chdir=infra/aws output -raw db_password)"
  EOT
}
