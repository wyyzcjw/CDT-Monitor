#!/usr/bin/env bash
# Keep the fork main branch as a pure fast-forward mirror of wang4386/CDT-Monitor main,
# then rebase mod onto the latest upstream, verify, and push.
# Safe to re-run. main is never force-pushed by this script.
#
#   ./scripts/sync-from-upstream.sh
#   ./scripts/sync-from-upstream.sh --no-push
#   ./scripts/sync-from-upstream.sh --no-sync-main
#   ./scripts/sync-from-upstream.sh --dry-run
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

BRANCH="${BRANCH:-mod}"
UPSTREAM_REMOTE="${UPSTREAM_REMOTE:-upstream}"
UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/wang4386/CDT-Monitor.git}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-main}"
ORIGIN_REMOTE="${ORIGIN_REMOTE:-origin}"
MAIN_BRANCH="${MAIN_BRANCH:-main}"

PUSH=1
VERIFY=1
SYNC_MAIN=1
DRY_RUN=0
REBUILD_IMAGE=0
RESTART_CONTAINER=0

usage() {
  cat <<EOF_USAGE
用法: $(basename "$0") [选项]

功能分支已由 feature/telegram-daily-report 更名为 mod，默认同步 mod。
如有通过 BRANCH 环境变量指定旧分支的命令或定时任务，请同步改为 BRANCH=mod。

默认执行完整同步：
  1. fetch upstream/origin；
  2. 检查 origin/${MAIN_BRANCH} 没有 fork 自定义提交；
  3. 将本地 ${MAIN_BRANCH} 对齐到 ${UPSTREAM_REMOTE}/${UPSTREAM_BRANCH}，并 fast-forward 推送 origin/${MAIN_BRANCH}；
  4. 将 ${BRANCH} rebase 到最新 ${UPSTREAM_REMOTE}/${UPSTREAM_BRANCH}；
  5. 同步 <上游版本>-mod；
  6. 运行 Go/Web 或 Docker 构建验证；
  7. 验证成功后使用 force-with-lease 推送 ${BRANCH}。

${MAIN_BRANCH} 永远只作为上游镜像；Telegram 功能只保留在 ${BRANCH}。
脚本不会 force-push ${MAIN_BRANCH}。如果检测到 ${MAIN_BRANCH} 含自定义提交或历史分叉，会直接停止。

选项:
  --no-push       完成本地同步/rebase/验证，但不推送任何分支
  --skip-verify   跳过构建验证
  --no-sync-main  不同步 fork 的 ${MAIN_BRANCH}
  --sync-main     显式同步 ${MAIN_BRANCH}（兼容旧用法；现在默认开启）
  --rebuild       同步完成后重建 Docker 镜像
  --restart       重建镜像后重启容器（需配合 --rebuild）
  --dry-run       只 fetch 并显示 main/功能分支状态和目标 mod 版本，不改分支
  -h, --help      显示帮助
EOF_USAGE
}

