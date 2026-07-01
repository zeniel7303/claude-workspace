# 로깅 시스템 도입 — Context

Last Updated: 2026-06-18 (C1/C2 Critical 2건 모두 해결 완료)

## 구현 상태: C1(SIOF), C2(CRASH flush 블로킹) 모두 해결 완료

Phase 1~4(로깅 도입 자체)는 완료. 이후 code-architecture-reviewer 리뷰에서 Critical 2건이 발견됨:
- C1: SIOF(정적 초기화 순서) 위험 — **해결 완료** (Meyer's Singleton)
- C2: CRASH의 무제한 flush 블로킹 위험 — **해결 완료** (워치독 스레드)

**C1은 같은 세션 안에서 세 가지 접근을 차례로 시도한 끝에 최종적으로 Meyer's Singleton으로 해결함. Option B(전역 정적 객체 패턴 완전 제거)는 한 번 끝까지 구현하고 빌드/런타임 검증까지 마쳤으나, 사용자가 최종적으로 롤백을 지시하고 처음 추천안(Meyer's Singleton)으로 되돌리기로 결정함.**
**C2는 다음 세션에서 재개되어, `CRASH` 매크로 진입 시점에 별도 워치독 스레드를 띄워 500ms 후 무조건 크래시를 보장하는 방식으로 해결함 (아래 "C2(CRASH flush 블로킹) 해결 과정" 참고).**

## C1(SIOF) 해결 과정 — 시행착오 전체 기록 (다음 세션에서 다시 같은 논의가 나오지 않도록)

