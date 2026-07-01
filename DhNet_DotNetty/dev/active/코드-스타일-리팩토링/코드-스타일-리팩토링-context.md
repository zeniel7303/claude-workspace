# 코드 스타일 리팩토링 — Context

Last Updated: 2026-05-29

## 세션 요약

사용자 요청: "if문이나 for문같은거 한줄로 쓰고나 중괄호가 없는데 그런거 좀 챙겨줘. 사람이 보기에 가독성 좋게 해줘."
후속 요청: 코드 리뷰 에이전트 권장사항 2가지 적용 — StageComponent.Update() 분리 + Fisher-Yates 셔플

## 완료 상태

**완료됨.** 빌드 0 에러/경고, 테스트 53/53 통과 (GameServer.Tests 디렉토리에서 실행 필요).

## 주요 결정사항

1. **모든 제어 흐름에 중괄호 강제**: guard-clause 스타일 `if (x) return;`도 예외 없이 멀티라인 중괄호로.
2. **단일 라인 `{ stmt1; stmt2; }` 분리**: `if (dSq < minDistSq) { minDistSq = dSq; nearest = m; }` → 3줄로.
3. **`lock` 블록도 중괄호 + 개행**: `lock (_lock) return x;` 패턴 수정.
4. **WeaponComponent.cs 전체 재작성**: 수정 포인트가 14개 이상이어서 Edit 대신 Write 선택.
5. **StageComponent.Update() 메서드 분리**: 170줄짜리 Update()를 5개 private 메서드로 추출.
6. **Fisher-Yates 셔플 적용**: `OrderBy(_ => Random.Shared.Next())` → Fisher-Yates (O(n), 균등 분포 보장).
7. **CheckAllPlayersDead 파라미터**: 원본은 `players`(전체 목록) 전달, 리팩터 후 `alivePlayers` 전달 — 의미상 동일 (게임이 먼저 종료됐으면 _endedFlag가 보호).

## StageComponent.Update() 메서드 분리 결과

```
Update(dt)                     ← 메인 틱 (50줄로 축소)
  DrainInputQueue()            ← _inputQueue while 루프
  TickSurvivalTimer(dt)        ← 생존 타이머 누적 + 10초 브로드캐스트
  TickMonsterAI(dt, alivePlayers) ← 몬스터 AI foreach + 이동 배치 패킷
  CleanupDeadMonsters()        ← 10틱마다 리스폰 불가 몬스터 제거
  TickWeapons(dt, alivePlayers) ← 자동 무기 틱 + 히트 적용
  TickWaveSpawner(dt)          ← 웨이브 스포너 틱
```

각 서브루틴은 `_pending` 필드에 직접 접근 (파라미터 전달 불필요 — 단일 스레드 보장).

## Fisher-Yates 적용 위치

`WeaponComponent.GenerateChoices()` 마지막 줄:
```csharp
// Before
return pool.OrderBy(_ => Random.Shared.Next()).Take(3).ToList();

// After
for (int i = pool.Count - 1; i > 0; i--)
{
    int j = Random.Shared.Next(i + 1);
    (pool[i], pool[j]) = (pool[j], pool[i]);
}
return pool.Take(3).ToList();
```
이유: OrderBy는 비교 기반 정렬이므로 같은 원소를 여러 번 비교하는 과정에서 랜덤 키가 변해 위치 편향 발생. Fisher-Yates는 O(n)이고 모든 순열이 정확히 1/n! 확률.

## 수정된 주요 패턴

### 단일 라인 if → 멀티라인

```csharp
// Before
if (Players == null || Monsters == null) return;

// After
if (Players == null || Monsters == null)
{
    return;
}
```

### continue 중괄호

```csharp
// Before
if (!monster.IsAlive || nearestPlayer == null) continue;

// After
if (!monster.IsAlive || nearestPlayer == null)
{
    continue;
}
```

### if-else 래핑 수학 연산

```csharp
// Before
if (dx > mapW * 0.5f) dx -= mapW; else if (dx < -mapW * 0.5f) dx += mapW;

// After
if (dx >  mapW * 0.5f) { dx -= mapW; } else if (dx < -mapW * 0.5f) { dx += mapW; }
```

