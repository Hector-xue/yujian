# Yujian Server（可选）

同步中继 + 加密备份。**不含账本规则**：它只按顺序存每台设备推上来的变更日志，和一份客户端加密后的备份 blob。单用户，一个 Bearer token。

```bash
export YUJIAN_SYNC_TOKEN=$(openssl rand -hex 24)
pip install .            # 或 pip install '.[test]' && pytest
YUJIAN_DATA=./data uvicorn app.main:app --port 8787
```

接口：
- `POST /api/v1/sync/push` `{device_id, changes:[{entity, entity_id, deleted, payload, at}]}`（App 开了「同步加密」时 entity_id 是哈希、payload 是密文，服务端看不到账本内容；没开是明文 JSON）
- `GET  /api/v1/sync/pull?device_id=&since=&limit=` → 其他设备的变更，按 seq 分页
- `PUT/GET /api/v1/backup`（客户端 AES-GCM 加密后的字节；服务端看不到明文）、`GET /api/v1/backup/info`
- `GET /api/v1/devices`：推过变更的设备（条数、首末时间、是否已移出）；`POST /api/v1/devices/{id}/block` / `unblock`：移出 / 恢复某台设备（丢了的手机移出后推拉都 403）
- `POST /api/v1/sync/compact`：压缩变更日志，每个实体只留最新一条（客户端按 LWW 只要最新状态）
- `POST /api/v1/ai/chat/completions`：AI 代理（可选，配 `YUJIAN_AI_UPSTREAM`=上游 base url、`YUJIAN_AI_KEY`；请求带 `stream: true` 时按 SSE 边收边转）。App 里 Base URL 填 `<server>/api/v1/ai`，API Key 填同步 token，多设备共用一把上游密钥
- `GET /healthz`

Docker 见 `deploy/docker-compose.yml`。
