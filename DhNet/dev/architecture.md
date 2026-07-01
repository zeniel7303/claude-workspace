# DhNet 서버 아키텍처 & 멀티스레딩 구조

## 전체 구조 개요

```
                  ┌─────────────────────────────────────────────────────┐
클라이언트 TCP    │              WorkerThread × N개 (hardware_concurrency) │
──────────────►  │                                                       │
                  │  while (true) {                                      │
                  │      Dispatch(10ms);        ← IOCP 완료 이벤트 처리 │
                  │      DoGlobalQueueWork();   ← GlobalQueue 처리       │
                  │  }                                                    │
                  └─────────────────────────────────────────────────────┘

REST 요청         ┌──────────────────────────────────────────────────────┐
──────────────►  │              gRPC 스레드 (별도)                       │
                  │  → DispatchToLogicThreadWithTimeout(lambda)           │
                  │       → PushGlobalQueue(lambda)                      │
                  │  → GlobalQueue에 넣고 future.wait_for(1초)            │
                  └──────────────────────────────────────────────────────┘
```

N개의 워커 스레드 전부가 IOCP와 GlobalQueue를 **둘 다 처리**한다.
"로직 전담 스레드"는 따로 없다.

---

## 워커 스레드 루프

`GameServer.cpp`의 `Job()` 함수가 각 스레드의 메인 루프다.

```
while (true) {
    IocpCore::Dispatch(10ms)     → GetQueuedCompletionStatus (최대 10ms 블로킹)
    DoGlobalQueueWork()          → GlobalQueue에서 JobQueue를 꺼내 Execute()
}
```

- `LEndTickCount` (TLS) : 이번 루프 반복의 시간 슬라이스 만료 시각. `GetTickCount64() + 64ms`로 설정.
- `LCurrentJobQueue` (TLS) : 현재 이 스레드에서 실행 중인 JobQueue. `nullptr`이면 아무것도 실행 중 아님.

---

## IOCP 완료 처리

```
클라이언트 → TCP 패킷 → OS IOCP 큐에 완료 이벤트 적재
   │
   ▼ (N개 워커 중 하나가 GQCS에서 깨어남)
IocpObject::Dispatch(event)
   ├─ recv 완료 → Session::OnRecv() → PacketHandler 라우팅
   ├─ send 완료 → Session::OnSend()
   └─ 0바이트 → Session::Disconnect()
```

어느 스레드가 처리할지는 OS가 결정한다.

---

## JobQueue — 객체별 직렬화

`Lobby`와 `Room`이 상속하는 클래스. 내부 `m_players` 맵에 대한 동시 접근을 방지한다.

```
DoAsync(lobby, &Lobby::Enter, player)
   │
   ▼
JobQueue::Push(job)
   prevCount = m_jobCount.fetch_add(1)

   if prevCount == 0:                     // 내가 첫 번째 작업
       if LCurrentJobQueue != nullptr:    // 이 스레드가 이미 다른 JQ 실행 중
           GGlobalQueue→Push(this)        // 위임 → 다른 워커가 나중에 실행
       else:
           Execute()                      // 현재 스레드에서 즉시 실행

   if prevCount > 0:
       // 이미 누군가 Execute() 중 → 자동으로 루프에서 가져감
```

**핵심 보장**: 같은 Lobby/Room의 작업은 동시에 두 스레드가 실행하지 않는다.
단, 서로 다른 Lobby끼리는 동시에 실행된다.

### Execute() 동작

job을 1개씩 꺼내는 게 아니라 **배치 단위(PopAll)로 한 번에 꺼낸 뒤 배치가 끝난 경계에서만 시간을 체크**한다.

```
Execute():
    LCurrentJobQueue = this                     // TLS 설정

    loop:
        jobs = m_jobs.PopAll()                  // 현재 큐에 있는 job 전부 꺼냄
        for job in jobs:
            try: job()
            catch: (예외 삼킴)

        remaining = m_jobCount.fetch_sub(jobs.size())
        if remaining == jobs.size():            // 배치 처리 후 큐가 비었다
            break                              // 정상 종료

        // 배치 실행 중 새 job이 추가됐으면 계속
        if GetTickCount64() > LEndTickCount:   // 시간 슬라이스 초과
            GGlobalQueue→Push(this)            // 남은 작업 위임 후 중단
            LCurrentJobQueue = nullptr
            return

    LCurrentJobQueue = nullptr
```

- 시간 초과 판정은 job 단위가 아니라 **배치(PopAll) 경계 단위**다.
- 예외는 try/catch로 삼켜서 다음 job 실행을 이어간다.
- 정상 종료(큐 빔)와 시간 초과 위임 두 경로 모두 `LCurrentJobQueue = nullptr`로 복원한다.

---

## GlobalQueue — 워커 간 작업 분배

`LockQueue<JobQueueRef>` — `WRITE_LOCK`으로 보호되는 JobQueue 포인터 큐.

```
┌──────────────┐    push    ┌──────────────────────────────┐
│ 임의 코드에서 │ ─────────► │       GlobalQueue             │
│ PushGlobalQueue(lambda) │  │  [LobbyA_JQ][LobbyB_JQ][임시] │
└──────────────┘           └──────────────────────────────┘
                                      │ pop (WRITE_LOCK)
                        ┌─────────────┼─────────────┐
                        ▼             ▼             ▼
                   WorkerThread1  WorkerThread2  WorkerThread3
                   Execute()      Execute()      Execute()
```

