# Runbook：在 Azure SQL Database 上重現本專案

同一套綱要與 ETL，第二朵雲。與 [AWS 版](runbook-aws.md) 對照著看，差異就是這份文件的重點。

設計前提同樣是**短命環境**：開起來、跑完 ETL、留下證據、立刻銷毀。

---

## 0. 前置

| 項目 | 說明 |
|---|---|
| Azure CLI | `brew install azure-cli`，`az login` |
| 訂閱 ID | `az account show --query id -o tsv`，填進 `terraform.tfvars` |
| 對外 IP | `curl -s https://api.ipify.org`，填進 `allowed_ip` |
| Terraform | `brew install hashicorp/tap/terraform` |
| Python | `.venv` 內含 `pymssql`；連線參數全部走環境變數 |

### 成本護欄

由 `var.use_free_offer` 決定走哪條路。**預設 `true`，走 Free Offer。**

#### 預設路徑：Free Offer + AutoPause（上限是硬的）

每月 10 萬 vCore 秒 ＋ 32 GB 資料 ＋ 32 GB 備份，訂閱終身、每月重置。
額度用完的預設行為是暫停到下個月；**要被收費必須自己把設定改成 `BillOverUsage`，
而且改了不可逆**。官方原話：「You will not incur any charges unless you exceed
these allowances **and you opt to pay** for usage beyond the free limits」。

換算一下這個專案吃掉多少：10 萬 vCore 秒 ＝ 0.5 vCore 跑 **55.6 小時**。
一次完整實跑（建綱要＋ETL＋驗證查詢＋60 分鐘 auto-pause 延遲）約 7,200 vCore 秒，
**佔月額度 7.2%**。失手重跑五次也才三成六。

> **這條路的意義不是省錢，是把上限變硬。** 省下的錢按當期東南亞牌價（實查
> 零售價 API：serverless GP Gen5 運算 US$0.620892／vCore-hour、GP 儲存
> US$0.138／GB/月）也不過一兩美金。真正的差別是：走這條路，**產生帳單需要你
> 主動做一個不可逆的動作**；不走，就只能靠估算與「記得拆」。
> 這與本專案在 GCP 上走無計費帳戶 Sandbox 是同一個原則。

#### 備用路徑：serverless + auto-pause（上限是軟的）

`use_free_offer = false` 時 Terraform 連資料庫一起建，`GP_S_Gen5_1` +
`auto_pause_delay_in_minutes = 60`。閒置一小時後自動暫停，暫停期間只算儲存費
（32 GB 約每月 US$4.4），不算運算費。少一個手動步驟，代價是上限靠設定與紀律。

`variables.tf` 有 validation 擋住 `-1`（停用自動暫停）——那等於把短命環境變成常駐帳單，
按牌價是 0.5 × 730 × US$0.620892 ≈ **US$227／月**。這就是那個 validation 的價目。

#### 兩條路都要的兩層

1. **`storage_account_type = "Local"`**：短命環境不需要異地備援。
2. **`terraform destroy` 後實查歸零**（見第 4 節）。這一層不能省——
   前面的護欄只是讓「忘了拆」的代價變小，沒有讓它變成零。
   **走 Free Offer 時更不能省**，因為資料庫不在 Terraform 的狀態裡（見第 4 節）。

### Azure 沒有 BigQuery Sandbox 的等價物（查證於官方文件，2026-08-11）

| | GCP BigQuery Sandbox | Azure |
|---|---|---|
| 信用卡 | **不需要** | **必要**（可用非預付簽帳金融卡；會有 $1 暫時授權）——這一項 Free Offer 也免不掉 |
| 成本上限的硬度 | **硬**（沒有計費帳戶＝不可能產生帳單） | **走 Free Offer 也是硬的**（計費需要一個不可逆的 opt-in）；走一般 serverless 才是軟的 |
| 額度形態 | 每月 1 TB 查詢／10 GB 儲存 | SQL DB Free Offer：每月 10 萬 vCore 秒＋32 GB 資料＋32 GB 備份 |
| 期限 | 表 60 天過期 | **訂閱終身、每月重置**，每訂閱最多 10 個資料庫 |

**2026-08-11 更正**：本文件先前寫「Free Offer 用完會靜默轉為計費」——**那是錯的**。
Free Offer 有明確的 `Behavior when free limit reached` 設定，兩個選項：
`AutoPause`（用完暫停到下個月，**建立時的預設**）與 `BillOverUsage`（超量計費，
**不可逆**）。官方原話：「You will not incur any charges unless you exceed these
allowances **and you opt to pay** for usage beyond the free limits」。

**但 Terraform 吃不到 Free Offer**：azurerm provider 沒有 `use_free_limit`／
`free_limit_exhaustion_behavior`（已 grep provider 自己的文件確認，只有
`auto_pause_delay_in_minutes`）。要用 Free Offer 就得走混合式——
Terraform 建資源群組／邏輯伺服器／防火牆，資料庫改用 CLI：

