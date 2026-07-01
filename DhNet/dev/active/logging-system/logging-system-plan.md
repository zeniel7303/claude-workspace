# 로깅 시스템 도입 — 계획

Last Updated: 2026-06-18

## Executive Summary

DhNet 서버는 C++ 게임 서버(`DhNet_Server`/`ServerCore`/`DhUtil`)와 C# 관리 API(`DhNet_Web`) 양쪽 모두에 구조화된 로깅이 없다. C++ 쪽은 `std::cout`/`printf`가 17곳에 흩어져 있고 레벨·타임스탬프·파일 출력이 전혀 없으며, 인텐셔널 크래시 매크로(`CRASH`)는 원인 문자열을 받지만 그것을 어디에도 기록하지 않은 채 즉시 AV를 일으킨다. C# 쪽은 ASP.NET Core 기본 `ILogger`가 콘솔에만 나가고 컨트롤러들은 예외를 잡아 HTTP 응답으로만 변환할 뿐 서버 로그에는 전혀 남기지 않는다.

이 작업은 양쪽에 레벨 기반·스레드 안전·파일 영속 로깅을 도입하고, 기존 산발적 출력문을 교체하며, 운영 중 장애 진단에 필요한 최소 가시성(요청/에러/크래시 직전 상태)을 확보하는 것을 목표로 한다.

## Current State Analysis

### C++ 서버

| 위치 | 현재 방식 | 문제 |
|------|-----------|------|
| `DbConnectionPool.cpp`, `DbSystem.cpp` | `std::cout` | 레벨 없음, 파일 미출력 |
| `GameSession.cpp`, `Room.cpp`, `TestController.cpp` | `std::cout` (일부는 주석 처리됨) | 운영용 로그와 디버그 낙서가 구분 안 됨 |
| `ServerCore/IocpCore.cpp`, `Service.cpp`, `Session.cpp` | `std::cout`/`std::wcout` | 멀티바이트 인코딩 깨짐(`IocpCore.cpp:41` 한글 mojibake 확인됨) |
| `DhUtil/DeadLockProfiler.cpp` | `printf` | 데드락 감지 로그가 콘솔에만, 파일 기록 없어 재현 어려움 |
| `DhUtil/Macro.h` `CRASH(cause)` | `cause` 매개변수를 받지만 **사용하지 않음** | 크래시 원인이 메모리 덤프 분석에만 의존, 즉시 식별 불가 |

스레딩 모델(`dev/architecture.md` 참조): N개 IOCP 워커 + DB 워커 스레드 + gRPC 스레드가 모두 동시에 출력문을 실행할 수 있음. `std::cout`은 스트림 자체는 깨지지 않지만 줄 단위 인터리빙이 발생해 로그가 뒤섞인다.

### C# 관리 API (`DhNet_Web`)

- `Program.cs`: `AddHttpLogging`으로 요청 메서드/경로/상태코드만 기록. 파일 sink 없음, `appsettings.json` 자체가 존재하지 않음(환경변수 기반 설정만 사용).
- 컨트롤러(`PlayersController` 등): try/catch로 5종 예외를 잡아 HTTP 상태코드로 변환하지만 **어디에도 로그를 남기지 않는다.** 504(타임아웃)나 503(gRPC 연결 실패)이 발생해도 서버 로그에는 흔적이 없어 운영 중 원인 추적이 불가능하다.
- `GrpcAdminClient`: gRPC 호출 실패/타임아웃 시 예외만 던지고 로깅 없음.

## Proposed Future State

### C++ — spdlog 기반 비동기 로거 (DhUtil)

- `vcpkg.json`에 `spdlog` 추가 (header-only 모드로 사용 — 별도 DLL 배포 불필요).
- `DhUtil/Logger.h/.cpp`: 전역 비동기 로거 1개. `spdlog::async_logger` + rotating file sink + console sink 조합.
  - 레벨: `Trace/Debug/Info/Warn/Error/Critical`.
  - 파일: `Binary/Debug/logs/dhnet-server.log`, 일별 롤링 + 최대 보관 파일 수 제한.
  - `Macro.h`에 `LOG_INFO(...)`, `LOG_WARN(...)`, `LOG_ERROR(...)` 등 매크로 추가 (파일명/라인/스레드ID 자동 포함).
