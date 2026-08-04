# ETL 執行映像。
#
# 取代 Compose 版的 `_PIP_ADDITIONAL_REQUIREMENTS`（官方標註僅供開發的捷徑：
# 每次容器啟動都重裝依賴，網路一斷就起不來，且沒有版本鎖定）。
# 依賴在建置期裝好，執行期不碰網路。
FROM python:3.11-slim

# pymssql 需要 FreeTDS 的執行期函式庫；wheel 已含編譯結果，故只裝執行期所需。
RUN apt-get update \
 && apt-get install -y --no-install-recommends libssl3 \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/dwrepo

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY sql/ ./sql/
COPY etl/ ./etl/
COPY data/ ./data/

# 來源快照走檔案而非隔壁 repo——容器裡看不到宿主機的其他專案。
ENV DW_SOURCE_CSV=/opt/dwrepo/data/source_credit_clients.csv \
    PYTHONUNBUFFERED=1

CMD ["python", "etl/run_etl.py"]
