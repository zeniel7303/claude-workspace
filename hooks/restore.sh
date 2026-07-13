#!/bin/bash
# restore.sh — post-merge hook에서 호출
# workspace의 Claude 관련 파일을 프로젝트로 복원

WORKSPACE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_KEY=$(git config claude.projectKey 2>/dev/null)
MEMORY_PATH=$(git config claude.memoryPath 2>/dev/null)

[ -z "$PROJECT_KEY" ] || [ -z "$MEMORY_PATH" ] && exit 0

REPO_ROOT=$(git rev-parse --show-toplevel)
SOURCE="$WORKSPACE/$PROJECT_KEY"

cd "$WORKSPACE" && git pull --quiet

restore_dir() {
    local src="$1" dst="$2"
    [ -d "$src" ] || return 0
    rm -rf "$dst"
    cp -r "$src" "$dst"
}

restore_dir "$SOURCE/claude"  "$REPO_ROOT/.claude"
restore_dir "$SOURCE/dev"     "$REPO_ROOT/dev"
restore_dir "$SOURCE/memory"  "$MEMORY_PATH"

{
  [ -f "$WORKSPACE/CLAUDE.md" ] && cat "$WORKSPACE/CLAUDE.md" && echo ""
  [ -f "$SOURCE/CLAUDE.md" ]    && cat "$SOURCE/CLAUDE.md"
} > "$REPO_ROOT/CLAUDE.md"

[ -f "$SOURCE/settings.local.json" ]   && cp "$SOURCE/settings.local.json"   "$REPO_ROOT/.claude/settings.local.json"
