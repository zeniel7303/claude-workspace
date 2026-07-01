# 프로젝트 개선 백로그

Last Updated: 2026-05-29

이 문서는 즉시 착수하지 않지만 언제든 작업 가능한 개선 항목을 관리한다.
이미 `dev/active/` 에 있는 작업은 여기 중복 기재하지 않는다.

---

## 버그 / 로직 오류

### B-1: WaveComponent MaxMonsters 초과 스폰 `[보통]`
- **파일**: `GameServer/Component/Stage/Wave/WaveComponent.cs`
- **문제**: `remaining` 계산 후 실제 스폰 수 기준으로만 제한하므로, 현재 살아있는 몬스터가 이미 MaxMonsters를 초과해도 추가 스폰 발생 가능
- **수정**: 스폰 전 `_monsters.Count >= MaxMonsters` 조기 반환 추가

### B-2: 5명 이상 플레이어 스폰 처리 `[낮음]`
- **파일**: `GameServer/Component/Stage/StageComponent.cs:97`
- **문제**: `SpawnPoints` 배열이 4개, 5명 이상 입장 시 `(400f, 300f)` 고정 좌표 사용 — 로그도 없고 겹침 발생
- **수정**: 경고 로그 추가 또는 맵 크기 기준 동적 스폰 포인트 생성

### B-3: EndGame 후 같은 틱 후속 Tick 패킷 누락/혼선 `[보통]`
- **파일**: `GameServer/Component/Stage/StageComponent.cs:162-170`
- **문제**: `EndGame`이 호출된 틱에서 `_endedFlag` 체크 없이 나머지 `TickMonsterAI`/`TickWeapons`/`TickWaveSpawner`가 계속 실행됨 → "종료 후 스폰" 패킷이 `NotiGameEnd`와 함께 전송돼 클라이언트 혼선
- **수정**: `Update`의 각 서브루틴 사이에 `if (_endedFlag == 1) break;` 추가하거나, 보스 처치/전멸 판정을 모든 Tick 종료 후 한곳에서 처리

### B-4: 사망 시 무기선택 대기 stuck — 기능 손실 `[보통]`
- **파일**: `GameServer/Component/Stage/Weapons/WeaponComponent.cs:222-262`
- **문제**: `_waitingForChoice=true` 상태에서 플레이어 사망 시 `_waitingForChoice`/`_pendingLevelUps`가 정리되지 않아 남은 게임 동안 무기 선택 기회 영구 손실
- **수정**: 플레이어 사망 시 해당 accountId의 `_waitingForChoice`/`_pendingLevelUps` 정리 또는 부활 시 재발행 정책 구현

### B-5: 죽은 플레이어가 젬 수집·레벨업 가능 `[낮음]`
- **파일**: `GameServer/Component/Stage/StageCombatHelper.cs:71-107`
- **문제**: `ProcessMove` enqueue 시점과 실제 실행 사이에 사망하면 `CollectGems`에 IsAlive 가드가 없어 죽은 플레이어가 젬 수집 → B-4(레벨업 stuck) 연쇄
- **수정**: `CollectGems` 진입부에 `if (!player.Character.IsAlive) return;` 추가

---

## 성능

### ~~P-1~P-3: 매 틱 할당 최적화~~ `[측정 결과 불필요 — 2026-05-29]`
- **측정 조건**: 20클라이언트 / 10룸 동시 진행 / 60초
- **결과**: alloc-rate 평균 1.5 MB/s, Gen0 GC 0.1회/s, CPU 0.1% 미만
- **재검토 조건**: 동시 룸 수 50개 이상 또는 alloc-rate 지속 10 MB/s 초과 시
- 동일 범주 항목: `StageComponent:181` alivePlayers ToList(), `:352` attackerMap ToDictionary(), `WeaponComponent` Where().ToList(), `BibleWeapon._enemyCooldowns` 3회 순회

### P-4: BibleWeapon 매 틱 임시 리스트 3개 할당 `[낮음]`
- **파일**: `GameServer/Component/Stage/Weapons/BibleWeapon.cs:46-69`
- **문제**: 매 틱 `expired`, `toUpdate`, `hits` 리스트를 새로 할당하고 쿨다운 딕셔너리를 2회 순회. 다른 무기는 `_pendingPackets` 멤버 재사용
- **수정**: `_enemyCooldowns` in-place 갱신(만료 키만 제거) + 재사용 멤버 버퍼 전환, 또는 쿨다운을 "만료 절대시각"으로 저장해 매 틱 가산 제거

