# Tasks: externalize-hardcoded-constants
Last Updated: 2026-05-27

## Phase 1 — config.json + MapConfig [S] ✅
- [x] config.json에 mapWidth, mapHeight, waveScalePerWave, maxDtSec 추가
- [x] GameDataTable에 MapConfig 레코드 및 정적 프로퍼티 추가, Load()에서 파싱
- [x] PlayerWorldComponent — MapW/H const → GameDataTable.Map.*
- [x] MonsterComponent — MapWidth/Height const + waveScalePerWave → GameDataTable.Map.*
- [x] WeaponBase — MapW/H const → GameDataTable.Map.*
- [x] WaveComponent — MapWidth/Height const → GameDataTable.Map.*
- [x] StageComponent — 인라인 1600f/3200f/1200f/2400f → GameDataTable.Map.*
- [x] dotnet test 통과 확인

## Phase 2 — player.json + PlayerConfig [M] ✅
- [x] Bin/resources/player.json 신규 생성
- [x] GameDataTable에 PlayerConfig 레코드 및 정적 프로퍼티 추가, Load()에서 파싱
- [x] PlayerWorldComponent — 초기 MoveSpeed, MaxSpeed → GameDataTable.Player.*
- [x] PlayerCharacterComponent — 초기 스탯, 레벨업 계수, 업그레이드 증감·상한 → GameDataTable.Player.*
- [x] WeaponComponent — MoveSpeedUp 증가량 → GameDataTable.Player.MoveSpeedUpAmount
- [x] dotnet test 통과 확인

## Phase 3 — weapons.json 확장 + 무기 물리 파라미터 [M] ✅
- [x] WeaponStat 레코드에 물리 필드 추가 (nullable)
- [x] weapons.json 각 무기에 물리 파라미터 추가
- [x] GarlicWeapon — _radius, _knockbackDist, upgradeAuraRadius → GameDataTable.Weapons["Garlic"].*
- [x] KnifeWeapon — Speed, Lifetime, HitRadius, MaxProjectiles → GameDataTable.Weapons["Knife"].*
- [x] WandWeapon — 동일
- [x] AxeWeapon — Gravity, HorizontalSpeed, VerticalSpeed, Lifetime, HitRadius, MaxProjectiles
- [x] BibleWeapon — OrbitRadius, HitRadius, PerEnemyCooldown, AngularSpeedRad
- [x] CrossWeapon — MaxDist, Lifetime, HitRadius, MaxProjectiles
- [x] dotnet test 통과 확인

## Phase 4 — 단위 테스트 동기화 [S] ✅
- [x] PlayerWorldTests — IClassFixture<GameDataFixture> 추가, MoveSpeed/MaxSpeed/MaxDtSec 기대값 → GameDataTable에서 읽기
- [x] PlayerCharacterTests — IClassFixture<GameDataFixture> 추가, 초기 스탯/업그레이드 증감·상한 → GameDataTable에서 읽기
- [x] GarlicWeaponTests — CooldownSec, radius, upgradeAuraRadius 기대값 → GameDataTable에서 읽기
- [x] dotnet test 최종 53개 전체 통과 확인

## Status
- [x] Phase 1 완료
- [x] Phase 2 완료
- [x] Phase 3 완료
- [x] Phase 4 완료
- [x] 전체 완료 — 빌드 경고 0, 오류 0, 테스트 53/53 통과
