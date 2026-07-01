# StageComponent 통합 테스트 — Tasks

Last Updated: 2026-05-29

## Phase 1: 인터페이스 추출 (프로덕션 코드)

- ✅ `IRoomContext` 인터페이스 파일 생성 (`GameServer/Component/Room/IRoomContext.cs`)
- ✅ `RoomComponent` — `: IRoomContext` 선언 추가
- ✅ `StageComponent` — 생성자 파라미터 `RoomComponent` → `IRoomContext` (internal로 변경)
- ✅ `GameServer/AssemblyInfo.cs` — `InternalsVisibleTo("GameServer.Tests")` 추가
- ✅ `SessionComponent` — `IsConnected`, `SendAsync`, `ClearPacketQueue` virtual 추가
  (ISession 인터페이스 대신 virtual override 방식 채택 — PlayerComponent.Session 타입 변경 불필요)
- ✅ `dotnet build` — 0 에러 확인

## Phase 2: 테스트 인프라

- ✅ `GameServer.Tests/Stage/FakeRoomContext.cs` — IRoomContext 구현, Broadcasts 캡처
- ✅ `GameServer.Tests/Stage/FakeSession.cs` — SessionComponent 서브클래스, base(null!) 생성자
- ✅ `GameServer.Tests/Stage/StageTestHelpers.cs`
  - `MakePlayer` — RuntimeHelpers + 리플렉션 (AccountId, Name, Session, Character, World, Save 주입)
  - `InjectMonster`, `ClearMonsters`

## Phase 3: 테스트 케이스 작성

- ✅ `GameServer.Tests/Stage/StageComponentTests.cs` 파일 생성
- ✅ TC-1: `SurvivalTimer_Elapsed1800s_BroadcastsGameEndClear`
- ✅ TC-2: `EndGame_CalledTwice_OnlyOneNotiGameEnd`
- ✅ TC-3: `BossKill_BroadcastsGameEndClear`
- ✅ TC-4: `AllPlayersDead_BroadcastsGameEndFail`

## Phase 4: 검증

- ✅ `dotnet test` — 57/57 통과 (기존 53 + 신규 4)
- ✅ `dotnet build` — 0 에러, 0 경고
