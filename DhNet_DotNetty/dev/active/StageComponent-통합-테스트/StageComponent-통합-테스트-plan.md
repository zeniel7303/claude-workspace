# StageComponent 통합 테스트 — Plan

Last Updated: 2026-05-29

## 요약

`StageComponent`의 핵심 게임 흐름(보스 처치, 전원 사망, 타이머 클리어)을 자동화 테스트로 검증한다.
현재 테스트 없이 운영 중이며, CCD 수정 이후 회귀 위험이 가장 높은 영역이기도 하다.

---

## 현재 상태

- `GameServer.Tests/` 에 53개 테스트 있음 (PlayerCharacter, PlayerWorld, WeaponComponent, Garlic)
- `StageComponent` 테스트 전무 — 가장 복잡한 컴포넌트인데 커버리지 0%
- `StageComponent(RoomComponent room)` 생성자가 구체 클래스에 강결합 → 테스트 어려움
- `p.Session.SendAsync()` 가 DotNetty `IChannel`에 직접 의존 → 테스트 환경에서 크래시

---

## 핵심 과제: 의존성 격리

`StageComponent`가 테스트하기 어려운 이유 두 가지:

### 1. RoomComponent 강결합
`StageComponent.Update()` 내부에서 `_room.GetPlayers()` · `_room.BroadcastPacket()` 호출.
두 메서드가 `virtual`이 아니라 서브클래싱으로도 오버라이드 불가.

**해결**: `IRoomContext` 인터페이스 추출
```csharp
internal interface IRoomContext
{
    ulong RoomId { get; }
    IReadOnlyList<PlayerComponent> GetPlayers();
    void BroadcastPacket(GamePacket packet);
}
```
- `RoomComponent : IRoomContext` 추가
- `StageComponent` 생성자: `RoomComponent` → `IRoomContext`

### 2. SessionComponent ↔ IChannel 결합
`SessionComponent.SendAsync()` 가 `Channel.WriteAndFlushAsync()` 직접 호출.
`IChannel` 없이 인스턴스화 불가.

**해결**: `ISession` 인터페이스 추출
```csharp
internal interface ISession
{
    bool IsConnected { get; }
    Task SendAsync(GamePacket packet);
    void ClearPacketQueue();
}
```
- `SessionComponent : ISession` 추가
- `PlayerComponent.Session` 타입: `SessionComponent` → `ISession`

---

## 구현 단계

### Phase 1: 인터페이스 추출 (프로덕션 코드 최소 변경) `[S]`

변경 파일:
- `GameServer/Component/Room/RoomComponent.cs` — `IRoomContext` 구현 선언 추가
- `GameServer/Component/Stage/StageComponent.cs` — 생성자 파라미터 타입 변경
- `GameServer/Network/SessionComponent.cs` — `ISession` 구현 선언 추가
- `GameServer/Component/Player/PlayerComponent.cs` — Session 타입 변경

> 로직 변경 없음. 인터페이스 선언 + 타입 교체만.

### Phase 2: 테스트 인프라 `[M]`

`GameServer.Tests/` 에 추가:

```csharp
// FakeRoomContext.cs
internal sealed class FakeRoomContext(ulong roomId, List<PlayerComponent> players) : IRoomContext
{
    private readonly List<GamePacket> _broadcasts = new();
    public IReadOnlyList<GamePacket> Broadcasts => _broadcasts;

    public ulong RoomId => roomId;
    public IReadOnlyList<PlayerComponent> GetPlayers() => players;
    public void BroadcastPacket(GamePacket p) => _broadcasts.Add(p);
}

// FakeSession.cs
internal sealed class FakeSession : ISession
{
    private readonly List<GamePacket> _sent = new();
    public IReadOnlyList<GamePacket> Sent => _sent;
    public bool IsConnected => true;
    public Task SendAsync(GamePacket p) { _sent.Add(p); return Task.CompletedTask; }
    public void ClearPacketQueue() { }
}
```

플레이어 팩토리 (기존 WeaponComponentTests 패턴 확장):
```csharp
// StageTestHelpers.cs
internal static class StageTestHelpers
{
    // RuntimeHelpers.GetUninitializedObject + 리플렉션으로 PlayerComponent 최소 초기화
    internal static PlayerComponent MakePlayer(ulong accountId)
    {
        var p = (PlayerComponent)RuntimeHelpers.GetUninitializedObject(typeof(PlayerComponent));
        // AccountId, Character(new), World(new), Session(FakeSession) 필드 주입
        ...
        return p;
    }

    // boss 몬스터를 _monsters에 직접 주입
    internal static void InjectBossMonster(StageComponent stage, ulong monsterId) { ... }
}
```

### Phase 3: 핵심 게임 흐름 테스트 `[M]`

```
StageComponentTests.cs
```

**TC-1: 생존 타이머 클리어**
```
Setup : FakeRoomContext(players=[])
Act   : stage.Initialize() → Update(900f) × 2 (합계 1800s)
Assert: Broadcasts에 NotiGameEnd{IsClear=true} 포함
```

**TC-2: _endedFlag 멱등성**
```
Setup : FakeRoomContext
Act   : Update(1800f) × 2 (첫 번째에 EndGame 트리거, 두 번째는 early return)
Assert: NotiGameEnd가 정확히 1개
```

**TC-3: 보스 처치 → 클리어**
```
Setup : 플레이어 1명, boss 몬스터(IsBoss=true, Hp=1) 주입
Act   : ProcessAttack(player, bossId) → Update(0.1f)
Assert: Broadcasts에 NotiGameEnd{IsClear=true} 포함
```

**TC-4: 전원 사망 → 실패**
```
Setup : 플레이어 1명(Hp=1), 일반 몬스터(Atk=9999, AttackRange=큰값) 주입
Act   : Update(0.1f) 반복 (몬스터가 플레이어 공격하도록)
Assert: Broadcasts에 NotiGameEnd{IsClear=false} 포함
```

---

## 위험 평가

| 위험 | 완화 |
|------|------|
| `PlayerComponent` 생성자 체인 복잡 | `RuntimeHelpers.GetUninitializedObject` + 리플렉션 (기존 WeaponComponentTests 패턴) |
| `IRoomContext` 변경이 `RoomComponent.Ready()` 내 `StageComponent(this)` 호출 영향 | `RoomComponent : IRoomContext` 선언 후 `StageComponent(this)` 그대로 동작 |
| `Session` 타입 변경이 `LoginProcessor` 등에서 `SessionComponent` 직접 참조 시 컴파일 오류 | `ISession`에 없는 메서드(`TrySetLoginStarted` 등)는 구체 타입으로 캐스팅 또는 `SessionComponent`에 유지 |
| 모노스테이트 `GameSessionRegistry.Instance.Unregister()` — 테스트 간 상태 오염 | `Unregister`는 멱등(키 없어도 안전), 각 테스트에 고유 RoomId 사용으로 충분 |

---

## 성공 지표

- `dotnet test` (GameServer.Tests/) 신규 테스트 포함 전체 통과
- TC-1 ~ TC-4 4개 테스트 케이스 Green
- 프로덕션 코드 동작 변화 없음 (인터페이스 도입만, 로직 수정 없음)
