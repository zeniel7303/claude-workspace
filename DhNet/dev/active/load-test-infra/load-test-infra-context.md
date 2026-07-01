Last Updated: 2026-06-19

# 부하 테스트 인프라 (Phase 5) — Context

## 배경

README.md 로드맵의 마지막 미완 항목. 직전 작업(로깅 시스템 도입, Critical 2건 해결, Important 2건 해결)을 마친 뒤 진입 전 종합 코드 리뷰를 거쳤고, 그 리뷰에서 나온 Important 이슈(spdlog `async_overflow_policy::block`이 고부하 시 IOCP 워커 전체를 블로킹시킬 수 있는 위험)를 "이론적으로 먼저 고치지 말고 Phase 5에서 실측 후 대응"하기로 사용자가 결정했음. 이 결정은 메모리(`project_phase5_logger_overflow_decision`)에도 저장됨. **이 Phase 5는 단순 부하 생성기가 아니라, 그 결정을 검증할 실측 도구를 포함해야 한다.**

## 현재 상태에서 발견한 핵심 사실 (코드만 봐서는 바로 드러나지 않는 것들)

1. **`DhNet_StressTest`는 이름만 부하 테스트, 실제로는 게임 로직을 전혀 거치지 않는다.**
   - `ServerSession::OnConnected()`(`DhNet_Client/DhNet_Client/ServerSession.cpp:94-95`)가 핸드셰이크 완료 시 자동으로 `testuser`/`testpass` 로그인을 보내므로 로그인까지는 실제로 일어남
   - 로그인 이후에는 `main.cpp`의 메인 루프가 그냥 `TestPacket`(의미 없는 echo)을 반복 전송할 뿐 — `Req_LobbyChat`/`Req_RoomEnter`/`Req_RoomChat`/`Req_RoomExit` 등 실제 패킷은 전혀 안 씀
   - **(정정) `TestController.h`의 `RecvTestPacket`에 `std::this_thread::sleep_for(1초)`가 있지만, 실제로는 실행되지 않는 죽은 코드다.** 서버 측 핸들러(`DhNet_Server/DhNet_Server/TestController.cpp`의 `HandleTestPacket`)가 `Sender::Alloc`/`GetWritePointer`로 패킷을 준비만 하고 `_session->Send(...)`를 호출하지 않아 — 서버는 `TestPacket`에 대해 echo 응답을 절대 보내지 않음. 따라서 클라이언트가 `PacketEnum::Test`를 수신해 `RecvTestPacket`이 호출되는 경로 자체가 발생하지 않고, 1초 sleep도 실행되지 않음. 부하 스로틀링 효과는 없었음 — 처음 분석이 틀렸던 부분, 바로 수정.
   - 실제 부하 특성은: 각 서비스가 `msgPerSecond` 주기로 자신의 모든 세션에 대해 **응답 없는 fire-and-forget** `TestPacket`을 한 번씩 전송. RTT 측정도 원천적으로 불가능한 구조.
2. **측정/리포트가 전혀 없다.** 기존 코드는 "서비스 재생성 완료" 로그 한 줄뿐, RTT/성공률/에러 카운트 등 어떤 지표도 안 모음. Phase 5의 핵심 가치는 이 인프라를 새로 만드는 것 자체임.
3. **Admin REST API(Phase 4 산물)를 부하 테스트에서 전혀 활용하지 않고 있다.** `GET /players`, `/lobbies`, `/rooms`, `/health`가 이미 동작 중이므로, 부하 테스트 중 서버 상태를 외부에서 폴링해 클라이언트 추적치와 교차 검증하는 데 그대로 쓸 수 있음 — 새로 만들 필요 없음.
4. **테스트 계정이 `testuser` 하나뿐.** 다수 동시 로그인을 시뮬레이션하려면 동일 계정 동시 로그인이 서버에서 어떻게 처리되는지(거부? 허용? 세션 덮어쓰기?) 먼저 확인이 필요. 미확인 상태.
5. **`DhNet_MAX_SESSION_COUNT` 기본값 1000.** 의도적으로 이 한도를 넘기는 시나리오를 설계한다면 슬롯 부족 시 서버 거부 응답이 정상 동작하는지도 부수적으로 검증 가치가 있음.

## 주요 결정사항

