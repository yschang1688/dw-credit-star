variable "subscription_id" {
  description = <<-EOT
    Azure 訂閱 ID。取得方式：az account show --query id -o tsv
    刻意不給預設值——多訂閱帳號下猜錯訂閱會把資源開到別人的帳上。
  EOT
  type        = string
}

variable "location" {
  description = "部署區域。Free 方案的可用區域有限，東亞用 southeastasia 較穩（eastasia 常缺配額）。"
  type        = string
  default     = "southeastasia"
}

variable "allowed_ip" {
  description = <<-EOT
    唯一允許連 1433 的來源 IP（單一位址，非 CIDR）。
    取得方式：curl -s https://api.ipify.org
    刻意不給預設值——漏填會在 plan 階段報錯，比預設成 0.0.0.0 安全。
  EOT
  type        = string

  validation {
    condition     = var.allowed_ip != "0.0.0.0" && !can(regex("/", var.allowed_ip))
    error_message = "請填單一對外 IP（例 203.0.113.5），不要填 CIDR，也不接受 0.0.0.0。"
  }
}

variable "sku_name" {
  description = <<-EOT
    資料庫 SKU。預設 GP_S_Gen5_1（一般用途・無伺服器・1 vCore），
    搭配 auto_pause_delay 讓閒置時歸零計費——這個專案是「開起來跑完就銷毀」，
    不需要常駐。

    ⚠️ Azure 的「免費」有兩種，別搞混：
      1. 新帳號 30 天 $200 額度——過期就開始收費。
      2. **SQL Database Free Offer**（每月 10 萬 vCore 秒 + 32 GB 資料 + 32 GB 備份，
         **訂閱終身、每月重置**，每個訂閱最多 10 個資料庫）。

    **2026-08-11 更正**：本檔先前寫「Free Offer 用完會靜默轉為計費」——**那是錯的**。
    Free Offer 有一個明確設定 `Behavior when free limit reached`，兩個選項：
      - `AutoPause`：用完即暫停到下個月（**建立時的預設**）
      - `BillOverUsage`：超量계費，且**此選項不可逆**（設了就回不去 AutoPause）
    官方文件的原話是「You will not incur any charges unless you exceed these
    allowances **and you opt to pay** for usage beyond the free limits」——
    要收費得自己選，不是靜默發生。

    **但 Terraform 用不到 Free Offer**：azurerm provider 沒有 `use_free_limit`／
    `free_limit_exhaustion_behavior` 這兩個參數（已 grep 過 provider 自己的文件，
    只有 `auto_pause_delay_in_minutes`）。Free Offer 資料庫只能用 Portal／CLI 建。
    所以本目錄的 Terraform 走「serverless + auto-pause」，成本靠閒置歸零而非免費額度；
    要吃 Free Offer 就得改成混合式：Terraform 建資源群組／伺服器／防火牆，
    資料庫改用
      az sql db create --use-free-limit --free-limit-exhaustion-behavior AutoPause
    這件事寫在這裡而不是假裝 Terraform 全包——**IaC 覆蓋不到的地方要講出來**。

    無論哪種，跑完都要 terraform destroy 並實查資源歸零（見 runbook）。
  EOT
  type        = string
  default     = "GP_S_Gen5_1"
}

variable "max_size_gb" {
  description = "資料庫上限。18 萬列事實表 + 索引實際用不到 2 GB，給 32 GB 已寬裕。"
  type        = number
  default     = 32
}

variable "auto_pause_minutes" {
  description = <<-EOT
    閒置多久後自動暫停（分鐘）。暫停期間只算儲存費、不算運算費。
    最小值 60；設 -1 為停用自動暫停——**不要設 -1**，那等於常駐計費。
  EOT
  type        = number
  default     = 60

  validation {
    condition     = var.auto_pause_minutes >= 60
    error_message = "auto_pause_minutes 至少 60；設 -1（停用）會讓這個短命環境變成常駐帳單。"
  }
}

variable "master_username" {
  description = "伺服器管理員帳號。不得用 sa／admin／administrator，Azure 會直接拒絕。"
  type        = string
  default     = "dwadmin"
}
