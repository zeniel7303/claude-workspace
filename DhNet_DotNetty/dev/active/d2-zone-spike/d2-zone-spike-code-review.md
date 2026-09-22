# d2-zone-spike 코드 리뷰

Last Updated: 2026-09-22

대상: `GameServer/World/ContentZone.cs`, `DisconnectOrchestrator.cs`, `ZoneContracts.cs`, `GameServer.Tests/ContentZoneContractTests.cs` (미커밋 변경)

---

## Executive Summary

Fix 1(EnterZoneAsync 타임아웃 레이스)과 Fix 2(Remove 이후 늦은 작업 무시) 모두 **블로킹 이슈 없음.**

---

## Critical Issues — 없음

---

## 로직 검증 메모 (참고용)

### Fix 1 — EnterZoneAsync 타임아웃 레이스

세 가지 경쟁 시나리오를 모두 추적했다.

**A. 타임아웃이 루프 실행 전에 발생 (phase == 0)**
- CAS: `outcome = 2`
- `phase == 0` → finished 대기 없이 즉시 `Unavailable()` 반환
- 루프 실행 시 `outcome == 2` 확인 → 스폰 없이 반환
- 스폰/스냅샷 없음 ✓

**B. 루프가 CanSpawn 도중 타임아웃 발생 (phase == 1)**
- CAS: `outcome = 2`
- `phase != 0` → `finished.Task.WaitAsync(_enterTimeout)` 대기
- CanSpawn이 끝나면 루프: entity 생성, `createdFlag = 1`, `CAS outcome 1` 실패(이미 2) → `Despawn(enqueueSnapshot: false)` ← 스냅샷 없음 ✓
- `finished.TrySetResult()` → timeout handler 재개, `Unavailable()` 반환
- 두 번째 `WaitAsync`도 타임아웃되면(CanSpawn이 더 오래 걸릴 때) warn 로그 후 반환; 루프가 나중에 완료될 때 여전히 `Despawn(enqueueSnapshot: false)` 실행 ✓

**C. 루프가 스폰 완료 직후 타임아웃 발생 (rare race)**
- 루프: `createdAccount` → `createdFlag = 1` → `CAS outcome = 1`(성공) → `done.TrySetResult(Spawned)`
- `WaitAsync` 드물게 타임아웃
- CAS `outcome = 2` 실패(이미 1) → `createdFlag == 1` → `RollbackSpawnAsync`
- `RollbackSpawnAsync`: `Despawn(enqueueSnapshot: false)` 포스트 ← 스냅샷 없음 ✓

**메모리 순서 확인**  
`Volatile.Write(createdAccount)` → `Volatile.Write(createdFlag = 1)` (release fence)  
`Volatile.Read(createdFlag)` (acquire fence) → `createdAccount` 읽기  
표준 producer-consumer volatile 패턴, .NET 메모리 모델 상 안전 ✓

**테스트 `EnterZoneAsync_TimeoutDuringSpawn_RollsBackOccupant` 분석**  
- `release.Set()`이 `await enterTask` 이후에 호출되는 구조:
  - 첫 번째 WaitAsync(400ms) 타임아웃 → finished 대기
  - 두 번째 WaitAsync(400ms) 타임아웃(release 안 됐으므로) → warn 로그, Unavailable 반환
  - `release.Set()` → 루프 재개, CAS 실패, `Despawn(false)` 실행
  - `zone.RunOneTick(0.1f)` 시점에 이미 despawn 완료
- `Assert.Empty(writer.Rows)`, `Assert.False(zone.IsSpawned(4))` ✓

---

### Fix 2 — Remove 이후 늦은 작업 무시

에포크(epoch) 메커니즘이 세 가지 경로를 차단한다.

**경로 1: `DisconnectOnLoop` 에포크 체크 (try 블록 상단)**
```csharp
if (EpochOf(accountId) != epoch) { DropStale(accountId, epoch); return; }
```
`MarkSessionRemoved` 호출 후 에포크 불일치 → `DropStale` 호출 → `Despawn(enqueueSnapshot: false)` ← 스냅샷 없음 ✓

**경로 2: `Despawn` 스냅샷 에포크 체크**
```csharp
if (enqueueSnapshot && occupant.Epoch == EpochOf(accountId))
```
오래된 occupant(epoch 0)가 `enqueueSnapshot: true`로 Despawn되더라도, `EpochOf == 1`이면 스냅샷 스킵 ✓

**경로 3: finally의 snapshotQueued 에포크 체크**
```csharp
if (EpochOf(accountId) == epoch) { snapshotQueued(); }
```
에포크 불일치 시 `SignalIfWaiting` 호출 자체가 차단됨. 이미 Flush가 진행 중이더라도 `TryEnterFlush`가 CAS로 보호돼 이중 실행 없음 ✓

**`Disconnect_OnSnapshotTimeout_StillFlushThenRemove_AndIgnoresLateSignal` 어서션 변경 검증**  
- 기존: `Assert.Contains("upsert", order)` (틱 없이 RunAsync 반환 불가능한 어서션이었음)
- 변경: `Assert.DoesNotContain("upsert", order)` + `Assert.Empty(writer.Rows)`
- 50ms 타임아웃 → 틱 없이 Flush+Remove+MarkSessionRemoved
- `zone.RunOneTick(0.1f)` → DisconnectOnLoop: 에포크 불일치 → DropStale → no snapshot ✓

**`Disconnect_AfterRemove_LateWorkDoesNotReplaceNewSpawn` 실행 순서**  
루프 큐 순서: `DisconnectOnLoop` 먼저 → `PostEnter` 다음  
DisconnectOnLoop: epoch mismatch(0≠1) → DropStale → `Despawn(false)` (기존 occupant 제거)  
PostEnter/EnterOnLoop: epoch=1로 새 occupant 생성 ✓  
기존 세션 스냅샷 없음, 새 스폰 정상 ✓

**`MarkSessionRemoved`가 `Remove()` 성공 시에만 호출되는 것 확인**  
`DisconnectOrchestrator`의 `removed` 플래그 패턴: Remove 예외 시 epoch 미증가 → 정합성 유지 ✓

---

## Next Steps

블로킹 이슈가 없으므로 현재 구현을 그대로 커밋 가능.
