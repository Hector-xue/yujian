import json
import os

import httpx

import pytest
from fastapi.testclient import TestClient

from app.main import create_app

TOKEN = "test-token-0123456789abcdef"


@pytest.fixture
def client(tmp_path):
    return TestClient(create_app(data_dir=tmp_path, token=TOKEN))


def h(device="dev-a"):
    return {"Authorization": f"Bearer {TOKEN}", "X-Device": device}


def test_health_and_auth(client):
    assert client.get("/healthz").json()["ok"] is True
    assert client.post("/api/v1/sync/push", json={"device_id": "a", "changes": []}).status_code == 401
    assert client.post("/api/v1/sync/push", json={"device_id": "a", "changes": []}, headers={"Authorization": "Bearer nope"}).status_code == 401


def test_push_pull_excludes_own_device_and_pages(client):
    ch = [{"entity": "transaction", "entity_id": f"t{i}", "deleted": False, "payload": {"id": f"t{i}", "amount_minor": i}, "at": 1000 + i} for i in range(3)]
    r = client.post("/api/v1/sync/push", json={"device_id": "dev-a", "changes": ch}, headers=h())
    assert r.status_code == 200 and r.json() == {"accepted": 3, "server_seq": 3}
    # 自己拉不到自己的
    r = client.get("/api/v1/sync/pull", params={"device_id": "dev-a", "since": 0}, headers=h())
    assert r.json()["changes"] == [] and r.json()["next_since"] == 3
    # 别的设备分页拉
    r = client.get("/api/v1/sync/pull", params={"device_id": "dev-b", "since": 0, "limit": 2}, headers=h("dev-b"))
    j = r.json()
    assert [c["entity_id"] for c in j["changes"]] == ["t0", "t1"] and j["has_more"] is True and j["next_since"] == 2
    r = client.get("/api/v1/sync/pull", params={"device_id": "dev-b", "since": 2}, headers=h("dev-b"))
    j = r.json()
    assert [c["entity_id"] for c in j["changes"]] == ["t2"] and j["has_more"] is False
    assert j["changes"][0]["payload"] == {"id": "t2", "amount_minor": 2} and j["changes"][0]["device_id"] == "dev-a"
    # 墓碑与中文原样
    client.post("/api/v1/sync/push", json={"device_id": "dev-b", "changes": [{"entity": "budget", "entity_id": "b1", "deleted": True, "payload": None, "at": 5}, {"entity": "memory", "entity_id": "楼下面馆", "payload": {"key": "楼下面馆"}, "at": 6}]}, headers=h("dev-b"))
    j = client.get("/api/v1/sync/pull", params={"device_id": "dev-a", "since": 3}, headers=h()).json()
    assert j["changes"][0]["deleted"] is True and j["changes"][1]["entity_id"] == "楼下面馆"


def test_push_validation(client):
    assert client.post("/api/v1/sync/push", json={"device_id": "", "changes": []}, headers=h()).status_code == 422
    assert client.post("/api/v1/sync/push", json={"device_id": "a", "changes": [{"entity": "x", "entity_id": "1"}]}, headers=h()).status_code == 422


def test_backup_roundtrip(client):
    assert client.get("/api/v1/backup", headers=h()).status_code == 404
    blob = b"\x00\x01encrypted-bytes\xff" * 100
    r = client.put("/api/v1/backup", content=blob, headers=h())
    assert r.status_code == 200 and r.json()["size"] == len(blob)
    r = client.get("/api/v1/backup", headers=h("dev-b"))
    assert r.status_code == 200 and r.content == blob and r.headers["X-Updated-At"]
    assert client.get("/api/v1/backup/info", headers=h()).json()["device_id"] == "dev-a"
    r = client.put("/api/v1/backup", content=b"v2", headers=h("dev-b"))
    assert client.get("/api/v1/backup", headers=h()).content == b"v2"
    assert client.put("/api/v1/backup", content=b"", headers=h()).status_code == 400


def test_ai_proxy_forwards_with_server_key(tmp_path, monkeypatch):
    seen = {}

    def upstream(req: httpx.Request) -> httpx.Response:
        seen["auth"] = req.headers.get("authorization")
        seen["url"] = str(req.url)
        seen["body"] = json.loads(req.content)
        return httpx.Response(200, json={"choices": [{"message": {"role": "assistant", "content": "hi"}}], "model": "m"})

    monkeypatch.setenv("YUJIAN_AI_UPSTREAM", "https://api.example.com/v1/")
    monkeypatch.setenv("YUJIAN_AI_KEY", "upstream-secret")
    app = create_app(data_dir=tmp_path, token=TOKEN, upstream_client=httpx.AsyncClient(transport=httpx.MockTransport(upstream)))
    c = TestClient(app)
    r = c.post("/api/v1/ai/chat/completions", json={"model": "m", "messages": []}, headers=h())
    assert r.status_code == 200 and r.json()["choices"][0]["message"]["content"] == "hi"
    assert seen["auth"] == "Bearer upstream-secret" and seen["url"] == "https://api.example.com/v1/chat/completions" and seen["body"]["model"] == "m"
    assert c.post("/api/v1/ai/chat/completions", json={}).status_code == 401


