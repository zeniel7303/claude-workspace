# 도끼 다중발사 레벨업 — 체크리스트

Last Updated: 2026-05-22

## 구현

- ✅ `AxeWeapon._axeCount` 필드 추가 (초기값 1)
- ✅ `MaxProjectiles` 5 → 10으로 상향 (다중 도끼 수용)
- ✅ `TryAttack()`: 슬롯 계산 후 최근접 적 기준 baseAngle, _axeCount 균등 분산 발사
- ✅ `TryAttack()` 슬롯 초과 버그 수정 (`Math.Min(_axeCount, slots)`)
- ✅ `OnUpgrade()` 오버라이드:
  - 홀수 레벨 → `_axeCount++`
  - 짝수 레벨 → `Damage *= UpgradeMultDamage`
  - `base.OnUpgrade()` 미호출 (쿨다운 단축 제거 — 설계 의도)

## 빌드 검증

- ✅ 경고 0, 오류 0 (수정 후 재빌드 포함)

## 코드 리뷰 결과 처리

- ✅ Major #1: `MaxProjectiles` 초과 버그 수정
- ✅ Major #2: 쿨다운 미적용 — 의도적 설계, context.md에 근거 문서화
- ✅ Major #3: velY 고정 — 포물선 아크 무기 특성상 의도적, context.md에 문서화
- ✅ Minor #4: 주석 "최대 5개" → 슬롯 코드로 대체돼 주석 의미 없어짐 (수용)

## 밸런스/디자인 수정 (2026-05-22 추가)

- ✅ 부채꼴 집중 발사: SpreadOffsetsDeg 테이블 도입
  - 1발: [0°], 2발: [±25°], 3발: [±40°, 0°], 4발: [±45°, ±15°], 5발: [±50°, ±25°, 0°]
- ✅ 짝수 레벨 쿨다운 단축 복원 (데미지 ×1.2 + 쿨다운 ×0.9 동시 적용)

## 미완료

- ⬜ 실제 게임 테스트 (레벨 3, 5 다중 도끼 확인)
- ⬜ 커밋
