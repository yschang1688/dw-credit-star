# Azure SQL Database 上的短命環境：開起來、跑完 ETL、留下證據、立刻銷毀。
#
# 與 AWS RDS 那份的關鍵差異（這正是「可攜性」要講的東西）：
#   - RDS 是「一台伺服器上的一個資料庫」，`CREATE DATABASE` 由 SQL 腳本自己做；
#     Azure SQL Database 的**資料庫本身就是一個資源**，由 Terraform 建立，
#     T-SQL 端的 CREATE DATABASE／USE 反而是語法錯誤。
#     ETL 側以 DW_PLATFORM=azure-sql 處理，見 etl/db.py。
#   - RDS 用安全群組限制來源；Azure 用伺服器層防火牆規則。
#   - RDS 的成本護欄是「關閉 storage autoscaling + 預算警示」；
#     Azure 的成本護欄是 serverless 的 auto-pause（閒置歸零運算費）。

resource "azurerm_resource_group" "this" {
  name     = "rg-dw-credit-star"
  location = var.location

  tags = {
    Project   = "dw-credit-star"
    ManagedBy = "terraform"
    Lifecycle = "ephemeral"
  }
}

# 密碼由 Terraform 產生，不經人手也不進版控。
# 值只存在本機 state（已 gitignore），要用時以 `terraform output` 取出。
resource "random_password" "master" {
  length = 24
  # Azure SQL 管理員密碼不接受這些字元，且要求四類字元中至少三類
  override_special = "!#$%&*()-_=+[]{}<>:?"
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
  min_special      = 2
}

resource "azurerm_mssql_server" "this" {
  name                          = "sql-dw-credit-star-${random_string.suffix.result}"
  resource_group_name           = azurerm_resource_group.this.name
  location                      = azurerm_resource_group.this.location
  version                       = "12.0" # 即 Azure SQL Database 的當前世代
  administrator_login           = var.master_username
  administrator_login_password  = random_password.master.result
  minimum_tls_version           = "1.2"
  public_network_access_enabled = true # 短命環境走公開端點 + 單一 IP 防火牆，不建 VNet
}

# 伺服器名稱是全域唯一的 DNS 標籤，固定名稱在重建時會撞名
resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

# 只開自己的對外 IP。刻意不加「允許 Azure 服務存取」那條規則——
# 它會放行整個 Azure 平台的出口 IP，不是「只有我的資源」。
resource "azurerm_mssql_firewall_rule" "operator" {
  name             = "operator-only"
  server_id        = azurerm_mssql_server.this.id
  start_ip_address = var.allowed_ip
  end_ip_address   = var.allowed_ip
}

resource "azurerm_mssql_database" "dw" {
  name        = "CreditRiskDW"
  server_id   = azurerm_mssql_server.this.id
  sku_name    = var.sku_name
  max_size_gb = var.max_size_gb
  collation   = "SQL_Latin1_General_CP1_CI_AS"

  # serverless 專屬：閒置自動暫停，暫停期間不計運算費
  auto_pause_delay_in_minutes = var.auto_pause_minutes
  min_capacity                = 0.5

  # 短命環境不需要異地備援；LRS 是最便宜且足夠的選項
  storage_account_type = "Local"

  # 跑完即銷毀，不留長備份
  short_term_retention_policy {
    retention_days = 1
  }

  lifecycle {
    # 這個資料庫是可重建的（整套綱要與 ETL 都在版控裡），
    # 不設 prevent_destroy——設了反而會讓 destroy 半途卡住、留下計費資源。
    prevent_destroy = false
  }
}