`DoGlobalQueueWork()` : 시간 슬라이스가 남아있는 동안 GlobalQueue에서 계속 꺼내 실행.

### PushGlobalQueue

`ThreadManager::PushGlobalQueue(lambda)`:
1. 일회용 임시 `JobQueue`를 생성
2. 람다를 job으로 추가
3. 임시 JQ를 `GGlobalQueue`에 push

→ 람다가 어느 워커 스레드든 다음에 GlobalQueue를 pop하는 스레드에서 실행된다.

---

## Admin API 요청 흐름

```
curl GET /lobbies
   │
   ▼ (ASP.NET Core 스레드)
GrpcAdminClient → gRPC 호출
   │
   ▼ (gRPC 스레드)
AdminServiceImpl::ListLobbies()
   └─ DispatchToLogicThreadWithTimeout(lambda, 1000ms)
        ├─ PushGlobalQueue(lambda)     ← GlobalQueue에 추가
        └─ future.wait_for(1000ms)     ← gRPC 스레드 블로킹
                 │
                 ▼ (워커 스레드 X — 어느 스레드든)
             lambda 실행:
               LobbySystem::GetLobbies()  ← READ_LOCK으로 스냅샷
               resp 채움
               prom->set_value(true)
                 │
          ◄──── future 준비됨
   └─ gRPC 응답 전송
```

---

## 패킷 처리 전체 흐름 (로그인 예시)

```
클라이언트 → TCP 수신 → IOCP 완료
   │
   ▼ (워커 스레드 A)
Session::OnRecv()
   └─ PacketHandler → HandleReqLoginPacket()
        └─ DbSystem::Execute(쿼리, 콜백)   ← DB 워커 스레드로 위임

                │
                ▼ (DB 워커 스레드)
           MySQL 쿼리 실행
           PushGlobalQueue(결과 처리 람다)
                │
                ▼ (워커 스레드 B — 어느 스레드든)
           GameSession::OnLoginResult()
             └─ Player 생성
             └─ PlayerSystem::Add(player)       ← WRITE_LOCK
             └─ lobby->DoAsync(Lobby::Enter)    ← GlobalQueue에 push
                    │
                    ▼ (워커 스레드 C — 어느 스레드든)
               Lobby::Enter()
                 └─ player->SetCurrentLobby(this)
                 └─ 기존 멤버에게 브로드캐스트
```

---

## 동시성 보호 방식 요약

| 대상 | 보호 방법 | 세부 사항 |
|------|-----------|-----------|
| `Lobby` / `Room` 내부 (`m_players`) | JobQueue 직렬화 | 한 번에 한 스레드만 Execute |
| `PlayerSystem.m_players` | RW SpinLock | `concurrent_unordered_map` + SpinLock 병용 (`Remove`는 `unsafe_erase` + WRITE_LOCK) |
| `LobbySystem.m_lobbies` | RW SpinLock | 생성 후 사실상 불변 |
| `Lobby.m_availableSlots` | `atomic<int32>` CAS | TryReserveSlot / ReleaseReservedSlot |
| `Session.m_connected` | `atomic<bool>` | Disconnect 중복 방지 |
| `Session.m_handshakeDone` | `atomic<bool>` acquire/release | 암호화 핸드셰이크 완료 플래그 |
| `GameSession.m_loginProcessed` | `atomic<bool>` CAS | 중복 로그인 응답 방지 |
| `GlobalQueue` | WRITE_LOCK | `LockQueue<JobQueueRef>` 내부 |
| `Player.m_currentLobby/Room` | **없음** | ⚠️ 데이터 레이스 위험 — 별도 문서 참조 |
| `Player.m_playerId/name/ownerSession` | 생성 후 불변 | 안전 |

---

## TLS (스레드 로컬 저장소)

`DhUtil/TLS.h`에 정의. 각 워커 스레드마다 독립적으로 존재.

| 변수 | 타입 | 용도 |
|------|------|------|
| `LThreadId` | `uint32` | 디버그/로그용 스레드 ID |
| `LEndTickCount` | `uint64` | 현재 루프 시간 슬라이스 만료 시각 |
| `LCurrentJobQueue` | `JobQueue*` | 현재 실행 중인 JobQueue (nullptr이면 없음) |
| `LLockStack` | `std::stack<int32>` | 락 획득 순서 스택 (데드락 감지는 `GDeadLockProfiler` 전역 객체가 별도 수행) |

---

## RW SpinLock 규칙

`DhUtil/Lock.h`의 `Lock` 클래스. 매크로(`USE_LOCK`, `READ_LOCK`, `WRITE_LOCK`)는 `DhUtil/Macro.h`에 정의.

- **W→W**: 재진입 가능 (같은 스레드가 Write 중 Write 재획득 OK — writeCount 증가로 처리)
- **W→R**: OK (Write 소유 스레드는 ReadLock을 바로 통과)
- **R→W**: **금지** — 무한 대기가 아니라 약 10초(ACQUIRE_TIMEOUT_TICK) 후 `CRASH("LOCK_TIMEOUT")`
- `WriteUnlock` 시 read 카운트가 남아있으면 `CRASH("INVALID_UNLOCK_ORDER")`
- `USE_LOCK` : `Lock m_locks[1]` 배열 멤버를 클래스에 선언하는 매크로 (`USE_MANY_LOCKS(1)` 래핑)
- `READ_LOCK` / `WRITE_LOCK` : RAII 가드 (스코프 종료 시 자동 해제)
