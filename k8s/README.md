# Kubernetes 部署

把 [`airflow/docker-compose.yml`](../airflow/docker-compose.yml) 的兩服務堆疊搬到 k8s。**Compose 版仍然可用**——這一層的價值不在「同一件事換個地方跑」，而在翻譯過程中被迫顯性化的三個決定。

## 一、Compose 直譯會壞掉的地方

| Compose 寫法 | 直譯成 k8s | 為什麼錯 | 這裡的做法 |
|---|---|---|---|
| `volumes: sqldata:/var/opt/mssql` | Deployment + PVC | Deployment 預設滾動更新會**先起新 Pod 再殺舊 Pod**，兩個 Pod 同時掛同一個 PVC、同時開啟同一份 SQL Server 資料檔 | **StatefulSet + volumeClaimTemplates**：同一時間只有一個 Pod 持有該身分與磁碟 |
| `depends_on: sqledge` | initContainer 或直接啟動 | `depends_on` 只保證「容器已啟動」，不保證「服務已就緒」。SQL Server 暖機十幾秒，ETL 會在第一秒連線失敗 | **readinessProbe + initContainer 輪詢 `nc -z sqledge 1433`**，等到真的能連才開始 |
| `environment:` 一段包含密碼 | 全部塞進 ConfigMap | 設定要進版控、密碼不能 | **ConfigMap／Secret 分離**——在 Compose 是慣例，在 k8s 是型別 |
| ETL 靠 `docker compose run` 手動觸發 | 做成常駐 Deployment | 批次任務不是服務，沒有「跑完就結束」的表達方式 | **Job**：有完成狀態、有 `backoffLimit` 重試上限、`ttlSecondsAfterFinished` 自動清理 |
| `_PIP_ADDITIONAL_REQUIREMENTS` 開機裝依賴 | 照搬 | 官方標註僅供開發：每次啟動重裝、網路一斷起不來、無版本鎖定 | **建置期裝好依賴的映像**（[`Dockerfile`](../Dockerfile)），執行期不碰網路 |

**冪等性在這裡從「好習慣」升格為「前提」**：Job 會依 `backoffLimit` 自動重試，不冪等的 ETL 配上自動重試，等於自動化地製造重複資料。本專案的 ETL 事實表先刪後插、SCD2 以雜湊比對，叢集內實測兩輪落地筆數相同。

## 二、實跑結果

```bash
docker build -t dw-credit-star-etl:local .

kubectl apply -f k8s/00-namespace-and-config.yaml -f k8s/10-sqledge.yaml
kubectl -n dw-credit-star rollout status statefulset/sqledge

kubectl apply -f k8s/20-etl-job.yaml
kubectl -n dw-credit-star wait --for=condition=complete job/dw-etl --timeout=900s

kubectl apply -f k8s/30-data-dictionary-job.yaml     # 必須在上一步完成之後
kubectl -n dw-credit-star logs job/dw-etl
```

從空命名空間到 ETL 完成 **42 秒**（不含映像建置）：事實 180,000 列、客戶維度 51,110 個 SCD Type 2 版本、違約結果 30,000 列，**9 條 ERROR 級品質規則全數通過、3 條 WARN 如實標記來源髒資料**，與本機 Compose 版結果一致。刪除 Job 後重新套用，第二輪落地筆數不變（冪等）。

叢集為 OrbStack 內建 Kubernetes（v1.35.6），單節點；映像走本機 daemon，`imagePullPolicy: IfNotPresent` 不對外拉取。

## 三、實跑當場打臉的一個設計錯誤

第一版把 ETL Job 與資料字典 Job 寫在**同一份 manifest**，並在註解裡寫「字典跑在 ETL 之後」。實跑立刻證明那句話是假的：`kubectl apply` 一次送出兩個 Job，它們**同時啟動**——字典 Job 第一次因資料庫尚未就緒而失敗，第二次剛好撞上 ETL 套完綱要的時點，於是「成功」產出了一份描述**空倉儲**的文件。

**k8s 的 Job 之間沒有隱含順序，註解不會產生依賴關係。** 拆成兩份 manifest 並以 `kubectl wait` 串接後，順序才真的成立：ETL 失敗時第二份根本不會被套用，文件因此永遠只描述通過稽核的那版綱要。

同一個約束在 Airflow 版是用 task 依賴表達的（見 [`airflow/`](../airflow/)）——**兩邊都需要顯式表達，差別只在語法**。

## 四、誠實邊界

- 單節點開發叢集，非生產部署。**沒有**做：HA、備份還原、資源配額與 LimitRange、NetworkPolicy、Ingress／TLS、監控告警、PodDisruptionBudget。
- Secret 以明文 `stringData` 寫在 manifest 裡，是本機一次性開發憑證。生產環境應以 External Secrets／Vault 注入，**不得放進 repo**。
- 這裡編排的是**批次 ETL**，不是把 Airflow 搬上 k8s。真要在 k8s 跑 Airflow，該用官方 Helm chart 搭配 KubernetesExecutor，那是另一個層級的工作。
- 映像未推送到任何 registry，僅存在於本機 daemon；多節點叢集需要 registry。
