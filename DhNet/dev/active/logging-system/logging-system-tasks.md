# 로깅 시스템 도입 — Tasks

Last Updated: 2026-06-19 (C1/SIOF는 Meyer's Singleton으로 최종 해결 — Option B는 시도 후 전체 롤백됨. C2/CRASH 블로킹은 워치독 스레드로 해결 완료. 4.3 동시성 로그 손상 실측 완료. Important #1·#2 수정 완료)

## Phase 1 — C++ Logger 코어 (DhUtil)

- [x] 1.1 `vcpkg.json`에 `spdlog` 추가 + `vcpkg install` 재실행 (S)
- [x] 1.2 `DhUtil/Logger.h`/`Logger.cpp` 작성 — 비동기 로거, console+rotating file sink (M)
- [x] 1.3 `Macro.h`에 `LOG_TRACE/DEBUG/INFO/WARN/ERROR/CRITICAL` 매크로 추가 (S)
- [x] 1.4 `CRASH(cause)` 매크로에 `LOG_CRITICAL` + 강제 flush 추가 (S)
- [x] 1.5 ~~`main()`에 `LoggerInit()`/`LoggerDestroy()` 명시적 호출 연결~~ — **최종 채택 안 함**. SIOF 위험(C1) 발견 후 한 번은 Option B(명시적 Init/Shutdown)로 구현했으나 사용자가 최종 롤백, `Logger`를 Meyer's Singleton(`Logger::Get()`)으로 바꿔 정적 초기화 패턴 자체는 그대로 유지하면서 SIOF만 제거하는 방향으로 확정. 근거는 context.md "C1 해결 과정" 참고

## Phase 2 — C++ 기존 호출부 교체

- [x] 2.1 `DbConnectionPool.cpp`, `DbSystem.cpp` — `std::cout` 7곳 교체 (S)
- [x] 2.2 `GameSession.cpp`, `Room.cpp`, `TestController.cpp`, `main.cpp` 교체 + 죽은 주석 코드 삭제 (S)
  - 추가 발견: `Player.cpp`에도 동일한 죽은 주석 코드(`~Player`) 있어 같이 삭제함 (플랜에 없었음)
- [x] 2.3 `ServerCore` (`IocpCore.cpp`, `Service.cpp`, `Session.cpp`) 교체 + 한글 mojibake 수정 (M)
  - `Session::Disconnect`의 wide-string 로깅 관련 C2664 컴파일 에러 해결 (narrow 변환 추가)
- [x] 2.4 `DeadLockProfiler.cpp` `printf` 2곳 교체 (S)
  - 추가로 발견한 CP949 mojibake 주석들도 정상화. 단 1곳은 원본 바이트 손실로 의미 동일한 새 주석으로 대체 (복구 아님)
- [x] 2.5 전체 재검사: `grep -rn "std::cout\|printf" DhNet_Server DhUtil`로 잔존 확인 (S)
  - DhNet_Server/DhUtil(서버 스코프) 내 잔존 0건 확인. `DhNet_Client`/`DhNet_StressTest`(클라이언트, 스코프 밖)와 `external/vcpkg`(서드파티)에는 남아있으나 의도된 것

## Phase 3 — C# Serilog 통합

- [x] 3.1 `Serilog.AspNetCore`, `Serilog.Sinks.File` NuGet 추가 (S)
- [x] 3.2 `appsettings.json` 신규 작성 (rolling file, 레벨 설정) (S)
- [x] 3.3 `Program.cs`에 `UseSerilog()` 통합, `GrpcAdminClient` DI 등록 수정 (M)
  - 기존 `AddHttpLogging`/`UseHttpLogging`은 제거하고 `UseSerilogRequestLogging()`으로 완전히 대체 (플랜의 "대체 권장" 옵션 채택)
- [x] 3.4 `PlayersController`/`LobbiesController`/`RoomsController`/`HealthController`에 `ILogger<T>` 주입 + catch 블록 로깅 (M)
  - `HealthController`는 플랜에 명시 안 됐지만 동일 패턴이라 같이 처리
  - 로그 레벨 배분이 플랜 원문보다 세분화됨 (context.md "주요 결정사항 #4" 참고)
- [x] 3.5 `GrpcAdminClient`에 로깅 추가 (S)

## Phase 4 — 검증

- [x] 4.1 전체 빌드 성공 확인 (S) — MSBuild 전체 솔루션 0 에러, `dotnet build` 0 에러/0 경고
- [x] 4.2 C# 서버 기동 후 시나리오 실행, 로그 파일 내용 확인 (S) — gRPC 백엔드 미기동 상태로 503 유발, 3단계 로그(GrpcAdminClient→Controller→RequestLogging) 전부 파일에 정상 기록됨을 확인
  - C++ 서버 측 실제 정상 시나리오(로그인/로비 등) 실행 검증은 **미수행** — 다음 세션에서 필요 시 수행
- [x] 4.3 `DhNet_StressTest`로 동시 다중 접속 시 로그 인터리빙/손상 없음 확인 (S) — **실측 완료, 손상 없음 확인**
  - 실측 전 발견: `DhNet_Client.sln`(DhNet_Client, DhNet_StressTest 프로젝트)이 로깅 시스템 도입 이후 빌드가 깨져 있었음(C2338 `/utf-8` 누락 + spdlog/fmt include·lib 경로 누락 + `DhUtil.lib` 미링크 — `Logger::Get()`이 비-inline 정적 멤버라 DhUtil 컴파일 단위 없이는 링크 불가). `DhNet_Server.sln`만 빌드 검증 대상이라 이 회귀가 지금까지 미발견 상태였음. `DhNet_Client.vcxproj`/`DhNet_StressTest.vcxproj`의 Debug|x64 설정에 `/utf-8`, vcpkg include/lib 경로, `DhUtil.lib;spdlogd.lib;fmtd.lib` 추가로 수정, 둘 다 재빌드 0 에러 확인
  - 실측: `DhNet_Server.exe`(포트 7777, env `DhNet_PORT` 기존 설정값) 구동 후 `DhNet_StressTest.exe 127.0.0.1 7777 5 10 5 10`으로 5개 서비스×10세션=50개 동시 연결 생성. 포트 불일치로 인한 첫 시도에서 클라이언트 측 9개의 서로 다른 IOCP 디스패치 스레드가 동시에 `ERROR_CONNECTION_REFUSED`를 반복 발생시켜 `LOG_WARN`을 동시다발적으로 호출하는 상황이 재현됨 — 50줄 중 39줄이 **정확히 같은 1ms 타임스탬프**(`11:05:33.017`)에 기록됨
  - 검증: 정규식으로 50줄 전체가 `[timestamp] [level] [tid] [logger] message` 패턴에 100% 일치, 깨지거나 합쳐진 줄 0건, 9개 스레드 ID 전부 정상 식별됨 → spdlog `async_logger`가 진짜 동시 경쟁 상황에서도 큐 직렬화로 인터리빙/손상을 방지한다는 것을 실측으로 확인
  - 포트 수정 후 정상 핸드셰이크+로그인 시도(DB 없음 → 거부)도 50세션 규모로 재현, 클라이언트 측 정상 동작 확인. 서버 측 정상 연결/해제는 `LOG_DEBUG` 레벨(기본 `info` 레벨에서 필터링됨)이라 파일에는 기록되지 않음 — 이는 의도된 로그 레벨 설계이며 버그 아님

## 작업 후 필수 절차 (CLAUDE.md RULE 2)

- [x] 코드 작업 완료 후 `Skill("dev-docs-update")` 실행
- [x] `code-architecture-reviewer` 리뷰 실행 — `logging-system-code-review.md`에 저장됨

## 리뷰에서 발견되어 후속 처리 필요

- [x] `Binary/Debug/spdlogd.dll`, `fmtd.dll`을 git에 추가 — `git add` 완료 (커밋은 별도 승인 필요)
- [x] **C1 — SIOF 위험.** 최종 해결: **Meyer's Singleton**. `DhUtil/Logger.h`/`.cpp`에서 `GLogger` 전역 포인터를 제거하고 `Logger::Get()`(함수 지역 static, lazy 1회 초기화)으로 대체, `Macro.h`의 6개 `LOG_*` 매크로가 이를 경유하도록 변경. (※ 시행착오: 1차로 이 방식으로 구현 → 사용자가 전체 롤백 → 재논의 후 Option B(전역 정적 객체 패턴 완전 제거, `UtilGlobal`/`ServerGlobal`/`main.cpp`까지 명시적 Init/Shutdown으로 교체)로 2차 구현, 빌드/런타임 검증까지 마침 → 그 변경분을 code-architecture-reviewer로 검토했더니 `AccountRepository.cpp`의 `g_dummy`에도 동일한 SIOF 패턴이 남아있다는 걸 발견(리뷰는 `logging-system-code-review-optionB.md`에 저장됨) → 사용자가 피로감 표현 후 Option B 전체 + AccountRepository 수정까지 전부 `git restore`로 롤백 → 최종적으로 1차 시도였던 Meyer's Singleton으로 재구현하여 확정. `UtilGlobal.cpp`/`ServerGlobal.cpp`/`main.cpp`/`AccountRepository.cpp`는 git 원본 그대로 — Meyer's Singleton 구조에서는 이 패턴들이 더 이상 SIOF 위험이 아니므로 손댈 필요 없음. 상세 경위는 context.md "C1 해결 과정" 참고)
- [x] **C2 — CRASH의 LoggerShutdown() flush 블로킹 위험.** **최종 해결: 워치독 스레드.** `Macro.h`의 `CRASH` 매크로 진입 시점에 별도 detached 스레드를 띄워 500ms 후 무조건 크래시를 보장 — `LOG_CRITICAL`(enqueue)이든 `LoggerShutdown()`(flush)이든 어디서 멈추든 상관없이 fail-fast가 깨지지 않음. `DeadLockProfiler::PushLock()`이 자신의 mutex를 쥔 채 CRASH를 호출하는 경로(`DEADLOCK_DETECTED`)에서 flush가 멈추면 서버 전체 Lock 연산이 연쇄적으로 멈추는 위험까지 같이 해소됨(워치독이 500ms 후 프로세스 전체를 죽이므로). `<thread>`/`<chrono>` include 추가. `ASSERT_CRASH`는 내부적으로 `CRASH`를 호출하므로 무변경으로 자동 적용. 빌드 0 에러 확인.
  - 후속 code-architecture-reviewer 리뷰(`logging-system-code-review-c2-watchdog.md`)에서 Critical 1건 발견: `std::thread` 생성자가 리소스 부족 시 `std::system_error`를 던질 수 있는데 예외 처리가 없어, 워치독 생성 자체가 실패하면 (a) 처리 안 된 예외로 `std::terminate()`되어 로그도 안 남거나 (b) 호출자가 예외를 흡수하면 크래시 자체가 무력화되는 더 나쁜 상황이 생길 수 있음 → **`try { ... } catch (...) {}`로 워치독 생성부 감싸서 즉시 수정 완료**, 재빌드 0 에러 확인.
- [x] **GrpcAdminClient의 nameof(methodName) 반복 패턴 — 수정 완료.** `[CallerMemberName]` 속성을 사용하는 `private async Task<T> ExecuteAsync<T>(Func<Task<T>> rpcCall, [CallerMemberName] string methodName = "")` 헬퍼를 추가하고, 6개 public 메서드(`HealthCheckAsync`/`ListRoomsAsync`/`ListPlayersAsync`/`KickPlayerAsync`/`ListLobbiesAsync`/`BroadcastAsync`)를 모두 이 헬퍼를 통해 호출하도록 변경 — 각 메서드의 try/catch 블록과 `nameof(...)` 인자가 전부 제거됨. `dotnet build` 0 에러/0 경고 확인. 후속 리뷰(general-purpose agent, code-architecture-reviewer 역할 위임 — Critical/Important 0건, Minor 3건)에서 `[CallerMemberName]`이 람다가 아닌 호출부 메서드 이름을 정확히 캡처함을 C# 스펙 기준으로 확인.
- [x] **컨트롤러 4개의 거의 동일한 5-branch catch 체인 — 수정 완료.** `DhNet_Web/Filters/GrpcExceptionFilterAttribute.cs`(`ExceptionFilterAttribute` 상속)를 신규 작성, `Program.cs`의 `AddControllers(o => o.Filters.Add<GrpcExceptionFilterAttribute>())`로 전역 등록. `TimeoutException→504`/`KeyNotFoundException→404`/`ArgumentException→400`/`HttpRequestException→503`/그 외→500 매핑과 로깅(컨트롤러/액션명 + route의 `id` 값을 태그로 구성)을 필터 한 곳으로 통합. `PlayersController`/`LobbiesController`/`RoomsController`/`HealthController`에서 try/catch 블록과 미사용 `ILogger<T>` 생성자 파라미터를 모두 제거(순수 비즈니스 로직만 남김). `RoomsController.Broadcast`의 `body.Message` 사전 검증 로직은 예외 매핑과 무관하므로 그대로 보존. `dotnet build` 0 에러/0 경고 확인. 리뷰에서 나온 Minor 지적(필터 안에서 `RequestServices.GetRequiredService<ILoggerFactory>()`로 매번 로거를 만드는 대신 생성자 주입이 더 적절함)을 반영해 `GrpcExceptionFilterAttribute(ILogger<GrpcExceptionFilterAttribute> logger)` 주 생성자로 변경 — `AddControllers(o => o.Filters.Add<T>())`가 내부적으로 `TypeFilterAttribute`로 감싸 `ActivatorUtilities`를 통해 인스턴스화하므로 DI 주입이 정상 동작함. 재빌드 0 에러/0 경고 확인.

- [ ] **I1 (신규, Meyer's Singleton 리뷰에서 발견)**: `LoggerShutdownGuard`가 `spdlog::shutdown()`을 호출해도 실제로는 공유 스레드풀만 정리됨(로거 자체는 별도 `shared_ptr`라 영향 없음). 가드와 `Logger::Get()` 정적 변수의 소멸 순서가 보장되지 않아, 프로그램 종료 시점에 아주 드물게 로그 한 줄이 조용히 누락될 수 있음(크래시/UAF 아님 — spdlog가 내부적으로 예외를 삼킴). 영향이 작아 Minor에 가까움, 사용자 확인 후 필요 시 수정 (Important, 미수정). 상세는 `logging-system-code-review-meyers.md` 참고
- [x] **신규 발견 및 수정 — `DhNet_Client.sln` 빌드 회귀.** 로깅 시스템 도입 이후 `DhNet_Client.vcxproj`/`DhNet_StressTest.vcxproj`(Debug|x64)가 `/utf-8` 미적용 C2338 정적 단언 에러 + spdlog/fmt include·lib 경로 누락 + `DhUtil.lib` 미링크로 빌드 불가 상태였음. `DhNet_Server.sln`만 빌드 검증 대상이었던 CLAUDE.md 빌드 절차의 사각지대. 두 vcxproj의 Debug|x64 `ItemDefinitionGroup`에 `/utf-8`, vcpkg include 경로, `DhUtil.lib;spdlogd.lib;fmtd.lib` 링크 추가로 수정, 재빌드 0 에러 확인 (4.3 실측 작업 중 발견)

상세 내용은 `logging-system-code-review-meyers.md` 참고 (Option B 시도 당시 리뷰는 `logging-system-code-review-optionB.md`에 보존됨, 참고용). **Critical 2건(C1: Meyer's Singleton, C2: 워치독 스레드) 모두 최종 해결. Phase 4.3(동시 로그 손상 실측)도 완료. Important 3건 중 2건(GrpcAdminClient nameof, 컨트롤러 catch 체인) 수정 완료. I1은 사용자 지시로 보류 중(영향 작아 Minor에 가까움).**
