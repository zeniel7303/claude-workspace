# 공통 작업 규칙 (모든 프로젝트 적용)

## 거버넌스 룰

- **계획 먼저**: 코드 작성 전 반드시 구현 계획을 세우고 사용자에게 컨펌받는다. 승인 전까지 구현하지 않는다.
- **커밋 금지**: `git commit`을 직접 실행하지 않는다. 커밋 메시지만 제안하고 실제 커밋은 사용자가 직접.  
  사용자가 명시적으로 "커밋해줘"라고 요청한 경우만 예외.
- **Co-Authored-By 금지**: 커밋 메시지에 `Co-Authored-By: Claude ...` 줄을 절대 추가하지 않는다.
- **push 금지**: 사용자가 명시적으로 요청하지 않는 한 push하지 않는다.

## 작업 워크플로우

### RULE 1: 새 작업 시작 시 → `/dev-docs` 실행 [필수]
새로운 기능/작업 구현 요청 시 **코드 작성 전에** 반드시 `Skill("dev-docs", "[작업명]")`을 실행한다.

### RULE 2: 코드 작업 완료 후 → `/dev-docs-update` + 코드 리뷰 [필수]
파일 수정 후 응답 마지막에 반드시:
1. `Skill("dev-docs-update")` 실행
2. `Agent(subagent_type="general-purpose", prompt="You are a code-architecture-reviewer. ...")` 실행

## 에이전트 주의사항

`.claude/agents/`의 에이전트(`code-architecture-reviewer` 등)는 `subagent_type`으로 직접 등록되어 있지 않다.  
Agent 호출 시 반드시 `subagent_type="general-purpose"`를 사용하고 프롬프트 안에 페르소나를 포함한다.
