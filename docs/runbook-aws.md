# Runbook：在 AWS RDS for SQL Server 上重現本專案

本專案平時跑在本機容器（`azure-sql-edge`）。這份 runbook 記錄如何把同一套綱要與 ETL
原封不動跑在 **AWS RDS for SQL Server Express** 上，以及跑完如何完整拆除。

設計前提是**短命環境**：開起來、跑完 ETL、留下證據、立刻銷毀。不是常駐服務。

---

## 0. 前置

| 項目 | 說明 |
|---|---|
| AWS CLI | `brew install awscli`，`aws configure` 設定憑證與 `ap-northeast-1` |
| Terraform | `brew install hashicorp/tap/terraform`（terraform 已從 homebrew-core 移除，須走官方 tap） |
| IAM 權限 | 套用 [`infra/aws/iam-policy-terraform-rds.json`](../infra/aws/iam-policy-terraform-rds.json)，見下節 |
| Python | `.venv` 內含 `pymssql`；ETL 連線參數全部走環境變數 |

### IAM 權限設計

政策刻意只給這個部署會用到的動作，兩個關鍵收斂：

- **`RegionLock`**：除全球服務外，任何非 `ap-northeast-1` 的 API 一律 Deny。
  改部署區域時**必須同步改這個條件**，否則所有呼叫會被自己的政策擋掉。
- **`RdsServiceLinkedRole`**：唯一的 IAM 寫入權限，且資源鎖死到
  `role/aws-service-role/rds.amazonaws.com/AWSServiceRoleForRDS` 這一條路徑。
  新帳號第一次開 RDS 需要這個角色；不給的話 `CreateDBInstance` 會回
  `Verify that you have permission to create service linked role`。

### 成本護欄

Terraform 這幾個設定是為了「不會在無人看管時長出費用」而寫的，改動前想清楚：

- `max_allocated_storage = 0`：關閉儲存自動擴充
- `backup_retention_period = 0` + `skip_final_snapshot = true`：destroy 後不留計費 snapshot
- `monitoring_interval = 0`、`performance_insights_enabled = false`：兩個額外收費項目
- `deletion_protection = false`：確保一次 destroy 就能清乾淨

另外在帳號層級設 **$5 月預算警示**（Billing → Budgets），這是唯一防止意外扣款的兜底機制。

---

## 1. 開環境

```bash
cd infra/aws
cp terraform.tfvars.example terraform.tfvars
# 填入自己的對外 IP：1433 只開給這一個位址
curl -s https://checkip.amazonaws.com

terraform init
terraform plan     # 確認是 5 個資源、沒有預期外的變更
terraform apply
```

建立耗時約 10–15 分鐘。產出：RDS 執行個體、DB 子網路群組、安全群組與其單一 ingress 規則、
以及 Terraform 產生的 24 碼主密碼（只存在本機 state，不進版控）。

**換網路（換 WiFi、開熱點）後會連不上**——安全群組綁的是舊 IP。
重新取得 IP 填回 `terraform.tfvars` 再 `terraform apply` 即可，只會改那一條規則。

---

## 2. 跑 ETL

ETL 的連線參數全部可由環境變數覆寫（見 `etl/db.py`），所以**不需要改任何程式碼**：

```bash
cd ../..                      # 回到 repo 根目錄
export DW_HOST=$(terraform -chdir=infra/aws output -raw db_host)
export DW_PORT=1433
export DW_USER=dwadmin
export DW_PASSWORD="$(terraform -chdir=infra/aws output -raw db_password)"

.venv/bin/python etl/run_etl.py
```

主使用者名稱用 `dwadmin` 而非本機預設的 `sa`——`sa` 是 RDS 保留字，不能當主使用者。

---

## 3. 拆除

```bash
terraform -chdir=infra/aws destroy
```

destroy 後**務必實查資源歸零**，不要只信 Terraform 的輸出：

```bash
aws rds describe-db-instances --query 'DBInstances[].DBInstanceIdentifier'
aws rds describe-db-snapshots --snapshot-type manual --query 'DBSnapshots[].DBSnapshotIdentifier'
aws ec2 describe-security-groups --filters Name=tag:Project,Values=dw-credit-star \
  --query 'SecurityGroups[].GroupId'
```

三個都該回空陣列。snapshot 那條特別重要：留下來的 snapshot 會**持續計費**，
而它不會出現在 RDS 執行個體清單裡，最容易被漏掉。

隔天再查一次當期花費：

```bash
aws ce get-cost-and-usage --time-period Start=$(date -v-2d +%F),End=$(date +%F) \
  --granularity DAILY --metrics UnblendedCost
```

---

## 4. 已知踩點

| 症狀 | 原因與解法 |
|---|---|
| `CreateDBInstance` 回 `Verify that you have permission to create service linked role` | 新帳號缺 `AWSServiceRoleForRDS`。補上政策裡的 `RdsServiceLinkedRole` 段 |
| 補完權限仍回 `Missing necessary credentials` | 角色剛建好、後端尚未生效。等幾分鐘重跑 apply 即可，不需改設定 |
| `plan` 階段報 `ec2:DescribeVpcAttribute` 未授權 | `data "aws_vpc" { default = true }` 會呼叫該 API。本專案改由子網路反推 VPC id 迴避 |
| 連線逾時 | 多半是換了網路、對外 IP 變了。重跑 `curl checkip` 更新 `terraform.tfvars` |
| `ModifyDBInstance` 回 `FreeTierRestrictionError` | 2025-07-15 後建立的帳號屬免費方案，**只能開最小規格**。要更大規格得把帳號轉付費方案 |
| ETL 跑到一半突然變超慢 | t3 的 CPU 積分耗盡（查 `CPUCreditBalance`，見下節）。免費方案下無解，只能等 |
| ETL 卡住不動、行程還活著但無輸出 | 連線已死而 pymssql 沒有讀取逾時，會無限等待。查 `sys.dm_exec_sessions` 若已無該連線即可確認；成因多半是筆電睡眠，用 `caffeinate -is` 執行可避免 |

### 效能預期：這個 ETL 在免費方案下要跑 3–5 小時

不是設定錯誤，是機型限制。`db.t3.micro` 是可爆發機型，載入約一小時後 CPU 積分歸零，
吞吐從 **250 列/秒掉到 13 列/秒**。診斷時看這三個指標就能確認瓶頸在 CPU 額度而非磁碟：

```bash
aws cloudwatch get-metric-statistics --namespace AWS/RDS \
  --metric-name CPUCreditBalance \
  --dimensions Name=DBInstanceIdentifier,Value=dw-credit-star \
  --start-time "$(date -u -v-1H +%FT%TZ)" --end-time "$(date -u +%FT%TZ)" \
  --period 300 --statistics Average
```

`CPUCreditBalance` 歸零、`CPUUtilization` 卻只有 35%、`WriteIOPS` 個位數 —— 三者同時成立
就是積分耗盡被限流。排程時直接預留一整晚，不要以為十幾分鐘會跑完。