```bash
az sql db create -g rg-dw-credit-star -s <SERVER> -n CreditRiskDW \
  --use-free-limit --free-limit-exhaustion-behavior AutoPause
```

**2026-08-26 更新（本次改動）**：上面這段先前只是說明，實際預設走的是
「serverless + auto-pause」。現在**預設已改為 Free Offer**（`use_free_offer = true`），
理由見上方成本護欄——硬上限值得多一個 CLI 步驟。一般計費那條路仍以
`use_free_offer = false` 保留，兩條都在。

provider 缺參數這件事本次重新實查過（azurerm **4.81.0** 二進位檔）：
`use_free_limit` 與 `free_limit_exhaustion_behavior` 皆 **0 命中**，而對照組
`auto_pause_delay_in_minutes`（2 命中）、`min_capacity`（6 命中）有值——
**對照組有值，才代表這個檢查本身是有效的**，否則「grep 不到」只是探針壞了。

**IaC 覆蓋不到的地方寫出來，不假裝 Terraform 全包**——那是這份 runbook
比「跑得起來」更該傳達的東西。

---

## 1. 佈建

```bash
cd infra/azure
cp terraform.tfvars.example terraform.tfvars   # 填 subscription_id 與 allowed_ip
terraform init
terraform plan      # 先看清楚要開什麼
terraform apply
```

Terraform 開出來的東西：資源群組、SQL Server（邏輯伺服器）、一條只放行自己 IP 的防火牆規則。
**資料庫不在裡面**——預設走 Free Offer，而 provider 沒有那兩個參數（見第 0 節）。

### 1.1 建資料庫（僅 `use_free_offer = true`，即預設）

指令由 Terraform 產生，不要自己拼：

```bash
eval "$(terraform output -raw free_offer_create_command)"
```

或先看清楚再貼：

```bash
terraform output -raw free_offer_create_command
```

它展開後長這樣（伺服器名含隨機後綴，故必須由 output 取得）：

```
az sql db create -g rg-dw-credit-star -s sql-dw-credit-star-xxxxxx -n CreditRiskDW   -e GeneralPurpose -f Gen5 -c 1 --compute-model Serverless   --auto-pause-delay 60 --min-capacity 0.5   --backup-storage-redundancy Local --collation SQL_Latin1_General_CP1_CI_AS   --use-free-limit --free-limit-exhaustion-behavior AutoPause
```

建完確認 Free Offer 真的套上了（**不要只看指令沒報錯**）：

```bash
az sql db show -g rg-dw-credit-star -s <SERVER> -n CreditRiskDW   --query "{name:name, sku:currentSku.name, freeLimit:useFreeLimit, behavior:freeLimitExhaustionBehavior}" -o table
```

`freeLimit` 要是 `true`、`behavior` 要是 `AutoPause`。這兩個欄位是這條路的全部價值所在，
沒看到就等於走回一般計費而不自知。

> ⚠️ **區域鎖死**：同一訂閱下第一個 Free Offer 資料庫選定的區域，之後該訂閱所有
> Free Offer 資料庫都固定在那個區域且**不能改**。`var.location`（預設 `southeastasia`）
> 第一次就要選對。
>
> ⚠️ **官方文件互相矛盾**：Free Offer 說明頁寫「每訂閱最多 10 個資料庫」，
> `az sql db create` 的 `--use-free-limit` 參數說明卻寫「Allowed on one database
> in a subscription」。本專案只需要一個，兩種說法都不影響；要開第二個之前請自行實測。

走 `use_free_offer = false` 時跳過本節，資料庫已由 Terraform 建好。

### 與 AWS 版的第一個結構差異：資料庫是誰建的

| | AWS RDS for SQL Server | Azure SQL Database |
|---|---|---|
| 資源粒度 | 一台**執行個體**，裡面可以有多個資料庫 | **一個資料庫就是一個資源** |
| `CREATE DATABASE` | 由 `sql/01_schema.sql` 自己執行 | 由 Terraform 執行；T-SQL 端**不支援** |
| `USE CreditRiskDW` | 正常 | **不支援**（連上使用者資料庫後即報錯） |
| 來源限制 | VPC 安全群組 | 伺服器層防火牆規則 |

ETL 側的處理是 `DW_PLATFORM=azure-sql`：`etl/db.py` 會在送出前**略過**
「整批只有 `USE` 或 `CREATE DATABASE`」的批次，並把略過數印出來，不靜默。

刻意**不維護第二份 SQL**——兩份 SQL 會漂移，而漂移不會有任何錯誤訊息，
只會讓某一朵雲上的綱要悄悄變成舊版。

> **踩過的坑（2026-08-10）**：第一版的「純脈絡批次」比對沒有先剝註解，
> 而 `01_schema.sql` 的第一批前面有整段檔頭區塊註解、`02_reference_data.sql`
> 的 `USE` 前面也有註解，於是比對不成立、`USE CreditRiskDW` 照送——
> **後續 DDL 全部落到另一個資料庫**。症狀是 `dim_date` 主鍵重複，
> 完全指不到真因。回歸測試在 `tests/test_portability.py`。

---

## 2. 跑 ETL

