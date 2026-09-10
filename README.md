# Sub2API Pterodactyl Egg

這是一個可直接匯入最新版 Pterodactyl Panel 的 Sub2API Egg。專用映像已包含：

- Sub2API 最新官方映像內容
- PostgreSQL 18
- Redis
- 首次啟動自動初始化及安全密鑰產生
- `linux/amd64` 與 `linux/arm64` 支援

應用程式、PostgreSQL、Redis 與密鑰都持久化於 Pterodactyl 管理的 `/home/container`。PostgreSQL 和 Redis 只監聽容器內的 localhost，不需要額外配置 Panel Database、Docker network 或外部服務。

## 使用方式

1. 從本 repo 下載 [`egg-sub2api.json`](./egg-sub2api.json)。
2. 在 Panel 管理後台開啟 `Nests`，選擇或建立一個 Nest，按 `Import Egg` 匯入 JSON。
3. 以此 Egg 建立伺服器並分配一個 TCP port；建議至少配置 2 GiB RAM、2 CPU threads 與 10 GiB disk。
4. 啟動伺服器。看到 `Sub2API is ready.` 後，使用瀏覽器開啟主要 allocation。

管理員 email 預設為 `admin@sub2api.local`。管理員密碼留空時，Sub2API 會在第一次啟動的 Console log 中顯示自動產生的密碼；也可以在建立伺服器時預先填寫。

## 更新

停止伺服器後，在 Panel 重新安裝或讓 Wings 重新拉取 `latest` 映像，再啟動即可。資料存放在 `/home/container`，更換映像不會清除資料。

本 repo 的 GitHub Actions 每天重建 `ghcr.io/apple050620312/sub2api-pterodactyl:latest`，使映像跟隨上游 `weishaw/sub2api:latest`。每次發布也會保留 `sha-*` tag 以便鎖定或回復版本。

GHCR 映像已公開，Wings 可直接匿名拉取，不需要 registry 帳號或 token。

## 備份與注意事項

- 請一併備份 `data/`、`postgres/`、`redis/` 與 `.sub2api-secrets`。
- 不要單獨刪除或修改 `.sub2api-secrets`；其中的資料庫密碼與加密密鑰必須和資料目錄配套。
- 此 all-in-one 架構是為單一 Pterodactyl 實例的簡易部署設計。大型或高可用環境仍建議使用上游官方的外部 PostgreSQL/Redis 部署。

## 本機建置

```sh
docker build -t sub2api-pterodactyl .
docker run --rm -it -p 8080:8080 -v sub2api-data:/home/container sub2api-pterodactyl
```

## 授權

本 repo 的 Egg、啟動腳本與 workflow 以 [MIT License](./LICENSE) 發布。容器中包含的 Sub2API 由其上游依 LGPL-3.0-or-later 授權；詳見 [THIRD_PARTY_NOTICES.md](./THIRD_PARTY_NOTICES.md)。
