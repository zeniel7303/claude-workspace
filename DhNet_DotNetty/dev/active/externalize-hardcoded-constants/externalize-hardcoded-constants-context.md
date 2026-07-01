# Context: externalize-hardcoded-constants
Last Updated: 2026-05-27

## 핵심 파일
- `GameServer.Resources/GameDataTable.cs` — Load() 확장 및 레코드 추가 대상
- `Bin/resources/config.json` — mapWidth/mapHeight/waveScalePerWave/maxDtSec 추가
- `Bin/resources/player.json` — 신규 생성
- `Bin/resources/weapons.json` — 물리 파라미터 필드 추가
- `GameServer/Component/Player/PlayerWorldComponent.cs` — MoveSpeed, MaxSpeed, MapW/H, MaxDtSec
- `GameServer/Component/Player/PlayerCharacterComponent.cs` — 초기 스탯, 레벨업 계수, 업그레이드 증감·상한
- `GameServer/Component/Stage/Weapons/GarlicWeapon.cs` — _radius, _knockbackDist, 업그레이드 반경 증가
- `GameServer/Component/Stage/Weapons/KnifeWeapon.cs` — Speed, Lifetime, HitRadius, MaxProjectiles
- `GameServer/Component/Stage/Weapons/WandWeapon.cs` — 동일
- `GameServer/Component/Stage/Weapons/AxeWeapon.cs` — Gravity, HorizontalSpeed, VerticalSpeed 등
- `GameServer/Component/Stage/Weapons/BibleWeapon.cs` — OrbitRadius, AngularSpeed 등
- `GameServer/Component/Stage/Weapons/CrossWeapon.cs` — MaxDist, Lifetime 등
- `GameServer/Component/Stage/Weapons/WeaponComponent.cs` — MoveSpeedUp 증가량(25f)
- `GameServer/Component/Stage/Monster/MonsterComponent.cs` — MapWidth/Height, waveScale(0.08f)
- `GameServer/Component/Stage/Weapons/WeaponBase.cs` — MapW, MapH 중복 선언

## 주요 결정 사항
- 맵 크기는 `config.json`에 통합 (MapConfig 레코드)
- 플레이어 관련 값은 `player.json` 신규 파일로 분리 (PlayerConfig 레코드)
- 무기 물리 파라미터는 `weapons.json`의 `WeaponStat` 레코드 확장으로 처리
- `GameDataTable`은 정적 싱글턴 — Load() 이후 읽기만 허용
- JSON 옵션: PropertyNameCaseInsensitive=true, CamelCase NamingPolicy (기존 동일)

## player.json 구조 (예시)
```json
{
  "initialHp": 500,
  "initialAttack": 20,
  "initialDefense": 10,
  "initialMoveSpeed": 300.0,
  "maxMoveSpeed": 500.0,
  "levelExpCoeff": 15,
  "attackUpAmount": 2,
  "attackUpCap": 80,
  "maxHpUpAmount": 25,
  "maxHpUpCap": 1000,
  "moveSpeedUpAmount": 25.0,
  "expMultiUpFactor": 1.10,
  "expMultiUpCap": 2.5,
  "expRadiusUpAmount": 15.0,
  "expRadiusUpCap": 120.0
}
```

## config.json 추가 항목 (예시)
```json
{
  "waveInterval": 8,
  "mapWidth": 3200.0,
  "mapHeight": 2400.0,
  "waveScalePerWave": 0.08,
  "maxDtSec": 0.1
}
```

## weapons.json WeaponStat 확장 필드 (예시, 마늘)
```json
"Garlic": {
  "damage": 5,
  "cooldownSec": 1.0,
  "upgradeMultDamage": 1.20,
  "upgradeMultCooldown": 0.90,
  "cooldownMin": 0.30,
  "auraRadius": 80.0,
  "knockbackDist": 50.0,
  "upgradeAuraRadius": 10.0
}
```
