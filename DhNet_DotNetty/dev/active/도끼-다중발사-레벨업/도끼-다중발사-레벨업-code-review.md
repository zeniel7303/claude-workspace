# 도끼 다중발사 레벨업 — 코드 리뷰

Last Updated: 2026-05-22

## Critical: 없음

## Major

**M1 (수정 완료): MaxProjectiles 초과 가능**
- 원인: `if (_projectiles.Count >= MaxProjectiles) return []` 이후 루프에서 _axeCount개를 무조건 추가
- 수정: `int slots = MaxProjectiles - _projectiles.Count; int fireCount = Math.Min(_axeCount, slots);`

**M2 (의도적 설계): CooldownSec 단축 영구 누락**
- `base.OnUpgrade()` 미호출로 쿨다운 감소 없음
- 원래 task spec: "공전 속도 업그레이드 로직 제거 (레벨 기준 변경)" — 설계 의도
- 도끼 업그레이드 전략은 개수/데미지만, 쿨다운 단축 없음

**M3 (의도적 설계): 분산 각도의 Sin 성분이 velY에 반영되지 않음**
- `velY = -VerticalSpeed` 고정 (각도와 무관)
- 포물선 아크 무기 특성: 항상 위로 솟구치는 궤적이 도끼의 정체성
- 각도는 velX(수평 방향)에만 영향, velY는 중력 공식에 사용됨

## Minor

**m1 (수용): MaxProjectiles 주석 "최대 5개" 오래된 숫자**
- `slots` 기반 코드로 대체되어 주석 자체가 불필요해짐

**m2 (수용): 첫 _axeCount 증가가 레벨 3부터**
- Level=2(짝수, 데미지업) → Level=3(홀수, 개수+1) 순서 — 의도적 설계

**m3 (BibleWeapon 관련, 별도 이슈): AddBible()의 _angles[0] 기준 재배치 시 순간이동 가능성**
- AxeWeapon과 무관, 필요 시 별도 task로 처리