### P-5: SessionSystem 고정 10ms 폴링 `[낮음]`
- **파일**: `GameServer/Systems/SessionSystem.cs:95-108`
- **문제**: `Thread.Sleep(10)` 폴링으로 이벤트 최대 10ms 지연, 유휴 시에도 100회/s 깨어남
- **수정**: `BlockingCollection<T>` 또는 `System.Threading.Channels`로 전환해 enqueue 시 즉시 처리

---

## 테스트 커버리지

### T-1: 게임 종료 케이스 테스트 `[높음]`
- **파일**: `GameServer.Tests/`
- **문제**: 전원 사망 경로, 30분 타임아웃 경로 모두 미검증
- **추가할 케이스**:
  - 플레이어 전원 사망 → `EndGame(false)` 호출 확인
  - `_survivalElapsed >= ClearTimeSec` → `EndGame(true)` 호출 확인

### T-2: WeaponComponent.ApplyChoice 분기 테스트 `[보통]`
- **파일**: `GameServer.Tests/`
- **문제**: 신규 무기 추가 / 기존 무기 레벨업 / 스탯 업그레이드 / 대기열 누적 4개 경로 미검증
- **추가할 케이스**:
  - `_waitingForChoice` 상태에서 두 번째 레벨업 → `_pendingLevelUps` 누적 확인
  - `ApplyChoice` 후 `FlushChoice` 자동 호출 확인

### T-3: 무기 히트 판정 회귀 테스트 `[보통]`
- **파일**: `GameServer.Tests/`
- **문제**: CCD 수정 이후 단검·완드 터널링 버그 픽스 검증 테스트 없음
- **추가할 케이스**: 투사체가 몬스터를 한 틱 내에 완전히 통과하는 시나리오

### T-4: StageCombatHelper WeaponHit 테스트 `[보통]`
- **파일**: `GameServer.Tests/`
- **문제**: Knockback 적용 여부, attacker == null 시 골드 지급 생략 미검증

### T-5: LoginProcessor 실패 경로 테스트 `[보통]`
- **파일**: `GameServer.Tests/`
- **문제**: 로비 만원, PlayerGameEnter 대기 중 연결 해제, 캐릭터 로드 실패 후 상태 복구 미검증

---

## 외부화 / 설정

### E-1: `ClearTimeSec` JSON 외부화 `[낮음]`
- **파일**: `GameServer/Component/Stage/StageComponent.cs:56`
- **문제**: `private const float ClearTimeSec = 1800f;`
- **수정**: `config.json`에 `clearTimeSec` 추가 → `GameDataTable.Map.ClearTimeSec`로 읽기

### E-2: 기타 하드코딩 상수 `[낮음]`
- `StageComponent.cs:215` — Survival 브로드캐스트 간격 `10f`
- `PlayerWorldComponent.cs:20` — AttackCooldown `0.3f`
- `WaveComponent.cs:17-18` — `SpawnMargin = 40f`, `MaxMonsters = 500`

### E-3: 초기 웨이브·스폰 좌표 하드코딩 `[낮음]`
- **파일**: `GameServer/Component/Stage/StageComponent.cs:66-73, 123-131`
- **문제**: 초기 몬스터 4마리·플레이어 스폰 좌표가 하드코딩. `GameDataTable.Map`의 MapWidth/Height와 어긋나면 스폰이 화면 밖에 생김
- **수정**: `waves.json`/`map.json`에서 산출(맵 중앙 = MapWidth/2, MapHeight/2 등)

---

## 구조 / 아키텍처

### A-1: 무기 OnUpgrade 전략 통일 `[보통]`
- **파일**: `AxeWeapon.cs:184`, `BibleWeapon.cs:100`
- **문제**: 홀수/짝수 레벨 분기 + `GameDataTable` 조회 보일러플레이트가 두 무기에 동일하게 중복
- **수정**: `WeaponBase`에 `OddLevelUp()` / `EvenLevelUp()` 훅 추가

### A-2: GetPendingPackets OwnerId 설정 중복 `[낮음]`
- **파일**: `KnifeWeapon.cs`, `WandWeapon.cs`, `CrossWeapon.cs`, `AxeWeapon.cs`
- **문제**: 투사체 무기마다 동일한 OwnerId 주입 로직 반복
- **수정**: `WeaponBase`에 공통 메서드로 추상화