- `CRASH(cause)` 매크로 수정: AV를 일으키기 직전에 `LOG_CRITICAL(cause)` + 강제 flush 호출. 비동기 로거 특성상 flush 없이 죽으면 마지막 로그가 buffer에 남아 사라지므로 **이 부분이 핵심 보강 지점**.
- `GameServer::StartServer()`에서 로거 초기화, 서버 종료 경로에서 flush.

### C# — Serilog 기반 구조화 로깅 (DhNet_Web)

- `Serilog.AspNetCore`, `Serilog.Sinks.File` 패키지 추가.
- `appsettings.json` 신규 생성: 로그 레벨, rolling file 설정(`logs/dhnet-web-.log`, 일별 롤링).
- `Program.cs`에 `UseSerilog()` 통합. 기존 `AddHttpLogging`은 유지하거나 Serilog의 request logging으로 대체.
- 모든 컨트롤러에 `ILogger<T>` 주입, catch 블록마다 적절한 레벨로 기록:
  - `TimeoutException`/`HttpRequestException` → `LogWarning` (gRPC 백엔드 이슈, 운영상 주시 대상)
  - 그 외 `Exception` → `LogError` (예상 못한 오류)
- `GrpcAdminClient`에도 `ILogger` 주입, 호출 실패 시 기록.

### 로그 보관 정책

- 둘 다 `.gitignore`에는 이미 `*.log`가 포함되어 있어 추가 변경 불필요. 단, 로그 디렉토리 자체(`Binary/Debug/logs/`, `DhNet_Web/logs/`)는 빌드 시 자동 생성되도록 함.

## Implementation Phases

### Phase 1 — C++ Logger 코어 (DhUtil)
spdlog 의존성 추가, 전역 비동기 로거 구축, 매크로 정의.

### Phase 2 — C++ 기존 호출부 교체
산발적 `std::cout`/`printf`를 신규 매크로로 전부 교체, `CRASH`에 로깅 보강.

### Phase 3 — C# Serilog 통합
패키지 추가, `appsettings.json` 작성, `Program.cs` 통합, 컨트롤러/`GrpcAdminClient`에 로깅 추가.

### Phase 4 — 검증
양쪽 빌드 + 실행 후 로그 파일 생성/포맷/레벨 필터링/동시 다중 스레드 로깅 정합성 확인.

## Detailed Tasks

### Phase 1 — C++ Logger 코어

**1.1 vcpkg에 spdlog 추가**
- 작업: `vcpkg.json` dependencies에 `spdlog` 추가, `vcpkg install` 재실행.
- 수용 기준: `vcpkg_installed/x64-windows/include/spdlog/spdlog.h` 존재, 기존 빌드(grpc/openssl/mysql) 영향 없음.
- 의존성: 없음. 노력: S.

**1.2 `DhUtil/Logger.h`/`Logger.cpp` 작성**
- 작업: 전역 비동기 로거 싱글톤. 초기화 함수(`Logger::Init(logDir)`), 종료 함수(`Logger::Shutdown()` — flush 보장).
- 수용 기준: console sink + rotating file sink 동시 출력, 레벨별 색상 콘솔 출력, 파일은 타임스탬프+레벨+스레드ID+메시지 포맷.
- 의존성: 1.1. 노력: M.

**1.3 `Macro.h`에 `LOG_*` 매크로 추가**
- 작업: `LOG_TRACE/DEBUG/INFO/WARN/ERROR/CRITICAL(fmt, ...)` — `__FILE__`/`__LINE__` 자동 삽입.
- 수용 기준: 매크로 호출이 기존 `printf` 스타일 포맷 문자열과 호환(또는 명확한 마이그레이션 패턴 제공).
- 의존성: 1.2. 노력: S.

**1.4 `CRASH(cause)` 매크로 보강**
- 작업: AV 트리거 직전 `LOG_CRITICAL(cause)` 호출 + 즉시 flush.
- 수용 기준: `CRASH("LOCK_TIMEOUT")` 등 호출 시 크래시 직전 로그 파일에 해당 cause가 기록됨을 실제 트리거로 확인.
- 의존성: 1.3. 노력: S.

