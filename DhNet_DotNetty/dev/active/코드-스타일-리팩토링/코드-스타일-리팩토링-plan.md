# 코드 스타일 전체 리팩토링 — Plan

Last Updated: 2026-05-29

## Executive Summary

중괄호 누락 및 가독성 저하 패턴을 전수 수정.
C# 코딩 표준에 따라 `if`, `for`, `foreach`, `while`, `lock` 블록에 항상 중괄호를 붙인다.

## 현재 상태 (Current State Analysis)

- 이미 완료됨 (2026-05-29 세션)
- 빌드 0 오류·0 경고, 테스트 53개 전 통과

## 수정 범위

### 핵심 규칙

| Before | After |
|--------|-------|
| `if (x) return;` | `if (x) { return; }` (멀티라인) |
| `foreach (var x in y) f(x);` | `foreach (...) { f(x); }` |
| `lock (_lock) return x;` | `lock (_lock) { return x; }` |
| `if (a) { b; c; }` 단일 라인 | 개행 분리 |

## 수정된 파일 목록

| 파일 | 수정 사항 수 |
|------|------------|
| Common.Shared/Logging/GameLogger.cs | 4 |
| GameServer/Network/SessionComponent.cs | 1 |
| GameServer/Component/Player/PlayerCharacterComponent.cs | 3 |
| GameServer/Component/Player/PlayerWorldComponent.cs | 4 |
| GameServer/Component/Player/PlayerLobbyComponent.cs | 2 |
| GameServer/Component/Player/PlayerRoomComponent.cs | 2 |
| GameServer/Component/Player/PlayerSaveComponent.cs | 5 |
| GameServer/Component/Stage/StageComponent.cs | 2 |
| GameServer/Component/Stage/StageCombatHelper.cs | 7 |
| GameServer/Component/Stage/Monster/MonsterComponent.cs | 6 |
| GameServer/Component/Stage/Wave/WaveComponent.cs | 4 |
| GameServer/Component/Stage/Weapons/WeaponComponent.cs | 전체 재작성 (14+) |
| GameServer/Component/Stage/Weapons/GarlicWeapon.cs | 2 |
| GameServer/Component/Stage/Weapons/BibleWeapon.cs | 6 |
| GameServer/Component/Stage/Weapons/WandWeapon.cs | 7 |
| GameServer/Component/Stage/Weapons/KnifeWeapon.cs | 4 |
| GameServer/Component/Stage/Weapons/AxeWeapon.cs | 5 |
| GameServer/Component/Stage/Weapons/CrossWeapon.cs | 5 |
| GameServer/Component/Lobby/LobbyComponent.cs | 4 |
| GameServer/Systems/LobbySystem.cs | 2 |
| GameServer/Systems/PlayerSystem.cs | 2 |
| GameServer/Auth/LoginProcessor.cs | 4 |
