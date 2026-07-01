# 코드 스타일 리팩토링 — 코드 아키텍처 리뷰

리뷰 일시: 2026-05-29  
리뷰 대상: 중괄호 누락 패턴 수정 및 가독성 개선 (22개 파일)

---

## 1. 로직 변경 여부 검증 (PASS)

전체 22개 파일을 읽고 확인한 결과, **로직 변경은 없다.** 중괄호 추가는 기존 제어 흐름을 그대로 보존한다.

특히 주의해서 확인한 부분:

- `PlayerCharacterComponent.AddGold` / `ApplyAttackUp` / `ApplyMaxHpUp` — early-return 패턴 보존 확인
- `PlayerSaveComponent.Update` — Volatile.Read 체인 조건 순서 유지 확인
- `StageComponent.Update` — 입력 드레인 루프, 생존 타이머, AI 틱 분기 보존 확인
- `StageCombatHelper.ApplyWeaponHit` — 넉백 → HP 변경 → 사망 처리 순서 유지 확인
- `MonsterComponent.Update` — 리스폰/추적 분기 보존 확인
- `WaveComponent.GetWaveEntries` — 프리셋/무한 웨이브 분기 보존 확인
- `LoginProcessor.ProcessInternalAsync` — Timing Attack 방어 더미 해시 경로 보존 확인
- `WeaponComponent` 전체 재작성 — 원래 로직 완전 보존 확인 (하단 §4 참조)

---

## 2. 남아있는 중괄호 누락 패턴

리팩토링 후에도 아래 패턴들이 남아있다. **의도적 스타일**인지 **누락**인지를 구분해 기록한다.

### 2-A. 수정이 필요한 누락 패턴

#### StageComponent.cs — Initialize() (line 104–105)
```csharp
// 현재 (중괄호 없음)
foreach (var p in players)
    _weaponManager.Register(p);
```
한 줄이지만 for 루프 바디이므로 중괄호가 있어야 한다.

#### StageComponent.cs — SendInitialState() (line 134–137)
```csharp
// 현재 (중괄호 없음)
foreach (var p in players)
    res.Players.Add(StageBroadcastHelper.BuildPlayerInfo(p));
foreach (var m in _monsters.Values)
    res.Monsters.Add(StageBroadcastHelper.BuildMonsterInfo(m));
```
두 foreach 모두 중괄호 누락.

#### BibleWeapon.cs — OnUpgrade() (line 108–110)
```csharp
else
{
    if (!GameDataTable.Weapons.TryGetValue(Id.ToString(), out var stat))
        throw new InvalidOperationException(...);   // 중괄호 없음
    Damage = (int)(Damage * stat.UpgradeMultDamage);
}
```
throw 단일 문이지만 표준 스타일에 맞추려면 중괄호 필요.

#### AxeWeapon.cs — OnUpgrade() (line 192–194)
```csharp
if (!GameDataTable.Weapons.TryGetValue(Id.ToString(), out var stat))
    throw new InvalidOperationException(...);   // 중괄호 없음
```
동일 패턴.

### 2-B. 의도적 한 줄 스타일 (허용 가능)

아래는 가독성을 위해 의도적으로 한 줄로 쓴 패턴이다. 프로젝트 관례상 허용 가능하지만, 팀이 "모든 제어문에 중괄호" 정책을 채택한다면 아래도 수정 대상이다.

| 위치 | 패턴 |
|------|------|
| `StageComponent.cs:149` | `if (IsDisposed \|\| _endedFlag == 1) return;` |
| `StageComponent.cs:156` | `if (_endedFlag == 1) break;` |
| `StageComponent.cs:163` | `foreach (var pkt in _pending) _room.BroadcastPacket(pkt);` |
| `StageComponent.cs:324,366,387` | `if (_endedFlag == 1) return;` (ProcessXxx 가드) |
| `StageComponent.cs:237` | `if (!monster.IsAlive \|\| ...) continue;` |
| `StageComponent.cs:403` | `if (string.IsNullOrWhiteSpace(...)) return;` (ProcessChat) |
| `LobbyComponent.cs:84` | `if (IsDisposed) return false;` |
| `StageComponent.cs:473` | `if (Interlocked.CompareExchange(...) != 0) return;` (EndGame) |

이 중 `StageComponent.cs:163` (`foreach (...) _room.BroadcastPacket(pkt);`)는 블록 내에 두 개의 문이 있는 것처럼 착각하기 쉬우므로 중괄호 추가를 권장한다.

---

## 3. 가독성 추가 개선 포인트

