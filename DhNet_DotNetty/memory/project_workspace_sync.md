---
name: claude-workspace-sync
description: 모든 Claude 파일(dev/, .claude/, 메모리)을 claude-workspace private 레포로 기기 간 동기화하는 시스템
metadata:
  type: project
---

`dev/`, `.claude/`, Claude 메모리, `CLAUDE.md`를 `claude-workspace` private 레포(`zeniel7303/claude-workspace`)로 동기화해 여러 PC에서 작업 연속성 유지.

**Why:** 두 PC 환경에서 Claude 설정과 작업 문서를 공유해야 함. `.claude/`와 `CLAUDE.md`는 public 레포에서 제거됨.

**How to apply:** 새 PC 셋업 시 레포 루트에서 1회만 실행:
```bash
bash setup-claude.sh
```
내부적으로 claude-workspace를 클론, `.claude/` + `dev/` + `CLAUDE.md` + 메모리 복원, post-commit/post-merge 훅 설치.

구조:
- `workspace/DhNet_DotNetty/setup.sh` — DhNet_DotNetty 전용 설치 스크립트
- `workspace/DhNet_DotNetty/claude/` — .claude/ 백업
- `workspace/DhNet_DotNetty/dev/` — 작업 문서
- `workspace/DhNet_DotNetty/memory/` — Claude 메모리
- `workspace/DhNet_DotNetty/CLAUDE.md` — 전용 규칙 (공통 규칙과 합쳐짐)
- `workspace/hooks/sync.sh` — post-commit 훅 (자동 업로드)
- `workspace/hooks/restore.sh` — post-merge 훅 (자동 복원)

이전 방식(`.claude/install-hooks.sh`)을 대체 (2026-07-01 전환).
