#!/usr/bin/env bash
# 简单更新：同步上游 → 验证 → 重建镜像 → 重启容器。
# 实际逻辑在 sync-from-upstream.sh，这里只是带上 --rebuild --restart 的快捷方式。
#
#   ./scripts/update-and-restart.sh            # 本地更新并重启，不推送
#   ./scripts/update-and-restart.sh --push     # 同时推送到 origin
#   ./scripts/update-and-restart.sh --skip-verify
set -euo pipefail

exec "$(dirname "$0")/sync-from-upstream.sh" --rebuild --restart "$@"
