Last Updated: 2026-06-19

# 부하 테스트 인프라 (Phase 5) — Tasks

## Phase 5.1 — 시나리오 클라이언트 코어

- [x] 5.1.1 `TestPacket` 의존 제거 — `RegisterHandlers()`의 `Test` 핸들러 등록, 사전 빌드된 TestPacket 템플릿, 메인 루프의 `BroadCast` 호출을 모두 제거. vcxproj에서 `RoomController.cpp`(전역 `g_inRoom` 기반, 다중 세션에 부적합)와 `TestController.h` 참조도 제거.
- [x] 5.1.2 시나리오 루프 구현: 로그인 → 로비 체류(채팅 N회) → 룸 입장 → 룸 채팅 N회 → 룸 퇴장 → 반복.
  - 동일 계정 동시 로그인 정책 확인 결과: 서버는 거부하지 않음. `PlayerSystem::Add`가 `unordered_map::insert`라 동일 ID 충돌 시 두 번째 등록은 무시되고(맵에는 첫 세션만 남음), `Remove`는 ID로 무조건 erase. 각 세션의 게임플레이 자체는 독립적으로 정상 동작하지만 Admin REST(`/players`)는 동시 세션 수를 과소집계함 — Phase 5.4에서 인지하고 처리해야 할 제약으로 기록.
  - **핵심 발견**: 서버 `Player::EnterRoom`/`LeaveRoomAndReenterLobby`(`Player.cpp`)는 `Res_RoomEnter`/`Res_RoomExit` 전송 코드가 주석 처리되어 있어 실제로 전송되지 않음. 룸 입장 확인은 `Noti_RoomEnter`(자기 ID 매칭, 룸 전체 브로드캐스트)로, 룸 퇴장 후 로비 복귀 확인은 `Res_LobbyEnter` 재수신으로만 가능 — 이를 반영해 상태머신 설계.
  - 구현: `ScenarioConfig.h`(설정), `ScenarioState.h`(단계 enum+상태), `ScenarioStateRegistry.h/.cpp`(Session* 키, USE_LOCK 기반 스레드세이프 레지스트리), `ScenarioHandlers.h/.cpp`(Res_LobbyEnter/Noti_RoomEnter 핸들러 + `AdvanceScenario` 틱 함수) 신규 작성.
  - 세션 생명주기 연동을 위해 `ServerSession`(공용 파일, DhNet_Client와 공유)에 범용 훅 `m_onConnectedExtra`/`m_onDisconnectedExtra`(기본 no-op) 추가 — 인터랙티브 클라이언트 동작에는 영향 없음.
  - `ServerCore::Service`에 읽기 전용 `GetSessions()` 스냅샷 접근자 추가(`READ_LOCK`) — 메인 루프가 매 틱마다 서비스별 세션을 순회하며 `AdvanceScenario` 호출.
- [x] 5.1.3 시나리오 파라미터화 — CLI 인자 확장 (argv[6]=로비 채팅 횟수, argv[7]=로비 채팅 간격ms, argv[8]=룸 채팅 횟수, argv[9]=룸 채팅 간격ms). 기존 `msgPerSecond` 인자(TestPacket 전용)는 제거, 내부 틱 해상도는 상수 `kTickIntervalMs=200`으로 고정.

빌드 검증: `DhNet_Server.sln`(ServerCore 변경분 포함), `DhNet_Client.sln`(ServerSession 훅 포함), `DhNet_StressTest.sln`(신규 시나리오 코드) 3개 솔루션 모두 0 에러로 빌드 확인.

### 5.1 완료 후 코드 리뷰 대응 (2026-06-19)

5.1 구현 직후 general-purpose 에이전트(code-architecture-reviewer 페르소나)로 종합 리뷰 실행. 발견된 Critical 1건, Important 3건 중 이번 작업 범위 내(신규 작성 파일)인 2건을 즉시 수정:

