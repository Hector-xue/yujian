真服务端端到端（本机手动）：
1. `cd server && YUJIAN_SYNC_TOKEN=<16+位> YUJIAN_DATA=/tmp/yj uvicorn app.main:app --port 18787`
2. 在 test/sync_test.dart 的契约之外，用 bin/yujian_cli 起两个账本各自配同一服务端 sync（App 里就是「更多 → 同步」）。
2026-09-15 实测：两设备收敛、预算/记忆同步、加密备份 5KB 往返、恢复后 integrityCheck 为空。