log() { printf '\n==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

ref_exists() {
  git rev-parse --verify "$1^{commit}" >/dev/null 2>&1
}

is_ancestor() {
  git merge-base --is-ancestor "$1" "$2"
}

latest_upstream_version() {
  git ls-remote --tags --refs "$UPSTREAM_REMOTE" 'v[0-9]*' 2>/dev/null | awk '
    {
      ref = $2
      sub(/^refs\/tags\/v/, "", ref)
      n = split(ref, p, ".")
      if (n != 3 || p[1] !~ /^[0-9]+$/ || p[2] !~ /^[0-9]+$/ || p[3] !~ /^[0-9]+$/) next
      major = p[1] + 0
      minor = p[2] + 0
      patch = p[3] + 0
      if (!found || major > best_major || (major == best_major && minor > best_minor) || (major == best_major && minor == best_minor && patch > best_patch)) {
        found = 1
        best_major = major
        best_minor = minor
        best_patch = patch
        best = "v" ref
      }
    }
    END { if (found) print best }
  '
}

show_main_status() {
  local origin_main="${ORIGIN_REMOTE}/${MAIN_BRANCH}"

  log "fork main 状态"
  if ! ref_exists "$origin_main"; then
    echo "origin/${MAIN_BRANCH}: 不存在"
    return
  fi

  if [[ "$(git rev-parse "$origin_main")" == "$(git rev-parse "$UPSTREAM_REF")" ]]; then
    echo "origin/${MAIN_BRANCH}: 已与 ${UPSTREAM_REF} 完全一致"
  elif is_ancestor "$origin_main" "$UPSTREAM_REF"; then
    echo "origin/${MAIN_BRANCH}: 落后上游 $(git rev-list --count "${origin_main}..${UPSTREAM_REF}") 个提交，可安全 fast-forward"
  elif is_ancestor "$UPSTREAM_REF" "$origin_main"; then
    echo "origin/${MAIN_BRANCH}: 比上游多 $(git rev-list --count "${UPSTREAM_REF}..${origin_main}") 个提交；为保护纯镜像结构，脚本不会覆盖"
  else
    echo "origin/${MAIN_BRANCH}: 与上游历史已分叉；脚本不会覆盖"
  fi
}

show_feature_status() {
  local feature_ref

  if ref_exists "$BRANCH"; then
    feature_ref="$BRANCH"
  elif ref_exists "${ORIGIN_REMOTE}/${BRANCH}"; then
    feature_ref="${ORIGIN_REMOTE}/${BRANCH}"
  else
    die "找不到分支 ${BRANCH}"
  fi

  log "Telegram 功能分支状态"
  echo "功能分支: ${feature_ref}"
  echo "相对上游自定义提交: $(git rev-list --count "${UPSTREAM_REF}..${feature_ref}")"
  echo "尚未包含的上游提交: $(git rev-list --count "${feature_ref}..${UPSTREAM_REF}")"

  if is_ancestor "$UPSTREAM_REF" "$feature_ref"; then
    echo "状态: 已包含最新上游"
  else
    echo "状态: 需要 rebase 到 ${UPSTREAM_REF}"
  fi
}

checkout_feature_branch() {
  local origin_feature="${ORIGIN_REMOTE}/${BRANCH}"
  local local_sha remote_sha

  if ref_exists "$BRANCH"; then
    git switch "$BRANCH"

    if ref_exists "$origin_feature"; then
      local_sha="$(git rev-parse "$BRANCH")"
      remote_sha="$(git rev-parse "$origin_feature")"
      REMOTE_FEATURE_SHA="$remote_sha"

      if [[ "$local_sha" == "$remote_sha" ]]; then
        :
      elif is_ancestor "$BRANCH" "$origin_feature"; then
        log "本地 ${BRANCH} 落后 origin，先 fast-forward"
        git merge --ff-only "$origin_feature"
      elif is_ancestor "$origin_feature" "$BRANCH"; then
        log "本地 ${BRANCH} 含尚未推送的提交，保留本地版本"
      else
        warn "本地 ${BRANCH} 与 origin 已分叉；这通常是上次 rebase 后尚未 push。"
        warn "将保留本地分支，并用 force-with-lease=${remote_sha} 防止覆盖新的远端提交。"
      fi
    else
      REMOTE_FEATURE_SHA=""
      warn "origin/${BRANCH} 不存在；首次推送时会创建远端分支"
    fi
  elif ref_exists "$origin_feature"; then
    git switch -c "$BRANCH" --track "$origin_feature"
    REMOTE_FEATURE_SHA="$(git rev-parse "$origin_feature")"
  else
    die "找不到分支 ${BRANCH}"
  fi
}

sync_main_branch() {
  local origin_main="${ORIGIN_REMOTE}/${MAIN_BRANCH}"
  local local_main_sha upstream_sha

  ref_exists "$origin_main" || die "找不到 ${origin_main}，拒绝自动创建默认分支"

  if ! is_ancestor "$origin_main" "$UPSTREAM_REF"; then
    if is_ancestor "$UPSTREAM_REF" "$origin_main"; then
      die "${origin_main} 比上游多 $(git rev-list --count "${UPSTREAM_REF}..${origin_main}") 个提交。main 必须保持纯上游镜像，请先人工检查。"
    fi
    die "${origin_main} 与 ${UPSTREAM_REF} 历史已分叉。为避免误删提交，拒绝自动重置 main。"
  fi

  upstream_sha="$(git rev-parse "$UPSTREAM_REF")"
  local_main_sha="$(git rev-parse "$origin_main")"

  log "对齐本地 ${MAIN_BRANCH} -> ${UPSTREAM_REF}"
  git branch -f "$MAIN_BRANCH" "$UPSTREAM_REF" >/dev/null
  git branch --set-upstream-to="${ORIGIN_REMOTE}/${MAIN_BRANCH}" "$MAIN_BRANCH" >/dev/null 2>&1 || true

  if [[ "$local_main_sha" == "$upstream_sha" ]]; then
    log "origin/${MAIN_BRANCH} 已与上游一致"
    return
  fi

  if [[ "$PUSH" -eq 1 ]]; then
    log "fast-forward origin/${MAIN_BRANCH} -> ${UPSTREAM_REF}"
    git push "$ORIGIN_REMOTE" "${UPSTREAM_REF}:refs/heads/${MAIN_BRANCH}"
  else
    log "--no-push：仅本地 ${MAIN_BRANCH} 已对齐，上游更新未推送到 origin"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-push) PUSH=0 ;;
    --skip-verify) VERIFY=0 ;;
    --no-sync-main) SYNC_MAIN=0 ;;
    --sync-main) SYNC_MAIN=1 ;;
    --rebuild) REBUILD_IMAGE=1 ;;
    --restart) RESTART_CONTAINER=1 ;;
    --dry-run) DRY_RUN=1; PUSH=0 ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数: $1" ;;
  esac
  shift