### A-3: WeaponComponent.Update() 복잡도 `[낮음]`
- **파일**: `WeaponComponent.cs:91-141`
- **문제**: Orbital 패킷 생성이 BibleWeapon에 종속적. WeaponBase 가상 메서드로 위임하는 것이 일관성 있음

### A-4: 투사체 무기 4종 코드 중복 — ProjectileWeaponBase 부재 `[보통]`
- **파일**: `KnifeWeapon.cs`, `WandWeapon.cs`, `CrossWeapon.cs`, `AxeWeapon.cs`
- **문제**: `GetPendingPackets(ownerId)` 4개 파일이 완전히 동일. `_projectiles`+`_pendingPackets` 멤버, nearest 탐색 루프, Tick 구조 반복. 신규 투사체 무기 추가 시 보일러플레이트 큼
- **수정**: `ProjectileWeaponBase<TProjectile>` 추상 클래스로 공통화(투사체 관리, OwnerId 주입, nearest 탐색, 수명/소멸). 각 무기는 투사체 생성 파라미터와 위치 공식만 override

### A-5: WeaponComponent.Update 타입 분기 OCP 위반 `[낮음]`
- **파일**: `WeaponComponent.cs:106-134`
- **문제**: 매 틱 `weapon is KnifeWeapon`(FacingDir 주입), `weapon is BibleWeapon`(orbital sync) 런타임 타입 분기 → 무기 추가 시 이 메서드 수정 강제
- **수정**: `WeaponBase`에 `virtual void PreTick(PlayerComponent owner)` / `virtual void ContributeSync(...)` 훅 추가해 다형성으로 위임

### A-6: MonsterComponent/WaveComponent/WeaponComponent BaseComponent 과상속 `[낮음]`
- **파일**: `GameServer/Component/Stage/Monster/MonsterComponent.cs:101-105`
- **문제**: `MonsterComponent`는 WorkerSystem에 등록되지 않고 `StageComponent`가 직접 `new`로 생성함 → `Initialize()` 호출 안 됨, `InstanceId`/`EnqueueEvent` 등 BaseComponent 기능 전부 불필요한 죽은 코드. `WaveComponent`/`WeaponComponent`도 동일
- **수정**: POCO 또는 풀링 대상 클래스로 전환(BaseComponent 상속 제거)

### A-7: 전역 싱글톤 남발 → 테스트 격리 불가 `[보통]`
- **파일**: `Systems/*.cs` 전반, `GameSessionRegistry`, `DatabaseSystem.Instance`
- **문제**: 모든 시스템이 `static readonly Instance = new()`이고 컴포넌트들이 직접 참조 → 단위 테스트에서 mock/격리 불가(T-1~5 부재의 근본 원인), 테스트 병렬 실행 시 상태 공유, DB/레지스트리 강결합
- **수정**: 게임 로직 컴포넌트(Stage/Room/Weapon)에 `IGameSessionRegistry`, `IPlayerRepository` 등 생성자 주입 도입. `Instance` 대신 컴포지션 루트에서 주입(점진적 전환)

### A-8: 라우팅 계층 async 미지원 `[낮음]`
- **파일**: `Common.Server/Routing/PacketRouter.cs:5-9`, `GameServer/Component/Player/PlayerComponent.cs:91-118`
- **문제**: `IRouter.Handle`이 동기 `Action<TReq>`만 지원. DB 조회 필요 인게임 요청(상점, 인벤토리 등) 추가 시 워커 스레드 블로킹 또는 fire-and-forget 우회 강제
- **수정**: `IRouter`에 `Func<TReq, Task<object?>>` async 변형 추가 또는 RouterBuilder 확장

### A-9: 1인/빈 방 게임 시작 + 시작 스냅샷 불일치 `[낮음]`
- **파일**: `GameServer/Component/Room/RoomComponent.cs:154-162`
- **문제**: `playerCount < 1` 가드만 있어 혼자 Ready 시 즉시 게임 시작 가능. 시작 직전 다른 플레이어 Leave 시 "방금 나간 플레이어 포함" 엣지 존재
- **수정**: 최소 시작 인원을 설정값으로 외부화(`MinPlayersToStart`), 시작 직전 `_players` 스냅샷 확정 후 `NotiGameStart`/`StageComponent` 구성