- [x] **Critical**: `ScenarioHandlers.cpp`의 `AwaitingRoomEnter`/`AwaitingRoomExit` 타임아웃 재시도가 무한 반복되며, 서버 `HandleReqRoomEnterPacket`이 멱등하지 않아 재시도 중 첫 요청이 아직 처리 중이면 중복 `Room::Enter`가 큐잉되어 `Player::SetCurrentRoom()`(동기화 없는 단순 대입) race를 유발할 수 있었음 → `ScenarioConfig.maxRoomActionRetries`(기본 3) 추가, 초과 시 `ScenarioPhase::Stuck`으로 전환해 더 이상 재전송하지 않고 `std::wcerr`로 진단 로그 출력. `ScenarioState.actionRetries` 필드 추가, 단계 진입 시(`AwaitingRoomEnter`/`AwaitingRoomExit` 진입) 0으로 리셋.
- [x] **Important**: `ScenarioStateRegistry::Apply()`가 `WRITE_LOCK`을 쥔 채로 콜백 내부에서 직접 `Session::Send()`(네트워크 syscall)를 호출해, 매 200ms 틱마다 모든 세션의 전송이 레지스트리 락 하나로 직렬화되는 구조였음 → `AdvanceScenario`를 "락 안에서는 `ScenarioAction` enum만 결정"/"락 해제 후 실제 `Send*()` 호출"로 분리. `ScenarioState.h`에 `ScenarioAction` enum(`SendLobbyChat`/`SendRoomEnter`/`SendRoomChat`/`SendRoomExit`/`LogStuckRoomEnter`/`LogStuckRoomExit`) 추가.
- [ ] **Important (보류, 사용자 결정: 후속 작업으로 미룸, 2026-06-19)**: `services` 벡터에 대한 IOCP 디스패치 스레드와 메인 스레드 churn 로직 간 동기화 없는 접근(`main.cpp`) — 리뷰어가 "이번 PR 신규 도입 아님, pre-existing"으로 분류했고 StressTest 전용 코드라 production 서버에 영향 없음. Phase 5 이후 별도 작업으로 처리.
- [x] **2차 리뷰**: 위 두 수정(Critical/Important) 자체에 새 버그가 없는지 general-purpose 에이전트로 재검증 — "이상 없음" 확인 (actionRetries 리셋 누락 없음, 락/Send 분리 스레드 안전, Stuck 전환 후 재전송 완전 중단 확인).
- 수정된 파일: `ScenarioState.h`(Stuck 단계, ScenarioAction enum, actionRetries 필드), `ScenarioConfig.h`(maxRoomActionRetries), `ScenarioHandlers.cpp`(AdvanceScenario 락/Send 분리 + 재시도 한도)
- 빌드 재검증: `DhNet_StressTest.sln` 0 에러.

## Phase 5.2 — 메트릭 수집

