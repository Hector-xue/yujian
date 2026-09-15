import json

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
