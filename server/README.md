# Yujian Server（可选）

同步中继 + 加密备份。**不含账本规则**：它只按顺序存每台设备推上来的变更日志，和一份客户端加密后的备份 blob。单用户，一个 Bearer token。

```bash
export YUJIAN_SYNC_TOKEN=$(openssl rand -hex 24)
pip install .            # 或 pip install '.[test]' && pytest
YUJIAN_DATA=./data uvicorn app.main:app --port 8787
```

接口：
- `POST /api/v1/sync/push` `{device_id, changes:[{entity, entity_id, deleted, payload, at}]}`
- `GET  /api/v1/sync/pull?device_id=&since=&limit=` → 其他设备的变更，按 seq 分页
- `PUT/GET /api/v1/backup`（客户端 AES-GCM 加密后的字节；服务端看不到明文）、`GET /api/v1/backup/info`
- `GET /healthz`

Docker 见 `deploy/docker-compose.yml`。
