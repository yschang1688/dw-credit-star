output "server_fqdn" {
  description = "連線主機名稱，填給 DW_HOST。"
  value       = azurerm_mssql_server.this.fully_qualified_domain_name
}

output "database_name" {
  description = <<-EOT
    資料庫名稱，填給 DW_DATABASE。

    刻意取自 local 而非 azurerm_mssql_database.dw——走 Free Offer 時那個資源
    count = 0，若在此引用它，output 會在最需要它的那條路上直接壞掉。
  EOT
  value       = local.database_name
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
    "DW_DATABASE=${local.database_name}",
  ])
}

output "free_offer_create_command" {
  description = <<-EOT
    走 Free Offer 時（use_free_offer = true）要自己執行的建庫指令。
    走一般計費時（false）此值為說明字串，因為資料庫已由 Terraform 建好。

    參數依 `az sql db create` 官方範例：
      -e GeneralPurpose -f Gen5 --compute-model Serverless
      --use-free-limit --free-limit-exhaustion-behavior AutoPause

    `AutoPause` 是額度用完後暫停到下個月；另一個值 `BillOverUsage` 會開始計費
    且**不可逆**。這裡固定寫死 AutoPause，不做成變數——
    **一個不可逆又會產生帳單的選項，不應該是一個打錯字就會踩到的參數。**
  EOT
  value = var.use_free_offer ? join(" ", [
    "az sql db create",
    "-g ${azurerm_resource_group.this.name}",
    "-s ${azurerm_mssql_server.this.name}",
    "-n ${local.database_name}",
    "-e GeneralPurpose -f Gen5 -c 1",
    "--compute-model Serverless",
    "--auto-pause-delay ${var.auto_pause_minutes}",
    "--min-capacity 0.5",
    "--backup-storage-redundancy Local",
    "--collation SQL_Latin1_General_CP1_CI_AS",
    "--use-free-limit --free-limit-exhaustion-behavior AutoPause",
  ]) : "use_free_offer = false：資料庫已由 Terraform 建立，不需要這道指令。"
}
