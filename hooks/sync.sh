#!/bin/bash
# sync.sh — post-commit hook에서 호출
# 프로젝트의 Claude 관련 파일을 workspace로 동기화

WORKSPACE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_KEY=$(git config claude.projectKey 2>/dev/null)
MEMORY_PATH=$(git config claude.memoryPath 2>/dev/null)

[ -z "$PROJECT_KEY" ] || [ -z "$MEMORY_PATH" ] && exit 0

REPO_ROOT=$(git rev-parse --show-toplevel)
TARGET="$WORKSPACE/$PROJECT_KEY"

sync_dir() {
    local src="$1" dst="$2"
    [ -d "$src" ] || return 0
    rm -rf "$dst"
    cp -r "$src" "$dst"
    rm -rf "$dst/.git"
}

sync_dir "$REPO_ROOT/.claude"  "$TARGET/claude"
sync_dir "$REPO_ROOT/dev"      "$TARGET/dev"
sync_dir "$MEMORY_PATH"        "$TARGET/memory"

# CLAUDE.md는 workspace가 소스 — 역방향 동기화 안 함
[ -f "$REPO_ROOT/.claude/settings.local.json" ] && cp "$REPO_ROOT/.claude/settings.local.json" "$TARGET/settings.local.json"

cd "$WORKSPACE"
git add "$PROJECT_KEY/"
git diff --cached --quiet && exit 0
git commit -m "sync: $PROJECT_KEY $(date '+%Y-%m-%d %H:%M')"
git push
