#!/usr/bin/env bash
# 简单更新脚本：拉取最新代码 → 重建镜像 → 重启容器
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

BRANCH="${BRANCH:-mod}"
UPSTREAM_REMOTE="${UPSTREAM_REMOTE:-upstream}"
UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/wang4386/CDT-Monitor.git}"

log() { echo "==> $*"; }
die() { echo "错误: $*" >&2; exit 1; }

# 检查是否在 git 仓库中
git rev-parse --git-dir >/dev/null 2>&1 || die "不在 git 仓库中"

# 确保 upstream 远程存在
if ! git remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1; then
  log "添加 upstream 远程: $UPSTREAM_URL"
  git remote add "$UPSTREAM_REMOTE" "$UPSTREAM_URL"
fi

# 拉取最新代码
log "拉取最新代码..."
git fetch "$UPSTREAM_REMOTE"

# 切换到目标分支并 rebase
CURRENT_BRANCH=$(git branch --show-current)
if [[ "$CURRENT_BRANCH" != "$BRANCH" ]]; then
  log "切换到分支: $BRANCH"
  git checkout "$BRANCH"
fi

log "Rebase 到最新上游代码..."
git rebase "${UPSTREAM_REMOTE}/main"

# 获取版本号
UPSTREAM_VERSION=$(git show "${UPSTREAM_REMOTE}/main:version.txt" 2>/dev/null || echo "unknown")
MOD_VERSION="${UPSTREAM_VERSION}-mod"

# 重建 Docker 镜像
log "重建 Docker 镜像: cdt-monitor:${MOD_VERSION}"
if docker compose version >/dev/null 2>&1; then
  docker compose build cdt-monitor
else
  docker build --build-arg VERSION="$MOD_VERSION" -t "cdt-monitor:${MOD_VERSION}" .
fi

# 重启容器
log "重启容器..."
if docker compose version >/dev/null 2>&1; then
  docker compose down
  docker compose up -d
  log "容器已重启"
  echo
  docker compose ps
else
  die "未找到 docker compose，请手动重启容器"
fi

log "完成！"
echo "MOD 版本: ${MOD_VERSION}"
echo "当前分支: ${BRANCH} @ $(git rev-parse --short HEAD)"
