---
name: 커밋과 push는 사용자가 직접 처리
description: 코드 작업 완료 후 git commit과 git push를 자동으로 실행하지 않는다
type: feedback
---

git commit과 push는 사용자가 명시적으로 요청할 때만 실행한다.

**Why:** 사용자가 커밋 타이밍과 메시지를 직접 제어하기를 원한다.

**How to apply:** 코드 작업 후 변경된 파일 목록과 내용 요약만 보고한다. 사용자가 "커밋해줘" 또는 "푸쉬해줘"라고 명시적으로 요청하면 실행한다.
