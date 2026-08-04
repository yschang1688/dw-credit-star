variable "region" {
  description = "部署區域。改這裡的話，IAM policy 的 RegionLock 條件也要一起改，否則所有 API 會被 Deny。"
  type        = string
  default     = "ap-northeast-1"
}

variable "allowed_cidr" {
  description = <<-EOT
    唯一允許連 1433 的來源 CIDR，填自己的對外 IP 加 /32。
    取得方式：curl -s https://checkip.amazonaws.com
    刻意不給預設值——漏填會在 plan 階段就報錯，比預設成 0.0.0.0/0 安全。
  EOT
  type        = string

  validation {
    condition     = var.allowed_cidr != "0.0.0.0/0"
    error_message = "不接受 0.0.0.0/0：這台 RDS 是公開可達的，開全世界等於把 SQL Server 掛上網路。"
  }
}

variable "instance_class" {
  description = <<-EOT
    RDS 執行個體規格。db.t3.micro 是 sqlserver-ex 在東京可開的最小規格。

    ⚠️ 免費方案帳號改不了這個值。2025-07-15 之後建立的帳號屬「free plan」，
    只能開最小規格；填 db.t3.medium 會在 ModifyDBInstance 階段被擋下：
      FreeTierRestrictionError: This instance size isn't available with free
      plan accounts. To remove all limitations, upgrade your account plan.
    要開更大規格必須把帳號轉成付費方案——那是帳務決定，不是這份設定能解的。

    效能實測（t3.micro，18 萬列 ETL）：t3 是可爆發機型，載入約一小時後
    CPU 積分耗盡，吞吐從 250 列/秒掉到 13 列/秒
    （CPUCreditBalance 歸零、CPUUtilization 僅 35%、WriteIOPS 個位數
    ——瓶頸是 CPU 額度，不是磁碟）。全程因此需要 3–5 小時而非十幾分鐘。
    這是免費方案下的已知代價，不是設定錯誤；預留足夠時間即可。
  EOT
  type        = string
  default     = "db.t3.micro"
}

variable "engine_version" {
  description = "SQL Server 2022 Express。專案本機開發用 azure-sql-edge（2019 引擎），綱要與預存程序皆向上相容。"
  type        = string
  default     = "16.00.4255.1.v1"
}

variable "allocated_storage" {
  description = "儲存空間 GB。20 是 sqlserver-ex 的下限；18 萬列的資料量遠低於此。"
  type        = number
  default     = 20
}

variable "master_username" {
  description = "主使用者名稱。不能用 sa/admin（RDS 保留字），ETL 端以 DW_USER 覆寫。"
  type        = string
  default     = "dwadmin"
}
