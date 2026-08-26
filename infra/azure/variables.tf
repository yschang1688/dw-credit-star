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

variable "use_free_offer" {
  description = <<-EOT
    走 SQL Database Free Offer（預設 true），還是走一般 serverless 計費（false）。

    **true（預設）**：Terraform 只建資源群組／邏輯伺服器／防火牆，**資料庫要自己用
    CLI 建**（見 `terraform output free_offer_create_command`）。理由是 azurerm
    provider 至今沒有 `use_free_limit` 與 `free_limit_exhaustion_behavior`
    這兩個參數（實查 provider 4.81.0 二進位檔：兩者 0 命中，而同檔的
    `auto_pause_delay_in_minutes` 有 2 命中、`min_capacity` 有 6 命中，
    對照組有值代表這個檢查是有效的）。
    **IaC 蓋不到的地方要講出來，不要假裝 Terraform 全包。**

    為什麼預設是它：Free Offer 每月 10 萬 vCore 秒＋32 GB 資料＋32 GB 備份，
    訂閱終身、每月重置；用完的預設行為是 `AutoPause`（暫停到下個月），
    要被收費必須自己改成 `BillOverUsage`，而且**改了不可逆**。
    也就是說**成本上限是硬的**——不是靠估算、也不是靠記得拆，是靠一個你不去做的動作。
    這正是本專案在 AWS／GCP 上一貫的原則（GCP 走無計費帳戶的 Sandbox、
    AWS 用完即拆並複驗歸零）在 Azure 上的等價物。

    **false**：Terraform 連資料庫一起建，走 `GP_S_Gen5_1` + auto-pause。
    少一個手動步驟，但閒置時仍有儲存費，上限是軟的。

    ⚠️ **區域會被鎖死**：同一訂閱下第一個 Free Offer 資料庫選定的區域，
    之後該訂閱所有 Free Offer 資料庫都固定在那個區域且不能改。第一次就要選對。

    ⚠️ **官方文件互相矛盾**：Free Offer 說明頁寫「每訂閱最多 10 個資料庫」，
    但 `az sql db create` 的 `--use-free-limit` 參數說明寫「Allowed on one
    database in a subscription」。本專案只需要一個，兩種說法都不影響；
    真要開第二個之前請自行實測，不要照抄這裡的任何一句。
  EOT
  type        = bool
  default     = true
}

variable "sku_name" {
  description = <<-EOT
    資料庫 SKU。預設 GP_S_Gen5_1（一般用途・無伺服器・1 vCore），
    搭配 auto_pause_delay 讓閒置時歸零計費——這個專案是「開起來跑完就銷毀」，
    不需要常駐。

    **僅在 `use_free_offer = false` 時生效**——走 Free Offer 時資料庫由 CLI 建立，
    規格參數在那道指令裡（見 `outputs.tf` 的 `free_offer_create_command`）。

    ⚠️ Azure 的「免費」有兩種，別搞混：
      1. 新帳號 30 天 $200 額度——過期就開始收費。
      2. **SQL Database Free Offer**（每月 10 萬 vCore 秒 + 32 GB 資料 + 32 GB 備份，
         **訂閱終身、每月重置**）。這條路由 `use_free_offer = true` 走。

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
