Last Updated: 2026-07-05 (Noti_* 브로드캐스트 자멸 버그 발견/수정 + Stuck/타임아웃 카운팅 실측 검증)

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

## Phase 5.3 — 리포팅 (2026-07-03 완료)

- [x] 5.3.1 주기적 콘솔 요약 출력 (10초 간격: 누적 연결 수/RTT 평균/에러 카운트) (S)
  - `MetricsAggregator`에 리셋되지 않는 누적 카운터 `m_totalConnections`(atomic) 추가 — `RecordConnection()`/`GetTotalConnections()`. `MakeService()`의 `SetOnConnectedExtra`에서 세션 연결마다 호출.
  - "에러 카운트" 정의를 사용자와 논의: 핑 타임아웃과 `Stuck`(재시도 한도 초과로 시나리오 진행 포기) 세션 수를 **별도 필드로 분리** — 둘을 하나로 합치면 세션이 조용히 멈춰도 RTT 통계가 계속 "건강하게" 보이는 맹점이 생김. `MetricsSnapshot`에 `stuckCount` 추가, `ScenarioHandlers.cpp`의 `LogStuckRoomEnter`/`LogStuckRoomExit` 처리부(기존 `Stuck` 전환 시 진단 로그 찍는 지점)에 `MetricsAggregator::Instance().RecordStuck()` 한 줄 추가.
  - 신규 `ReportManager` 싱글톤(`ReportManager.h/.cpp`) — `ReportInterval()`이 `MetricsAggregator::GetSnapshotAndReset()` 스냅샷을 콘솔에 출력하고 히스토리 벡터에 적재. `main.cpp` 메인 루프에 `lastReport` 타이머(`kReportIntervalSec=10`) 추가해 매 10초 호출.
  - **버그 발견 및 수정 (Critical)**: 최초 구현 시 콘솔 출력에 `std::wcout`(wide)를 썼으나, 같은 stdout에 `ServerSession::OnConnected`의 기존 `std::cout`(narrow, "Connected To Server")가 먼저 실행되어 stdout의 스트림 orientation이 narrow로 고정됨 — 이후 `std::wcout` 호출은 MSVC에서 조용히 아무것도 출력하지 않는 정의되지 않은 동작이 됨. 실제로 서버+클라이언트를 띄워 실측하기 전까지 리포트 줄이 전혀 안 찍히는 걸로 발견. `ReportManager`의 콘솔 출력 전부를 `std::cout`(narrow)로 통일해 해결(CSV 파일 스트림은 stdout과 무관한 별도 `std::wofstream`이라 wide 유지, 문제 없음). `main.cpp`의 기존 churn 로그(`std::wcout`, 30초 간격)도 동일한 잠재적 문제가 있으나 이번 작업 범위 밖이라 미수정 — 후속 참고사항으로 기록.
  - 실측 검증: 로컬에서 서버(DB 없이) + StressTest(서비스 2×세션 3) 실행, 10초 뒤 `[리포트 19:20:37] 누적연결=6 RTT(ms) avg=0.58 p95=0.96 p99=1.23 성공=276 핑타임아웃=0 Stuck세션=0` 정상 출력 확인 (로그인은 DB 없어 실패하지만 RTT 핑은 로그인과 무관하게 독립 동작 확인됨).
- [x] 5.3.2 종료 시 CSV/텍스트 리포트 파일 생성 (S)
  - `ReportManager::WriteFinalReport()` — 누적 히스토리를 `report_<타임스탬프>.csv`로 저장(구간별 RTT/성공/타임아웃/Stuck + 마지막 줄에 전체 합산 요약).
  - 메인 루프가 원래 `while(true)`로 종료 지점이 없었음 — `SetConsoleCtrlHandler`로 `CTRL_C_EVENT`/`CTRL_BREAK_EVENT`/`CTRL_CLOSE_EVENT` 핸들러 등록, 핸들러에서 `WriteFinalReport()` 실행 후 `ExitProcess(0)`으로 종료(CTRL_C/BREAK는 핸들러가 TRUE 반환해도 기본 종료 동작이 억제되므로 명시적 종료 필요).
  - **미검증 항목**: 이 세션 환경(bash 툴)에서 실행 중인 Windows 콘솔 프로세스에 실제 `CTRL_C_EVENT`를 전달하는 게 어려워(taskkill은 강제종료라 핸들러 우회) 실제 Ctrl+C 트리거 후 CSV 파일 생성까지는 실측하지 못함. 코드 경로 자체는 5.3.1에서 이미 검증된 `GetSnapshotAndReset()`/히스토리 적재 로직을 그대로 재사용하고 파일 I/O는 표준 `std::wofstream`이라 리스크는 낮다고 판단하지만, 다음 세션에서 실제 콘솔(터미널)에서 Ctrl+C로 한 번 확인 권장.
  - 신규 파일: `ReportManager.h/.cpp` (`DhNet_StressTest.vcxproj`에 추가, `.filters`는 기존 관행대로 미갱신).