### lambda 내부 guard clause

```csharp
// Before (ProcessAttack 람다 내부)
if (!player.Character.IsAlive) return;

// After
if (!player.Character.IsAlive)
{
    return;
}
```

## 테스트 실행 주의사항

솔루션 루트에서 `dotnet test` 실행 시 경로 이슈 발생:
- 솔루션 루트 빌드 시 출력 경로: `Bin\output\Debug\GameServer.Tests\net9.0\`
- 4단계 위로 올라가면 `Bin\`, 거기서 `Bin/resources` 추가 → `Bin\Bin\resources` (잘못됨)

**올바른 실행 방법**:
```
cd GameServer.Tests && dotnet test
```
또는 솔루션 루트에서 `dotnet test GameServer.Tests/GameServer.Tests.csproj`

이는 기존 이슈이며 이번 리팩토링과 무관.

## 수정된 파일 전체 목록

### Phase 1-3 (중괄호 수정)
- Common.Shared/Logging/GameLogger.cs
- GameServer/Network/SessionComponent.cs
- GameServer/Component/Player/PlayerCharacterComponent.cs
- GameServer/Component/Player/PlayerWorldComponent.cs
- GameServer/Component/Player/PlayerLobbyComponent.cs
- GameServer/Component/Player/PlayerRoomComponent.cs
- GameServer/Component/Player/PlayerSaveComponent.cs
- GameServer/Component/Stage/StageComponent.cs
- GameServer/Component/Stage/StageCombatHelper.cs
- GameServer/Component/Stage/Monster/MonsterComponent.cs
- GameServer/Component/Stage/Wave/WaveComponent.cs
- GameServer/Component/Stage/Weapons/WeaponComponent.cs
- GameServer/Component/Stage/Weapons/GarlicWeapon.cs
- GameServer/Component/Stage/Weapons/BibleWeapon.cs
- GameServer/Component/Stage/Weapons/WandWeapon.cs
- GameServer/Component/Stage/Weapons/KnifeWeapon.cs
- GameServer/Component/Stage/Weapons/AxeWeapon.cs
- GameServer/Component/Stage/Weapons/CrossWeapon.cs
- GameServer/Component/Lobby/LobbyComponent.cs
- GameServer/Systems/LobbySystem.cs
- GameServer/Systems/PlayerSystem.cs
- GameServer/Auth/LoginProcessor.cs

### Phase 5 (리뷰 후 추가 수정)
- StageComponent.cs — Initialize() foreach, SendInitialState() foreach 2개
- BibleWeapon.cs — OnUpgrade() throw
- AxeWeapon.cs — OnUpgrade() throw

### Phase 6 (코드 리뷰 권장사항 적용)
- StageComponent.cs — Update() → 6개 private 메서드로 분리 + 잔여 중괄호 수정 (람다, if-else 수학 연산)
- WeaponComponent.cs — GenerateChoices() Fisher-Yates 셔플 적용

## 확인하지 않은 파일

다음 파일은 이번 세션에서 수정하지 않았으나 중괄호 패턴이 있을 가능성 있음:
- GameServer/Controllers/PlayerRoomController.cs
- GameServer/Controllers/PlayerHeartbeatController.cs
- GameServer/Network/Policies/PacketHandshakePolicy.cs
- GameServer/Utilities/*.cs
- TestClient/ (테스트 코드)
- tools/ (툴 코드)

## 다음 단계

이 작업은 완료됨. 커밋 메시지 예시:

```
style: 코드 스타일 리팩토링 — 중괄호 통일, Update() 분리, Fisher-Yates 적용

- 모든 if/for/foreach/while/lock/람다 블록에 중괄호 추가
- StageComponent.Update() 170줄 → DrainInputQueue/TickSurvivalTimer/TickMonsterAI/CleanupDeadMonsters/TickWeapons/TickWaveSpawner 분리
- WeaponComponent.GenerateChoices() OrderBy(random) → Fisher-Yates 셔플 (위치 편향 제거)
- 빌드 0 에러/경고, 테스트 53개 전 통과
```