- **로거 정책을 먼저 고치지 않는다.** Phase 5 진행하며 실제로 병목이 나타나는지 관찰 후 대응 (사용자 명시적 결정, 2026-06-19). 관련 메모리: `project_phase5_logger_overflow_decision`.
- **2개 커밋으로 분리된 직전 작업**(`a2258b5` 빌드 회귀 수정, `9e970d3` C# Important 이슈 수정)은 Phase 5 착수 전 별도 종합 리뷰(general-purpose agent에 code-architecture-reviewer 페르소나 위임)를 거쳤음 — Critical 0건, Important 1건(로거 block 정책, 위 참고)만 남음.

## 주요 파일

- `DhNet_Client/DhNet_StressTest/main.cpp` — 부하 생성기 메인. 이번 Phase에서 시나리오 루프/메트릭/리포팅을 추가할 핵심 위치
- `DhNet_Client/DhNet_Client/TestController.h` — 제거 대상인 1초 sleep이 들어있는 leftover 핸들러
- `DhNet_Client/DhNet_Client/ServerSession.cpp` — 자동 로그인 로직(재사용), 향후 RTT 측정을 위한 송신 타임스탬프 삽입 지점이 될 수 있음
- `DhNet_Client/DhNet_Client/{LoginController,RoomController,ClientLobbyController}.h/.cpp` — 기존 패킷 핸들러, 콘솔 출력 위주라 메트릭 집계 로직 추가 필요
- `DhNet_Server/DhNet_Server/ServerSetting.cpp` — `DhNet_MAX_SESSION_COUNT`, `DhNet_DB_POOL_SIZE` 등 부하 테스트 시 의식해야 할 환경변수 정의
- `DhNet_Server/DhNet_Web/` — Admin REST API. Phase 5 교차 검증용으로 그대로 재사용 (수정 불필요 예상)
- `DhUtil/Logger.cpp` — 실측 결과에 따라 `async_overflow_policy` 변경 여부를 결정할 최종 대상 파일

## 의존성 / 전제조건

- MySQL Docker 컨테이너 기동 필요 (`docker/docker-compose.yml`) — 로그인 시나리오 테스트용
- `testuser` 계정의 비밀번호 해시가 DB에 세팅되어 있어야 함 (README "테스트 계정 설정" 섹션 참고)
- 직전 세션에서 `DhNet_Client.sln` 빌드 회귀가 수정된 상태 (`a2258b5`) — 이 위에서 작업 시작 가능, 별도 빌드 수정 불필요

## 5.1 구현 완료 후 추가로 발견한 핵심 사실

6. **`Res_RoomEnter`/`Res_RoomExit`는 와이어 상에서 죽은 패킷이다.** `Player.cpp`의 `EnterRoom()`/`EnterRoomFailed()`/`LeaveRoom()`/`LeaveRoomFailed()`를 보면 해당 패킷을 보내는 코드가 전부 `/* ... */`로 주석 처리되어 있음 — 패킷 타입(`PacketList.h`)과 클라이언트 핸들러(`HandleResRoomEnterPacket`)는 존재하지만 서버가 실제로 보내는 일이 없음. 룸 입장 확인은 `Noti_RoomEnter`(룸 전원에게 브로드캐스트, 자기 `playerId` 매칭 필요)로, 룸 퇴장 후 로비 복귀 확인은 뒤따라오는 `Res_LobbyEnter` 재수신으로만 가능. `ReqRoomEnter`도 실패 응답이 전혀 없어(룸이 가득 차 `EnterRoomFailed()`가 호출돼도 클라이언트는 무응답) 클라이언트 쪽에서 타임아웃 기반 재시도가 필요함 — `ScenarioHandlers.cpp`의 `AwaitingRoomEnter`/`AwaitingRoomExit` 분기가 이를 처리.
7. **동일 계정 동시 로그인은 서버가 거부하지 않는다.** `LoginController.cpp`에 중복 검사가 없고, `PlayerSystem::Add`가 `unordered_map::insert`(키 충돌 시 무시, 덮어쓰지 않음)이므로 동일 `accountId`로 여러 세션이 로그인하면 각자 독립된 `Player` 객체로 정상 동작하지만 `PlayerSystem`의 맵에는 첫 세션만 남는다. `Remove`는 ID로 무조건 `erase`하므로, 맵에 없는(두 번째 이후) 세션이 먼저 끊기면 무해하지만, **첫 세션이 끊기기 전에 두 번째 세션이 끊기면 erase가 빗나가 아무 일도 없고, 반대로 첫 세션이 끊기면 맵에서 정상 제거된다 — 다만 두 번째 이후 세션들은 처음부터 맵에 없었으므로 영향 없음.** 결론: 게임플레이 자체는 세션마다 독립적으로 정상 작동하므로 부하 테스트 진행에 지장 없음. 다만 **Admin REST(`GET /players`)는 동일 계정으로 접속한 동시 세션 수를 과소집계**하게 되므로, Phase 5.4(서버 상태 교차 검증)에서 이 제약을 감안해야 함 — 정확한 동시접속 수 검증을 하려면 테스트 계정을 여러 개 만들어야 하나, 현재는 1개(`testuser`)뿐이라 5.4 시점에 재검토 필요.

## 5.1에서 만든/수정한 파일

- **신규**: `ScenarioConfig.h`(설정 구조체), `ScenarioState.h`(단계 enum+상태 구조체), `ScenarioStateRegistry.h/.cpp`(Session* 키, `USE_LOCK` 기반 스레드세이프 레지스트리 — 포인터 재사용 위험 때문에 connect/disconnect 시점에 반드시 Register/Unregister 호출 필요), `ScenarioHandlers.h/.cpp`(Res_LobbyEnter/Noti_RoomEnter 핸들러 + `AdvanceScenario` 틱 함수)
- **수정**: `DhNet_StressTest/main.cpp`(TestPacket 경로 제거, 시나리오 틱 루프로 교체, CLI 인자 확장), `DhNet_StressTest/DhNet_StressTest.vcxproj`(신규 파일 추가, `RoomController.cpp`/`TestController.h` 참조 제거)
- **수정(공용 파일, DhNet_Client 인터랙티브 도구와 공유)**: `DhNet_Client/ServerSession.h/.cpp` — 범용 lifecycle 훅 `m_onConnectedExtra`/`m_onDisconnectedExtra`(기본 no-op) 추가. 인터랙티브 도구는 이 훅을 설정하지 않으므로 동작 변화 없음.
- **수정(서버 코어, `DhNet_Server.sln`에도 포함)**: `ServerCore/Service.h/.cpp` — 읽기 전용 `GetSessions()` 스냅샷 접근자 추가(`READ_LOCK`, `ClientService::End()`와 동일한 snapshot-then-act 패턴). 기존 동작에는 영향 없는 순수 추가.
- 빌드 확인: `DhNet_Server.sln` / `DhNet_Client.sln` / `DhNet_StressTest.sln` 3개 솔루션 모두 0 에러.

## 5.1 코드 리뷰 대응 (2026-06-19)

5.1 완료 직후 general-purpose 에이전트(code-architecture-reviewer 페르소나)로 리뷰 실행. 결과:

- **Critical**: `AwaitingRoomEnter`/`AwaitingRoomExit`의 타임아웃 재시도가 무한 반복 — 서버 `HandleReqRoomEnterPacket`(`RoomController.cpp`)이 멱등하지 않아(매 호출마다 `LeaveLobby()`+`GetNotFullRoom()`/`MakeRoom()`+`room->DoAsync(Room::Enter)` 재실행), 첫 요청이 서버 async 큐에 아직 처리 대기 중일 때 재시도가 도착하면 중복 `Room::Enter`가 큐잉되어 `Player::SetCurrentRoom()`(동기화 없는 단순 대입) race 가능. **수정 완료**: 재시도 횟수 한도(`ScenarioConfig::maxRoomActionRetries`, 기본 3) 추가, 초과 시 `ScenarioPhase::Stuck`으로 전환(더 이상 재전송 안 함) + 진단 로그.
- **Important**: `ScenarioStateRegistry::Apply()`가 `WRITE_LOCK`을 쥔 채 콜백 안에서 `Session::Send()`를 직접 호출 — 매 틱 모든 세션 전송이 레지스트리 락 하나로 직렬화됨. **수정 완료**: `AdvanceScenario`를 "락 안에서 상태만 결정해 `ScenarioAction` enum 반환" + "락 해제 후 실제 Send" 구조로 분리.
- **Important (보류, 사용자 결정 완료)**: `main.cpp`의 `services` 벡터가 IOCP 디스패치 스레드(읽기, 람다 캡처)와 메인 스레드 churn 로직(erase/push_back, 락 없음) 사이에서 동기화 없이 공유됨. 리뷰어가 "이 변경으로 새로 생긴 문제가 아닌 pre-existing"으로 명시. **사용자가 Phase 5 후속 작업으로 미루기로 결정(2026-06-19)** — StressTest 전용 코드라 production 서버 미영향, churn이 활성화되는 부하 시나리오에서 실제로 트리거될 수 있는 race이므로 완전히 닫힌 건 아님. 별도 작업으로 재검토 필요.
- **2차 리뷰 완료**: 위 Critical/Important 수정 자체에 새 버그가 있는지 general-purpose 에이전트로 재검증 — "이상 없음". `actionRetries`가 `ScenarioState{}` 기본 생성자에서 0으로 초기화되고 단계 전환 시점에 재리셋되어 누락 경로 없음, `action` 지역 변수는 동일 스레드 순차 실행이라 데이터 레이스 없음, `Stuck` 전환 후 default case로 빠져 재전송이 완전히 멈춤(반복 로그 없음) 확인.
- **Important (chained, 자동 해소)**: 위 Critical이 `Lobby::Enter`의 `try_emplace` 충돌을 유발하면 실패 경로에 `Res_LobbyEnter` 미전송이라 세션이 영구 stranding될 수 있음 — Critical 수정(재시도 한도+Stuck 전환)으로 무한 재시도 자체가 사라져 사실상 같이 해소됨.
- Minor 4건(미사용 변수명, `ReqRoomExit::Init()` 일관성, 캐스팅 스타일, 포인터 업캐스트 주석)은 스타일 수준 — 미반영, 필요 시 후속.
- 수정 파일: `ScenarioState.h`, `ScenarioConfig.h`, `ScenarioHandlers.cpp`. 빌드 재검증(`DhNet_StressTest.sln`) 0 에러.

## Phase 5.5.0 — 워치독 단독 검증 (2026-06-19)

git stash에 있던 `Tools/watchdog_test/`(독립 cl.exe 빌드, 솔루션 미포함)를 복구해 실행. 내용은 stash 안에서나 작업 디렉토리에나 동일했음(줄바꿈 문자만 차이) — `git stash drop`으로 정리, 별도 커밋은 아직 안 함.

**위치 정리 (2026-06-19)**: 루트 `Tools/`는 이미 `Tools/include/`(grpc/absl/openssl 등 vcpkg 헤더, 코드 생성 도구용)로 쓰이고 있어 성격이 다름을 사용자가 지적 — `Tools/diagnostics/watchdog_test`로 이동해 "개발자 진단 도구" 카테고리를 명확히 분리. 이동 후 재빌드(`build.bat`) + 재실행으로 동작 확인(`new` 모드 세그폴트 재현 성공). 이전 빈 디렉토리는 Windows 파일 핸들 잠금으로 즉시 안 지워졌다가 재시도 후 삭제됨.

- 검증 대상: `DhUtil/Macro.h`의 `CRASH` 매크로에 이미 적용된 워치독(별도 스레드가 500ms 후 무조건 크래시)이 "LOG_CRITICAL/LoggerShutdown이 멈춰도 fail-fast하는가"를 보장하는지.
- 방법: spdlog 워커를 `HangingSink`로 영원히 멈추게 하고 큐(8192)를 가득 채워 enqueue 자체가 막히는 최악 상황 재현. `OLD_CRASH`(워치독 전)와 `NEW_CRASH`(현재 코드) 비교.
- **실행 결과**: `old` → 8초 타임아웃까지 생존(강제종료, exit 124) = 버그 재현. `new` → 즉시 세그폴트(exit 139) = 워치독 정상 작동.
- **결론**: `async_overflow_policy::block`으로 워커가 영원히 멈추는 최악의 경우에도 프로세스는 무한 hang 없이 fail-fast함. 단, 이건 "영원히 응답불가로 남는 것"만 막아주는 안전망이며, 로거가 막혀있는 동안 일반 요청 처리가 지연/저하되는 문제는 별개 — 그건 여전히 5.5.1/5.5.2(연결 폭주 실측)로 확인해야 함.

## Phase 5.2 — RTT 측정 + 집계기 (2026-06-19)

### 설계 검토: RTT를 무엇으로 측정할 것인가

세 가지 옵션을 검토:
1. 기존 채팅/룸 패킷에 타임스탬프를 끼워넣는 방식 — 기각. `Req_LobbyChat`/`Req_RoomChat`은 서버가 송신자 본인에게 응답을 안 보내(브로드캐스트/무응답) RTT 계산이 원천적으로 불가능.
2. `Req_RoomEnter`/`Req_RoomExit` 송수신 시각 차이 활용 — 기각. 사이클당 2번뿐이라 분포 표본으로 너무 희소하고, 이미 Critical 수정으로 재시도 한도(`maxRoomActionRetries`) 로직이 붙어있어 고빈도 핑 목적과 섞으면 안 됨(서버가 멱등하지 않아 재시도 자체가 race 위험 요소).
3. **(채택)** `PacketEnum::Test`의 죽어있던 echo를 되살려 시나리오와 완전히 독립적인 전용 핑 채널로 사용. 사용자에게 "뭐가 나을까" 질문을 받고 1·2의 한계를 설명한 뒤 이 3번을 새로 제안, "알았어 이렇게 진행해줘"로 승인받음.

**되살린 죽은 버그**: `DhNet_Server/DhNet_Server/TestController.cpp`의 `HandleTestPacket`이 `Sender::Alloc<TestPacket>()`+`GetWritePointer`로 응답 패킷을 준비만 하고 `_session->Send(sender)`를 호출하지 않았음 — 서버가 `Test` 패킷에 echo를 절대 안 보내던 진짜 원인. 한 줄 추가(`_session->Send(sender);`)로 수정. (참고: `DhNet_Client/DhNet_Client/TestController.h`의 `RecvTestPacket`엔 1초 sleep이 있는데, 애초에 응답이 안 와서 호출된 적이 없던 죽은 코드였음 — 이번 핑은 그 핸들러를 재사용하지 않고 StressTest 전용 `Scenario_HandleResTestPacket`을 새로 만들어 분리.)

`TestPacket`은 서버 상태를 전혀 바꾸지 않는 순수 echo이므로 `Req_RoomEnter`와 달리 무한 재시도해도 race 위험이 없음 — `pingIntervalMs=200`(타임아웃 시 그냥 다음 인터벌에 자동 재시도, 별도 retry-cap 불필요)으로 고빈도 표본 확보.

### 구현

- `ScenarioState.h`: `pingInFlight`(bool)/`pingSentTime`/`lastPingSentTime`(둘 다 `steady_clock::time_point`) 추가 — 시나리오 phase와 무관하게 독립 진행.
- `ScenarioConfig.h`: `pingIntervalMs=200`, `pingTimeoutMs=3000` 추가.
- `ScenarioHandlers.h/.cpp`:
  - `Scenario_HandleResTestPacket` — `pingInFlight`가 꺼져있으면(이미 타임아웃 처리된 늦은 응답) 무시, 켜져있으면 RTT 계산해 `MetricsAggregator::Instance().RecordRtt(ms)` 호출 후 `pingInFlight=false`.
  - `AdvancePing` — `AdvanceScenario`와 동일한 "락 안에서는 상태만 결정(`shouldSendPing` bool), 락 해제 후 실제 `Send`" 패턴. 타임아웃 판정(`RecordTimeout()`)은 네트워크 I/O가 아니라 단순 카운터 증가라 락 안에서 호출해도 무방(다른 락 객체이므로 데드락 위험 없음, 진짜 피해야 하는 건 락 보유 중 `Session::Send()` syscall).
- `main.cpp`: `RegisterHandlers()`에 `PacketEnum::Test → Scenario_HandleResTestPacket` 등록, 메인 틱 루프에서 `AdvanceScenario` 다음에 `AdvancePing` 호출 추가.
- 신규 `MetricsAggregator.h/.cpp`: `USE_LOCK` 싱글톤, `RecordRtt`/`RecordTimeout`/`GetSnapshotAndReset()`(구간 통계 계산 후 내부 상태 리셋 — Phase 5.3의 10초 주기 리포트에 맞춘 "snapshot-and-reset" 모델).
- `DhNet_StressTest.vcxproj`: `MetricsAggregator.h/.cpp` 추가.

### 빌드 중 발견한 부수 문제

`TestController.cpp`에 `_session->Send(sender)`만 추가했을 때 `Session` 타입이 미정의라는 컴파일 에러(C2027/C2039) 발생 — 이 파일은 지금까지 `Session::Send()`를 호출한 적이 없어서 `Session.h`를 직접/간접으로 include한 적이 없었음(`Sender.h`만 include). 다른 컨트롤러들의 패턴(`#include "GameSession.h"`, 이게 `../ServerCore/Session.h`를 include함)을 따라 `TestController.cpp`에 `#include "GameSession.h"` 추가해 해결.

### 빌드 검증

`DhNet_Server.sln -t:DhNet_Server` 0 에러, `DhNet_StressTest.sln` 0 에러.

### 5.2 코드 리뷰 대응 (2026-06-19)

general-purpose 에이전트(code-architecture-reviewer 페르소나)로 리뷰 실행. Critical 0건. Important 3건 중 2건 즉시 수정, 1건은 기존(5.1) 설계 이슈라 기록만:

- [x] **Important**: `AdvancePing`/`Scenario_HandleResTestPacket`이 `AdvanceScenario`가 정립한 "레지스트리 락 안에서는 상태만 결정, 락 해제 후 부수효과(Send/기록) 수행" 원칙을 어기고 레지스트리 `WRITE_LOCK` 보유 중 `MetricsAggregator`의 락까지 중첩해서 잡고 있었음(데드락은 없었지만 일관성 없는 패턴이라 추후 `MetricsAggregator`에 무거운 연산이 추가되면 회귀 위험). **수정**: 두 함수 모두 콜백 안에서는 `bool`/`double` 로컬 변수로 "기록해야 하는가/RTT 값"만 결정하고, `MetricsAggregator::Instance().RecordRtt/RecordTimeout()` 호출은 락 해제 후로 이동.
- [x] **Important**: `TestController.cpp`에 추가한 `#include "GameSession.h"`가 불필요하게 무거움(Player/AesGcm/EcdhKeyExchange까지 끌어옴) — `Session`이 `PacketHandler.h`에서 전방선언(`class Session;`)만 되어 있어 `Session::Send()` 호출 시 미완성 타입 에러가 났던 게 원인이었으므로, 실제로 필요한 건 `Session` 완전한 정의뿐. **수정**: `#include "GameSession.h"` → `#include "../ServerCore/Session.h"`로 교체, 재빌드 0 에러 확인.
- [ ] **Important (기록만, 5.1 기존 설계)**: `ServerCore::Service::GetSessions()`(5.1에서 추가)가 매 200ms 틱마다 `READ_LOCK` 안에서 모든 세션의 `shared_ptr`를 복사한 새 벡터를 만듦 — 서비스 10개×세션 100개 구성 기준 매 틱 최대 1000개의 shared_ptr 복사/원자적 refcount 증가 발생. 부하테스트 도구 자체의 오버헤드가 RTT 측정치를 왜곡할 가능성. 이번 5.2 변경으로 새로 생긴 문제는 아니고 5.1 산물이라 이번엔 미수정 — 추후 캐시 가능한 세션 목록 참조나 in-place 콜백 순회로 개선 검토.
- Minor 2건(`MetricsAggregator::GetSnapshotAndReset()`의 불필요한 `.clear()` 중복 호출, `pingIntervalMs`와 `kTickIntervalMs`가 같은 값이라 틱 지연 누적 시 핑 간격이 계단식으로 튈 수 있는 점)도 보고됨 — 전자는 제거(반영), 후자는 설계상 큰 문제 아니라 미반영.
- 수정 파일: `ScenarioHandlers.cpp`(락 중첩 제거), `TestController.cpp`(include 교체), `MetricsAggregator.cpp`(중복 `.clear()` 제거). 재빌드: `DhNet_Server.sln`/`DhNet_StressTest.sln` 모두 0 에러.

## 다음 즉시 단계

Last Updated: 2026-07-01

1. **Phase 5.3 착수**: `MetricsAggregator::GetSnapshotAndReset()`을 10초 주기로 호출해 콘솔에 찍는 리포팅 루프, 종료 시 CSV/텍스트 파일 생성.
2. **Phase 5.4 착수 전 결정 필요**: 동일 계정 동시 로그인 과소집계 제약 처리 방법 — 테스트 계정 다중화 여부 사용자 확인 필요.
3. **보류 중 이슈**: `services` 벡터 동기화 없는 접근(`main.cpp`) — 사용자 결정으로 Phase 5 이후 별도 처리. pre-existing, StressTest 전용, churn 30초 간격으로 실제 위험도 낮음.

### 완료된 항목 (2026-06-19 ~ 2026-07-01)
- [x] `services` 벡터 동기화 이슈 결정 → 보류
- [x] `Tools/diagnostics/watchdog_test/` git 커밋 완료 (소스만, DLL 제외)
- [x] Phase 5.2 코드 리뷰 완료 (general-purpose agent, code-architecture-reviewer 페르소나)
