# 도끼 다중발사 레벨업 — 컨텍스트

Last Updated: 2026-05-22

## 구현 상태: 완료 (빌드 경고 0, 오류 0)

## 핵심 파일

| 파일 | 역할 |
|------|------|
| `GameServer/Component/Stage/Weapons/AxeWeapon.cs` | **수정 완료** |
| `GameServer/Component/Stage/Weapons/BibleWeapon.cs` | 홀수/짝수 레벨업 패턴 참조 |
| `GameServer/Component/Stage/Weapons/WeaponBase.cs` | OnUpgrade 기본 구현 |
| `GameServer/Component/Stage/Weapons/WeaponComponent.cs` | 무기 틱/레벨업 진입점 (수정 없음) |

## 이 세션에서 내린 결정사항

### 1. `_axeCount` (int) 로 발사 수 관리
Bible처럼 `List<float> _angles`가 아닌 단순 정수 카운터로 관리.
도끼는 매 cooldown마다 발사 시 방향을 새로 계산하므로 각도 상태를 유지할 필요 없음.

### 2. 쿨다운 단축 제거 (의도적)
`base.OnUpgrade()` 미호출 → 쿨다운 단축 없음.
원래 task spec: "공전 속도 업그레이드 로직 제거 (레벨 기준 변경)".
도끼 레벨업 전략 = 홀수: 개수+1, 짝수: 데미지×UpgradeMultDamage. 쿨다운 감소 없음.

### 3. velY 항상 -VerticalSpeed (의도적)
분산 각도의 Sin 성분을 velY에 반영하지 않음.
도끼는 "포물선 아크" 무기이므로 방향과 무관하게 항상 위로 솟구쳤다가 내려오는 궤적 유지.
각도는 velX(수평 방향)에만 영향을 줌.

### 4. MaxProjectiles 5 → 10 상향
다중 도끼 최대 5개(레벨 9) 수용을 위해 상향.

### 5. 슬롯 초과 버그 수정 (코드 리뷰 Major #1)
코드 리뷰에서 발견: `_axeCount`개 일괄 추가 전 슬롯 체크 미흡으로 MaxProjectiles 초과 가능.
`int slots = MaxProjectiles - _projectiles.Count; int fireCount = Math.Min(_axeCount, slots);` 로 수정.

## 수정된 코드 핵심 (AxeWeapon.cs)

```csharp
private int _axeCount = 1;

// TryAttack() 핵심 변경:
int slots = MaxProjectiles - _projectiles.Count;
if (slots <= 0) return [];
int fireCount = Math.Min(_axeCount, slots);
float baseAngle = MathF.Atan2(nearest.Y - ownerY, nearest.X - ownerX);
for (int i = 0; i < fireCount; i++)
{
    float angle = baseAngle + 2f * MathF.PI * i / _axeCount;
    float velX  = MathF.Cos(angle) * HorizontalSpeed;
    float velY  = -VerticalSpeed;
    ...
}

// OnUpgrade() 추가:
protected override void OnUpgrade()
{
    if (Level % 2 == 1) _axeCount++;
    else Damage = (int)(Damage * stat.UpgradeMultDamage);
    // base.OnUpgrade() 미호출 — 쿨다운 단축 없음 (설계 의도)
}
```

## 다음 단계

- 실제 게임 테스트 (레벨 3, 5에서 다중 도끼 동작 확인)
- weapon-balance-rework tasks 완료 처리
- 커밋