빌드 검증: `DhNet_Server.sln`(`DhUtil`/`ServerCore`/`DhNet_Server` 전체), `DhNet_StressTest.sln` 모두 0 에러. (참고: 이 PC는 이번 세션에서 최초로 vcpkg install 수행 — `external/vcpkg/installed` junction 재생성 포함)

### 5.3 완료 후 코드 리뷰 대응 (2026-07-03)

general-purpose 에이전트(code-architecture-reviewer 페르소나)로 리뷰 실행. Critical 0건, Important 3건 전부 즉시 수정, Minor 4건 중 1건 반영·나머지는 기록만:

- [x] **Important**: `ReportManager.cpp`의 파일 생성 실패 진단 메시지가 `std::cerr`(narrow)였는데, `ScenarioHandlers.cpp`의 Stuck 진단 로그(`std::wcerr`, 200ms마다 평가되어 훨씬 자주 실행됨)가 먼저 stderr의 orientation을 wide로 고정시켜 이 메시지가 조용히 안 찍힐 위험이 있었음(stdout의 wcout/cout 혼용 버그와 동일한 원인) → `std::wcerr`로 통일해 수정.
- [x] **Important**: `WriteFinalReport()`가 `m_history`(10초 주기 스냅샷)만 덤프하고 마지막 미완결 구간(Ctrl+C 시점까지 쌓였지만 아직 10초가 안 지난 RTT/성공/타임아웃/Stuck)은 반영 안 해 그대로 유실되는 문제 → `WriteFinalReport()` 시작 시 `ReportInterval()`을 한 번 더 호출해 마지막 구간을 히스토리에 반영 후 CSV로 덤프하도록 수정.
- [x] **Important**: `ConsoleHandler`가 재진입 가드가 없어, 콘솔 제어 이벤트가 연달아 들어오면(Windows는 각 이벤트를 별도 스레드에서 처리) 두 스레드가 동시에 `WriteFinalReport()`를 호출 → 초 단위 타임스탬프라 같은 파일명에 동시에 `std::wofstream`을 열고 `ExitProcess` 경쟁까지 발생할 수 있었음 → `static std::atomic<bool> s_handling`으로 최초 1회만 처리하도록 수정.
- [x] **Minor**: `ReportManager.h`의 "Ctrl+C 핸들러가 종료 시 1회만 읽음" 주석이 실제로는 메인 스레드의 다음 `ReportInterval()`과 동시 실행될 수 있다는 사실을 감추고 있어(뮤텍스로 안전은 하지만 순서 보장은 아님) 주석을 정정.
- Minor 3건은 기록만 하고 미수정: CSV 끝의 `#` 요약 줄이 엄격한 CSV 파싱을 깨뜨림(필요 시 후속 작업), `CTRL_LOGOFF_EVENT`/`CTRL_SHUTDOWN_EVENT` 미처리(의도적, 인터랙티브 도구라 낮은 우선순위), 매우 긴 소크 테스트 시 `CTRL_CLOSE_EVENT`의 종료 유예 시간 내 CSV 쓰기 완료 여부(현재 스케일에서는 무관).
- 재빌드 0 에러 확인, 콘솔 리포트 재실측으로 회귀 없음 확인(`누적연결=6 ... Stuck세션=0`).
- **미해결로 기록만**: Ctrl+C→`WriteFinalReport()` 실제 트리거 후 CSV 파일 생성 자체는 이번 세션 환경(자동화 셸)에서 실제 `CTRL_C_EVENT` 전달이 어려워 실행 검증 못함 — 다음 세션에서 실제 터미널로 한 번 확인 권장.

### 5.3 후속 — cout/wcout/cerr/wcerr 전부 LOG_* 로거로 전환 (2026-07-03, 사용자 요청)