```bash
cd ../..
eval "$(cd infra/azure && terraform output -raw connection_env)"
export DW_PASSWORD="$(cd infra/azure && terraform output -raw admin_password)"

./.venv/bin/python etl/run_etl.py
./.venv/bin/python etl/gen_data_dictionary.py
```

`connection_env` 會設好 `DW_PLATFORM=azure-sql`、`DW_HOST`、`DW_PORT`、`DW_USER`、`DW_DATABASE`。
密碼另外取，不進任何檔案。

預期輸出與本機容器一致：暫存區 30,000 列 → 事實 180,000 列 → 維度 51,110 個 SCD2 版本 →
8 條 ERROR 級規則全過、3 條 WARN 如實顯示。

**第一次連線可能等 30–60 秒**：serverless 從暫停狀態恢復需要時間，
`pymssql` 會先丟一個 timeout。重試即可——這是 auto-pause 的已知代價，不是設定錯誤。

---

## 3. 留存證據

```bash
mkdir -p docs/evidence/azure
{ echo "# Azure SQL Database 實跑存證 $(date -u +%FT%TZ)"; echo;
  echo '## terraform output'; (cd infra/azure && terraform output);
  echo; echo '## ETL 輸出'; } > docs/evidence/azure/run.md
./.venv/bin/python etl/run_etl.py 2>&1 | tee -a docs/evidence/azure/run.md
```

跑完把 `docs/evidence/azure/run.md` 收進版控（**密碼不要收**，`terraform output` 的
`admin_password` 是 sensitive，不會被印出來，但仍請自行確認）。

---

## 4. 拆除並實查歸零

```bash
cd infra/azure
terraform destroy
```

> ⚠️ **走 Free Offer 時，資料庫不在 Terraform 的狀態裡。**
> `terraform destroy` 刪的是邏輯伺服器與資源群組；CLI 建的那個資料庫活在伺服器內，
> 會被 Azure 連鎖刪除（`versions.tf` 已設 `prevent_deletion_if_contains_resources = false`，
> 否則資源群組裡有「Terraform 不認識的東西」時會擋下刪除、留一個以為拆乾淨的殘留群組）。
> **但連鎖刪除是 Azure 的行為，不是 Terraform 管的狀態**——所以下面四項實查在這條路上
> 不是保險，是唯一的歸零證據。

`destroy` 說成功不等於真的沒了。逐項實查：

```bash
az sql db list    --resource-group rg-dw-credit-star -o table 2>&1   # 應為資源群組不存在
az sql server list --resource-group rg-dw-credit-star -o table 2>&1  # 同上
az group exists   --name rg-dw-credit-star                           # 應為 false
az resource list  --query "[?resourceGroup=='rg-dw-credit-star']" -o table   # 應為空
```

四項都乾淨才算拆完。AWS 版的教訓在這裡同樣適用：**「terraform destroy 沒報錯」
與「雲端帳戶裡沒有資源」是兩件事**，只有後者能讓你安心關電腦。

---

## 5. 跟 AWS 版比，學到什麼

| 面向 | AWS RDS | Azure SQL Database | 這對「可攜性」的意義 |
|---|---|---|---|
| 資料庫的資源粒度 | 執行個體內的一個物件 | 資源本身 | **綱要腳本的邊界要畫在「資料庫之內」**——一旦腳本假設自己能建資料庫，就綁死在特定形態上 |
| 免費方案的限制形態 | 規格上限（只能開 t3.micro） | 額度上限（vCore 秒／儲存），用完的行為**可選** AutoPause 或 BillOverUsage | 兩者的失敗模式不同：AWS 是**開不起來**（明顯、當場知道）；Azure 是**你選錯選項才會計費**——危險的不是額度用完，是那個一旦選了就回不去的 BillOverUsage |
| 免費方案在 IaC 裡的可達性 | Terraform 全包 | **Terraform 到不了**（provider 缺 `use_free_limit`），得混合 CLI | 「IaC 覆蓋率」不是全有全無。**能誠實標出覆蓋不到的那一塊，比宣稱全自動更有用**——本目錄用 `var.use_free_offer` 讓這個缺口出現在型別裡，而不是只出現在註解裡 |
| 成本護欄 | 關閉 storage autoscaling ＋ 預算警示 | Free Offer + AutoPause（預設）／serverless auto-pause | 前者防「悄悄長大」，後者防「忘了關」。**但只有 Free Offer 那條把上限變成硬的**——其餘都是「讓忘記的代價變小」，不是「讓它變成零」 |
| 效能的意外 | t3 CPU 積分耗盡，吞吐 250→13 列/秒 | 首次連線需等待恢復（30–60 秒） | 兩個都不是設定錯誤，是**免費方案的物理**；不預先知道就會誤判成 bug |

**可攜的是語意，不是實作。** 同一套 T-SQL 能在三個地方跑，靠的不是「到處都一樣」，
而是把「不一樣的地方」收斂到一個明確的介面（`DW_PLATFORM` ＋ 環境變數），
並讓每個差異都有一行說明為什麼。
