# DhNet 코드 리뷰

> 작성일: 2026-06-16  
> 리뷰 범위: Phase 4 (Admin REST API) 완료 시점 전체 서버 코드  
> Opus 모델 2차 검증 반영

---

## 잘 된 부분

### 스레드 모델

- **IOCP + GlobalQueue 통합 풀** — "IOCP 전담/로직 전담" 이중 구조 없이 N개 워커가 둘 다 처리. 유휴 스레드가 없어 CPU 활용률이 높다.
- **JobQueue 직렬화** — Lobby/Room 내부 `m_players` 맵에 별도 락 없이 JobQueue 하나로 동시 접근을 막는다. 락 경합 없이 직렬화를 달성하는 좋은 패턴.

### 동시성 설계

- **`m_availableSlots` atomic CAS** — `TryReserveSlot`/`ReleaseReservedSlot`이 JobQueue 밖에서도 슬롯 예약을 안전하게 처리. Lobby JobQueue에 진입하기 전에 자리를 먼저 확보하는 구조가 정확하다.
- **`m_loginProcessed` atomic** — 중복 로그인 응답 경쟁을 CAS 한 줄로 막는다.
- **`m_connected` atomic** — Disconnect 중복 호출 방지가 깔끔하다.
- **`AssignLobby()` 클러스터링** — 가장 인원 많은 로비에 먼저 배정해 새 로비를 최대한 비워두는 것은 좋은 UX 결정.
- **`GetPlayers()` 스냅샷 반환** — READ_LOCK 하에 vector 복사본을 반환하므로 호출자가 락 없이 안정적으로 순회할 수 있다.

### 보안

- **ECDH + AES-GCM 핸드셰이크** — `SecureZeroMemory`로 스택의 `secret`/`sessionKey`를 핸드셰이크 직후 즉시 지운다.
- **`m_handshakeDone` acquire/release ordering** — 핸드셰이크 완료 전 일반 패킷을 받으면 즉시 Disconnect. 상태 기계가 명확하다.

---

## 🔴 크리티컬 버그

### 1. `Session::ProcessRecv` — 다중 패킷 미처리 ✅ 수정 완료

**파일**: `DhNet_Server/ServerCore/Session.cpp`

TCP는 패킷 경계를 보장하지 않는다. 한 번의 recv에 완성 패킷이 2개 이상 도착해도 기존 루프는 첫 번째만 처리하고 종료했다.

**기존 코드 (문제)**:
```cpp
while (1) {
    auto packet = reinterpret_cast<PacketHeader*>(m_recvBuffer.ReadPos());
    if (m_recvBuffer.DataSize() >= packet->m_dataSize) {
        OnRecv(packet);
        m_recvBuffer.OnRead(packet->m_dataSize);
    }
    break;  // 항상 탈출 → 뭉쳐온 나머지 패킷은 다음 recv까지 적체
}
```

**수정 후**:
```cpp
while (true) {
    if (m_recvBuffer.DataSize() < sizeof(PacketHeader)) break;

    auto packet = reinterpret_cast<PacketHeader*>(m_recvBuffer.ReadPos());

    if (packet->m_dataSize < sizeof(PacketHeader)) {   // 악성 패킷 크기 방어
        Disconnect(L"Invalid Packet Size");
        return;
    }
    if (m_recvBuffer.DataSize() < packet->m_dataSize) break;  // 부분 패킷 → 대기

    if (OnRecv(packet) == false) {
        Disconnect(L"OnRead Error");
        return;
    }
    if (m_recvBuffer.OnRead(packet->m_dataSize) == false) {
        Disconnect(L"OnRead Overflow");
        return;
    }
    // 소비 후 루프 계속 → 다음 완성 패킷 처리
}
```

추가로 기존 코드에서 `OnRecv` 실패 후 `Disconnect`를 호출하고도 이후 코드를 계속 실행하던 문제도 함께 수정(`return`으로 즉시 종료).

---

### 2. `Player::m_currentLobby/Room` 데이터 레이스 ✅ 수정 완료

**파일**: `DhNet_Server/DhNet_Server/Player.h:13-14`, `Player.cpp`, `AdminController.cpp:94,99`

```cpp
// Player.h
std::weak_ptr<Room>  m_currentRoom;   // 보호 없음
std::weak_ptr<Lobby> m_currentLobby; // 보호 없음
```