Phase 5.3 작업 중 발견한 wcout/cout stdout orientation 버그를 계기로, 사용자가 "이런 것들은 어지간하면 파일로그로 쌓이게 해달라"고 요청 — `DhNet_Client`(인터랙티브 클라이언트) + `DhNet_StressTest` 전체 범위로 진행(사용자 확인).

- [x] **`DhUtil/Logger.{h,cpp}` — 실행파일별 로그 파일 분리**. 기존에는 로그 파일 경로가 `"logs/dhnet-server.log"`로 하드코딩되어 있어, 서버+클라이언트+스트레스테스트를 같은 작업 디렉터리에서 동시 실행하면(부하테스트의 기본 시나리오) 여러 프로세스가 같은 파일에 동시 rotate/write하는 위험이 있었음 → `Logger::SetLogFileName(name)` 추가(첫 `Get()` 호출 전에 호출해야 함, 기본값 `dhnet-server.log` 유지로 서버는 무변경). `DhNet_Client::main()`/`DhNet_StressTest::wmain()` 최상단에서 각각 `"dhnet-client.log"`/`"dhnet-stresstest.log"`로 설정.
  - **버그 발견(부수적)**: `spdlog::flush_every(3초)`가 spdlog 전역 레지스트리 기반인데 기존 `CreateLogger()`가 로거를 `spdlog::register_logger()`로 등록한 적이 없어 주기적 flush가 애초에 전혀 동작 안 하고 있었음 — 서버는 DB 재연결 경고(WARN 레벨, `flush_on(warn)` 트리거)가 잦아서 우연히 가려져 있었을 뿐, info 레벨만 찍는 프로세스(StressTest 등)는 몇 분이 지나도 로그 파일이 0바이트로 남을 수 있었음. 실측(스트레스테스트 실행 후 파일 0바이트 확인)으로 발견, `register_logger()` 추가로 해결 후 재실측(콘솔=파일 내용 일치) 확인.
  - 코드 리뷰(Important 2건) 반영: (1) `ConsoleHandler`의 `ExitProcess(0)`가 비동기 로거 워커를 그대로 죽여 "최종 리포트 저장 완료" 등 마지막 info 로그가 flush 전에 유실될 수 있어 `ExitProcess` 직전에 `LoggerShutdown()` 추가. (2) `SetLogFileName`이 첫 `Get()`보다 늦게 불리면 조용히 무시되던 문제 — 향후 전역 정적 객체 생성자가 `LOG_*`를 먼저 호출하는 회귀가 생겨도 알아챌 수 있도록 "이미 생성됨" 플래그 추가, 위반 시 `LOG_WARN`으로 남기도록 수정. Minor 1건(`register_logger` 예외 미처리) 방어적 try/catch 추가.
- [x] **cout/wcout/cerr/wcerr → LOG_INFO/WARN/ERROR/TRACE 전환**: `ServerSession.cpp/h`(공유, 3곳+소멸자), `ClientLobbyController.cpp`(4곳), `RoomController.cpp`(4곳), `LoginController.cpp`(1곳), `DhNet_StressTest/main.cpp`(churn 로그), `ScenarioHandlers.cpp`(Stuck 진단 2곳), `ReportManager.cpp`(리포트 3곳) — `<<` 체이닝을 fmt 스타일 `{}` 플레이스홀더로 변환. 코드 리뷰로 fmt의 `char[16]`/`char[256]` 패킷 필드 포맷팅이 안전함(vcpkg 벤더 fmt 12.1.0 소스로 직접 확인, `strlen` 기반 처리) 확인됨.
- 빌드 검증: `DhUtil`, `DhNet_Server`, `DhNet_Client.sln`, `DhNet_StressTest.sln` 전부 0 에러. 실측: 서버+스트레스테스트 동시 실행 시 `logs/dhnet-server.log`(레포 루트, 서버 cwd)와 `DhNet_Client/x64/Debug/logs/dhnet-stresstest.log`(스트레스테스트 cwd)로 정상 분리되어 기록됨, 콘솔 출력과 파일 내용 일치 확인.
- **알려진 제한 (기록만, 미수정)**: 로그 파일 분리가 실행파일 단위라 같은 `DhNet_StressTest.exe`를 여러 프로세스로 동시 실행하면(스케일아웃 시) 여전히 파일명이 충돌함 — 현재 사용 패턴(1개 프로세스)에서는 무관, 필요해지면 PID/커맨드라인 인자로 suffix 추가 검토.

