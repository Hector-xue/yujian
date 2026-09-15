# 自托管

余见不需要服务器。只有在你想多设备同步或云端加密备份时才需要 Yujian Server。

```bash
git clone https://github.com/Hector-xue/yujian && cd yujian/deploy
export YUJIAN_SYNC_TOKEN=$(openssl rand -hex 24)   # 记下来，App 里要填
docker compose up -d --build
curl http://127.0.0.1:8787/healthz
```

反向代理加 HTTPS（示例 `deploy/Caddyfile`），然后在 App「更多 → 同步与云备份」填地址和 token。

服务端存什么：每台设备推上来的变更日志（实体 JSON，原样存）、一份客户端加密后的备份。它不解析账本，也解不开备份。数据在 docker volume `yujian-data`。

不用 Docker：`cd server && pip install . && YUJIAN_SYNC_TOKEN=… YUJIAN_DATA=/var/lib/yujian uvicorn app.main:app --port 8787`。
