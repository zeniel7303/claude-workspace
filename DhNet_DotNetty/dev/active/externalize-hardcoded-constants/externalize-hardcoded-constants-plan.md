# Plan: 하드코딩 상수 외부화 (externalize-hardcoded-constants)
Last Updated: 2026-05-27

## Executive Summary
C# 컴포넌트 전반에 흩어진 게임 밸런스 상수(플레이어 초기 스탯, 스탯 업그레이드 증감·상한, 무기별 물리 파라미터, 맵 크기 등)를 JSON 파일로 이전한다. 재컴파일 없이 밸런스 조정이 가능해지고, 단위 테스트에서 기대값을 JSON에서 읽어 코드 변경 시 자동으로 동기화된다.

## Current State (현재 상태)
- `weapons.json` / `monsters.json` — 이미 데이터화 완료
- C# 코드 내 하드코딩 상수 120+ 개
- 맵 크기(3200×2400)가 PlayerWorldComponent, MonsterComponent, WeaponBase, StageComponent에 중복 선언
- 플레이어 초기 스탯, 레벨업 공식 계수, 스탯 업그레이드 증감/상한 전부 코드에 매몰

## Proposed Future State
| JSON 파일 | 담당 영역 |
|-----------|-----------|
| `config.json` (기존 확장) | 맵 크기, 웨이브 스케일링 계수, dt 클램프 |
| `player.json` (신규) | 초기 스탯, 레벨업 계수, 스탯 업그레이드 증감·상한, 이동속도 상한 |
| `weapons.json` (기존 확장) | 무기별 물리 파라미터(반경, 속도, 수명, 넉백 등) |

`GameDataTable`이 세 파일을 모두 로드하고 정적 프로퍼티로 노출한다.

## Implementation Phases

### Phase 1 — config.json 확장 + GameDataTable MapConfig (S)
- `config.json`에 `mapWidth`, `mapHeight`, `waveScalePerWave`, `maxDtSec` 추가
- `GameDataTable.MapConfig` 레코드 추가
- PlayerWorldComponent, MonsterComponent, WeaponBase, StageComponent에서 상수 참조 → `GameDataTable.MapConfig.*` 치환

### Phase 2 — player.json 신규 + PlayerConfig (M)
- `player.json` 생성: 초기 스탯, 레벨업 계수, 스탯 업그레이드 파라미터
- `GameDataTable.Player` 레코드 추가
- PlayerWorldComponent, PlayerCharacterComponent, WeaponComponent에서 읽도록 수정

### Phase 3 — weapons.json 확장 + 무기 물리 파라미터 (M)
- `WeaponStat` 레코드에 무기별 물리 필드 추가
  - 공통: `hitRadius`, `projectileSpeed`, `projectileLifetime`, `maxProjectiles`
  - 마늘 전용: `auraRadius`, `knockbackDist`, `upgradeAuraRadius`
  - 성경 전용: `orbitRadius`, `perEnemyCooldown`, `angularSpeedRad`
  - 도끼 전용: `gravity`, `verticalSpeed`
  - 십자가 전용: `maxDist`
- 각 무기 클래스에서 const → `GameDataTable.Weapons[Id].*` 치환

### Phase 4 — 단위 테스트 동기화 (S)
- GarlicWeaponTests, PlayerWorldTests 등에서 하드코딩된 기대값을 `GameDataTable.*`로 치환

## Risk Assessment
| 위험 | 대책 |
|------|------|
| JSON 키 누락 시 런타임 오류 | GameDataTable.Load()에서 필수 키 검증 + 서버 시작 시 throw |
| 기존 53개 테스트 회귀 | 각 Phase 후 `dotnet test` 확인 |
| 맵 크기 중복 제거 시 컴파일 에러 | const → 프로퍼티 참조로 일괄 치환, 빌드 확인 |