### 3-A. `StageComponent.Update` — 과도한 메서드 길이 (170줄)
`Update()` 메서드가 170줄에 달한다. 이미 `StageCombatHelper`로 일부 분리되어 있지만, 내부에 몬스터 AI 루프와 웨이브 처리가 혼재한다. 아래 분리를 제안한다:
```csharp
// 제안: private void TickMonsterAI(List<PlayerComponent> alivePlayers) 분리
// 제안: private void TickWeapons(List<PlayerComponent> alivePlayers) 분리
```
이번 리팩토링 범위 밖이지만 다음 개선 작업에서 고려할 가치가 있다.

### 3-B. `WeaponComponent.GenerateChoices` — LINQ 혼용
```csharp
var ownedIds = owned.Select(w => w.Id).ToHashSet();
// ...
return pool.OrderBy(_ => Random.Shared.Next()).Take(3).ToList();
```
로직상 문제는 없다. 단, `OrderBy(_ => Random.Shared.Next())`는 셔플이 보장되지 않는 anti-pattern이다 (같은 랜덤값이 나올 경우 정렬이 불안정). Fisher-Yates 셔플로 대체를 권장한다. 이 패턴은 이번 리팩토링에서 새로 도입된 것이 아니므로 별도 작업으로 처리한다.

### 3-C. `StageComponent.CollectNearbyGems` — 중간 result 리스트 경유
```csharp
var result = new List<(ulong, float, float, int)>();
foreach (var gem in _gems.Values) { ... result.Add(...); }
foreach (var (id, _, _, _) in result) { _gemPool.Push(...); _gems.Remove(id); }
return result;
```
_gems을 순회 중 수정할 수 없어서 두 단계로 나뉜 것은 맞다. 그러나 `result` 타입 추론이 튜플 4개짜리라서 가독성이 떨어진다. named tuple로 선언하면 개선된다:
```csharp
var result = new List<(ulong Id, float X, float Y, int ExpValue)>();
```
이미 반환 시그니처가 이 형태이므로 변수 타입도 일치시키면 좋다.

### 3-D. `LobbyComponent.RoomCount` — 프로퍼티 바디 스타일
```csharp
public int RoomCount { get { lock (_roomLock) return _rooms.Count; } }
```
단일 표현식이지만 `=>` 표현식 바디를 쓸 수 없는 lock이 포함된 경우이므로, 현재 스타일이 실질적으로 최선이다. 지적 불필요.

---

## 4. WeaponComponent.cs 전체 재작성 검증 (PASS)

이번 리팩토링에서 가장 위험한 변경은 `WeaponComponent.cs` 전체 재작성이었다. 아래 항목을 대조 확인했다:

| 기능 | 원래 로직 보존 여부 |
|------|-------------------|
| `Update()` — KnifeWeapon FacingDir 주입 | 보존 |
| `Update()` — BibleWeapon NotiOrbitalWeaponSync 수집 | 보존 |
| `Register()` — 기본 무기 KnifeWeapon | 보존 |
| `EnqueueChoice()` — 중첩 레벨업 pendingLevelUps 큐 | 보존 |
| `ApplyChoice()` — statUpgradeLevels 추적 | 보존 |
| `ApplyChoice()` — choiceId >= 100 스탯 업그레이드 분기 | 보존 |
| `ApplyStatUpgrade()` — 5종 switch 분기 | 보존 |
| `SendWeaponUpgrade()` — GarlicWeapon Radius 파라미터 특수 처리 | 보존 |
| `GenerateChoices()` — 소유 무기 업그레이드 + 미소유 신규 + 스탯 업그레이드 혼합 풀 | 보존 |
| `WeaponChoice` record 선언 (파일 하단) | 보존 |

**결론: 재작성 후 원래 로직이 완전하게 보존되어 있다.**

---

## 5. 종합 평가

| 항목 | 결과 |
|------|------|
| 로직 변경 없음 | PASS |
| 중괄호 추가 완결도 | 95% (4개 누락 잔존) |
| WeaponComponent 재작성 무결성 | PASS |
| 가독성 개선 | 양호 |

### 필수 후속 수정 (이번 리팩토링 완결을 위해)

1. `StageComponent.cs:104–105` — `foreach` 중괄호 추가
2. `StageComponent.cs:134–137` — `foreach` 두 개 중괄호 추가
3. `BibleWeapon.cs:108–110` — `if (!TryGetValue(...)) throw` 중괄호 추가
4. `AxeWeapon.cs:192–194` — 동일 패턴 중괄호 추가