`std::weak_ptr`은 **같은 인스턴스에 동시 읽기/쓰기가 발생하면 UB**다. 현재 같은 N개 워커 풀에서 동시에 접근하는 세 경로가 존재한다:

| 연산 | 호출 경로 |
|------|-----------|
| `SetCurrentLobby()` write | `Lobby::Enter()` → Lobby JobQueue에서 실행 |
| `m_currentLobby.reset()` write | `LeaveLobby()` ← `OnDisconnected()` ← IOCP 완료 단계 |
| `GetCurrentLobby().lock()` read | `AdminListPlayers` 람다 ← GlobalQueue에서 실행 |

> 참고: "IOCP 스레드"와 "GlobalQueue 워커"는 별도 풀이 아니다. `GameServer::Job()`이 동일한 N개 워커에서 Dispatch → DoGlobalQueueWork를 순서대로 실행한다. 셋 모두 같은 풀이므로 어느 두 경로든 동시 실행이 가능하다.

**수정 방향**:

```cpp
// Player.h에 추가
std::atomic<int32> m_currentLobbyIndex{ -1 };
std::atomic<int32> m_currentRoomIndex{ -1 };

// Lobby::Enter() — SetCurrentLobby와 함께 인덱스도 저장
_player->m_currentLobbyIndex.store(m_lobbyIndex, std::memory_order_relaxed);

// Player::LeaveLobby()
m_currentLobbyIndex.store(-1, std::memory_order_relaxed);

// AdminController.cpp — AdminListPlayers
p->set_lobbyindex(player->GetCurrentLobbyIndex());  // atomic load, 락 불필요
```

게임플레이용 `weak_ptr`은 유지하되, Admin API는 atomic 인덱스만 읽도록 분리한다.  
근본적 해결은 Player를 JobQueue로 감싸 접근 자체를 직렬화하는 것이지만 큰 리팩터가 필요하다.

---

### 3. 타임아웃 후 `resp` 댕글링 포인터 (use-after-free) ✅ 수정 완료

**파일**: `DhNet_Server/DhNet_Server/AdminController.cpp` — 5개 핸들러 전부

```cpp
return DispatchToLogicThreadWithTimeout([resp]() -> bool {
    resp->add_lobbies();  // 타임아웃 후 실행되면 UAF
}, 1000ms, err);
```

타임아웃 발생 시:
1. `DispatchToLogicThreadWithTimeout` → `false` 반환 후 gRPC 핸들러 리턴
2. gRPC 프레임워크가 `resp` 객체 해제
3. **람다는 GlobalQueue에 잔류** → 나중에 다른 워커가 실행
4. 해제된 `resp`에 쓰기 → use-after-free

`AdminListRooms`, `AdminBroadcast`, `AdminListPlayers`, `AdminKickPlayer`, `AdminListLobbies` **5개 모두 해당**.  
로직 스레드가 1초 이상 블로킹될 때만 발동하므로 정상 운용 중에는 희귀하나, 서버 과부하 시 발생한다.

**수정 방향**: `resp*` 대신 공유 결과 버퍼에 쓰고, 타임아웃 없이 돌아온 경우에만 `resp`에 복사.

```cpp
bool AdminListLobbies(...) {
    auto result = std::make_shared<std::vector<dhnet::LobbyInfo>>();

    bool ok = DispatchToLogicThreadWithTimeout([result]() -> bool {
        auto lobbies = GameServer::Instance().GetSystem<LobbySystem>()->GetLobbies();
        for (const auto& lobby : lobbies) {
            dhnet::LobbyInfo& l = result->emplace_back();
            l.set_id(lobby->GetLobbyIndex());
            l.set_playercount(lobby->GetPlayerCount());
            l.set_capacity(MAX_LOBBY_PLAYERS);
        }
        return true;
    }, 1000ms, err);

    if (!ok) return false;  // 타임아웃 시 resp 접근 없이 반환

    for (const auto& l : *result)
        *resp->add_lobbies() = l;
    return true;
}
```

---

## 🟡 동작 오류

### 4. `AdminListRooms` — 빈 방 목록 → HTTP 504 ✅ 수정 완료

**파일**: `DhNet_Server/DhNet_Server/AdminController.cpp:29`

