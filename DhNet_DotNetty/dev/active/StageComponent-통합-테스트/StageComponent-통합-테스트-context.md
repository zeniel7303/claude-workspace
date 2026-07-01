# StageComponent 통합 테스트 — Context

Last Updated: 2026-05-29 (세션 완료)

## 핵심 파일

| 파일 | 역할 |
|------|------|
| `GameServer/Component/Stage/StageComponent.cs` | 테스트 대상. `EndGame`, `TickSurvivalTimer`, `TickMonsterAI`, `DrainInputQueue` 포함 |
| `GameServer/Component/Stage/StageCombatHelper.cs` | `CheckAllPlayersDead`, `ApplyWeaponHit` — 보스/전원사망 흐름 핵심 |
| `GameServer/Component/Room/RoomComponent.cs` | `IRoomContext` 구현 대상. `GetPlayers()`, `BroadcastPacket()` 변경 |
| `GameServer/Network/SessionComponent.cs` | `ISession` 구현 대상. `SendAsync`, `ClearPacketQueue`, `IsConnected` |
| `GameServer/Component/Player/PlayerComponent.cs` | `Session` 필드 타입 변경 대상 |
| `GameServer.Tests/GameDataFixture.cs` | 기존 픽스처 — `GameDataTable.Load()` 1회 실행 |
| `GameServer.Tests/WeaponComponentTests.cs` | `RuntimeHelpers.GetUninitializedObject` + 리플렉션 패턴 참조 |

## 의존성 그래프 (테스트 관점)

```
StageComponentTests
  └─ StageComponent(IRoomContext)         ← 생성자 타입만 변경
       ├─ FakeRoomContext                 ← NEW (테스트 전용)
       │    ├─ GetPlayers() → List<PlayerComponent>
       │    └─ BroadcastPacket() → _broadcasts 캡처
       ├─ PlayerComponent (RuntimeHelpers.GetUninitializedObject)
       │    ├─ PlayerCharacterComponent(null!)  → Character
       │    ├─ PlayerWorldComponent(null!)      → World (GameDataTable 필요)
       │    └─ FakeSession                     ← NEW (테스트 전용)
       ├─ MonsterComponent(id, type, x, y)      → 리플렉션으로 _monsters 주입
       └─ GameDataFixture                       → IClassFixture<GameDataFixture>
```

## 핵심 결정사항

### 1. 인터페이스 범위
`IRoomContext`는 `StageComponent`가 실제 사용하는 3개만:
- `ulong RoomId`
- `IReadOnlyList<PlayerComponent> GetPlayers()`
- `void BroadcastPacket(GamePacket packet)`

`ISession`은 `PlayerComponent.Session`이 사용하는 것만:
- `bool IsConnected`
- `Task SendAsync(GamePacket packet)`
- `void ClearPacketQueue()`

`SessionComponent`에만 있는 메서드(`TrySetLoginStarted`, `DrainPackets` 등)는 인터페이스에 포함하지 않는다. 해당 메서드를 쓰는 코드는 구체 타입(`SessionComponent`)으로 접근하거나 `as` 캐스팅.

### 2. PlayerComponent 생성 전략
`RuntimeHelpers.GetUninitializedObject(typeof(PlayerComponent))` + 리플렉션으로 필드 직접 주입.
WeaponComponentTests의 기존 패턴과 동일. 생성자 체인(SessionComponent ↔ IChannel)을 피하는 유일한 현실적 방법.

### 3. _monsters 주입 방법
`StageComponent._monsters`는 `private readonly Dictionary<ulong, MonsterComponent>`.
리플렉션으로 접근하여 테스트 시나리오에 맞는 몬스터를 직접 추가.

### 4. 생존 타이머 테스트 전략
`Update(ClearTimeSec + 0.1f)` 단일 호출로 충분 (float 덧셈 오버플로 없음).
플레이어 없이도 `_survivalElapsed >= ClearTimeSec` 분기에 도달한다.

### 5. GameSessionRegistry 부작용
`EndGame()` 내부에서 `GameSessionRegistry.Instance.Unregister(RoomId)` 호출.
키가 없어도 `TryRemove`는 안전 → 각 테스트에 고유 RoomId 사용하면 테스트 간 오염 없음.

## 주의사항

- `PlayerWorldComponent` 생성자 `new PlayerWorldComponent(null!)` — `BaseComponent` 상속, `null` 허용됨
  (생성자에서 `GameDataTable` 접근: `MoveSpeed = GameDataTable.Player.InitialMoveSpeed` → `IClassFixture<GameDataFixture>` 필요)
- `SessionComponent`의 `IsConnected => Channel.Active` — `FakeSession`에서는 항상 `true` 반환
- `StageComponent.Initialize()`는 `_room.BroadcastPacket(ResEnterGame)` 호출 → `FakeRoomContext`가 캡처하므로 무해

## 최종 구현 상태 (세션 완료)

### 실제 채택된 방식 (계획에서 변경된 것)
- `ISession` 인터페이스 추출 대신 `SessionComponent.IsConnected/SendAsync/ClearPacketQueue` **virtual** 추가로 대응
  - `PlayerComponent.Session` 타입 변경 없음 (여전히 `SessionComponent`)
  - `FakeSession : SessionComponent` + `base(null!)` 생성자로 DotNetty 채널 우회
- `StageComponent` 생성자를 `internal`로 변경 + `GameServer/AssemblyInfo.cs`에 `InternalsVisibleTo("GameServer.Tests")` 추가

### 반복 수정이 필요했던 문제들
1. **`PlayerComponent.Name = null`** — protobuf `PlayerInfo.set_Name`이 null 거부. `MakePlayer`에 Name 필드 주입 추가
2. **`PlayerCharacterComponent(null!)`** — `AddGold`가 `player.Save.MarkDirty()` 호출. `PlayerSaveComponent` 주입 추가
3. **`PlayerCharacterComponent(p)` 순환 참조** — `null!` 대신 실제 `p`를 전달해야 `AddGold` 동작

### 최종 MakePlayer 주입 목록
```csharp
AccountIdField, NameField, SessionField, CharacterField (←p 전달), WorldField, SaveField
```

### 검증 결과
- `dotnet test` (GameServer.Tests/): 57/57 통과
- 기존 53개 회귀 없음, 신규 4개 모두 Green

## 관련 백로그 항목

- `dev/backlog.md` T-1: 이 작업
- `dev/backlog.md` T-2: WeaponComponent.ApplyChoice 분기 테스트 (후속)
- `dev/backlog.md` T-3: CCD 히트 판정 회귀 테스트 (후속)
