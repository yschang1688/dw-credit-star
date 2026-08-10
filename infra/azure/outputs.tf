output "server_fqdn" {
  description = "連線主機名稱，填給 DW_HOST。"
  value       = azurerm_mssql_server.this.fully_qualified_domain_name
}

output "database_name" {
  description = "資料庫名稱，填給 DW_DATABASE。"
  value       = azurerm_mssql_database.dw.name
}

output "admin_username" {
  value = azurerm_mssql_server.this.administrator_login
}

output "admin_password" {
  description = "以 terraform output -raw admin_password 取出；不要貼進任何檔案。"
  value       = random_password.master.result
  sensitive   = true
}

output "connection_env" {
  description = "直接可貼的環境變數（密碼另取，故此處留空）。"
  value = join(" ", [
    "DW_PLATFORM=azure-sql",
    "DW_HOST=${azurerm_mssql_server.this.fully_qualified_domain_name}",
    "DW_PORT=1433",
    "DW_USER=${azurerm_mssql_server.this.administrator_login}",
    "DW_DATABASE=${azurerm_mssql_database.dw.name}",
  ])
}
