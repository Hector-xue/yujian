"""余见服务端（§4.5 / §12.3）。

只做这几件事：存变更日志（不解释语义；App 开了同步加密时存的就是密文）、存一份加密备份 blob、
设备列表 / 移出设备、压缩变更日志、可选的 AI 代理、健康检查。
单用户：一个 Bearer token（环境变量 YUJIAN_SYNC_TOKEN）。数据落在 YUJIAN_DATA 目录的 SQLite。
"""
from __future__ import annotations

import hmac
import json
import os
import sqlite3
import threading
import time
from contextlib import asynccontextmanager, contextmanager
from pathlib import Path
from typing import Any, Iterator, List, Optional

import httpx
from fastapi import Depends, FastAPI, Header, HTTPException, Query, Request, Response
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field
from starlette.background import BackgroundTask

VERSION = "0.5.0"
MAX_BACKUP_BYTES = 64 * 1024 * 1024
MAX_PUSH = 2000


def _data_dir() -> Path:
    d = Path(os.environ.get("YUJIAN_DATA", "./data"))
    d.mkdir(parents=True, exist_ok=True)
    return d


def _token() -> str:
    t = os.environ.get("YUJIAN_SYNC_TOKEN", "")
    if len(t) < 16:
        raise RuntimeError("YUJIAN_SYNC_TOKEN 未设置或太短（至少 16 位）：openssl rand -hex 24")
    return t


