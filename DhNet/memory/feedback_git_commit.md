---
name: git commit 메시지 규칙
description: 커밋 메시지에 Co-Authored-By 서명 금지, "코드 리뷰 수정" 표현 금지
type: feedback
originSessionId: 72d4b378-b69f-4777-b358-962b9d682785
---
1. 커밋 메시지에 `Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>` 또는 어떤 Claude 관련 서명도 절대 추가하지 않는다.
2. 커밋 제목에 "코드 리뷰 수정", "리뷰 반영" 등 리뷰 관련 표현을 쓰지 않는다. 변경된 내용 자체를 제목으로 쓴다.

**Why:** 사용자가 두 항목 모두 명시적으로 금지함.

**How to apply:**
- Co-Authored-By는 모든 커밋에서 완전히 제외.
- 리뷰 후 수정 커밋도 "무엇을 바꿨는가"로만 제목 작성. 예: `Room 해제 시 shared_ptr 누락 수정`
