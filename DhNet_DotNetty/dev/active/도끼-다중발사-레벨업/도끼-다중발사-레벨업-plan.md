# 도끼 다중발사 레벨업 시스템 — 구현 계획

Last Updated: 2026-05-22

## Executive Summary

AxeWeapon이 레벨업 시 홀수 레벨마다 발사 개수가 늘어나고, 짝수 레벨마다 데미지가 증가하도록 구현한다.
BibleWeapon의 다중 성경 패턴을 참조하되, 도끼는 투사체(비공전)이므로 `_axeCount`로 발사 수만 관리한다.

---

## Current State Analysis

- `AxeWeapon.TryAttack()`: 가장 가까운 적 방향으로 투사체 1발 고정 발사
- `WeaponBase.OnUpgrade()`: 데미지 ×UpgradeMultDamage, 쿨다운 단축 — AxeWeapon은 이를 그대로 사용 중
- `BibleWeapon`: 홀수 레벨 → 개수+1, 짝수 레벨 → 데미지+20% 패턴이 이미 구현됨

## Proposed Future State

- 레벨 1: 도끼 1발 (기존 동작 유지)
- 레벨 2: 데미지 ×1.2
- 레벨 3: 도끼 2발 (0°, 180° — 가장 가까운 적 방향 기준 균등 분산)
- 레벨 4: 데미지 ×1.2
- 레벨 5: 도끼 3발 (0°, 120°, 240°)
- 이하 반복

발사 각도 계산: baseAngle(최근접 적 방향) + 2π × i / axeCount

---

## Implementation

### Phase 1 — AxeWeapon 수정

1. `private int _axeCount = 1;` 필드 추가
2. `OnUpgrade()` 오버라이드:
   - `Level % 2 == 1` (홀수) → `_axeCount++`
   - 짝수 → `Damage = (int)(Damage * 1.2f)`
   - base.OnUpgrade() 호출하지 않음 (쿨다운 단축도 제거)
3. `TryAttack()` 수정: 최근접 적 방향 baseAngle 계산 후 _axeCount 만큼 균등 각도로 발사

### Phase 2 — 빌드 검증

- 컴파일 오류 0, 경고 0

---

## Risk Assessment

| 위험 | 완화 |
|------|------|
| MaxProjectiles 한도 초과 | _axeCount × 발사 수 고려하여 한도 여유 확인 |
| 적이 없을 때 baseAngle | 최근접 적 없으면 기존처럼 return [] |
| 쿨다운 base.OnUpgrade 제거 시 누락 | CooldownMin만큼 하드캡 유지 |

## Success Metrics

- 레벨 3 도끼가 동시에 2방향으로 발사됨
- 레벨 5 도끼가 3방향 발사됨
- 기존 레벨 1 동작 변화 없음
- 빌드 경고 0
