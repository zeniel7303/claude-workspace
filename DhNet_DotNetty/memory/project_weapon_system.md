---
name: ""
description: "구현된 무기 목록, WeaponId 매핑, 이모지, 궤적 방식 — 새 무기 추가 시 참조"
metadata: 
  node_type: memory
  type: project
  originSessionId: e9d45a8d-2304-40ba-985c-d649a61a3bd8
---

## 현재 구현된 무기 (2026-03-30 기준)

| WeaponId | 이름 | 클래스 | 타입 | 이모지 | 특이사항 |
|----------|------|--------|------|--------|----------|
| 0 | 마늘 | GarlicWeapon | AoE 오라 | (없음) | 플레이어 주변 지속 데미지 + 넉백 |
| 1 | 마법 지팡이 | WandWeapon | 직선 투사체 | 🪄 | 최근접 적 자동 조준, 비관통. **기본 시작 무기** |
| 2 | 성경 | BibleWeapon | 공전형 | 📖 | 플레이어 주위 궤도 회전, 지속 데미지. NotiOrbitalWeaponSync |
| 3 | 도끼 | AxeWeapon | 포물선 투사체 | 🪓 | 중력(Gravity=1000) sin 아크, 관통. 홀수 레벨 개수+1(최대 5), 짝수 레벨 데미지×1.2. 다방향 균등 분산 발사 |
| 4 | 단검 | KnifeWeapon | 직선 투사체 | 🗡️ | 캐릭터 이동 방향(FacingDirX/Y) 발사, 비관통 |
| 5 | 십자가 | CrossWeapon | 부메랑 투사체 | ✝️ | sin 궤적 왕복, 관통, 전진·귀환 각 1회 명중 |

## 주요 아키텍처 포인트

- **공유 ProjectileId**: `WeaponBase.NextProjectileId()` — 모든 투사체 무기가 공유
- **도끼 위치 공식**: `y(t) = y0 + velY*t + 0.5*1000*t²` (서버·클라이언트 동일)
- **도끼 다중발사**: `_axeCount`로 관리, `baseAngle + 2π×i/_axeCount` 균등 분산. velY는 항상 -VerticalSpeed(포물선 고정)
- **십자가 위치 공식**: `pos(t) = start + dir * sin(π*t/1.4)` (서버·클라이언트 동일)
- **단검 방향**: `PlayerWorldComponent.FacingDirX/Y` — `Move()` 호출 시 갱신, 맵 순환 점프 제외
- **성경/도끼 레벨업 패턴**: 홀수 레벨 → 개수+1, 짝수 레벨 → 데미지×UpgradeMultDamage. base.OnUpgrade() 미호출(쿨다운 단축 없음)
- **성경 공전 동기화**: `NotiOrbitalWeaponSync` 매 틱 브로드캐스트

**Why:** 무기 추가 시 위 테이블의 다음 ID 사용. 클라이언트 상수(AXE_GRAVITY, CROSS_LIFETIME)는 서버 상수와 반드시 일치.
**How to apply:** 새 무기 추가 시 WeaponBase.cs enum → *Weapon.cs → WeaponManager 풀+팩토리 → game.js case+drawProjectile 순서로 진행.