done

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "请在 CDT-Monitor 仓库里运行"
cd "$ROOT"

if [[ -n "$(git status --porcelain)" ]]; then
  die "工作区不干净，请先 commit、stash 或清理未跟踪文件"
fi

if ! git remote get-url "$ORIGIN_REMOTE" >/dev/null 2>&1; then
  die "找不到 remote: ${ORIGIN_REMOTE}"
fi

if ! git remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1; then
  log "添加 ${UPSTREAM_REMOTE} -> ${UPSTREAM_URL}"
  git remote add "$UPSTREAM_REMOTE" "$UPSTREAM_URL"
fi

log "fetch ${UPSTREAM_REMOTE} 和 ${ORIGIN_REMOTE}"
git fetch "$UPSTREAM_REMOTE" --prune --tags
git fetch "$ORIGIN_REMOTE" --prune

UPSTREAM_REF="${UPSTREAM_REMOTE}/${UPSTREAM_BRANCH}"
ref_exists "$UPSTREAM_REF" || die "找不到 ${UPSTREAM_REF}"

UPSTREAM_VERSION="$(latest_upstream_version)"
if [[ -n "$UPSTREAM_VERSION" ]]; then
  MOD_VERSION="${UPSTREAM_VERSION}-mod"
else
  MOD_VERSION="dev-mod"
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  show_main_status
  show_feature_status
  echo
  echo "上游版本: ${UPSTREAM_VERSION:-未找到 tag}"
  echo "目标版本: ${MOD_VERSION}"
  exit 0
fi

REMOTE_FEATURE_SHA=""
checkout_feature_branch

if [[ "$SYNC_MAIN" -eq 1 ]]; then
  sync_main_branch
else
  log "已跳过 main 同步"
fi

if is_ancestor "$UPSTREAM_REF" HEAD; then
  log "${BRANCH} 已基于最新 ${UPSTREAM_REF}"
else
  log "rebase ${BRANCH} onto ${UPSTREAM_REF}"
  if ! git rebase "$UPSTREAM_REF"; then
    cat >&2 <<EOF_REBASE