**1.5 `GameServer`에 로거 생명주기 연결**
- 작업: `StartServer()` 진입부에서 `Logger::Init`, 서버 종료 경로에서 `Logger::Shutdown`.
- 수용 기준: 서버 기동 시 `logs/dhnet-server.log` 생성 확인.
- 의존성: 1.2. 노력: S.

### Phase 2 — C++ 기존 호출부 교체

**2.1 `DbConnectionPool.cpp`, `DbSystem.cpp` 교체**
- 작업: 5곳의 `std::cout` → `LOG_WARN`/`LOG_INFO`.
- 수용 기준: 동작 변화 없음(로그 출력 채널만 변경), 빌드 성공.
- 의존성: 1.3. 노력: S.

**2.2 `GameSession.cpp`, `Room.cpp`, `TestController.cpp`, `main.cpp` 교체**
- 작업: 활성 `std::cout`/`printf`를 `LOG_DEBUG`/`LOG_INFO`로 교체. 주석 처리된 디버그 출력은 삭제(불필요한 죽은 코드).
- 수용 기준: grep으로 해당 파일에 `std::cout`/`printf` 잔존 없음 확인.
- 의존성: 1.3. 노력: S.

**2.3 `ServerCore` (`IocpCore.cpp`, `Service.cpp`, `Session.cpp`) 교체**
- 작업: `std::cout`/`std::wcout` → `LOG_*`. `IocpCore.cpp:41`의 mojibake 한글 메시지는 UTF-8/와이드 처리 정리 포함해 재작성.
- 수용 기준: 한글 메시지가 콘솔/파일 양쪽에서 깨지지 않고 출력됨.
- 의존성: 1.3. 노력: M.

**2.4 `DeadLockProfiler.cpp` 교체**
- 작업: `printf` 2곳 → `LOG_ERROR`(데드락 사이클 경로 출력).
- 수용 기준: 데드락 감지 시 로그 파일에 사이클 경로가 남음.
- 의존성: 1.3. 노력: S.

### Phase 3 — C# Serilog 통합

**3.1 패키지 추가**
- 작업: `Serilog.AspNetCore`, `Serilog.Sinks.File` NuGet 추가.
- 수용 기준: `dotnet build` 성공.
- 의존성: 없음. 노력: S.

**3.2 `appsettings.json` 신규 작성**
- 작업: Serilog 설정(최소 레벨, rolling file 경로/주기, 콘솔 sink) 정의.
- 수용 기준: 파일이 `DhNet_Web/` 루트에 위치, `csproj`가 publish 시 포함하도록 확인(`CopyToOutputDirectory` 기본 동작 확인).
- 의존성: 3.1. 노력: S.

**3.3 `Program.cs`에 Serilog 통합**
- 작업: `Host.UseSerilog()`, 기존 `AddHttpLogging`과의 중복 여부 결정(요청 로깅을 Serilog의 `UseSerilogRequestLogging()`으로 통일 권장).
- 수용 기준: 앱 기동 시 `logs/dhnet-web-{date}.log` 생성, 요청 로그가 파일에 구조화된 형태로 기록.
- 의존성: 3.1, 3.2. 노력: M.

**3.4 컨트롤러에 `ILogger<T>` 주입 및 에러 로깅**
- 작업: `PlayersController`, `LobbiesController`, `RoomsController`에 로거 주입. 각 catch 블록에 레벨별 로그 추가(타임아웃/연결 실패는 Warning, 그 외는 Error — 예외 객체 포함).
- 수용 기준: 의도적으로 gRPC 서버를 내려서 503/504 유발 시 로그 파일에 해당 예외가 기록됨.
- 의존성: 3.3. 노력: M.

**3.5 `GrpcAdminClient`에 로깅 추가**
- 작업: 생성자에서 `ILogger` 주입(DI 등록 필요 — 현재 `new GrpcAdminClient(...)`로 수동 생성 중이므로 `Program.cs`의 등록 코드도 함께 수정), gRPC 호출 실패 시 기록.
- 수용 기준: gRPC 연결 끊김 시뮬레이션 시 로그에 호출 메서드명+예외가 남음.
- 의존성: 3.3. 노력: S.

