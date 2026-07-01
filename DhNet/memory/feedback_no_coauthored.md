---
name: feedback-no-coauthored
description: git 커밋 메시지에 Co-Authored-By 줄을 넣지 말 것
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 0d52f20e-224e-4a32-83d9-db211d48c144
---

git commit 메시지에 `Co-Authored-By: Claude ...` 줄을 절대 추가하지 말 것.

**Why:** 사용자가 명시적으로 원하지 않는다고 요청함. 이전에 추가된 것도 커밋을 rebase해서 제거했다.

**How to apply:** 모든 git commit (--amend 포함)에서 Co-Authored-By 줄을 쓰지 않는다.