rebase 出现冲突。处理完后：

  git add <文件>
  git rebase --continue
  ./scripts/sync-from-upstream.sh --no-push   # 可选：重新跑版本同步和验证
  git push --force-with-lease ${ORIGIN_REMOTE} ${BRANCH}

如果冲突仅位于 internal/web/dist，优先从 web 源码重新 npm run build，
不要手工合并带 hash 的压缩 JS 构建产物。

放弃这次 rebase： git rebase --abort
EOF_REBASE
    exit 1
  fi
fi

log "同步 MOD 版本 ${MOD_VERSION}"
if [[ -f docker-compose.yml ]]; then
  sed -i.bak -E \
    -e "s/(VERSION:[[:space:]]*\").*(\")/\\1${MOD_VERSION}\\2/" \
    -e "s|(image:[[:space:]]*cdt-monitor:).*|\\1${MOD_VERSION}|" \
    docker-compose.yml
  rm -f docker-compose.yml.bak
else
  die "找不到 docker-compose.yml"
fi

if ! git diff --quiet -- docker-compose.yml; then
  git add docker-compose.yml
  git commit -m "chore: set mod version ${MOD_VERSION}"
fi

if [[ "$VERIFY" -eq 1 ]]; then
  if command -v go >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
    log "使用本机 Go/npm 验证"
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
      git commit -m "chore: rebuild web dist"
    fi
  elif command -v docker >/dev/null 2>&1; then
    log "本机未安装 Go/npm，改用 Docker 完整构建验证"
    if docker compose version >/dev/null 2>&1; then
      docker compose build cdt-monitor
    else
      docker build --build-arg VERSION="$MOD_VERSION" -t "cdt-monitor:${MOD_VERSION}" .
    fi
    log "Docker 构建验证通过"
  else
    die "找不到 Go/npm，也找不到 Docker；可安装开发环境或使用 --skip-verify"
  fi
else
  log "已跳过构建验证"
fi

if [[ "$PUSH" -eq 1 ]]; then
  log "推送 ${BRANCH}（force-with-lease）"
  if [[ -n "$REMOTE_FEATURE_SHA" ]]; then
    git push \
      "--force-with-lease=refs/heads/${BRANCH}:${REMOTE_FEATURE_SHA}" \
      "$ORIGIN_REMOTE" \
      "HEAD:refs/heads/${BRANCH}"
  else
    git push -u "$ORIGIN_REMOTE" "HEAD:refs/heads/${BRANCH}"
  fi
else
  log "已跳过 feature push"
fi

if [[ "$REBUILD_IMAGE" -eq 1 ]]; then
  if ! command -v docker >/dev/null 2>&1; then
    die "未找到 docker 命令，无法重建镜像"
  fi

  log "重建 Docker 镜像: cdt-monitor:${MOD_VERSION}"
  if docker compose version >/dev/null 2>&1; then
    docker compose build cdt-monitor
  else
    docker build --build-arg VERSION="$MOD_VERSION" -t "cdt-monitor:${MOD_VERSION}" .
  fi
  log "Docker 镜像构建完成"

  if [[ "$RESTART_CONTAINER" -eq 1 ]]; then
    log "重启容器"
    if docker compose version >/dev/null 2>&1; then
      docker compose down
      docker compose up -d
      log "容器已重启"
      echo
      docker compose ps
    else
      warn "未找到 docker compose，请手动重启容器"
    fi
  fi
else
  if [[ "$RESTART_CONTAINER" -eq 1 ]]; then
    warn "--restart 需要配合 --rebuild 使用，已忽略"
  fi
fi

log "完成"
echo "上游: ${UPSTREAM_REF} @ $(git rev-parse --short "$UPSTREAM_REF")"
echo "MOD 版本: ${MOD_VERSION}"
echo "功能分支: ${BRANCH} @ $(git rev-parse --short HEAD)"
git log --oneline --decorate -5
echo
git status -sb