방이 하나도 없는 상태(서버 시작 직후 등)에서 `GET /rooms`를 호출하면 `false` → `DEADLINE_EXCEEDED` → HTTP 504로 응답하던 문제.

```cpp
// 수정 전
if (rooms.empty()) return false;

// 수정 후
if (rooms.empty()) return true;  // 빈 배열 [] 응답
```

---

## 🟡 설계 취약점

### 5. `GameSession` ↔ `Player` 순환 참조 ✅ 수정 완료

**파일**: `DhNet_Server/DhNet_Server/GameSession.h`, `Player.h:12`

```cpp
// GameSession
std::shared_ptr<Player> m_player;       // Session → Player

// Player.h
std::shared_ptr<GameSession> m_ownerSession;  // Player → Session
```

두 객체가 서로 `shared_ptr`로 참조하고 있어 순환 참조가 형성된다. `OnDisconnected()`에서 `m_player.reset()`으로 한쪽 링크를 끊어 해소하지만, 이 시점까지 Lobby/Room의 `m_players` 맵이 Player를 붙잡고 있으면:

- Lobby::Exit DoAsync가 큐에서 실행되기 전까지 Player 소멸 지연
- Player가 살아있으므로 `m_ownerSession`(세션 shared_ptr)도 유지
- 세션 소멸이 Lobby::Exit 실행 시점까지 지연

크래시는 아니지만 세션/Player 수명이 큐 처리 속도에 묶이며, 피크 상황에서 메모리 사용량이 예상보다 높아질 수 있다.

**수정 방향**: `Player::m_ownerSession`을 `std::weak_ptr<GameSession>`으로 변경. 세션이 살아있는지 확인이 필요할 때만 `.lock()`.

---

### 6. `OnDisconnected` 정리 순서 — 비동기 정리와 즉시 제거의 불일치

**파일**: `DhNet_Server/DhNet_Server/GameSession.cpp:26`

```cpp
void GameSession::OnDisconnected()
{
    m_player->LeaveLobby();              // DoAsync → 큐에 대기
    m_player->LeaveRoom();               // DoAsync → 큐에 대기
    PlayerSystem::Remove(m_player);      // 즉시 제거
    m_player.reset();
}
```

`PlayerSystem::Remove`가 실행될 때 Lobby::Exit / Room::Leave는 아직 GlobalQueue에 대기 중이다. 이 구간 동안 `Lobby::GetPlayerCount()`가 실제보다 크게 보이며, Admin API `GET /lobbies`의 playerCount가 부정확해진다.

---

### 7. `concurrent_unordered_map` + SpinLock 이중화 ✅ 수정 완료

**파일**: `DhNet_Server/DhNet_Server/PlayerSystem.h:9-10`

```cpp
USE_LOCK  // RW SpinLock
concurrency::concurrent_unordered_map<uint64, std::shared_ptr<Player>> m_players;
```

`WRITE_LOCK` 하에 `unsafe_erase`를 쓰는 순간 concurrent_map의 내부 동기화는 완전히 낭비다. 코드를 읽는 사람이 의도를 파악하기 어렵다.

```cpp
// 수정: std::unordered_map으로 교체, 동작 동일
std::unordered_map<uint64, std::shared_ptr<Player>> m_players;
```

---

## 수정 현황

| 순위 | 항목 | 심각도 | 상태 |
|------|------|--------|------|
| 1 | `Session::ProcessRecv` 다중 패킷 미처리 | 🔴 고부하 시 패킷 처리 지연 누적 | ✅ 완료 |
| 2 | `Player` weak_ptr 데이터 레이스 | 🔴 동시 접속 많을 때 크래시/corruption | ✅ 완료 |
| 3 | `resp` use-after-free | 🔴 타임아웃 발생 시(서버 과부하) UAF | ✅ 완료 |
| 4 | `AdminListRooms` 빈 목록 → 504 | 🟡 잘못된 HTTP 504 응답 | ✅ 완료 |
| 5 | `GameSession`↔`Player` 순환 참조 | 🟡 피크 시 메모리 지연 해제 | ✅ 완료 |
| 6 | `OnDisconnected` 정리 순서 | 🟡 모니터링 수치 일시 부정확 | 보류 (슬롯 타이밍 변경 시 새 레이스 위험) |
| 7 | `concurrent_unordered_map` 제거 | 🟢 코드 명확성 개선 | ✅ 완료 |
