#!/usr/bin/env bash
# Rebase feature/telegram-daily-report onto wang4386/CDT-Monitor main,
# then verify and push. Safe to re-run.
#
#   ./scripts/sync-from-upstream.sh
#   ./scripts/sync-from-upstream.sh --no-push
#   ./scripts/sync-from-upstream.sh --sync-main
#   ./scripts/sync-from-upstream.sh --dry-run
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

BRANCH="${BRANCH:-feature/telegram-daily-report}"
UPSTREAM_REMOTE="${UPSTREAM_REMOTE:-upstream}"
UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/wang4386/CDT-Monitor.git}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-main}"
ORIGIN_REMOTE="${ORIGIN_REMOTE:-origin}"

PUSH=1
VERIFY=1
SYNC_MAIN=0
DRY_RUN=0

usage() {
  cat <<EOF
用法: $(basename "$0") [选项]

把 ${BRANCH} rebase 到 ${UPSTREAM_REMOTE}/${UPSTREAM_BRANCH}，跑测试和前端构建，再推回 origin。

选项:
  --no-push       rebase / 验证后不推送
  --skip-verify   跳过 go test 和 npm build
  --sync-main     同时快进 origin/main 到上游 main
  --dry-run       只 fetch 并显示上游新提交，不改本地分支
  -h, --help      显示帮助
EOF
}

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-push) PUSH=0 ;;
    --skip-verify) VERIFY=0 ;;
    --sync-main) SYNC_MAIN=1 ;;
    --dry-run) DRY_RUN=1; PUSH=0 ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数: $1" ;;
  esac
  shift
done

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "请在 CDT-Monitor 仓库里运行"
cd "$ROOT"

if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  die "有未提交的已跟踪改动，先 commit 或 stash"
fi

if ! git remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1; then
  log "添加 ${UPSTREAM_REMOTE} -> ${UPSTREAM_URL}"
  git remote add "$UPSTREAM_REMOTE" "$UPSTREAM_URL"
fi

log "fetch ${UPSTREAM_REMOTE} 和 ${ORIGIN_REMOTE}"
git fetch "$UPSTREAM_REMOTE" --tags
git fetch "$ORIGIN_REMOTE"

UPSTREAM_REF="${UPSTREAM_REMOTE}/${UPSTREAM_BRANCH}"
git rev-parse --verify "$UPSTREAM_REF" >/dev/null 2>&1 || die "找不到 ${UPSTREAM_REF}"

if [[ "$DRY_RUN" -eq 1 ]]; then
  log "上游新提交 (${UPSTREAM_REF} 有、当前 HEAD 没有)"
  if git merge-base --is-ancestor "$UPSTREAM_REF" HEAD; then
    echo "无。当前分支已经包含最新上游。"
  else
    git log --oneline HEAD.."$UPSTREAM_REF"
  fi
  exit 0
fi

if [[ "$SYNC_MAIN" -eq 1 ]]; then
  log "快进 ${ORIGIN_REMOTE}/main"
  git checkout main
  git merge --ff-only "$UPSTREAM_REF"
  if [[ "$PUSH" -eq 1 ]]; then
    git push "$ORIGIN_REMOTE" main
  fi
fi

if git show-ref --verify --quiet "refs/heads/${BRANCH}"; then
  git checkout "$BRANCH"
elif git show-ref --verify --quiet "refs/remotes/${ORIGIN_REMOTE}/${BRANCH}"; then
  git checkout -b "$BRANCH" --track "${ORIGIN_REMOTE}/${BRANCH}"
else
  die "找不到分支 ${BRANCH}"
fi

BEFORE="$(git rev-parse HEAD)"
if git merge-base --is-ancestor "$UPSTREAM_REF" HEAD; then
  log "${BRANCH} 已基于最新 ${UPSTREAM_REF}"
  REBASED=0
else
  log "rebase ${BRANCH} onto ${UPSTREAM_REF}"
  if ! git rebase "$UPSTREAM_REF"; then
    cat >&2 <<EOF

rebase 出现冲突。处理完后：

  git add <文件>
  git rebase --continue
  $0 --no-push          # 可选：再跑验证
  git push --force-with-lease ${ORIGIN_REMOTE} ${BRANCH}

放弃这次 rebase： git rebase --abort
EOF
    exit 1
  fi
  REBASED=1
fi

AFTER="$(git rev-parse HEAD)"

if [[ "$VERIFY" -eq 1 && ( "$REBASED" -eq 1 || "$BEFORE" != "$AFTER" ) ]]; then
  command -v go >/dev/null || die "找不到 go，请先安装 Go"
  command -v npm >/dev/null || die "找不到 npm，请先安装 Node.js"
  log "go test ./..."
  go test ./...
  log "go build"
  go build -o /dev/null ./cmd/cdt-monitor
  log "web build"
  if [[ ! -d web/node_modules ]]; then
    (cd web && npm ci --ignore-scripts)
  fi
  (cd web && npm run build)
  if [[ -n "$(git status --porcelain --untracked-files=no -- internal/web/dist)" ]]; then
    log "提交重建后的前端 dist"
    git add internal/web/dist
    git commit -m "chore: rebuild web dist after upstream rebase"
  fi
elif [[ "$VERIFY" -eq 1 ]]; then
  log "上游无新提交，跳过测试和构建"
fi

if [[ "$PUSH" -eq 1 ]]; then
  log "push --force-with-lease ${ORIGIN_REMOTE} ${BRANCH}"
  git push --force-with-lease "$ORIGIN_REMOTE" "$BRANCH"
else
  log "已跳过 push"
fi

log "完成"
git log --oneline --decorate -5
echo
git status -sb
