# 코드 스타일 리팩토링 — Tasks

Last Updated: 2026-05-29

## Phase 1: 핵심 파일 중괄호 수정

- ✅ Common.Shared/Logging/GameLogger.cs
- ✅ GameServer/Network/SessionComponent.cs
- ✅ GameServer/Component/Player/PlayerCharacterComponent.cs
- ✅ GameServer/Component/Player/PlayerWorldComponent.cs
- ✅ GameServer/Component/Player/PlayerLobbyComponent.cs
- ✅ GameServer/Component/Player/PlayerRoomComponent.cs
- ✅ GameServer/Component/Player/PlayerSaveComponent.cs
- ✅ GameServer/Component/Stage/StageComponent.cs
- ✅ GameServer/Component/Stage/StageCombatHelper.cs
- ✅ GameServer/Component/Stage/Monster/MonsterComponent.cs
- ✅ GameServer/Component/Stage/Wave/WaveComponent.cs

## Phase 2: 무기 시스템 수정

- ✅ GameServer/Component/Stage/Weapons/WeaponComponent.cs
- ✅ GameServer/Component/Stage/Weapons/GarlicWeapon.cs
- ✅ GameServer/Component/Stage/Weapons/BibleWeapon.cs
- ✅ GameServer/Component/Stage/Weapons/WandWeapon.cs
- ✅ GameServer/Component/Stage/Weapons/KnifeWeapon.cs
- ✅ GameServer/Component/Stage/Weapons/AxeWeapon.cs
- ✅ GameServer/Component/Stage/Weapons/CrossWeapon.cs

## Phase 3: 시스템/인프라 수정

- ✅ GameServer/Component/Lobby/LobbyComponent.cs
- ✅ GameServer/Systems/LobbySystem.cs
- ✅ GameServer/Systems/PlayerSystem.cs
- ✅ GameServer/Auth/LoginProcessor.cs

## Phase 4: 미확인 파일 (선택적 후속 작업)

- ⬜ GameServer/Controllers/PlayerRoomController.cs
- ⬜ GameServer/Controllers/PlayerHeartbeatController.cs
- ⬜ GameServer/Network/Policies/PacketHandshakePolicy.cs
- ⬜ GameServer/Utilities/*.cs
- ⬜ TestClient/ 시나리오 파일들

## Phase 5: 코드 리뷰 지적사항 수정

- ✅ StageComponent.cs — Initialize() foreach 중괄호
- ✅ StageComponent.cs — SendInitialState() foreach 2개 중괄호
- ✅ BibleWeapon.cs — OnUpgrade() throw 중괄호
- ✅ AxeWeapon.cs — OnUpgrade() throw 중괄호

## Phase 6: 코드 리뷰 권장사항 적용

- ✅ StageComponent.cs — Update() 170줄 → 6개 private 메서드 분리 (DrainInputQueue, TickSurvivalTimer, TickMonsterAI, CleanupDeadMonsters, TickWeapons, TickWaveSpawner)
- ✅ StageComponent.cs — 람다 내부 guard clause 중괄호, if-else 수학 연산 중괄호, continue 중괄호 수정
- ✅ WeaponComponent.cs — GenerateChoices() Fisher-Yates 셔플 적용 (OrderBy 제거)

## 검증

- ✅ dotnet build — 0 에러, 0 경고 (Phase 6 완료 후 재빌드 포함)
- ✅ dotnet test — 53/53 통과 (GameServer.Tests/ 디렉토리에서 실행)