### 선택적 개선 (별도 작업)

- `StageComponent.Update()` 메서드 분리 (AI 틱, 무기 틱 sub-method화) → Phase 6에서 완료
- `WeaponComponent.GenerateChoices()` Fisher-Yates 셔플 교체 → Phase 6에서 완료
- `StageComponent.CollectNearbyGems` result 변수 named tuple 타입 명시

---

## Phase 6 추가 리뷰 — Update() 분리 + Fisher-Yates (2026-05-29)

리뷰 대상:
- `GameServer/Component/Stage/StageComponent.cs` — Update() 메서드 분리 (6개 private 서브루틴)
- `GameServer/Component/Stage/Weapons/WeaponComponent.cs` — Fisher-Yates 셔플 적용

---

### 6-1. StageComponent — 메서드 분리 응집도·명명 평가 (PASS)

| 메서드 | 책임 단일성 | 명명 | 평가 |
|--------|------------|------|------|
| `DrainInputQueue()` | 입력 큐 소진 전담 | 명확 | PASS |
| `TickSurvivalTimer(float dt)` | 생존 시간 누적 + 10초 브로드캐스트 | 명확 | PASS |
| `TickMonsterAI(float dt, List<PlayerComponent> alivePlayers)` | 몬스터 AI 루프 전담 | 명확 | PASS |
| `CleanupDeadMonsters()` | 리스폰 불가 몬스터 제거 | 명확 | PASS |
| `TickWeapons(float dt, List<PlayerComponent> alivePlayers)` | 자동 무기 틱 + 히트 적용 | 명확 | PASS |
| `TickWaveSpawner(float dt)` | 웨이브 스포너 위임 | 명확 | PASS |

각 메서드가 단일 책임을 갖고 있으며, `Tick` 접두사가 dt(delta time)를 받는 틱 기반 메서드임을 일관되게 표현한다.
파라미터 이름 `alivePlayers`가 살아있는 플레이어만 필터된 목록임을 명시해 `players` 전달 시의 혼동을 방지한다.

`Update()` 본체도 깔끔하다 — 초기화, 드레인, 종료 여부 분기, 4개 틱 서브루틴, 브로드캐스트로 선형적으로 읽힌다.

---

### 6-2. TickMonsterAI — CheckAllPlayersDead에 alivePlayers 전달 (PASS)

```csharp
// StageComponent.cs:315
_combat.CheckAllPlayersDead(_pending, alivePlayers);

// StageCombatHelper.cs:112
internal void CheckAllPlayersDead(List<GamePacket> pending, IReadOnlyList<PlayerComponent> players)
{
    if (players.All(p => !p.Character.IsAlive))
    {
        _onEndGame(false, pending);
    }
}
```

**의미 동일 여부: PASS**

원본에서 `players` 전체 목록을 전달했다면 `All(p => !p.Character.IsAlive)` 조건이 "전원 사망 여부"를 정확히 판별했다.
현재는 `alivePlayers`를 전달한다. `alivePlayers`는 `players.Where(p => p.Character.IsAlive).ToList()`이므로:

- 방금 사망한 플레이어는 이 틱의 `alivePlayers`에 아직 포함되어 있다.
  (`alivePlayers`는 `Update()` 진입 시점에 필터링되고, 사망 처리는 그 이후에 발생하므로 해당 틱의 `alivePlayers`에는 방금 사망한 플레이어도 포함된다.)
- `alivePlayers`에 대해 `All(p => !p.Character.IsAlive)`를 호출하면, 방금 사망한 플레이어의 `IsAlive`가 이미 `false`로 갱신된 경우 "전원 사망" 판정이 올바르게 작동한다.
- 따라서 원본(`players` 전체) 대비 동작 차이가 없다. 오히려 전체 플레이어 목록을 쓰지 않아도 되므로 `GetPlayers()` 재호출을 줄인 것이 긍정적이다.

**단, 주의할 점**: `alivePlayers` 리스트가 비어있으면(`Count == 0`) `All()` 조건이 vacuous true로 즉시 게임 종료를 트리거한다. 이 케이스는 원본에서도 동일하게 발생하므로 동작 변화는 없다. 빈 목록 케이스는 게임 인원 검증 단계(RoomComponent.Ready)에서 차단된다고 가정할 수 있다.

---

### 6-3. Fisher-Yates 구현 정확성 (PASS)