1. **1차 시도 (Meyer's Singleton)**: `Logger` 클래스 + 함수 지역 `static`(Meyer's Singleton)으로 `GLogger` 전역 포인터를 대체. SIOF는 해결되지만 사용자가 "처음으로 다시 돌아가자, 수정사항을 롤백하고 다시 생각해보자"며 전체 롤백 지시 (`git restore`로 원복, 커밋 없었음).
2. **재논의**: 사용자가 문제 2(CRASH 블로킹)는 일단 보류하고 문제 1(SIOF)만 먼저 해결하자고 명시적으로 한정. 참고 사례로 별도 C# 서버의 로깅 구성을 살펴봤으나, C#은 CLR 정적 초기화 모델이 C++의 SIOF와 근본적으로 다른 문제라 그 패턴(명시적 Init + null-조건부 호출)을 그대로 가져오는 건 근본 해결이 아니라 증상 은폐일 뿐이라고 판단.
3. **옵션 비교**: Meyer's Singleton(1차 시도와 동일, 작은 스코프) vs 전역 정적 객체 패턴 자체 제거(명시적 Init/Shutdown, 더 큰 스코프이지만 근본적). Claude는 작은 스코프의 Meyer's Singleton을 권장했으나, **사용자가 명시적으로 "전역 정적 객체 패턴 자체를 없애보자"며 Option B를 선택**.
4. **2차 시도 (Option B) — 끝까지 구현했으나 최종적으로 롤백됨**: `Logger.cpp`/`UtilGlobal.cpp`/`ServerGlobal.cpp`의 익명 정적 객체 3개를 모두 제거하고 `XxxInit()`/`XxxShutdown()` 명시적 함수로 교체, `main.cpp`에서 순서대로 호출. 빌드 0 에러, 런타임 스모크 테스트도 정상 통과함. 이후 code-architecture-reviewer로 이 변경분을 검토했는데, 리뷰어가 **`AccountRepository.cpp`의 `g_dummy`(타이밍 공격 방지용 더미 해시/솔트)도 동일한 eager 전역 정적 객체 패턴이고, 그 생성자가 실패 시 `ASSERT_CRASH`→`LOG_CRITICAL`→`GLogger`를 호출하는데 이 생성자가 `main()`(따라서 `LoggerInit()`) 이전에 실행되어 동일한 SIOF 클래스의 문제가 한 군데 더 남아있다**는 걸 찾아냄. 사용자에게 보고하자 "머리아프네 그냥 Meyer's singleton이 낫나?"라고 반응, 결국 **Option B 전체를 롤백하고 처음 추천했던 Meyer's Singleton으로 다시 구현하기로 최종 결정**.
5. **최종 구현 (Meyer's Singleton, 현재 상태)**: 아래 "현재 구현 상태" 참고. Option B 관련 변경 8개 파일(`Logger.h/.cpp`, `UtilGlobal.h/.cpp`, `ServerGlobal.h/.cpp`, `main.cpp`, `AccountRepository.cpp`)을 `git restore`로 전부 원복한 뒤, `Logger.h/.cpp`와 `Macro.h` 3개 파일만 다시 수정. **`UtilGlobal.cpp`/`ServerGlobal.cpp`/`main.cpp`/`AccountRepository.cpp`는 git 커밋 시점 원본 그대로** — 더 이상 손댈 필요가 없음(이유는 아래 참고).

## 현재 구현 상태 (Meyer's Singleton — 최종)

`GLogger` 전역 포인터를 제거하고, `Logger::Get()`이라는 함수 지역 `static`(Meyer's Singleton)으로 대체. C++11부터 함수 지역 static은 스레드 안전 1회 초기화가 보장되므로, **이 함수가 호출되는 시점이 프로그램의 어느 단계든(다른 전역 객체의 생성자 안에서 호출되더라도) 항상 안전하게 최초 1회만 로거를 생성**함 — SIOF가 원천적으로 사라짐.

- **`DhUtil/Logger.h`**: `extern shared_ptr<spdlog::logger> GLogger;` 제거 → `class Logger { public: static std::shared_ptr<spdlog::logger>& Get(); };` 추가. `LoggerShutdown()` 선언은 그대로 유지(시그니처 동일, CRASH가 호출).
- **`DhUtil/Logger.cpp`**: 익명 네임스페이스의 `LoggerInit` 클래스(eager 전역 정적 객체 `GLoggerInit`)를 제거. 그 생성자 본문은 `CreateLogger()`라는 일반 함수로 옮김(반환값을 GLogger에 대입하는 대신 `shared_ptr`를 그대로 리턴). `Logger::Get()`이 `static std::shared_ptr<spdlog::logger> instance = CreateLogger(); return instance;` 형태로 lazy 생성. 소멸 시 정리는 별도의 `LoggerShutdownGuard`(빈 생성자, 소멸자에서만 `spdlog::shutdown()` 호출, `Logger`/로거 인스턴스를 전혀 참조 안 함)의 익명 정적 객체 `GLoggerShutdownGuard`로 이동 — 이 가드는 아무것도 참조하지 않으므로 자신의 생성/소멸 순서가 다른 전역 객체와 어떻게 엇갈리든 안전함. `LoggerShutdown()`은 `Logger::Get()->flush()`로 변경(동작 동일, 그냥 GLogger 직접 참조 → Get() 경유로 바뀐 것).
- **`DhUtil/Macro.h`**: `LOG_TRACE/DEBUG/INFO/WARN/ERROR/CRITICAL` 6개 매크로를 `GLogger->X(...)` → `Logger::Get()->X(...)`로 변경. 매크로 호출 시그니처는 동일하므로 기존 ~30곳 호출부는 전혀 수정할 필요 없음. `CRASH`/`ASSERT_CRASH`는 완전히 무변경(여전히 `LoggerShutdown()` 호출, 문제 2 스코프이므로 손대지 않음).

**왜 `UtilGlobal.cpp`/`ServerGlobal.cpp`/`AccountRepository.cpp`를 안 고쳐도 되는가**: Option B 검토 중 발견된 "AccountRepository.cpp의 g_dummy가 LOG_CRITICAL을 호출하는데 LoggerInit() 전에 실행될 수 있다"는 문제가, Meyer's Singleton 하에서는 **자동으로 해소됨**. `Logger::Get()`은 누가 언제 호출하든(다른 전역 객체의 생성자 안에서, main() 시작 전이라도) 항상 그 호출 시점에 최초 1회만 안전하게 초기화되기 때문. 즉 이 구조에서는 "어떤 전역 정적 객체가 LOG_*를 호출해도 되는가"라는 질문 자체가 사라짐 — 전부 안전함.

**검증**: `MSBuild DhNet_Server.sln -p:Configuration=Debug -p:Platform=x64` 0 에러. `DhNet_Server.exe`를 5초간 실행해 정상 동작 확인(DbConnectionPool 경고는 로컬에 MySQL이 없어서 발생하는 것으로 이번 변경과 무관). 크래시 없이 `[Service] Server Start!` 로그까지 정상 출력됨.

## C2(CRASH flush 블로킹) 해결 과정

**문제 분석**: `CRASH` 매크로는 `LOG_CRITICAL(...)` → `LoggerShutdown()`(= `Logger::Get()->flush()`) → null 역참조 순으로 실행됨. spdlog의 `async_logger`는 `async_overflow_policy::block`으로 설정되어 있어, 워커 스레드가 멈춰 있으면 **(a) `LOG_CRITICAL`의 enqueue 자체**(큐가 꽉 찬 경우)나 **(b) `flush()`**(워커가 큐를 비울 때까지 대기) 둘 중 어디서든 무제한으로 블로킹될 수 있음. 이 경우 "반드시 크래시해서 덤프를 남긴다"는 CRASH의 존재 목적 자체가 무력화됨.

**호출부 분석으로 확인한 실제 위험 시나리오**: `DeadLockProfiler.cpp`의 `PushLock()`이 자신의 `std::mutex m_lock`을 쥔 채로 `CheckCycle()` → `DFS()` → `CRASH("DEADLOCK_DETECTED")`를 호출함. 즉 flush가 멈추면 `DeadLockProfiler::m_lock`이 영원히 안 풀리고, 이 mutex를 요구하는 서버 전체의 모든 `Lock::WriteLock/ReadLock/Unlock` 호출(`#if _DEBUG`로 `PushLock`/`PopLock`을 부르는 모든 지점)이 줄줄이 같이 멈춤 — 원래는 국소적 데드락이었던 게 flush 블로킹으로 서버 전체 정지로 증폭됨. 게다가 이렇게 멈춘 프로세스는 진짜 크래시(AV)가 아니라 "응답 없음" 상태라 WER 덤프도 안 남음.

**검토했던 옵션들** (전부 "일정 시간 기다리고 안 되면 강제로 죽인다"는 같은 계열, 감싸는 범위만 다름):
- 이전 세션에서 시도 후 함께 롤백됐던 Fix 2: `std::async` + `wait_for(500ms)` — `LoggerShutdown()` 호출 한 줄만 타임아웃으로 감쌈. **약점**: 그 앞의 `LOG_CRITICAL`(enqueue) 단계에서 멈추는 경우는 커버 못 함.
- B안(CRASH 전용 동기 로거 분리): 블로킹 가능성 자체를 회피하지만 로거 아키텍처를 새로 분리해야 해서 변경 범위가 큼.
- C안(flush 생략): 블로킹 위험을 회피하지만 크래시 직전 로그가 워커에 아직 안 반영된 채 잘려나갈 위험을 그냥 감수.

**최종 채택 — 워치독 스레드 (A안을 "flush 한 줄"이 아니라 "CRASH 매크로 전체"로 확장한 버전)**: `CRASH` 매크로 진입 시 가장 먼저 "500ms 후 무조건 크래시"하는 독립된 detached 스레드를 띄움. 그 다음 기존 로직(`LOG_CRITICAL` → `LoggerShutdown()` → 즉시 크래시)을 그대로 시도. 정상 케이스는 그 일련의 과정이 500ms 안에 끝나고 바로 크래시 → 프로세스 종료와 함께 워치독 스레드도 소멸, 아무 영향 없음. 메인 경로의 어느 단계든(enqueue든 flush든) 멈추면, 워치독이 500ms 후 무조건 크래시시켜 fail-fast를 보장. `DeadLockProfiler::m_lock` 연쇄 정지 시나리오도 "500ms간 잠깐 멈췄다가 결국 프로세스 전체가 죽는다"로 끝남(원래는 영원히 멈춤).

**구현**: `DhUtil/Macro.h`만 수정. `<thread>`/`<chrono>` include 추가(다른 프로젝트의 pch에 없을 수 있어 헤더 자체에 명시). `CRASH` 매크로 맨 앞에 `std::thread([]{ sleep_for(500ms); *nullptr = 0xDEADBEEF; }).detach();` 추가, 나머지 로직은 무변경. `ASSERT_CRASH`는 무변경(내부적으로 `CRASH`를 호출하므로 자동으로 같은 보장을 받음).

**검증**: `MSBuild DhNet_Server.sln -p:Configuration=Debug -p:Platform=x64` 0 에러, `DhNet_Server.exe` 정상 링크 확인. (실제 `CRASH()` 트리거 후 워치독이 500ms 타임아웃 시나리오에서 실제로 작동하는지는 — flush를 인위적으로 멈추게 하는 테스트 환경 구성이 필요해 미수행. 코드 리뷰/추론으로는 안전하다고 판단)

**후속 리뷰로 발견 + 즉시 수정**: code-architecture-reviewer 리뷰(`logging-system-code-review-c2-watchdog.md`)에서 Critical 1건 발견 — `std::thread` 생성자가 리소스 부족 시 `std::system_error`를 던질 수 있는데 예외 처리가 없어서, 워치독 스레드 생성 자체가 실패하면 처리 안 된 예외로 `std::terminate()`(로그도 안 남김)되거나 호출자가 흡수하면 크래시가 통째로 무력화될 위험이 있었음. 워치독 생성부를 `try { ... } catch (...) {}`로 감싸서 즉시 수정, 재빌드 0 에러 확인.

## 핵심 파일 (최종 상태)

### C++

| 파일 | 변경 내용 |
|------|-----------|
| `vcpkg.json` | `spdlog` 의존성 추가 (단순 `{"name": "spdlog"}` — header-only 강제 안 함) |
| `DhUtil/Logger.h` (Meyer's Singleton으로 최종 확정) | `extern shared_ptr<spdlog::logger> GLogger;` 제거 → `class Logger { static shared_ptr<spdlog::logger>& Get(); };` 추가. `LoggerShutdown()`은 시그니처 그대로 유지(내부 구현만 `Logger::Get()->flush()`로 변경) |
| `DhUtil/Logger.cpp` (Meyer's Singleton으로 최종 확정) | 익명 네임스페이스의 `LoggerInit` 클래스(`GLoggerInit` eager 전역 정적 객체) 제거. 생성자 본문은 `CreateLogger()` 일반 함수로 이동. `Logger::Get()`이 함수 지역 `static`으로 `CreateLogger()`를 최초 호출 시 1회만 실행해 lazy 생성(SIOF 회피). 소멸 정리는 아무것도 참조하지 않는 `LoggerShutdownGuard`(빈 생성자, 소멸자에서 `spdlog::shutdown()`만 호출)의 익명 정적 객체로 분리. async_logger 설정(console+10MB×5 rotating file sink, 패턴, flush_on(warn), flush_every(3s)) 자체는 전혀 변경 없음 |
| `DhUtil/Macro.h` | `LOG_TRACE/DEBUG/INFO/WARN/ERROR/CRITICAL` 6개 매크로를 `GLogger->X(...)` → `Logger::Get()->X(...)`로 변경. `CRASH`에 워치독 스레드(500ms 후 무조건 크래시) 추가해 C2(flush 무제한 블로킹) 해결. `<thread>`/`<chrono>` include 추가. `ASSERT_CRASH`는 무변경(내부적으로 `CRASH` 호출하므로 자동 적용) |
| `DhUtil/UtilGlobal.h`/`.cpp` | **변경 없음.** Option B 시도 때 한 번 명시적 Init/Shutdown으로 바꿨다가 최종 롤백되어 git 커밋 시점 원본(eager 정적 객체 `GUtilGlobal`) 그대로 — Meyer's Singleton 구조에서는 이 패턴이 더 이상 위험하지 않으므로 안 고쳐도 됨 |
| `DhNet_Server/DhNet_Server/ServerGlobal.h`/`.cpp` | **변경 없음.** 위와 동일한 이유로 원본(`GServerGlobal`) 그대로 |
| `DhNet_Server/DhNet_Server/main.cpp` | **변경 없음.** Option B용으로 추가했던 `XxxInit()`/`XxxShutdown()` 호출들 전부 롤백, 원본 그대로 |
| `DhNet_Server/DhNet_Server/AccountRepository.cpp` | **변경 없음.** Option B 검토 중 발견된 `g_dummy` eager 정적 객체 이슈는 Meyer's Singleton 구조에서 자동으로 해소되므로(위 "왜 안 고쳐도 되는가" 참고) 손대지 않음 — 원본의 `static DummyInit g_dummy;` 그대로 |
| `DhUtil/DhUtil.vcxproj`/`.filters` | Debug\|x64에 `AdditionalIncludeDirectories`(vcpkg include), `/utf-8`, `NOMINMAX` 추가. `Logger.h/.cpp` 추가 |
| `DhNet_Server/ServerCore/ServerCore.vcxproj` | 동일하게 include/`-utf-8`/`NOMINMAX` 추가 (DhUtil의 Logger.h를 transitively include하므로 필요) |
| `DhNet_Server/DhNet_Server/DhNet_Server.vcxproj` | Link에 `spdlogd.lib;fmtd.lib;`(Debug)/`spdlog.lib;fmt.lib;`(Release) 추가, ClCompile에 `/utf-8` 추가 |
| `DhUtil/DeadLockProfiler.cpp` | `printf` 2곳 → `LOG_CRITICAL`. 기존 CP949 깨진 주석도 정리 (단, 라인 46 주석은 파일 내에 이미 손실된 바이트(U+FFFD)가 박혀 있어 원문 복구 불가 — Python으로 바이트 직접 덮어써서 의미상 동일한 새 한글 주석으로 교체) |
| `DhNet_Server/DhNet_Server/DbConnectionPool.cpp`, `DbSystem.cpp` | `std::cout` 전부 `LOG_ERROR`/`LOG_WARN`/`LOG_INFO`로 교체 완료 |
| `DhNet_Server/DhNet_Server/GameSession.cpp` | 소멸자 로그 → `LOG_DEBUG`, 주석 처리된 죽은 코드(`OnSend`) 삭제 |
| `DhNet_Server/DhNet_Server/Room.cpp` | 플레이어 수 로그 → `LOG_DEBUG`, 기존 CP949 mojibake 주석 2곳도 정상 한글로 복원 |
| `DhNet_Server/DhNet_Server/TestController.cpp` | 죽은 주석 코드 삭제 |
| `DhNet_Server/DhNet_Server/Player.cpp` | 죽은 주석 코드 삭제 (플랜에 없었지만 grep 중 발견, 동일 패턴이라 같이 처리) |
| `DhNet_Server/DhNet_Server/main.cpp` | `printf` → `LOG_DEBUG` (단, 호출부 자체가 `// CheckAllEnv(envp);`로 주석 처리되어 있어 실제로는 미사용 — 그대로 둠, 스코프 밖) |
| `DhNet_Server/ServerCore/IocpCore.cpp` | mojibake `std::cout` → `LOG_WARN` + 한글 정상화 |
| `DhNet_Server/ServerCore/Service.cpp` | `std::cout` → `LOG_INFO` |
| `DhNet_Server/ServerCore/Session.cpp` | `std::wcout`(Disconnect) → `LOG_DEBUG` (와이드→내로우 변환 필요, 아래 "해결한 문제" 참고), `std::cout`(HandleError) → `LOG_WARN` |

### C#

| 파일 | 변경 내용 |
|------|-----------|
| `DhNet_Server/DhNet_Web/DhNet_Web.csproj` | `Serilog.AspNetCore` 8.0.3, `Serilog.Sinks.File` 6.0.0 추가 |
| `DhNet_Server/DhNet_Web/appsettings.json` (신규) | Serilog 설정: MinimumLevel(Default=Information, Microsoft.AspNetCore=Warning), Console + File(`logs/dhnet-web-.log`, Day rolling, 14개 보관) sink, `FromLogContext` enrich |
| `DhNet_Server/DhNet_Web/Program.cs` | `builder.Host.UseSerilog(...)`로 appsettings.json 읽음. 기존 `AddHttpLogging`/`UseHttpLogging` **제거**하고 `app.UseSerilogRequestLogging()`으로 대체(플랜의 권장사항 그대로 적용 — 중복 로깅 방지). `GrpcAdminClient` DI 등록을 `sp.GetRequiredService<ILogger<GrpcAdminClient>>()` 주입하는 형태로 변경 |
| `DhNet_Server/DhNet_Web/Services/GrpcAdminClient.cs` | 생성자에 `ILogger<GrpcAdminClient> logger` 파라미터 추가. `CreateHttpMappedException`을 인스턴스 메서드로 변경, 호출부마다 `nameof(메서드명)` 전달. `DeadlineExceeded`/`Unavailable`은 `LogWarning`, 그 외는 `LogError` (예외 객체 포함, RpcException 전체 스택 보존) |
| `Controllers/HealthController.cs`, `PlayersController.cs`, `LobbiesController.cs`, `RoomsController.cs` | 전부 `ILogger<T>` 주입. catch 블록별 로그 레벨: `TimeoutException`/`KeyNotFoundException`/`ArgumentException`/`HttpRequestException` → `LogWarning`(4xx/타임아웃은 클라이언트 유발 또는 일시적 장애로 간주), 그 외 `Exception` → `LogError`. `PlayersController.Kick`/`RoomsController.Broadcast`는 구조화 로깅으로 `id` 포함 |

## 이번 세션에서 내린 주요 결정사항 (플랜 대비 변경분)

1. **spdlog를 header-only가 아닌 컴파일 라이브러리로 통합.** 플랜 단계에서는 "header-only로 DLL 배포 부담 회피"를 가정했지만, 이 프로젝트는 CMake가 아닌 수동 `.vcxproj` 기반이라 `spdlog::spdlog_header_only` CMake 타겟을 그대로 못 씀. grpc/openssl/mysql처럼 이미 컴파일 라이브러리 + `AdditionalDependencies` + DLL 배치 패턴이 확립되어 있어 그 패턴을 그대로 따름. **(수정: 이전 기록이 틀렸음)** vcpkg의 spdlog/fmt 포트는 실제로는 동적 라이브러리(.dll)로 빌드됨 — `Binary/Debug/spdlogd.dll`, `Binary/Debug/fmtd.dll`이 빌드 후 실제 생성되어 있는 것을 code-architecture-reviewer가 발견함. `CLAUDE.md`의 런타임 DLL 목록에 `spdlogd, fmtd` 추가함(완료). **단, 이 두 DLL은 아직 git에 커밋되지 않은 untracked 상태** — 다른 vcpkg DLL들(abseil_dll 등)처럼 커밋이 필요할 수 있음, 사용자 확인 후 진행할 것.
2. **Logger 생명주기는 정적 초기화 패턴 유지(명시적 Init/Shutdown 채택 안 함) — 최종 결론.** 최초엔 "서버가 `GThreadManager->Join()`으로 영원히 블로킹하다가 외부 kill로 종료되므로 명시적 Shutdown 호출 경로를 신뢰할 수 없다"는 이유로 정적 초기화 패턴을 선택. 이후 SIOF 위험(C1)이 발견되어 한 번은 이 패턴 자체를 제거하는 Option B로 갈아탔으나(끝까지 구현 + 검증함), Option B 검토 중 다른 파일(`AccountRepository.cpp`)에서도 같은 패턴이 또 발견되면서 사용자가 피로감을 느끼고 전체 롤백 후 Meyer's Singleton으로 재결정. **결과적으로 정적 초기화 패턴(eager 전역 객체)은 유지되지만, `Logger`만 Meyer's Singleton으로 SIOF 자체를 무력화**해서 "이 패턴을 쓰는 다른 전역 객체가 LOG_*를 호출해도 안전한가"라는 질문이 더 이상 의미가 없어짐.
3. **C#: 기존 `AddHttpLogging`을 제거하고 Serilog의 `UseSerilogRequestLogging()`으로 완전히 대체.** 둘 다 켜두면 매 요청마다 로그가 중복되므로, 플랜이 제시한 "대체 권장" 옵션을 선택.
4. **컨트롤러 catch 블록 로그 레벨 배분을 플랜 문구보다 세분화.** 플랜 원문은 "타임아웃/연결 실패=Warning, 그 외=Error"였지만, 실제로는 `KeyNotFoundException`(404)과 `ArgumentException`(400)도 클라이언트 유발 상황이라 운영상 Error로 잡으면 잡음이 너무 커진다고 판단해 Warning으로 통일. `Exception`(500, 예상 못한 버그)만 Error로 격상.
5. **DeadLockProfiler.cpp의 일부 주석은 원문 복구 불가.** 파일을 바이트 단위로 열어보니 일부 CP949→UTF-8 변환 과정에서 U+FFFD(복구 불가 손실 마커)가 이미 박혀 있었음(라인 46). Edit 도구로 텍스트 매칭이 안 되어 Python으로 직접 바이트를 덮어써 의미상 동일한 새 주석으로 교체. 다른 mojibake 주석들(`Room.cpp`, `DeadLockProfiler.cpp`의 나머지)은 손실 없이 정상 복원 가능했음.

## 발견하고 해결한 버그/이슈

- **C2338 (fmt `/utf-8` 필수)**: spdlog의 기본 fmt 의존성이 유니코드 지원에 `/utf-8` MSVC 플래그를 강제함. `DhUtil`/`ServerCore`/`DhNet_Server` 세 프로젝트의 Debug(및 DhNet_Server는 Release도) ClCompile에 `/utf-8` 추가로 해결.
- **C2664 (`Session::Disconnect`의 wide-string 로깅)**: `LOG_DEBUG(L"Disconnect : {}", _cause)`처럼 와이드 포맷 문자열을 그대로 넘기면 spdlog의 narrow-char 로거(`spdlog::logger`, char 기반)와 타입이 안 맞아 컴파일 에러. `std::string(_cause, _cause + wcslen(_cause))`로 즉석 narrow 변환해서 해결 (이 코드베이스의 `_cause` 값들은 전부 ASCII 리터럴이라 손실 없음).
- **C4828 경고 다발 (DeadLockProfiler.h, Lock.h)**: `/utf-8` 활성화로 기존 CP949 인코딩 주석이 경고 대상이 됨. 빌드는 성공하므로 무시 가능하지만, 이번에 직접 수정한 파일(`DeadLockProfiler.cpp`, `Room.cpp`, `IocpCore.cpp`)의 주석만 정상 UTF-8 한글로 교체했고, 손대지 않은 다른 파일(`Lock.h`, `DeadLockProfiler.h` 등)의 동일 경고는 스코프 밖이라 그대로 남겨둠.
- **Edit 도구가 mojibake 텍스트 매칭에 실패하는 케이스**: 화면에 보이는 `�`(U+FFFD)는 실제 파일에 박힌 바이트가 매번 다를 수 있어(렌더링 시 같은 글리프로 보임) 문자열 그대로 복사해도 매칭이 안 됨. 해결: 라인 번호 기반으로 Python에서 직접 바이트를 읽고 덮어씀.

## 검증한 내용 (실제 실행으로 확인)

- C++: 전체 솔루션(`DhNet_Server.sln`, Debug\|x64) MSBuild 빌드 0 에러.
- C#: `dotnet build DhNet_Web.csproj` 0 에러/0 경고.
- C# 런타임: `dotnet run` 실행 후 `logs/dhnet-web-{date}.log` 자동 생성 확인. gRPC 백엔드(C++ 서버)를 띄우지 않은 상태로 `GET /players` 호출 → 503 응답 + 로그 파일에 다음이 순서대로 기록됨:
  1. `GrpcAdminClient` 레벨에서 `LogWarning` (RpcException 전체 스택 포함)
  2. `PlayersController` 레벨에서 `LogWarning`
  3. `UseSerilogRequestLogging()`이 `HTTP GET /players responded 503 in 2153ms`를 ERR 레벨로 기록 (Serilog의 기본 동작: 5xx 응답은 Error로 격상됨 — 의도된 동작, 별도 설정 안 함)
- C++ 런타임 라이브 실행 후 CRASH() 실제 트리거는 수행하지 않음 (Windows Error Reporting 크래시 다이얼로그가 뜨는 부작용을 피하기 위해 설계 리뷰로만 확인). **필요 시 향후 실제 트리거 테스트는 별도로 수행할 것.**

## 다음 단계

**Critical 2건(C1, C2) 모두 해결 완료.** 즉시 처리해야 할 차단 요소 없음. 아래는 code-architecture-reviewer 리뷰에서 발견된 Important 3건(미수정) 및 기타 후속 작업:

- **GrpcAdminClient의 `nameof(methodName)` 반복 패턴** — `[CallerMemberName]` 또는 wrapper로 개선 가능 (Important, 미수정)
- **컨트롤러 4개의 거의 동일한 5-branch catch 체인** — 공통 exception-mapping filter로 추출 가능 (Important, 미수정)
- **I1**: `LoggerShutdownGuard`/`Logger::Get()` 소멸 순서 미보장으로 종료 시점에 드물게 로그 한 줄 누락 가능 (Important, 미수정 — 영향 작아 Minor에 가까움)

**그 외 고려할 만한 것 (스코프 밖, 새 작업으로 분리 권장)**:
  - `CRASH()` 실제 트리거 테스트 (크래시 덤프 + 로그 파일 cause 매칭 확인, 워치독 500ms 타임아웃 시나리오 실측)
  - `DhNet_StressTest`로 동시 다중 스레드 로깅 시 인터리빙/손상 여부 실측 (플랜 4.3 — 코드 리뷰로는 안전하다고 판단했으나 실측 안 함)
  - C++/C# 로그 상호 연관(요청 ID 등) — 명시적으로 스코프 밖으로 결정됨
  - Important 3건 처리 후 `dev/active/logging-system/` → `dev/completed/`로 디렉토리 이동 검토

## 의존성 / 제약

- vcpkg manifest-mode이므로 `vcpkg.json` 수정 후 `vcpkg install --triplet x64-windows`을 repo root에서 재실행해야 신규 패키지가 `vcpkg_installed/`에 반영됨. (이번 세션에서 이미 실행 완료됨)
- MSBuild는 `-p:` 형식만 사용 (git-bash에서 `/p:`는 MSYS 경로 변환으로 깨짐).
- `DhUtil`은 `DhNet_Server`와 `ServerCore` 양쪽에서 참조되는 공용 라이브러리이므로 Logger가 여기 위치 — 양쪽 모두 동일 매크로 사용 가능함을 빌드로 확인.

## 관련 메모리

- [vcpkg build setup quirks](../../../../../../Users/Dohyun/.claude/projects/E--MyProject-DhNet/memory/project_vcpkg_build_setup.md) — manifest-mode 경로, junction, 누락 DLL 이슈.