### 5.3 후속 2 — 실행 시간 지정 자동 종료 + Ctrl+C 경로 실측 검증 (2026-07-03, 사용자 요청)

Ctrl+C→CSV 저장 경로를 이 세션 환경(자동화 셸)에서 직접 트리거할 방법이 없어 실측 미검증 상태였음 — 사용자가 "시간 지나면 알아서 꺼지게" 요청, 같은 종료 경로를 자동으로도 타게 만들어 실측 가능하게 함.

- [x] `argv[10] = 실행시간(초)` 추가(기본 0=무제한, 기존 호출부 무변경). `main.cpp`의 `ConsoleHandler` 내부 로직을 `GracefulShutdown()` 공용 함수로 분리(재진입 가드 `s_shuttingDown` 포함)해 Ctrl+C 경로와 타임아웃 경로가 동일한 절차(리포트 저장→로그 flush→종료)를 타도록 통일. 메인 루프에 `startTime` 대비 경과 시간 체크 추가.
- **실측으로 발견한 Critical 버그**: 실행시간 12~15초로 자동 종료 테스트해보니 CSV 파일과 "[리포트]" 로그는 정상 기록되는데 그다음 줄(`WriteFinalReport()` 끝의 "최종 리포트 저장 완료" `LOG_INFO`)이 로그 파일/콘솔 양쪽에서 전부 누락됨. vcpkg 벤더 spdlog 소스(`async_logger-inl.h`)를 직접 열어 원인 확인: `async_logger::flush_()`는 flush "요청"을 워커 스레드 큐에 던지기만 하고 **처리 완료를 기다리지 않는 비동기 호출**(`post_flush`는 `post_log`와 동일한 fire-and-forget 큐잉 메커니즘) — 그래서 `LoggerShutdown()` 직후 바로 `ExitProcess(0)`을 부르면 워커 스레드가 flush 요청은커녕 직전 로그조차 처리하기 전에 프로세스가 죽는 레이스가 실제로 발생함.
  - **수정**: `GracefulShutdown()`에서 `LoggerShutdown()`과 `ExitProcess(0)` 사이에 `std::this_thread::sleep_for(200ms)` 추가 — 워커 스레드가 큐를 비울 시간 확보. 재실측으로 "최종 리포트 저장 완료" 로그가 파일에 정상 기록됨을 확인(`[2026-07-03 23:06:13.603] ... 최종 리포트 저장 완료: report_20260703_230613.csv`).
  - 이 버그는 이전 라운드(Ctrl+C 핸들러에 `LoggerShutdown()` 추가)에서 "flush했으니 안전하다"고 판단했던 부분이 실제로는 async_logger에서 불충분했다는 뜻 — sleep 기반 완화는 근본 해결이 아니라 실용적 우회(200ms는 이 로거의 큐 처리 속도 대비 충분히 넉넉한 여유값). 워커 처리량이 훨씬 낮아지는 극단적 상황(디스크 I/O 병목 등)에서는 여전히 이론적으로 레이스가 남아있음 — Phase 5.5(로거 병목 실측)와 연관된 참고사항으로 기록.
- **Ctrl+C 경로도 간접 검증됨**: 이제 Ctrl+C와 타임아웃 종료가 `GracefulShutdown()`이라는 동일한 코드 경로를 공유하므로, 타임아웃 경로의 실측 성공(CSV+로그 모두 정상 기록)이 Ctrl+C 경로의 정확성도 사실상 함께 검증함. 다만 "OS가 실제로 CTRL_C_EVENT를 정상 전달하는지" 자체는 여전히 별개(이 부분만 미검증으로 남음, 표준 Windows API라 리스크 낮음으로 판단).
- 빌드 검증: `DhNet_StressTest.sln` 0 에러. 실측: `argv[10]=12` 지정 후 프로세스가 스스로 `exit code 0`으로 종료, CSV 파일 생성, 콘솔+파일 로그에 "지정된 실행 시간(12초) 경과 — 자동 종료"와 "최종 리포트 저장 완료" 모두 정상 기록 확인.

### 5.3 후속 3 — Noti_* 브로드캐스트 자멸 버그 발견/수정 + Stuck/타임아웃 카운팅 실측 (2026-07-05)

이전까지 Stuck/핑타임아웃 카운트가 실측에서 단 한 번도 0이 아닌 값으로 관측된 적이 없었음 — Docker/MySQL을 기동해 로그인을 실제로 성공시킨 뒤 원인을 추적한 결과, StressTest 시나리오 자체의 기존 결함(이 세션에서 만든 버그 아님)을 발견함.