def test_ai_proxy_unconfigured(client):
    assert client.post("/api/v1/ai/chat/completions", json={}, headers=h()).status_code == 503


def test_devices_block_and_compact(client):
    def ch(i, eid="t1"):
        return {"entity": "transaction", "entity_id": eid, "deleted": False, "payload": {"v": i}, "at": 1000 + i}
    client.post("/api/v1/sync/push", json={"device_id": "dev-a", "changes": [ch(1), ch(2), ch(3, "t2")]}, headers=h())
    client.post("/api/v1/sync/push", json={"device_id": "dev-b", "changes": [ch(4)]}, headers=h("dev-b"))
    devs = {d["device_id"]: d for d in client.get("/api/v1/devices", headers=h()).json()["devices"]}
    assert devs["dev-a"]["changes"] == 3 and devs["dev-b"]["changes"] == 1 and not devs["dev-a"]["blocked"]
    # 移出设备：它再推 / 拉都被拒，别的设备照常
    assert client.post("/api/v1/devices/dev-b/block", headers=h()).json()["blocked"] is True
    assert client.post("/api/v1/sync/push", json={"device_id": "dev-b", "changes": [ch(5)]}, headers=h("dev-b")).status_code == 403
    assert client.get("/api/v1/sync/pull", params={"device_id": "dev-b"}, headers=h("dev-b")).status_code == 403
    assert client.get("/api/v1/sync/pull", params={"device_id": "dev-c"}, headers=h("dev-c")).status_code == 200
    client.post("/api/v1/devices/dev-b/unblock", headers=h())
    assert client.get("/api/v1/sync/pull", params={"device_id": "dev-b"}, headers=h("dev-b")).status_code == 200
    # 压缩：每个实体只留最新一条
    r = client.post("/api/v1/sync/compact", headers=h()).json()
    assert r == {"before": 4, "after": 2, "removed": 2}
    rows = client.get("/api/v1/sync/pull", params={"device_id": "dev-c", "since": 0}, headers=h("dev-c")).json()["changes"]
    assert {(c["entity_id"], c["payload"]["v"]) for c in rows} == {("t1", 4), ("t2", 3)}


def test_ai_proxy_streams_and_reuses_one_client(tmp_path, monkeypatch):
    def upstream(req: httpx.Request) -> httpx.Response:
        return httpx.Response(200, headers={"content-type": "text/event-stream"}, content=b"data: {\"x\":1}\n\ndata: [DONE]\n\n")
    monkeypatch.setenv("YUJIAN_AI_UPSTREAM", "https://api.example.com/v1")
    shared = httpx.AsyncClient(transport=httpx.MockTransport(upstream))
    app = create_app(data_dir=tmp_path, token=TOKEN, upstream_client=shared)
    with TestClient(app) as c:
        r = c.post("/api/v1/ai/chat/completions", json={"model": "m", "stream": True}, headers=h())
        assert r.status_code == 200 and r.headers["content-type"].startswith("text/event-stream")
        assert b"[DONE]" in r.content
        assert app.state.upstream is shared


def test_health_reports_version(client):
    assert client.get("/healthz").json()["version"] == "0.5.0"


def test_reset_keeps_seq_moving(client):
    ch = [{"entity": "transaction", "entity_id": "t1", "deleted": False, "payload": {"v": 1}, "at": 1}]
    client.post("/api/v1/sync/push", json={"device_id": "dev-a", "changes": ch}, headers=h())
    assert client.post("/api/v1/sync/reset", headers=h()).json() == {"removed": 1}
    r = client.post("/api/v1/sync/push", json={"device_id": "dev-a", "changes": ch}, headers=h())
    assert r.json()["server_seq"] == 2  # 不回退：别的设备游标停在 1，照样能拉到新的这条
    rows = client.get("/api/v1/sync/pull", params={"device_id": "dev-b", "since": 1}, headers=h("dev-b")).json()["changes"]
    assert [c["seq"] for c in rows] == [2]