- [x] 5.2.1 세션별 RTT 측정 (송신 타임스탬프 → 대응 응답 수신 시 델타 계산) (M)
  - **설계 결정**: 로비/룸 채팅(`Req_LobbyChat`/`Req_RoomChat`)은 서버가 송신자 본인에게 응답을 안 보내 RTT 측정 자체가 불가능하고, `Req_RoomEnter`/`Req_RoomExit`는 사이클당 2번뿐이라 표본이 희소한 데다 이미 재시도 한도(Critical 수정 대상) 로직을 갖고 있어 고빈도 핑과 엮기에 부적합. 대신 **죽어있던 `PacketEnum::Test` echo를 되살려** 시나리오와 독립적인 전용 RTT 핑 채널로 사용(사용자 승인, "알았어 이렇게 진행해줘").
  - **죽은 버그 원인**: `DhNet_Server/DhNet_Server/TestController.cpp`의 `HandleTestPacket`이 `Sender::Alloc`/`GetWritePointer`로 응답 패킷을 준비만 하고 `_session->Send(sender)`를 호출하지 않아 서버가 `Test` 패킷에 대해 echo를 절대 보내지 않았음 — 한 줄(`_session->Send(sender);`) 추가로 수정.
  - `TestPacket`은 상태를 바꾸지 않는 순수 echo라 무한 재시도해도 `Req_RoomEnter`와 달리 서버 측 race 위험이 없음 — `pingIntervalMs=200`으로 고빈도 전송 가능.
  - 구현: `ScenarioState.h`에 `pingInFlight`/`pingSentTime`/`lastPingSentTime` 필드 추가, `ScenarioConfig.h`에 `pingIntervalMs`(200)/`pingTimeoutMs`(3000) 추가, `ScenarioHandlers.h/.cpp`에 `Scenario_HandleResTestPacket`(RTT 계산+기록)과 `AdvancePing`(주기적 송신+타임아웃 판정) 추가. `AdvanceScenario`와 동일한 "락 안에서는 상태만 결정, 락 해제 후 Send" 패턴 적용.
  - `main.cpp`: `RegisterHandlers()`에 `PacketEnum::Test → Scenario_HandleResTestPacket` 등록, 메인 틱 루프에서 세션마다 `AdvanceScenario` 호출 직후 `AdvancePing`도 호출.
- [x] 5.2.2 스레드세이프 집계기 (성공/실패/타임아웃 카운트, RTT 분포) (M)
  - 신규 `MetricsAggregator.h/.cpp`: `USE_LOCK` 기반 싱글톤. `RecordRtt(double ms)`/`RecordTimeout()`으로 기록, `GetSnapshotAndReset()`이 그 시점까지의 구간 통계(성공/타임아웃 카운트, min/max/avg/p50/p95/p99)를 계산해 반환하고 내부 상태를 비움 — Phase 5.3의 주기적(10초 간격) 콘솔 리포트가 "구간별" 통계를 찍는 모델에 맞춰 설계.
  - 수정 파일: `DhNet_Server/DhNet_Server/TestController.cpp`(`_session->Send(sender);` 추가 + `#include "GameSession.h"` 추가 — `Session` 타입 미정의 컴파일 에러 해결), `ScenarioState.h`, `ScenarioConfig.h`, `ScenarioHandlers.h/.cpp`, `main.cpp`, 신규 `MetricsAggregator.h/.cpp`, `DhNet_StressTest.vcxproj`(신규 파일 2개 추가).
  - 빌드 검증: `DhNet_Server.sln`(`-t:DhNet_Server`) 0 에러, `DhNet_StressTest.sln` 0 에러.
- [x] **5.2 코드 리뷰 대응**: general-purpose 에이전트(code-architecture-reviewer 페르소나) 리뷰 실행. Critical 0건. Important 2건 즉시 수정(레지스트리 락 안에서 `MetricsAggregator` 락 중첩 호출 제거 — `AdvancePing`/`Scenario_HandleResTestPacket`을 `AdvanceScenario`와 동일한 "락 안에서는 상태만 결정" 패턴으로 통일; `TestController.cpp`의 불필요하게 무거운 `#include "GameSession.h"`를 `#include "../ServerCore/Session.h"`로 교체), 1건은 5.1 기존 설계 이슈(`Service::GetSessions()`의 매 틱 전체 복사 오버헤드)라 기록만 하고 미수정. Minor 1건(중복 `.clear()`) 반영. 재빌드 0 에러. 상세: `load-test-infra-context.md`.

## Phase 5.3 — 리포팅

- [ ] 5.3.1 주기적 콘솔 요약 출력 (10초 간격: 누적 연결 수/RTT 평균/에러 카운트) (S)
- [ ] 5.3.2 종료 시 CSV/텍스트 리포트 파일 생성 (S)

## Phase 5.4 — 서버 상태 교차 검증

- [ ] 5.4.1 Admin REST API 폴링 추가 (`/players`, `/lobbies`, `/rooms`) (M)
- [ ] 5.4.2 불일치 감지 시 경고 출력 (S)

