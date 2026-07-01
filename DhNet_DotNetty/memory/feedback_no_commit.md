---
name: 커밋 금지 — 메시지만 제안
description: git commit을 직접 실행하지 않고 커밋 메시지만 제안한다
type: feedback
---

git commit 명령을 직접 실행하지 않는다. 커밋 메시지 텍스트만 제안하고, 실제 커밋은 사용자가 직접 수행한다.

**Why:** 회사 컴퓨터에서 작업 중이라 개인 git 계정(Dohyun Ahn)으로 커밋이 남는 것이 곤란하다.

**How to apply:** 코드 작업 완료 후 "커밋 메시지: `...`" 형태로 텍스트만 제안한다. git commit, git add 명령을 실행하지 않는다.