### A-10: GetDefaultLobby 비원자 + fallback 1회 의존 `[낮음]`
- **파일**: `GameServer/Systems/LobbySystem.cs:29-30`, `GameServer/Auth/LoginProcessor.cs:147-165`
- **문제**: `GetDefaultLobby`가 `IsFull`(비잠금 읽기)로 후보를 고르고 `TryEnter`에서 CAS로 재검사. 단일 로비 환경에서 fallback도 동일 로비를 가리키므로 정원 경계 재실패 시 정상 유저 연결 강제 종료 가능
- **수정**: `TryEnter` 실패 시 루프로 재선정(최대 N회) 또는 `TryReserveAndEnter` 원자적 통합

---

## 로깅 / 모니터링

### L-1: 게임 클리어(시간 만료) 로그 누락 `[낮음]`
- **파일**: `GameServer/Component/Stage/StageComponent.cs:174-176`
- **문제**: `EndGame(true, ...)` 호출 시 "시간 만료로 클리어" 로그 없음
- **수정**: `if (_survivalElapsed >= ClearTimeSec)` 분기에 로그 추가

### L-2: WeaponComponent weapon.Tick() 예외 미처리 `[보통]`
- **파일**: `GameServer/Component/Stage/Weapons/WeaponComponent.cs`
- **문제**: `weapon.Tick()` 예외 발생 시 로깅 없이 전파 → 게임 세션 전체 중단
- **수정**: try-catch로 감싸고 해당 무기만 skip 처리 또는 로깅

### L-3: 종료 시 Task.WhenAll 타임아웃 부재 `[낮음]`
- **파일**: `GameServer/ServerStartup.cs:53-63`
- **문제**: `statTask`/`webTask`/`wsTask` 중 하나가 취소에 협조하지 않으면 무한 대기 또는 예외로 프로세스 종료. 종료 타임아웃 없음
- **수정**: `Task.WhenAny(whenAll, Task.Delay(timeoutMs))`로 감싸고 미완료 시 경고 로그 후 강제 진행

---

## 동시성 / 스레드 안전

### C-1: _typeCounters 다중 스레드 정합성 구간 `[낮음]`
- **파일**: `GameServer/Network/SessionComponent.cs:69, 82, 95`
- **문제**: `ProcessPacket`(I/O 스레드)+1, `DrainPackets`(워커 스레드)-1, `ClearPacketQueue`는 `_typeCounters.Clear()` → Clear와 +1이 겹치면 카운터가 실제 큐 적재 수와 일시적 어긋남 → PacketPairPolicy 오탐/누락 가능
- **수정**: 카운터를 워커 단독 소유로 이동하거나 드레인 시 재계산, 또는 `ClearPacketQueue`를 I/O와 동기화

### C-2: PacketRatePolicy.Clear가 Stopwatch.Stop 후 재사용 불가 `[낮음]`
- **파일**: `GameServer/Network/Policies/PacketRatePolicy.cs:67-71`
- **문제**: `Clear()`가 `Stopwatch.Stop()`을 호출해 ElapsedMilliseconds가 동결됨. 현재는 세션당 1:1 사용이라 안전하지만, 정책 인스턴스를 풀링/재사용하면 rate limit 오작동
- **수정**: `Clear()`에서 `_stopwatch.Restart()` 또는 큐만 비우는 방식으로 변경, 또는 메서드명을 `Dispose` 의미로 명확히

### C-3: ReqMove dtMs 클라이언트 신뢰 — speedhack 여지 `[보통]`
- **파일**: `GameServer/Component/Stage/StageComponent.cs:434-446`, `GameServer/Component/Player/PlayerWorldComponent.cs:33-35`
- **문제**: 클라이언트가 `dtMs`를 전송하고 서버는 그대로 이동에 사용. `MaxDtSec` 클램프가 있지만 매 틱 최대값을 보내면 실제 서버 경과시간 무관하게 최대속도 이동 가능(speedhack)
- **수정**: 서버에서 마지막 `ReqMove` 처리 시각을 기록해 서버 측 delta로 이동 계산, 또는 `dtMs`를 워커 틱 간격+여유 수준으로 강하게 클램프

---

## 코드 품질

### Q-1: PlayerCharacterComponent 대량 레벨업 누적 / EXP 상한 미설정 `[낮음]`
- **파일**: `GameServer/Component/Player/PlayerCharacterComponent.cs:86-103`
- **문제**: `while (Exp >= NextLevelExp)` 루프로 보스+젬 대량 획득 시 한 틱에 수십 레벨업 → `_pendingLevelUps` 대량 누적(B-4 연쇄). EXP 곡선이 선형이라 레벨 무한 성장 가능
- **수정**: 한 틱 최대 레벨업 횟수 캡, `_pendingLevelUps` 상한, 또는 EXP 곡선 상한 설정