## Phase 5.5 — 로거 병목 실측 + 결론

- [x] 5.5.0 워치독 단독 검증 (`Tools/diagnostics/watchdog_test`) — 서버 불필요, 선행 완료 (2026-06-19)
  - git stash에 있던 독립 테스트 도구. `DhUtil/Macro.h`의 `CRASH` 매크로(워치독 스레드가 500ms 후 무조건 크래시)가 실제로 효과 있는지 결정론적으로 검증.
  - 위치: 기존 `Tools/`는 이미 `Tools/include/`(grpc/absl/openssl vcpkg 헤더, 코드 생성 도구용)로 쓰이고 있어 성격이 달라 `Tools/diagnostics/watchdog_test`로 분리 배치(2026-06-19, 사용자 요청). 이동 후 재빌드+재실행으로 동작 동일함 확인.
  - spdlog 워커를 `HangingSink`로 영원히 멈추게 하고 큐(8192)를 필러 스레드로 가득 채워 "enqueue 자체가 막히는" 최악 상황을 재현. `OLD_CRASH`(워치독 패치 전 코드)와 `NEW_CRASH`(현재 `Macro.h` 코드)를 비교.
  - **실행 결과**: `old` 모드는 `timeout 8` 동안 살아남아 강제종료(exit 124) — 워치독 없으면 로거가 막힐 때 프로세스가 영원히 hang되는 버그를 재현. `new` 모드는 즉시 세그폴트(exit 139) — 현재 코드의 워치독이 의도대로 ~500ms 내 fail-fast시킴을 확인.
  - **결론**: `async_overflow_policy::block`이 워커 스레드를 영원히 멈추게 해도, 이미 적용된 워치독 덕분에 프로세스 자체는 무한 hang에 빠지지 않고 fail-fast함. 단, 이건 "프로세스가 안 죽고 영원히 응답불가 상태로 남는" 최악의 시나리오만 막아주는 안전망이고, "로거가 막혀서 그 사이 들어오는 요청들이 지연/누락되는" 일반적인 성능 저하 자체는 여전히 5.5.1/5.5.2(연결 폭주 실측)로 따로 확인해야 함 — 별개 문제.
  - git stash 정리: 스태시 내용이 작업 디렉토리에 이미 동일하게 존재해(줄바꿈 차이만) `git stash drop`으로 제거, 별도 커밋 없음(사용자 커밋 의사 확인 필요).
- [ ] 5.5.1 "연결 폭주" 부하 프로파일 설계/구현 (S)
- [ ] 5.5.2 정상 vs 연결 폭주 프로파일 실측 비교 (RTT/성공률) (M)
- [ ] 5.5.3 결론에 따른 조치: `DhUtil/Logger.cpp` 정책 변경 또는 "문제 없음" 문서화 (S)

## 작업 후 필수 절차 (CLAUDE.md RULE 2)

매 코드 작업 라운드마다 반복 실행 — 직전 라운드(5.2)에서도 둘 다 실행 완료:

- [x] 코드 작업 완료 후 `Skill("dev-docs-update")` 실행에 준해 작업 문서 직접 업데이트(이 도구 자체가 dev-docs 자동화이므로 `dev-docs-update` 스킬을 별도 호출하는 대신 동일한 갱신 작업을 이 응답에서 직접 수행)
- [x] 코드 리뷰 실행 (이 환경에는 `code-architecture-reviewer`가 agent type으로 등록되어 있지 않음 — `general-purpose` 에이전트에 페르소나를 위임해서 실행. 참고: 메모리 `project_missing_agent_types`)

## 참고

- 이 Phase는 [[project_phase5_logger_overflow_decision]] 메모리에 기록된 결정(로거 정책을 미리 안 고치고 실측 후 대응)을 직접 검증하는 작업을 포함한다 (5.5).
- 상세 배경/발견사항은 `load-test-infra-context.md`, 전체 계획은 `load-test-infra-plan.md` 참고.