class Store:
    def __init__(self, path: Path):
        self._lock = threading.Lock()
        self._conn = sqlite3.connect(str(path), check_same_thread=False, isolation_level=None)
        self._conn.execute("PRAGMA journal_mode=WAL")
        self._conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS changes (
              seq INTEGER PRIMARY KEY AUTOINCREMENT,
              device_id TEXT NOT NULL,
              entity TEXT NOT NULL,
              entity_id TEXT NOT NULL,
              deleted INTEGER NOT NULL DEFAULT 0,
              payload TEXT,
              at INTEGER NOT NULL,
              received_at INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_changes_device ON changes(device_id, seq);
            CREATE INDEX IF NOT EXISTS idx_changes_entity ON changes(entity, entity_id, seq);
            CREATE TABLE IF NOT EXISTS blocked_devices (
              device_id TEXT PRIMARY KEY,
              blocked_at INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS backups (
              name TEXT PRIMARY KEY,
              blob BLOB NOT NULL,
              size INTEGER NOT NULL,
              device_id TEXT,
              updated_at INTEGER NOT NULL
            );
            """
        )

    @contextmanager
    def tx(self) -> Iterator[sqlite3.Connection]:
        with self._lock:
            self._conn.execute("BEGIN IMMEDIATE")
            try:
                yield self._conn
                self._conn.execute("COMMIT")
            except Exception:
                self._conn.execute("ROLLBACK")
                raise

    def push(self, device_id: str, changes: List["WireChange"]) -> int:
        now = int(time.time() * 1000)
        with self.tx() as c:
            c.executemany(
                "INSERT INTO changes(device_id,entity,entity_id,deleted,payload,at,received_at) VALUES (?,?,?,?,?,?,?)",
                [
                    (device_id, ch.entity, ch.entity_id, 1 if ch.deleted else 0, None if ch.payload is None else json.dumps(ch.payload, ensure_ascii=False), ch.at, now)
                    for ch in changes
                ],
            )
            return int(c.execute("SELECT COALESCE(MAX(seq),0) FROM changes").fetchone()[0])

    def pull(self, device_id: str, since: int, limit: int) -> tuple[list[dict[str, Any]], int]:
        with self._lock:
            rows = self._conn.execute(
                "SELECT seq,device_id,entity,entity_id,deleted,payload,at FROM changes WHERE seq > ? AND device_id != ? ORDER BY seq LIMIT ?",
                (since, device_id, limit + 1),
            ).fetchall()
            head = int(self._conn.execute("SELECT COALESCE(MAX(seq),0) FROM changes").fetchone()[0])
        out = [
            {
                "seq": r[0], "device_id": r[1], "entity": r[2], "entity_id": r[3], "deleted": bool(r[4]),
                "payload": None if r[5] is None else json.loads(r[5]), "at": r[6],
            }
            for r in rows[:limit]
        ]
        return out, head

    def devices(self) -> list[dict[str, Any]]:
        with self._lock:
            rows = self._conn.execute(
                "SELECT device_id, COUNT(*), MIN(received_at), MAX(received_at) FROM changes GROUP BY device_id ORDER BY MAX(received_at) DESC"
            ).fetchall()
            blocked = {r[0] for r in self._conn.execute("SELECT device_id FROM blocked_devices").fetchall()}
        seen = {r[0] for r in rows}
        out = [{"device_id": r[0], "changes": r[1], "first_seen": r[2], "last_seen": r[3], "blocked": r[0] in blocked} for r in rows]
        out += [{"device_id": d, "changes": 0, "first_seen": None, "last_seen": None, "blocked": True} for d in blocked - seen]
        return out

    def is_blocked(self, device_id: str) -> bool:
        with self._lock:
            return self._conn.execute("SELECT 1 FROM blocked_devices WHERE device_id = ?", (device_id,)).fetchone() is not None

    def set_blocked(self, device_id: str, blocked: bool) -> None:
        with self.tx() as c:
            if blocked:
                c.execute("INSERT OR REPLACE INTO blocked_devices(device_id, blocked_at) VALUES (?, ?)", (device_id, int(time.time() * 1000)))
            else:
                c.execute("DELETE FROM blocked_devices WHERE device_id = ?", (device_id,))

    def compact(self) -> dict[str, int]:
        """每个实体只留最新一条（按 seq）。客户端按 LWW 只关心最新状态，中间版本没用；新设备首次拉取也快得多。"""
        with self.tx() as c:
            before = int(c.execute("SELECT COUNT(*) FROM changes").fetchone()[0])
            c.execute(
                "DELETE FROM changes WHERE seq NOT IN (SELECT MAX(seq) FROM changes GROUP BY entity, entity_id)"
            )
            after = int(c.execute("SELECT COUNT(*) FROM changes").fetchone()[0])
        with self._lock:
            self._conn.execute("VACUUM")
        return {"before": before, "after": after, "removed": before - after}

    def put_backup(self, name: str, blob: bytes, device_id: Optional[str]) -> dict[str, Any]:
        now = int(time.time() * 1000)
        with self.tx() as c:
            c.execute(
                "INSERT INTO backups(name,blob,size,device_id,updated_at) VALUES (?,?,?,?,?) "
                "ON CONFLICT(name) DO UPDATE SET blob=excluded.blob,size=excluded.size,device_id=excluded.device_id,updated_at=excluded.updated_at",
                (name, blob, len(blob), device_id, now),
            )
        return {"name": name, "size": len(blob), "updated_at": now}

    def get_backup(self, name: str) -> Optional[tuple[bytes, dict[str, Any]]]:
        with self._lock:
            r = self._conn.execute("SELECT blob,size,device_id,updated_at FROM backups WHERE name = ?", (name,)).fetchone()
        if r is None:
            return None
        return bytes(r[0]), {"name": name, "size": r[1], "device_id": r[2], "updated_at": r[3]}


class WireChange(BaseModel):
    entity: str = Field(min_length=1, max_length=32)
    entity_id: str = Field(min_length=1, max_length=200)
    deleted: bool = False
    payload: Optional[dict[str, Any]] = None
    at: int


class PushBody(BaseModel):
    device_id: str = Field(min_length=1, max_length=64)
    changes: List[WireChange] = Field(max_length=MAX_PUSH)


def create_app(data_dir: Optional[Path] = None, token: Optional[str] = None, upstream_client: Optional[httpx.AsyncClient] = None) -> FastAPI:
    tok = token if token is not None else _token()
    store = Store((data_dir or _data_dir()) / "sync.db")

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        yield
        # 自己建的 AI 代理连接池在退出时关掉（测试传进来的不归我们管）
        own = getattr(app.state, "own_upstream", None)
        if own is not None:
            await own.aclose()

    app = FastAPI(title="Yujian Server", version=VERSION, lifespan=lifespan)
    # AI 代理（可选）：密钥放服务端，多设备共用；App 里 Base URL 填 <server>/api/v1/ai，API Key 填同步 token
    ai_upstream = os.environ.get("YUJIAN_AI_UPSTREAM", "").rstrip("/")
    ai_key = os.environ.get("YUJIAN_AI_KEY", "")
    app.state.upstream = upstream_client
    app.state.own_upstream = None

    def upstream() -> httpx.AsyncClient:
        # 整个进程共用一个连接池：以前每个请求 new 一个 AsyncClient 且从不关闭，连接和文件描述符会一直漏
        if app.state.upstream is None:
            app.state.own_upstream = httpx.AsyncClient(timeout=httpx.Timeout(120, connect=15))
            app.state.upstream = app.state.own_upstream
        return app.state.upstream

    def not_blocked(device_id: str) -> None:
        if store.is_blocked(device_id):
            raise HTTPException(403, "device removed")

    def auth(authorization: str = Header(default="")) -> None:
        scheme, _, cred = authorization.partition(" ")
        if scheme.lower() != "bearer" or not hmac.compare_digest(cred, tok):
            raise HTTPException(401, "bad token")

    @app.get("/healthz")
    def healthz() -> dict[str, Any]:
        return {"ok": True, "version": VERSION}

    @app.post("/api/v1/sync/push", dependencies=[Depends(auth)])
    def push(body: PushBody) -> dict[str, Any]:
        not_blocked(body.device_id)
        head = store.push(body.device_id, body.changes)
        return {"accepted": len(body.changes), "server_seq": head}

    @app.get("/api/v1/sync/pull", dependencies=[Depends(auth)])
    def pull(device_id: str = Query(min_length=1), since: int = Query(0, ge=0), limit: int = Query(500, ge=1, le=2000)) -> dict[str, Any]:
        not_blocked(device_id)
        changes, head = store.pull(device_id, since, limit)
        next_since = changes[-1]["seq"] if changes else max(since, head)
        return {"changes": changes, "next_since": next_since, "server_seq": head, "has_more": len(changes) == limit and next_since < head}

    @app.get("/api/v1/devices", dependencies=[Depends(auth)])
    def devices() -> dict[str, Any]:
        return {"devices": store.devices()}

    @app.post("/api/v1/devices/{device_id}/block", dependencies=[Depends(auth)])
    def block(device_id: str) -> dict[str, Any]:
        store.set_blocked(device_id, True)
        return {"device_id": device_id, "blocked": True}

    @app.post("/api/v1/devices/{device_id}/unblock", dependencies=[Depends(auth)])
    def unblock(device_id: str) -> dict[str, Any]:
        store.set_blocked(device_id, False)
        return {"device_id": device_id, "blocked": False}

    @app.post("/api/v1/sync/compact", dependencies=[Depends(auth)])
    def compact() -> dict[str, Any]:
        return store.compact()

    @app.put("/api/v1/backup", dependencies=[Depends(auth)])
    async def put_backup(request: Request, x_device: str = Header(default="")) -> dict[str, Any]:
        blob = await request.body()
        if not blob:
            raise HTTPException(400, "empty body")
        if len(blob) > MAX_BACKUP_BYTES:
            raise HTTPException(413, "backup too large")
        return store.put_backup("default", blob, x_device or None)

    @app.get("/api/v1/backup", dependencies=[Depends(auth)])
    def get_backup() -> Response:
        r = store.get_backup("default")
        if r is None:
            raise HTTPException(404, "no backup")
        blob, meta = r
        return Response(content=blob, media_type="application/octet-stream", headers={"X-Updated-At": str(meta["updated_at"])})

    @app.get("/api/v1/backup/info", dependencies=[Depends(auth)])
    def backup_info() -> dict[str, Any]:
        r = store.get_backup("default")
        if r is None:
            raise HTTPException(404, "no backup")
        return r[1]

    @app.post("/api/v1/ai/chat/completions", dependencies=[Depends(auth)])
    async def ai_proxy(request: Request) -> Response:
        if not ai_upstream:
            raise HTTPException(503, "服务端没配 YUJIAN_AI_UPSTREAM")
        body = await request.body()
        client = upstream()
        headers = {"Content-Type": "application/json", "Authorization": f"Bearer {ai_key}"}
        try:
            wants_stream = bool(json.loads(body or b"{}").get("stream"))
        except (ValueError, AttributeError):
            wants_stream = False
        url = f"{ai_upstream}/chat/completions"
        try:
            if wants_stream:
                # 流式：边收边转（SSE），不等上游说完再整包返回
                r = await client.send(client.build_request("POST", url, content=body, headers=headers), stream=True)
                return StreamingResponse(r.aiter_bytes(), status_code=r.status_code, media_type=r.headers.get("content-type", "text/event-stream"), background=BackgroundTask(r.aclose))
            r = await client.post(url, content=body, headers=headers)
        except httpx.HTTPError as e:
            raise HTTPException(502, f"upstream: {e}") from e
        return Response(content=r.content, status_code=r.status_code, media_type=r.headers.get("content-type", "application/json"))

    return app


app = create_app() if os.environ.get("YUJIAN_SYNC_TOKEN") else None  # uvicorn app.main:app 需要 token 已配置
