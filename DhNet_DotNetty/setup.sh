#!/bin/bash
# DhNet_DotNetty/setup.sh — 새 PC에서 1회 실행

PROJECT_KEY="DhNet_DotNetty"
WORKSPACE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_DIR="${1:-$(pwd)}"

if [ ! -d "$PROJECT_DIR/.git" ]; then
    echo "❌ git repo를 찾을 수 없음: $PROJECT_DIR"
    echo "   사용법: bash setup.sh /path/to/DhNet_DotNetty"
    exit 1
fi

derive_memory_key() {
    local path="$1"
    path="${path#/}"
    path="${path/:/}"
    local first_upper
    first_upper=$(echo "${path:0:1}" | tr 'a-z' 'A-Z')
    path="${first_upper}${path:1}"
    path="${path/\//"--"}"
    path="${path//\//-}"
    path="${path//_/-}"
    echo "$path"
}

MEMORY_KEY=$(derive_memory_key "$PROJECT_DIR")
USERPROFILE_UNIX=$(echo "$USERPROFILE" | sed 's|\\|/|g')
MEMORY_PATH="$USERPROFILE_UNIX/.claude/projects/$MEMORY_KEY/memory"

git config --global claude.workspace "$WORKSPACE"
git -C "$PROJECT_DIR" config claude.projectKey "$PROJECT_KEY"
git -C "$PROJECT_DIR" config claude.memoryPath "$MEMORY_PATH"

rm -rf "$PROJECT_DIR/.claude"
cp -r "$WORKSPACE/$PROJECT_KEY/claude" "$PROJECT_DIR/.claude"
[ -d "$WORKSPACE/$PROJECT_KEY/dev" ] && { rm -rf "$PROJECT_DIR/dev"; cp -r "$WORKSPACE/$PROJECT_KEY/dev" "$PROJECT_DIR/dev"; }
[ -d "$WORKSPACE/$PROJECT_KEY/memory" ] && { mkdir -p "$MEMORY_PATH"; cp -r "$WORKSPACE/$PROJECT_KEY/memory/." "$MEMORY_PATH/"; }

{
  [ -f "$WORKSPACE/CLAUDE.md" ] && cat "$WORKSPACE/CLAUDE.md" && echo ""
  [ -f "$WORKSPACE/$PROJECT_KEY/CLAUDE.md" ] && cat "$WORKSPACE/$PROJECT_KEY/CLAUDE.md"
} > "$PROJECT_DIR/CLAUDE.md"

cat > "$PROJECT_DIR/.git/hooks/post-commit" << EOF
#!/bin/bash
bash "\$(git config --global claude.workspace)/hooks/sync.sh"
EOF
cat > "$PROJECT_DIR/.git/hooks/post-merge" << EOF
#!/bin/bash
bash "\$(git config --global claude.workspace)/hooks/restore.sh"
EOF
chmod +x "$PROJECT_DIR/.git/hooks/post-commit" "$PROJECT_DIR/.git/hooks/post-merge"

echo "✓ $PROJECT_KEY 설정 완료"
echo "  Memory key : $MEMORY_KEY"
echo "  Memory path: $MEMORY_PATH"