- **근본 원인**: `DhNet_StressTest`의 `RegisterHandlers()`가 `Noti_LobbyChat`/`Noti_RoomChat`/`Noti_RoomExit`/`Noti_LobbyPlayerEnter`/`Noti_LobbyPlayerExit`에 대한 핸들러를 전혀 등록하지 않았음. 이 패킷들은 서버가 로비/룸 멤버 **전원(본인 포함)** 에게 브로드캐스트하는 알림(`Lobby::Chat`/`Room::Broadcast` 등, 자기 자신 제외 로직 없음) — 미등록 패킷 수신 시 `Handler<T>::Process`(`ServerCore/Handler.h:34`)가 `false`를 반환하고, 이는 `ServerSession::OnRecv`를 거쳐 공유 코드인 `Session::ProcessRecv`(`ServerCore/Session.cpp:250-252`)에서 클라이언트가 **자기 자신을 `Disconnect(L"OnRead Error")`로 끊어버리는** 결과로 이어짐. 즉 세션이 로비 채팅을 단 한 번만 보내도 그 즉시 자멸 — 대부분의 세션이 룸 근처도 못 가고 끊겼던 것, Stuck/타임아웃이 한 번도 관측 안 됐던 것 모두 이 버그로 설명됨.
- **진단 과정**: (1) Docker Desktop 기동 → 기존 `dhnet_mysql` 컨테이너 자동 기동 확인 (2) DB의 `testuser` 해시가 이미 실제 값으로 패치되어 있었음을 확인(단, `docker/mysql/init/01_schema.sql` 소스 파일은 여전히 플레이스홀더 `0000...0`라 신규 볼륨 생성 시 재현 안 됨 — 별도 동기화 필요, 낮은 우선순위로 보류) (3) 서버+StressTest 로그인 성공 확인 (4) Stuck을 강제 유도(타임아웃/재시도값 임시 하향 + `Noti_RoomEnter` 처리 임시 무력화)해도 `Stuck세션=0`이 계속 나와 이상함을 감지 (5) 단일 세션으로 격리해도 100% 재현되는 조기 `Disconnect : OnRead Error`(로거 레벨을 임시로 debug로 낮춰 원인 문자열 확인)를 발견 (6) 끊기는 타이밍이 `lobbyChatIntervalMs`와 정확히 비례함을 확인해 `Req_LobbyChat` 전송이 방아쇠임을 특정 (7) `Handler.h`/`Session.cpp` 코드 추적으로 근본 원인 확정.
- **수정**: `ScenarioHandlers.h/cpp`에 `Scenario_HandleIgnoredBroadcastPacket`(아무 것도 안 하고 `true`만 반환) 추가, `main.cpp`의 `RegisterHandlers()`에서 `Noti_LobbyChat`/`Noti_LobbyPlayerEnter`/`Noti_LobbyPlayerExit`/`Noti_RoomChat`/`Noti_RoomExit` 5개에 등록.
- **실측 검증**: 수정 전 — 세션 수와 무관하게 로비 채팅 전송 즉시 자멸(단일 세션 3회 재현 100%). 수정 후 — 15세션·25초 풀 시나리오(로비채팅 2회→룸입장→룸채팅 5회→룸퇴장) 반복 실행 동안 **연결 끊김 0회**. Stuck 카운팅 자체는 임시로 `roomActionTimeoutMs=500/maxRoomActionRetries=1` + `Noti_RoomEnter` 무력화로 강제 유도해 `Stuck세션=1`이 리포트/CSV에 정확히 기록됨을 확인 후 원복.
- 남은 미검증: 핑 타임아웃 카운트(로컬 서버라 항상 0으로만 관측됨 — 인위적 지연 유도가 필요하나 우선순위 낮음으로 보류).
- 빌드: `DhUtil.vcxproj`, `DhNet_StressTest.sln` 각각 0 에러로 재빌드 확인. `DhNet_StressTest.vcxproj`를 솔루션 없이 직접 빌드하면 `$(SolutionDir)`가 비어 다른 경로(`DhNet_StressTest\x64\Debug`)에 산출물이 생겨 실행 파일이 안 바뀐 것처럼 보이는 함정 발견 — 항상 `DhNet_StressTest.sln`으로 빌드해야 함.

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