### Q-2: TryAttack monsters 필터 계약 미문서화 `[낮음]`
- **파일**: `GameServer/Component/Stage/Weapons/WeaponBase.cs`
- **문제**: Knife/Wand/Cross/Axe는 IsAlive 필터된 리스트를 넘기는데, Garlic은 원본을 받아 내부에서 `m.IsAlive` 재검사. "필터 필요 여부"가 문서화되지 않아 향후 무기 구현 시 혼선
- **수정**: `WeaponBase.TryAttack`에 XML 주석으로 "monsters는 항상 IsAlive 필터 완료" 계약 명시, Garlic 내부 중복 검사 정리

### Q-3: 투사체 수명/적중 판정 순서 무기별 불일치 `[낮음]`
- **파일**: `KnifeWeapon.cs:66-118` 등
- **문제**: Knife/Wand는 적중 후 즉시 소멸, Axe/Cross는 lifetime까지 생존. 수명 만료+적중 동시 발생 시 경계 동작이 무기마다 다름. 4개 무기에 거의 동일한 `MoveProjectiles` 루프가 복붙 (A-4와 연관)
- **수정**: A-4 `ProjectileWeaponBase` 구현 시 판정 순서를 통일

---

## 우선순위 요약

| ID | 항목 | 심각도 | 규모 |
|----|------|--------|------|
| T-1 | 게임 종료 케이스 테스트 | 높음 | M |
| B-3 | EndGame 후 후속 패킷 혼선 | 보통 | S |
| B-4 | 사망 시 무기선택 stuck | 보통 | M |
| B-1 | WaveComponent MaxMonsters 초과 | 보통 | S |
| C-3 | ReqMove dtMs speedhack 여지 | 보통 | M |
| A-4 | 투사체 무기 4종 코드 중복 | 보통 | M |
| A-7 | 전역 싱글톤 → 테스트 격리 불가 | 보통 | L |
| L-2 | WeaponComponent 예외 미처리 | 보통 | S |
| T-2 | ApplyChoice 분기 테스트 | 보통 | M |
| T-3 | CCD 히트 판정 회귀 테스트 | 보통 | M |
| T-4 | StageCombatHelper WeaponHit 테스트 | 보통 | M |
| T-5 | LoginProcessor 실패 경로 테스트 | 보통 | M |
| A-1 | OnUpgrade 전략 통일 | 보통 | M |
| B-5 | 죽은 플레이어 젬 수집/레벨업 | 낮음 | S |
| P-4 | BibleWeapon 매 틱 리스트 할당 | 낮음 | S |
| P-5 | SessionSystem 고정 10ms 폴링 | 낮음 | S |
| A-9 | 1인 방 즉시 시작 / 스냅샷 불일치 | 낮음 | S |
| Q-1 | 대량 레벨업 누적 / EXP 상한 | 낮음 | S |
| C-1 | _typeCounters 다중 스레드 정합성 | 낮음 | S |
| A-5 | WeaponComponent.Update 타입 분기 OCP | 낮음 | M |
| A-6 | MonsterComponent BaseComponent 과상속 | 낮음 | M |
| A-8 | 라우팅 계층 async 미지원 | 낮음 | M |
| A-10 | GetDefaultLobby 비원자 fallback | 낮음 | S |
| E-1 | ClearTimeSec 외부화 | 낮음 | S |
| E-2 | 기타 하드코딩 상수 외부화 | 낮음 | S |
| E-3 | 초기 스폰 좌표 하드코딩 | 낮음 | S |
| B-2 | 5명+ 스폰 처리 | 낮음 | S |
| L-1 | 시간 만료 클리어 로그 누락 | 낮음 | S |
| L-3 | 종료 Task.WhenAll 타임아웃 부재 | 낮음 | S |
| C-2 | PacketRatePolicy.Clear Stopwatch 오용 | 낮음 | S |
| A-2 | GetPendingPackets OwnerId 중복 | 낮음 | M |
| A-3 | WeaponComponent.Update() 복잡도 | 낮음 | M |
| Q-2 | TryAttack monsters 필터 계약 미문서화 | 낮음 | S |
| Q-3 | 투사체 수명/적중 판정 순서 불일치 | 낮음 | S |
