---
name: project-phase5-logger-overflow-decision
description: "Decision on spdlog block-on-overflow risk — verify empirically during load test; watchdog_test confirmed CRASH macro's existing watchdog prevents infinite hang even if block triggers"
metadata: 
  node_type: memory
  type: project
  originSessionId: 2b03da2d-d7ea-4028-8d50-b1153b2de3d5
---

Phase 5 (부하 테스트 인프라, README.md 로드맵) 진입 전 종합 코드 리뷰에서 Important 이슈로 spdlog `async_overflow_policy::block` 정책이 지적됨: 큐 용량 8192 + 워커 스레드 1개 구조에서 워커가 밀리면 `Session::HandleError`/`IocpCore::Dispatch` 등 핫 경로의 `LOG_WARN`/`LOG_ERROR` 호출이 전부 블로킹되어, Phase 5가 의도적으로 만드는 "연결 폭주" 시나리오 자체가 IOCP 워커 스레드 전체를 멈추는 숨은 글로벌 스로틀이 될 위험이 있음.

**Why:** 사용자가 이론적 위험보다 실측을 선호 — "일단 Phase 5 뛰어들어서 실제로 타는지 확인" 결정. `overrun_oldest` 등으로 정책을 미리 바꾸지 않고, Phase 5 부하 테스트 도중 실제로 로깅 블로킹이 병목/지연으로 나타나는지 관찰 후 필요시 대응하기로 함. [[project_missing_agent_types]] 리뷰에서 발견된 사항.

**How to apply:** Phase 5 작업(부하 테스트 인프라 구축/실행) 중 서버 응답 지연이나 IOCP 스레드 정체가 관찰되면, 가장 먼저 이 로거 block 정책을 의심하고 spdlog 큐 상태(드롭 카운트, 워커 지연)를 확인할 것. 아직 정책은 변경 안 된 상태(`Logger.cpp`에 `async_overflow_policy::block` 그대로).

**추가 발견 (2026-06-19, Phase 5.5.0 — `Tools/diagnostics/watchdog_test` 실행 결과):** `DhUtil/Macro.h`의 `CRASH` 매크로에는 이미 별도 워치독(스레드가 500ms 후 무조건 강제 크래시)이 적용돼 있음. 독립 검증 도구로 "로거 워커가 영원히 멈추고 큐가 가득 찬" 최악의 상황을 재현해본 결과, 워치독 패치 전 코드는 영원히 hang(버그 재현), 현재 코드는 ~500ms 내 fail-fast(정상 작동) 확인됨. 즉 **block 정책이 워커를 영원히 멈추게 해도 프로세스 자체가 무한 hang에 빠지는 최악의 사태는 이미 막혀있음.** 다만 이건 "죽지도 않고 응답도 안 하는 상태"만 방지하는 안전망이고, 로거가 막혀있는 동안 일반 요청 처리가 지연되는 성능 저하 문제는 여전히 별개로 5.5.1/5.5.2(연결 폭주 부하 실측)에서 직접 확인해야 함.