### Phase 4 — 검증

**4.1 양쪽 빌드 확인**
- 작업: `/build` 스킬로 `DhNet_Server.sln` 전체 빌드.
- 수용 기준: C++/C# 모두 빌드 성공, 새 런타임 DLL(spdlog가 컴파일 라이브러리로 잡힐 경우) `Binary/Debug/`에 배치 확인.
- 의존성: Phase 1~3 전체. 노력: S.

**4.2 실행 후 로그 확인**
- 작업: C++ 서버, C# Web 둘 다 기동 후 정상 동작 시나리오(로그인, lobbies 조회 등) 실행, 로그 파일 내용 검사.
- 수용 기준: 양쪽 로그 파일에 레벨/타임스탬프/스레드ID(또는 요청 ID)가 포함된 라인이 정상 기록됨.
- 의존성: 4.1. 노력: S.

**4.3 동시성 검증**
- 작업: 다중 클라이언트 동시 접속(`DhNet_StressTest` 활용) 중 로그 출력이 깨지거나 인터리빙으로 손상되지 않는지 확인.
- 수용 기준: 한 줄 내에 여러 스레드의 메시지가 섞이는 현상 없음.
- 의존성: 4.1. 노력: S.

## Risk Assessment and Mitigation

| 위험 | 영향 | 완화 |
|------|------|------|
| 비동기 로거가 크래시 시 마지막 로그를 flush 못 함 | 가장 중요한 크래시 원인 로그가 사라짐 | `CRASH` 매크로에서 AV 트리거 직전 동기 flush 강제 (Task 1.4) |
| 로그 I/O가 핫패스(패킷 처리)를 블로킹 | 처리량 저하 | spdlog 비동기 모드 필수 사용, 패킷 단위 핫패스에는 `LOG_TRACE`/`LOG_DEBUG`만 사용하고 기본 레벨은 `INFO` 이상으로 설정 |
| spdlog vcpkg 추가로 빌드/DLL 배포 부담 증가 | 빌드 시간 증가, 누락된 DLL로 런타임 오류 | header-only 모드로 통합(컴파일 라이브러리 불필요), `CLAUDE.md`의 런타임 DLL 목록에 추가 여부는 header-only 확인 후 결정 |
| 디스크 가득 차는 문제 (장기 운영) | 서버 다운 가능성 | rotating file sink로 최대 파일 크기/개수 제한 (C++/C# 양쪽) |
| 기존 `std::cout` 호출 교체 누락 | 일부 로그가 여전히 콘솔에만 남고 파일 미기록 | Phase 2 완료 후 `grep -rn "std::cout\|printf"` 전체 재검사로 잔존 확인 |
| 컨트롤러 로깅 추가가 기존 5종 예외 처리 흐름을 깨뜨림 | API 응답 동작 변경 위험 | 로깅은 기존 catch 블록 내부에 추가만 하고 응답 로직은 변경하지 않음 |

## Success Metrics

- C++/C# 양쪽 코드베이스에서 `std::cout`/`printf`(디버그용 제외) 잔존 0건.
- 서버 크래시(`CRASH` 트리거) 시 로그 파일에서 원인 문자열을 즉시 확인 가능.
- API 503/504/500 발생 시 `DhNet_Web` 로그에서 원인 예외를 즉시 확인 가능.
- 동시 다중 스레드 환경에서 로그 라인 손상/인터리빙 없음.

## Required Resources and Dependencies

- vcpkg: `spdlog` 추가 설치 필요 (네트워크 접근 가능 환경에서 `vcpkg install` 1회 실행).
- NuGet: `Serilog.AspNetCore`, `Serilog.Sinks.File`.
- 기존 `CLAUDE.md` 코딩 컨벤션(`m_camelCase`, USE_LOCK 등) 준수.
- `dev/architecture.md`의 스레딩 모델 이해 필수(비동기 로거 설계 근거).
