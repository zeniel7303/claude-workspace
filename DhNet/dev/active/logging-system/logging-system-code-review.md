# 로깅 시스템 도입 — Code Review

Reviewed: 2026-06-18
Scope: spdlog 도입(C++, DhUtil/ServerCore/DhNet_Server) + Serilog 도입(C#, DhNet_Web). 컨텍스트: `dev/active/logging-system/logging-system-context.md`, `logging-system-plan.md`.

## Executive Summary

기능적으로는 동작한다(빌드 성공, 런타임 로그 파일 생성까지 확인됨). 다만 다음 핵심 우려가 있다:

1. **정적 초기화 순서(SIOF)는 현재 코드 기준으로는 안전하지만 매우 취약한 암묵적 불변식에 의존한다.** `GLoggerInit`(Logger.cpp), `GUtilGlobal`(UtilGlobal.cpp), `GServerGlobal`(ServerGlobal.cpp) 세 TU 전역 정적 객체 중 어느 것도 생성자 안에서 락을 잡거나 로그를 호출하지 않기 때문에 *지금은* 문제가 없다. 하지만 `Lock::WriteLock/ReadLock`(Lock.cpp)이 `GDeadLockProfiler->PushLock` 및 `CRASH`(→`LOG_CRITICAL`→`GLogger`)를 직접 호출하므로, 향후 누군가 전역 객체의 생성자 안에서 `USE_LOCK`을 쓰는 클래스를 인스턴스화하거나 `LOG_*`를 호출하면 `GLogger`가 아직 생성되지 않은 상태에서 nullptr 역참조가 발생할 수 있다. 컴파일러/링커가 보장하는 순서가 전혀 없다.
2. **`CRASH` 매크로의 `LoggerShutdown()` 호출은 스레드 안전하지 않다.** 동시에 다른 스레드들이 `LOG_*`를 호출 중인 상태에서 한 스레드가 `CRASH`로 진입하면, `flush()` 호출과 동시 `log()` 호출이 spdlog 내부에서 경쟁한다(spdlog 자체는 스레드 안전하지만, `flush()` 호출 자체가 끝나기를 보장하지 않고 곧바로 AV를 일으키므로 flush가 실제로 완료되기 전에 프로세스가 죽을 가능성이 있다).
3. **`Session.cpp`의 wide→narrow 변환은 동작하지만 idiomatic하지 않다.** 매 `Disconnect` 호출마다 힙 할당(`std::string` 생성)이 발생하고, 멀티바이트(비 ASCII) `_cause`가 들어오면 자모 손실 없이 깨진다(현재는 전부 ASCII 리터럴이라 우연히 안전).
4. **`GrpcAdminClient.CreateHttpMappedException`의 `nameof(...)` 패턴은 유지보수 부담이 있다.** 호출부 6곳에 동일한 try/catch + `nameof` 보일러플레이트가 반복된다.
5. **컨트롤러 4개에 동일한 5단 catch 체인이 거의 그대로(문자열만 다름) 복제되어 있다.** 로깅 추가로 기존의 반복 패턴이 더 길어지고 더 눈에 띄게 되었다(원래도 있던 패턴이지만 이번 변경으로 악화됨).
6. **런타임 DLL 관리 공백**: `vcpkg`가 이 triplet에서 spdlog/fmt를 동적 라이브러리로 빌드했고(`Binary/Debug/fmtd.dll`, `Binary/Debug/spdlogd.dll`이 실제로 생성됨), 이는 context 문서의 "정적 링크라 추가 DLL 불필요" 주장과 다르다. 이 두 DLL은 현재 git에 추가되지 않은 untracked 상태다. 기존 컨벤션(`abseil_dll.dll`, `cares.dll` 등 vcpkg 산출 DLL은 `Binary/Debug/`에 커밋)을 따르려면 이 두 파일도 커밋되어야 한다.

CLAUDE.md의 USE_LOCK/weak_ptr/금지 패턴(concurrent_unordered_map, raw new/delete) 위반은 발견되지 않았다.

## Critical Issues

### C1. SIOF 위험 — 현재는 무사고지만 불변식이 코드에 강제되지 않음
- 파일: `DhUtil/Logger.cpp:16-48`, `DhUtil/UtilGlobal.cpp:9-23`, `DhNet_Server/DhNet_Server/ServerGlobal.cpp:7-18`, `DhUtil/Lock.cpp` (전체)
- `GLoggerInit`, `GUtilGlobal`, `GServerGlobal`는 모두 각자의 `.cpp` 파일에 정의된 익명/파일 스코프 정적 객체이며, 서로 다른 TU(그리고 `ServerGlobal`은 다른 정적 라이브러리 `DhNet_Server`)에 속해 있어 **C++ 표준상 이들 간 생성 순서는 정의되지 않는다** (동일 TU 내부는 선언 순서가 보장되지만 TU 간에는 링커가 결정).
- 직접 조사 결과: 현재 `GUtilGlobal`/`GServerGlobal`의 생성자는 단순히 `new DeadLockProfiler()`/`new ThreadManager()`/`new GlobalQueue()`만 호출하고, 그 생성자들 내부도 락이나 로그 호출이 없다(`DeadLockProfiler`, `ThreadManager`, `GlobalQueue` 생성자 직접 확인). 따라서 **지금 당장 크래시가 발생하는 경로는 없다.**
- 그러나 `Lock::WriteLock`/`ReadLock`(`DhUtil/Lock.cpp:6-103`)은 `GDeadLockProfiler->PushLock(...)`을 무조건 호출하고(`#if _DEBUG`), 타임아웃/오류 시 `CRASH(...)`를 호출하여 `LOG_CRITICAL`이 `GLogger`(전역 `shared_ptr`, `Logger.cpp:8`)를 역참조한다. `GLogger`는 `GLoggerInit` 생성자가 실행되기 전까지 빈 `shared_ptr`(null)이다.
- 위험 시나리오: 향후 어떤 전역/네임스페이스 스코프 객체(예: 새로운 `GXxx` 싱글톤)가 생성자 본문에서 `USE_LOCK`이 걸린 클래스의 메서드를 호출하거나 직접 `LOG_*` 매크로를 쓰면, 빌드 환경에 따라 `GLoggerInit`보다 먼저 생성될 경우 `GLogger->critical(...)`이 null `shared_ptr` 역참조로 즉시 크래시한다. 이는 "우연히 안전한" 상태이며 코드 차원의 안전장치(예: `LOG_*` 매크로 내부에 `GLogger` null 체크, 또는 Logger를 `[[gnu::init_priority]]`/Meyer's singleton 패턴으로 전환해 lazy 초기화 보장)가 전혀 없다.
- 권장(구현은 하지 않음, 보고만): `LOG_*` 매크로를 `GLogger`를 직접 참조하는 대신 함수 호출(`Logger::Get()`)로 감싸 Meyer's singleton(`static` 지역 변수, 최초 사용 시 초기화 보장)으로 바꾸는 것이 SIOF에 대해 근본적으로 안전하다. 현재 `UtilGlobal.cpp`가 이미 이런 정적 초기화 패턴을 쓰고 있어서 "동일 스타일을 따른다"는 명분은 이해되나, `UtilGlobal`의 두 객체(`GDeadLockProfiler`, `GGlobalQueue`)는 서로를 생성자 안에서 호출하지 않는 반면 Logger는 코드베이스 전역에서 호출되는 의존성이라는 점에서 위험 노출 범위가 다르다.

### C2. CRASH 매크로의 LoggerShutdown()이 동시성 하에서 안전성 보장 없음
- 파일: `DhUtil/Macro.h:33-40`, `DhUtil/Logger.cpp:10-14`
- `CRASH(cause)`는 `LOG_CRITICAL(...)` → `LoggerShutdown()`(= `GLogger->flush()`) → 의도적 AV를 순서대로 실행한다. `spdlog::async_logger`의 `flush()`는 내부적으로 백그라운드 스레드 큐에 flush 작업을 push하고 완료를 기다리는데, 다른 스레드가 동시에 `LOG_*`를 호출하며 큐에 항목을 계속 추가하고 있다면:
  - `flush()`가 호출 스레드를 블로킹하고 완료를 기다리는 구현이라면(스레드 풀 정책에 따라 다름) 큐가 계속 채워지는 동안 AV 트리거가 지연되어 "크래시 직전 동기 flush"라는 의도가 다른 스레드의 로그량에 따라 수십~수백 ms 지연될 수 있다.
  - 더 중요한 문제는 **`CRASH`를 호출한 스레드 자신이 그 직후 `*crash = 0xDEADBEEF`로 프로세스를 통째로 죽이기 때문에, `flush()`가 실제로 디스크에 fsync까지 끝났는지 보장하는 코드가 없다** — `spdlog::async_logger::flush()`는 flush 메시지를 백그라운드 워커에 enqueue하고 그 메시지가 처리될 때까지 *현재 스레드를 블로킹*하는 것이 spdlog의 의도된 동작이긴 하나, 이는 spdlog 내부 구현에 대한 암묵적 신뢰이며 이 프로젝트의 코드에서 그 보장을 직접 확인하거나 타임아웃을 두지 않았다. 만약 백그라운드 워커 스레드가 다른 이유로(예: 그 자체가 데드락에 걸린 락을 거치는 경로) 응답 불능이면 `flush()`가 영원히 블로킹되어 **CRASH가 트리거되어야 할 크래시 자체가 멈춰버리는 역설적 상황**이 가능하다.
- `LoggerShutdown()` 자체에 `GLogger` null 체크가 있는 것은 양호하나(`if (GLogger)`), 멀티스레드 환경에서 `GLogger`를 가리키는 `shared_ptr`를 다른 스레드가 동시에 reset하는 경로는 없으므로 그 부분은 안전하다.
- 플랜 문서의 "필요 시 향후 실제 트리거 테스트는 별도로 수행할 것"이라는 셀프 인지가 있었던 부분과 일치 — 실측이 안 된 채로 이 위험이 남아있다.

## Important Improvements

### I1. Session.cpp의 wide→narrow 변환
- 파일: `DhNet_Server/ServerCore/Session.cpp:66`
- `LOG_DEBUG("Disconnect : {}", std::string(_cause, _cause + wcslen(_cause)));`
- 매 `Disconnect()` 호출마다 `std::string`을 새로 힙 할당한다. `Disconnect`는 `ProcessRecv`/`ProcessSend`/`HandleError` 등 비교적 빈번한 경로(연결 종료 시점이긴 하지만 다수 동시 접속 시 누적 가능)에서 불린다.
- 더 근본적인 문제: 이 변환은 단순 캐스팅(`char` 폭으로 잘라내기)이라 비 ASCII 와이드 문자가 들어오면 데이터가 깨진다(서로게이트 페어, 멀티바이트 한글 등 전부 깨짐). 현재 `_cause` 호출부(`ProcessRecv`, `ProcessSend`, `HandleError`)를 grep한 결과 전부 ASCII 리터럴(`L"Recv 0"`, `L"OnWrite Overflow"` 등)이라 지금은 안전하지만, 이 함수 시그니처(`const WCHAR* _cause`)가 와이드 문자열을 받는 이유 자체가 사실상 사라졌다(전부 ASCII면 `const char*`로 바꾸는 게 더 적절해 보임).
- 더 깔끔한 대안: (a) `WideCharToMultiByte`로 정확한 변환(현재 코드는 그조차 아닌 단순 truncation)을 쓰거나, (b) 더 근본적으로 `_cause` 매개변수 타입을 `const char*`로 바꿔 호출부 리터럴도 일반 문자열로 통일하는 것을 검토할 가치가 있다(이번 세션 스코프 밖일 수 있으나 향후 과제로 기록할 만함).
- 참고: 이 함수는 파일 끝(`Session.cpp` EOF)에 trailing newline이 없고, `Disconnect()` 함수 본문의 들여쓰기가 탭/스페이스 혼용으로 깨져 있다(diff에서 확인, 라인 61-64 부근) — 기능에는 영향 없으나 가독성 이슈.

### I2. GrpcAdminClient의 nameof(methodName) 수동 전달
- 파일: `DhNet_Server/DhNet_Web/Services/GrpcAdminClient.cs:22-128`
- 6개 public 메서드 각각이 동일한 `try { await _client.XxxAsync(...); } catch (RpcException ex) { throw CreateHttpMappedException(ex, nameof(XxxAsync)); }` 패턴을 반복한다. 새 gRPC 메서드를 추가할 때마다 동일 보일러플레이트를 베껴 쓰고 `nameof`를 빠뜨리거나 잘못된 이름을 넣을 수 있는 여지가 있다(컴파일러가 `nameof` 자체의 존재는 검증하지만 "맞는 메서드의 nameof를 썼는지"는 검증 못함 — 복붙 시 다른 메서드명을 그대로 두는 실수 가능).
- 대안 패턴(보고만, 구현 안 함): `[CallerMemberName]` 어트리뷰트를 `CreateHttpMappedException`의 추가 매개변수에 적용하면 호출부에서 `nameof(...)`를 생략해도 컴파일러가 자동으로 호출 메서드명을 채워준다. 또는 공통 래퍼 메서드(`ExecuteAsync<T>(Func<Task<T>> call, [CallerMemberName] string? methodName = null)`)로 try/catch 자체를 한 곳으로 모으면 6곳의 중복 try/catch 블록도 제거된다.

### I3. 컨트롤러 4개의 동일 catch 체인 반복
- 파일: `HealthController.cs`, `PlayersController.cs`, `LobbiesController.cs`, `RoomsController.cs`
- 4개 컨트롤러, 6개 액션 메서드 모두 `TimeoutException → 504/Warning`, `KeyNotFoundException → 404/Warning`, `ArgumentException → 400/Warning`, `HttpRequestException → 503/Warning`, `Exception → 500/Error` 5단 체인을 거의 글자 그대로(로그 메시지 prefix만 다름) 반복한다.
- 이번 로깅 추가로 각 catch 블록이 한 줄 더 길어지면서 반복 분량이 커졌다. 예외→HTTP 상태코드→로그레벨 매핑을 한 곳(예: 액션 필터/`ExceptionFilterAttribute` 또는 공통 베이스 클래스 메서드)으로 추출하면 향후 새 컨트롤러/액션을 추가할 때 매핑 누락이나 레벨 불일치 위험이 줄어든다. (이는 이번 세션 이전부터 있던 구조적 패턴이며, 로깅 추가가 직접적인 원인은 아니지만 악화시켰다.)

### I4. 런타임 DLL 누락 가능성
- `Binary/Debug/fmtd.dll`, `Binary/Debug/spdlogd.dll`이 작업 트리에 실제로 존재(`git status`에서 untracked로 확인)하지만 git에 추가되지 않았다. `DhNet_Server.vcxproj`는 `spdlogd.lib;fmtd.lib`를 링크하는데, 이 vcpkg triplet에서 이 두 라이브러리가 동적 빌드되어 런타임에 해당 DLL이 필요하다는 사실이 context 문서의 "정적 링크라 DLL 불필요" 결론과 모순된다. 기존 컨벤션상(`abseil_dll.dll`, `cares.dll`, `libcrypto-3-x64.dll` 등 vcpkg 산출 DLL이 `Binary/Debug/`에 커밋되어 있음) 이 두 파일도 커밋해야 신규 클론 환경에서 실행이 가능하다. CLAUDE.md의 "런타임 DLL" 목록도 갱신이 필요해 보인다.

## Minor Suggestions

- `DhUtil/Macro.h:11-16`: `LOG_*` 매크로가 `GLogger->trace(...)` 형태로 `GLogger`를 직접 역참조한다. `GLogger`가 어떤 이유로든 null인 시점(앞서 C1에서 설명한 SIOF 외에도, 예컨대 `LoggerShutdown()` 이후 `spdlog::shutdown()`이 실행된 뒤 — 현재는 발생하지 않지만 — 추가 로그 호출이 있다면)에 호출되면 즉시 크래시한다. 매크로 차원에서 null 체크를 넣는 것은 성능 저하가 거의 없으므로(분기 예측 favorable) 방어적으로 고려할 만하다.
- `DhUtil/Logger.cpp:39`: `spdlog::flush_every(std::chrono::seconds(3))`는 프로세스 전역(`spdlog`의 default registry 전체)에 적용되는 API다. 현재는 `GLogger` 하나만 등록되어 있어 문제 없으나, 향후 다른 로거를 spdlog 레지스트리에 추가하면 의도와 다르게 그 로거도 3초마다 flush될 수 있다는 점을 인지해두면 좋다.
- `DhNet_Server/DhNet_Server/main.cpp:11`: `LOG_DEBUG("{}", thisEnv)` 호출부 자체가 `// CheckAllEnv(envp);`로 주석 처리되어 죽은 코드 경로다(컨텍스트 문서에도 명시됨). 이번 스코프는 아니지만 정리 대상으로 남겨둘 만하다.
- `appsettings.json`(C#)의 `outputTemplate`에 `{SourceContext}`가 포함되어 있는데 C++ 쪽 로그 패턴(`Logger.cpp:36`, `[tid %t]`)에는 대응 정보가 없다 — 두 로그를 나란히 보며 디버깅할 때 형식이 상당히 다르다(C++: 스레드ID 중심, C#: SourceContext/클래스명 중심). 의도적으로 상호 연관을 스코프 밖으로 뒀다는 컨텍스트 문서 기록과 일치하므로 문제는 아니나, 향후 통합 운영 도구를 만들 때 참고할 사항.
- `DeadLockProfiler.cpp`의 `LOG_CRITICAL` 호출(라인 108, 113)이 데드락 사이클의 각 엣지를 줄 단위로 여러 번 호출한다 — 사이클이 길면 로그가 여러 줄로 흩어진다. 단일 메시지로 합쳐서 한 번에 기록하면 비동기 큐 안에서 다른 스레드의 로그와 인터리빙되어 사이클 경로가 섞여 보일 위험을 줄일 수 있다(현재는 `LOG_CRITICAL` 여러 호출 사이에 다른 스레드 로그가 끼어들 수 있음).

## Architecture Considerations

- **DhUtil의 책임 확장**: `DhUtil`은 기존에 `Lock`/`ThreadManager`/`TLS`/`JobQueue`/`ObjectPool`/`DeadLockProfiler` 등 "동시성 프리미티브" 전용 라이브러리였는데, 이제 `spdlog` 의존성을 가진 `Logger`도 포함하게 되어 `DhUtil`이 외부 서드파티 라이브러리(spdlog/fmt)에 직접 의존하는 첫 사례가 됐다. `DhNet_Server`와 `ServerCore` 양쪽이 `DhUtil`을 참조하므로 이 의존성은 전이적으로 두 프로젝트 모두에 영향을 준다(실제로 두 vcxproj 모두 `/utf-8`, `NOMINMAX`, include 경로 추가가 필요했던 이유). 설계 자체는 합리적이나(공용 매크로가 필요하므로 공용 라이브러리에 위치하는 것이 맞음), `DhUtil`이 순수 유틸리티에서 "인프라 의존성을 가진 유틸리티"로 성격이 바뀌었다는 점은 문서화해 둘 가치가 있다.
- **명시적 Init/Shutdown 대신 정적 초기화를 선택한 결정**(컨텍스트 문서 결정사항 #2)은 서버의 종료 방식(`GThreadManager->Join()`으로 영구 블로킹 후 외부 kill)을 고려하면 합리적인 트레이드오프다. 다만 이 선택이 C1에서 설명한 SIOF 노출 표면을 만들어낸 근본 원인이기도 하다 — "명시적 lifecycle 관리 없음"이라는 결정이 "그래서 순서 보장도 없음"이라는 결과를 자연스럽게 동반한다는 점을 인지하고 있어야 한다.
- **CRASH 매크로가 이제 로깅 시스템에 강하게 결합**되었다(`LOG_CRITICAL` + `LoggerShutdown()`). 이는 의도된 설계(크래시 원인을 로그에 남기기 위함)이지만, 결과적으로 `Macro.h`(가장 하위 레벨의 매크로 정의 파일)가 `Logger.h`(spdlog 의존)를 include하게 되어, `Macro.h`를 쓰는 모든 TU가 transitively spdlog 헤더를 끌고 들어온다. 컴파일 시간 영향은 측정되지 않았다.
- **C# 쪽 Serilog 통합은 구조적으로 깔끔하다.** `UseSerilogRequestLogging()`으로 기존 `AddHttpLogging`을 대체한 결정은 중복 로깅을 피하는 올바른 선택이고, DI를 통한 `ILogger<GrpcAdminClient>` 주입도 ASP.NET Core 표준 패턴을 따른다.

## Next Steps

1. (사용자 승인 필요) `Lock.cpp`/`DeadLockProfiler.cpp` 경로에서 SIOF에 대한 근본적 안전장치(Meyer's singleton 또는 `LOG_*` 매크로 내 null 체크)를 추가할지 결정.
2. (사용자 승인 필요) `CRASH`의 `LoggerShutdown()`이 실제로 동기 flush를 완료하는지 spdlog 문서/소스 기준으로 검증하거나, 컨텍스트 문서에 이미 기록된 "CRASH 실제 트리거 테스트"를 별도 작업으로 수행.
3. `Binary/Debug/fmtd.dll`, `Binary/Debug/spdlogd.dll`을 git에 커밋할지 여부 결정(다른 vcpkg 산출 DLL과 동일하게 취급할지).
4. (선택, 스코프 밖일 수 있음) `GrpcAdminClient`의 `nameof` 반복과 컨트롤러의 5단 catch 체인 반복을 공통 헬퍼로 추출하는 리팩토링을 별도 작업으로 고려.
5. `Session::Disconnect`의 `_cause` 매개변수를 `const char*`로 바꿔 wide→narrow 변환 자체를 제거하는 것을 향후 과제로 검토.

이 리뷰는 보고 전용이며 수정 작업은 수행하지 않았습니다. 사용자 승인 후 진행 여부를 결정해 주세요.

## Fix 1 / Fix 2 후속 리뷰

Reviewed: 2026-06-18
Scope: 위 C1(SIOF 위험), C2(CRASH의 LoggerShutdown 동시성 안전성 미보장) 두 Critical 이슈에 대한 수정사항만 검토. 대상 파일: `DhUtil/Logger.h`, `DhUtil/Logger.cpp`, `DhUtil/Macro.h`.

### Executive Summary

두 Critical 이슈 모두 의도한 방향으로 해결되었다고 판단한다.

- **C1(SIOF)**: `GLogger` 전역 `shared_ptr` 직접 참조를 `Logger::Get()`의 함수 지역 `static`(Meyer's Singleton)으로 교체. C++11부터 함수 지역 `static`의 최초 초기화는 스레드 안전성과 "최초 사용 시점"이 언어 차원에서 보장되므로, 다른 TU의 정적 객체가 생성자에서 `LOG_*`를 호출해도 더 이상 미정의 순서에 의존하지 않는다. **C1은 해결.**
- **C2(CRASH 블로킹)**: spdlog 소스(`thread_pool-inl.h:79-89`, `async_logger-inl.h:46-55`)를 직접 확인한 결과, `async_logger::flush()` → `post_flush()` → `post_async_msg_()`이며 `async_overflow_policy::block`(현재 `CreateLogger()`에서 사용 중인 정책, `Logger.cpp:23`)일 때 `q_.enqueue(...)`가 **큐가 가득 찬 경우 호출 스레드를 무기한 블로킹할 수 있는 코드 경로가 실제로 존재**한다(이전 리뷰의 C2 추정이 소스 레벨로 확인됨). `Logger::FlushWithTimeout`이 이 `flush()` 호출 자체를 `std::async`로 분리된 스레드에서 실행하고 호출 스레드는 `future::wait_for(500ms)`만 기다리므로, enqueue가 블로킹되어도 CRASH 매크로의 메인 흐름(`*crash = 0xDEADBEEF`)은 500ms 후 항상 진행된다. **C2는 해결.**

다만 아래 Important 항목 한 가지(I5, static 소멸 순서)는 현재 코드에서 실질적으로 안전하지만 그 안전성이 "우연"이 아니라 의도된 설계인지 문서화가 약하다는 점, 그리고 Minor 항목들(백그라운드 flush 스레드의 처리되지 않은 종료, 동시 CRASH 호출 시 멀티스레드 안전성)은 현재 코드 기준으로는 문제없음을 확인했다.

### Critical Issues

해당 없음 — 기존 C1/C2 모두 해소됨. 신규 Critical 발견 없음.

### Important Improvements

#### I5. `Logger::Get()`의 함수 지역 static과 `LoggerShutdownGuard`의 소멸 순서 의존성 — 현재는 안전하나 암묵적

- 파일: `DhUtil/Logger.cpp:36-46`
- `LoggerShutdownGuard`는 `Logger.cpp`의 익명 네임스페이스에 있는 **네임스페이스 스코프 정적 객체**(`GLoggerShutdownGuard`, 39번 줄)이고, `Logger::Get()`의 `instance`는 **함수 지역 static**(44번 줄)이다. C++ 표준상 정적 소멸 순서는 생성 순서의 역순이며, 함수 지역 static은 "그 함수가 처음 호출된 시점"에 생성된다. 즉:
  - 만약 프로그램 생애주기 중 어떤 코드든 `Logger::Get()`을 한 번이라도 호출하면(거의 항상 호출됨 — `LOG_*` 매크로가 전부 `Logger::Get()`을 거치므로), `instance`는 `GLoggerShutdownGuard`보다 **나중에** 생성된다(왜냐하면 `GLoggerShutdownGuard`는 TU 로드 시 즉시 생성되고, `instance`는 그보다 나중인 최초 `LOG_*` 호출 시점에 생성되기 때문).
  - 생성이 나중이므로 소멸은 **먼저** 일어난다 — 즉 `instance`(logger 객체)가 먼저 소멸되고, 그 다음에 `GLoggerShutdownGuard`(→ `spdlog::shutdown()`)가 소멸된다. 이 순서라면 "이미 shutdown된 thread_pool에 마지막으로 로깅"하는 use-after-shutdown 패턴은 발생하지 않는다 — 오히려 반대로 logger가 먼저 죽고 shutdown이 나중에 안전하게 정리하는, 의도한 바로 그 순서다.
  - **단, 이 순서 보장은 "동일 TU(`Logger.cpp`) 내에서 두 정적 객체가 모두 존재"하기 때문에 C++ 표준의 "동일 TU 내 정적 소멸은 생성의 역순" 규칙에 안전하게 의존할 수 있는 것**이다. 이는 일반적인 임의의 TU 간 SIOF 문제(C1에서 다뤘던 것)와는 달리, 같은 TU 안에 있다는 사실 덕분에 견고하다. 다만 코드 자체(주석 35번 줄: "Logger 자체를 참조하지 않으므로... 항상 안전하다")는 "참조하지 않음"만 근거로 들고 있고, "동일 TU 내 생성/소멸 역순 보장" 및 "instance가 GLoggerShutdownGuard보다 항상 나중에 생성됨"이라는 더 핵심적인 이유는 명시돼 있지 않다. 코드는 정확하지만 주석이 설명하는 이유가 불완전하다.
- 권장(보고만): 주석에 "instance는 항상 GLoggerShutdownGuard보다 나중에 생성되므로 표준의 역순 소멸 규칙상 항상 먼저 소멸된다"는 핵심 근거를 한 줄 추가하면 향후 유지보수자가 이 구조를 건드릴 때(예: `LoggerShutdownGuard`를 다른 파일로 옮기는 리팩토링) 안전 불변식을 깨뜨릴 위험을 줄일 수 있다.

### Minor Suggestions

- **백그라운드 flush 스레드의 운명(보고된 우려 사항 검증 결과, 문제 없음)**: `FlushWithTimeout`에서 `std::async(std::launch::async, ...)`로 생성된 워커는 `future`가 디스트럭트되며 `std::launch::async`로 시작된 태스크는 표준상 `~future()`가 태스크 완료까지 블로킹하는 것은 *invalid future*(즉 `get()`/`wait()`를 거치지 않은 shared state)에 대해서만 발생하는 의무이지만, 여기서는 `fut.wait_for(...)`만 호출하고 `fut` 자체가 함수 스코프를 벗어나며 소멸된다. 이 경우 `fut`의 소멸자는 `valid()`한 shared state를 가진 future이므로 **블로킹하지 않고 그냥 detach**된다(C++ 표준 [futures.unique_future] — `wait_for`로 timeout이 난 future를 소멸시키는 것은 unique_future를 블로킹 없이 버리는 것과 동일). 따라서 타임아웃 후 `*crash = 0xDEADBEEF`로 프로세스가 즉시 종료되면, 백그라운드 flush 스레드는 OS 프로세스 종료와 함께 강제 종료된다 — 이는 **CRASH의 목적(크래시를 항상 보장)과 일치하는 의도된 동작**이며, 운영체제 프로세스 종료 시 스레드가 정리되지 않는 것은 정상이다. 다만 Windows에서 `std::async`가 내부적으로 스레드 풀(thread pool) 기반인지 신규 스레드 생성인지는 구현 정의이므로, 만약 신규 스레드 생성이라면 OS 핸들 누수가 발생하지만 **프로세스가 즉시 종료되므로 실질적 영향 없음**. 문제 없음으로 판단.
- **동시 CRASH 호출 시 `Logger::Get()` 안전성(보고된 우려 사항 검증 결과, 문제 없음)**: 함수 지역 static의 최초 초기화가 끝나 "이미 생성된" 상태에서는, 이후의 모든 `Logger::Get()` 호출은 단순히 레퍼런스를 리턴하는 것뿐이라 추가 동기화 비용이나 경쟁이 없다(C++11 `[stmt.dcl]` 6항 — 초기화 완료 후의 접근은 동기화가 필요 없음, 컴파일러가 생성하는 가드 변수는 1회성 초기화 체크에만 쓰이고 그 이후엔 분기 비용도 거의 없음). 여러 스레드가 동시에 `CRASH`를 호출해 `Logger::FlushWithTimeout`이 동시에 여러 번 실행되더라도, 각자 독립된 `std::async` 태스크가 동일한 `Logger::Get()`(이미 생성된 동일 인스턴스)에 대해 `flush()`를 호출하는 것뿐이며, `spdlog::logger`/`async_logger` 자체는 내부적으로 스레드 안전하게 설계되어 있으므로(공식 문서 및 `sink_it_`/`flush_()`의 mutex 없는 lock-free 큐 enqueue 구조 확인) 문제가 없다. 다만 동시에 여러 스레드가 CRASH에 진입하면 각자 독립적으로 500ms 타임아웃을 거니, 프로세스 종료 자체는 가장 먼저 타임아웃(혹은 flush 완료)된 스레드가 `*crash = 0xDEADBEEF`에 도달하는 즉시 일어난다 — 이는 기존에도 동일했던 특성이며 이번 변경으로 악화되지 않았다.
- **`int32` 타입과 include 순서(보고된 우려 사항 검증 결과, 가정 일치 확인)**: `DhUtil/pch.h`(10-11번 줄)는 `Types.h`를 `Macro.h`보다 먼저 include하고, `Macro.h`는 `Logger.h`를 include한다. `Logger.h`의 `FlushWithTimeout(int32 _timeoutMs)` 선언은 `Macro.h`를 거쳐 pch에 포함되는 한 항상 `int32`가 먼저 정의된 상태에서 파싱되므로 문제 없다. `ServerCore/pch.h`(12번 줄)도 `../../DhUtil/pch.h`를 그대로 include하므로 동일한 순서가 적용된다. **단, `Logger.h`는 자체적으로 `int32`를 전방 선언하거나 include하지 않고 pch 포함 순서에 전적으로 의존**한다 — 만약 향후 누군가 `Logger.h`를 pch 없이 단독으로 (예: 새 TU에서 `#include "Logger.h"`만) include하면 컴파일 에러가 난다. 현재 코드베이스 grep 결과 `Logger.h`는 항상 `Macro.h`를 통해서만 도달하므로 실질적 위험은 낮으나, 헤더 자체의 자기완결성(self-containment) 원칙 관점에서는 약점으로 남는다.

### Architecture Considerations

- Meyer's Singleton 전환은 `DhUtil/UtilGlobal.cpp`가 이미 쓰던 정적 초기화 패턴과는 다른 패턴(지역 static vs 네임스페이스 스코프 정적 포인터)이지만, Logger처럼 "코드베이스 전역에서 호출되는 의존성"에는 지역 static 패턴이 구조적으로 더 안전하다(이전 리뷰 C1에서 권장했던 방향과 일치). `UtilGlobal`/`ServerGlobal`의 다른 전역 객체들은 여전히 기존 패턴(파일 스코프 정적 포인터, 명시적 `new`)을 유지하고 있어 코드베이스 내에 두 가지 정적 초기화 패턴이 공존하게 되었다 — Logger가 예외적으로 다른 패턴을 쓰는 이유(SIOF 노출 표면이 다른 전역 객체보다 컸기 때문)가 합리적이므로 문제는 아니나, 향후 유지보수자가 "왜 Logger만 다른가"를 궁금해할 수 있어 `Logger.h`의 현재 주석(5-6번 줄)이 그 이유를 이미 잘 설명하고 있다는 점은 긍정적이다.
- `CRASH` 매크로가 더 이상 `spdlog::shutdown()`을 직접 트리거하지 않게 되어(`LoggerShutdownGuard`로 분리), 크래시 경로와 정상 종료 경로의 책임이 명확히 분리되었다. 이는 견고성 측면에서 개선이다 — 크래시 시점에 다른 스레드가 여전히 로깅 중일 수 있다는 우려(원래 의도 3번)에 대해, 이제 크래시 경로는 전역 스레드풀을 파괴하지 않고 단지 enqueue + 짧은 대기만 하므로 다른 스레드의 로깅을 방해하지 않는다.

### Next Steps

1. (선택, 낮은 우선순위) `Logger.cpp:35` 주석에 "instance가 GLoggerShutdownGuard보다 항상 나중에 생성되어 항상 먼저 소멸된다"는 핵심 근거를 추가해 I5의 불변식을 명시적으로 문서화.
2. (선택, 낮은 우선순위) `Logger.h`가 `int32`를 사용하면서도 자체적으로 정의를 가져오지 않는 self-containment 약점을 인지해두되, 현재 include 그래프상 실질 위험은 낮으므로 별도 작업 없이 그대로 두는 것도 합리적 선택.
3. C1/C2 모두 해결되었으므로 추가 코드 변경 없이 현재 상태로 머지 가능하다고 판단(사용자 최종 승인 필요).

이 후속 리뷰도 보고 전용이며 수정 작업은 수행하지 않았습니다.