```csharp
// WeaponComponent.cs:214-219
for (int i = pool.Count - 1; i > 0; i--)
{
    int j = Random.Shared.Next(i + 1);
    (pool[i], pool[j]) = (pool[j], pool[i]);
}
return pool.Take(3).ToList();
```

표준 Knuth-Fisher-Yates 알고리즘(후방 순서)의 정확한 구현이다:

- `i`가 `pool.Count - 1`에서 `1`까지 역순 순회 (마지막 인덱스부터 축소)
- `j = Random.Shared.Next(i + 1)` — `[0, i]` 범위 균등 분포 (포함)
- 튜플 스왑으로 임시 변수 불필요

`Thread-static` 없이 `Random.Shared`를 사용하는 것은 .NET 6+ 스레드 안전 보장으로 적절하다.
StageComponent 단일 틱 스레드에서 호출되므로 경합 우려도 없다.

**Take(3) 이후 처리**: `pool.Count`가 3 미만인 경우에도 `Take(3)`은 가용한 수만큼만 반환하며 예외를 발생시키지 않는다. `FlushChoice()`에서 `choices.Count == 0`이면 조기 리턴하는 guard가 있으므로 안전하다.

**이전 패턴의 문제점(제거됨)**: `OrderBy(_ => Random.Shared.Next())`는 정렬 키가 동일한 경우 TimSort의 내부 동작에 의존하여 불균등 분포를 낼 수 있었다. Fisher-Yates로 교체한 것이 정확한 수정이다.

---

### 6-4. 잔여 중괄호 누락 여부 (PASS)

Phase 5에서 지적된 4건(StageComponent.cs 2건, BibleWeapon.cs, AxeWeapon.cs)이 모두 수정된 것을 Tasks 파일로 확인했다.

Phase 6 신규 코드(6개 서브루틴)에서 추가 중괄호 누락 여부를 확인:

| 코드 위치 | 패턴 | 평가 |
|----------|------|------|
| `DrainInputQueue` while/if 블록 | 중괄호 있음 | PASS |
| `TickSurvivalTimer` if 블록 | 중괄호 있음 | PASS |
| `TickMonsterAI` foreach/if/continue 블록 | 중괄호 있음 | PASS |
| `CleanupDeadMonsters` if/foreach/Where 체인 | 중괄호 있음 | PASS |
| `TickWeapons` foreach 블록 | 중괄호 있음 | PASS |
| `TickWaveSpawner` if 블록 | 중괄호 있음 | PASS |

단, 아래 2개 패턴은 이전 리뷰 §2-B에서 "의도적 한 줄 스타일(허용 가능)"로 분류된 항목들이 Update() 내에 그대로 잔존한다:

```csharp
// StageComponent.cs:155-158
if (IsDisposed || _endedFlag == 1)
{
    return;   // ← 이 부분은 수정됨
}

// ProcessXxx guard (라인 379, 439, 462, 475)
if (_endedFlag == 1)
{
    return;   // ← 이미 중괄호 있음
}
```

현재 코드를 전체 확인한 결과 Phase 6 신규 코드에서 누락된 중괄호는 없다.

---

### 6-5. 기타 관찰사항

**TickMonsterAI 이동 배치 패킷**: 몬스터 이동을 개별 패킷이 아닌 단일 `NotiMonsterMove`로 배치하는 패턴은 올바르게 유지되고 있다 (`movedList ??= []` 지연 초기화 포함).

**TickWeapons attackerMap 캐시**: `alivePlayers.ToDictionary(p => p.AccountId)` 를 매 틱 생성하는 비용이 존재하지만, `LastHits` 수 × 플레이어 수의 O(n²) 탐색을 O(1)로 줄이는 trade-off가 주석으로 문서화되어 있어 의도가 명확하다.

**NotiRespawn 처리 위치**: `monster.WasRespawned` 분기에서 `continue`를 사용해 이동·공격 처리를 건너뛰는 로직이 서브루틴 분리 후에도 정확하게 보존되었다.

---

### Phase 6 종합 평가

| 항목 | 결과 |
|------|------|
| 메서드 분리 응집도·명명 | PASS |
| CheckAllPlayersDead alivePlayers 전달 의미 동일성 | PASS |
| Fisher-Yates 구현 정확성 | PASS |
| Take(3) 경계 케이스 안전성 | PASS |
| 신규 코드 중괄호 누락 | 없음 (PASS) |
| 빌드/테스트 | 0 에러·0 경고, 53/53 통과 (Tasks 파일 기준) |

**결론: Phase 6 변경사항은 모두 정확하다. 지적할 버그나 로직 오류 없음.**
