# Code Review — Option B: Eliminate Eager Global-Static Init Pattern (C1 Fix)

**Scope**: Replace anonymous-namespace eager-global-static singletons (`GLogger`, `GDeadLockProfiler`,
`GGlobalQueue`, `GThreadManager`) with explicit `XxxInit()`/`XxxShutdown()` free functions called in
order from `main()`. C2 (CRASH macro's unbounded `flush()`) is explicitly out of scope this session.

**Files reviewed**:
- `DhUtil/Logger.h`, `DhUtil/Logger.cpp`
- `DhUtil/UtilGlobal.h`, `DhUtil/UtilGlobal.cpp`
- `DhNet_Server/DhNet_Server/ServerGlobal.h`, `DhNet_Server/DhNet_Server/ServerGlobal.cpp`
- `DhNet_Server/DhNet_Server/main.cpp`

---

## Executive Summary

The mechanical refactor itself is correct and clean: the three target eager-global-static objects
(`GLoggerInit`, `GUtilGlobal`, `GServerGlobal`) were successfully removed and replaced with explicit
`Init()`/`Shutdown()` pairs, called from `main()` in a dependency-correct order
(`LoggerInit → UtilGlobalInit → ServerGlobalInit`, reverse on shutdown). This does eliminate
cross-TU static-initialization-order non-determinism **for the three converted globals**.

However, the review surfaced two issues that undercut the goal of "fully eliminating SIOF risk":

1. **A fourth eager anonymous-namespace global (`g_dummy` in `AccountRepository.cpp`) was missed.**
   Its constructor can call `LOG_CRITICAL` via `ASSERT_CRASH`/`CRASH` through `GLogger`, which is
   guaranteed null at that point (static init happens before `main()`'s `LoggerInit()` call). This is
   not a hypothetical — it is the exact SIOF class of bug the refactor set out to remove, surviving in
   a file untouched this session.
2. **The new `Shutdown()` call sequence in `main()` is very likely unreachable in normal operation.**
   `GameServer::StartServer()` calls `GThreadManager->Join()`, which blocks until all worker threads
   exit — but the worker threads run `Job()`, an unconditional `while(true)` loop with no exit
   condition. There is no signal handler (`SIGINT`/`SetConsoleCtrlHandler`) anywhere in
   `ServerCore/Service.cpp` or `GameServer.cpp`. In practice the process is always terminated
   externally (Ctrl+C / taskkill / kill), so `mysql_library_end()` and the new
   `ServerGlobalShutdown(); UtilGlobalShutdown(); LoggerDestroy();` calls in `main.cpp` never execute.
   The refactor adds correct-looking teardown code that is dead code on every real run.

Neither issue is a regression introduced by this diff per se (the dummy-init bug pre-dates this
session; the missing shutdown path was already true with the old destructor-based teardown, which
also only ran at static-destruction time on a process that's killed before reaching there). But both
directly contradict the stated goal of this refactor ("이제 아무것도 main() 이전에 auto-construct되지
않는다" / nothing auto-constructs before `main()`, and "정리(shutdown)도 명시적으로 한 곳에서 보장된다").
Both should be flagged back to the user as the goal not being fully met yet.

---

## Critical Issues

### C1-residual. `AccountRepository.cpp`'s `g_dummy` eager static can crash via null `GLogger`

```cpp
// DhNet_Server/DhNet_Server/AccountRepository.cpp
namespace {
    struct DummyInit {
        std::string hash, salt;
        DummyInit()
        {
            bool ok = CryptoUtil::HashPassword("__dummy_password_init__", hash, salt);
            ASSERT_CRASH(ok); // OpenSSL RAND_bytes failure at startup is unrecoverable
        }
    };
    static DummyInit g_dummy;
}
```

`ASSERT_CRASH(ok)` expands (via `DhUtil/Macro.h`) to `CRASH("ASSERT_CRASH")` on failure, which expands
to:

```cpp
LOG_CRITICAL("CRASH: {} ({}:{})", cause, __FILE__, __LINE__);  // GLogger->critical(...)
LoggerShutdown();
*((unsigned __int32*)nullptr) = 0xDEADBEEF;
```

`GLogger` is a `shared_ptr<spdlog::logger>` that stays null until `LoggerInit()` is explicitly called
inside `main()`. `g_dummy`'s constructor runs at static-initialization time, before `main()` starts.
There is no ordering guarantee — and in fact a structural guarantee of the *wrong* order: this
constructor always runs strictly before `LoggerInit()` can possibly run, since `LoggerInit()` is the
first statement inside `main()`'s body.

Today this only manifests if `RAND_bytes` fails (rare, but the comment itself says "OpenSSL RAND_bytes
failure at startup is unrecoverable" — i.e. the code authors anticipated this path firing under real
failure conditions). When it fires, instead of a clean `LOG_CRITICAL` + controlled crash, it
null-derefs inside `GLogger->critical(...)` before `LoggerShutdown()` or the intended crash pointer
write even happen — same failure shape (null deref) but for the wrong reason and with no log line
written at all.

This is precisely the bug class the refactor exists to remove. It was out of this session's literal
file list, but it is in scope for "confirm there are no remaining eager anonymous-namespace global
objects left anywhere relevant" — and it is the one place left in the codebase where this risk is real
and reachable (not merely theoretical), because it both runs pre-`main()` *and* its body can call a
`LOG_*` macro.

**Recommendation**: Either (a) convert `g_dummy` to a function-local static (Meyer's singleton) inside
a `WarmupDummyHash()` function called explicitly from `main()` after `LoggerInit()`, consistent with
the rest of this refactor, or (b) at minimum, replace `ASSERT_CRASH` in this one constructor with a
raw `abort()`/`std::terminate()` that doesn't touch `GLogger`, since logging is provably unavailable
at this point in program lifetime.

### C-NEW. `Shutdown()` sequence added to `main()` is unreachable in normal operation

`GameServer::StartServer()` (`GameServer.cpp:61-88`) ends with:

```cpp
GThreadManager->Launch([=]() { Job(); });   // x N worker threads, each an infinite while(true) loop
...
GThreadManager->Join();                      // blocks until all threads finish — i.e. forever
```

`Job()` (`GameServer.cpp:90-99`) is `while (true) { ... }` with no break. No file in
`ServerCore/Service.cpp`, `GameServer.cpp`, or `main.cpp` registers a `SIGINT` handler or
`SetConsoleCtrlHandler` to request a clean shutdown. Consequently:

- `GameServer::Instance().StartServer();` in `main.cpp:31` never returns under normal operation.
- `mysql_library_end();`, `ServerGlobalShutdown();`, `UtilGlobalShutdown();`, `LoggerDestroy();`, and
  `return 0;` are all unreachable code paths in production use — they only run if `StartServer()`
  itself ever exits the loop, which nothing currently triggers.
- Process termination happens via OS-level kill (Ctrl+C, taskkill, container stop), which does not run
  any of this teardown. The async logger's buffered log lines and the final `flush()` in
  `LoggerShutdown()`/`LoggerDestroy()` are simply never executed — any log lines written in the last
  `flush_every(3s)` window before kill are lost, same as before this refactor.

This means the refactor's explicit teardown ordering, while correctly written, doesn't actually
deliver "guaranteed orderly shutdown" in practice — it delivers "correctly-ordered shutdown code that
never runs." This was *also* true before this session (the old eager-static destructors only run at
static-destruction time, which is likewise after `main` returns — same unreachability), so this is not
a regression. But it means one of the implicit benefits the user may expect from "명시적
Init/Shutdown 패턴" — actually observing clean shutdown logs — will not materialize without separately
adding a signal handler that breaks `Job()`'s loop and lets `StartServer()` return.

**Recommendation**: Out of scope for this fix, but flag as a follow-up: add a `SetConsoleCtrlHandler`
(Windows) or equivalent that sets an atomic stop-flag checked by `Job()`'s loop condition, so
`StartServer()` can return and the new `Shutdown()` chain in `main()` actually executes on
Ctrl+C/service-stop. Without this, consider whether the new shutdown calls in `main()` provide enough
value to justify their presence, or whether they're effectively unreachable dead code today.

---

## Important Improvements

### I1. Init ordering is correct and intentional; verified no Init-time logging dependency violation

`LoggerInit() → UtilGlobalInit() → ServerGlobalInit()` is the right order:
- `DeadLockProfiler`'s constructor (default, trivial) and `GlobalQueue`'s constructor do not call any
  `LOG_*` macro. `LOG_CRITICAL` calls in `DeadLockProfiler.cpp` only occur inside `DFS()` /
  `CheckCycle()`, which run later at runtime when an actual lock-cycle is detected — by which point
  `LoggerInit()` has long since run. So `UtilGlobalInit()` has no hard ordering requirement relative to
  `LoggerInit()` today, but placing `LoggerInit()` first is still the right defensive choice (low cost,
  protects against a future change that adds a constructor-time log call).
- `ThreadManager`'s constructor only calls `InitTLS()` (sets a thread-local ID) — no logging, no use of
  `GDeadLockProfiler`/`GGlobalQueue`. So `ServerGlobalInit()` after `UtilGlobalInit()` has no strict
  ordering requirement either, but is logically consistent (`ThreadManager`'s `Job()`/`PushGlobalQueue`
  methods do use `GGlobalQueue`, so `UtilGlobalInit` before `ServerGlobalInit` is the right call order
  conceptually, just not strictly required at construction time).

Net: the chosen order is correct and defensively sound, even though current constructors don't
strictly require it. Good practice for future-proofing.

### I2. `UtilGlobalShutdown()`/`ServerGlobalShutdown()` nulling pointers after `delete` is a net improvement, not a regression

The original destructors (`~UtilGlobal()`, `~ServerGlobal()`) just did `delete GDeadLockProfiler;` etc.
without nulling afterward — harmless before, because the object (and thus the pointer) ceased to exist
at static-destruction time near process teardown, with nothing left to observe the dangling pointer.
The new explicit functions add `GDeadLockProfiler = nullptr;` / `GGlobalQueue = nullptr;` /
`GThreadManager = nullptr;` after `delete`. This is strictly safer: it converts a potential
use-after-free (if any code ran between `Shutdown()` and process exit and dereferenced these globals)
into a detectable null-pointer crash instead, and it makes double-`Shutdown()` calls idempotent-safe
(second `delete nullptr` is a no-op). No issue here — correctly implemented defensive improvement.

### I3. `ThreadManager::~ThreadManager()` calling `Join()` inside `ServerGlobalShutdown()`'s `delete GThreadManager` is a latent hang risk

Given C-NEW above, this is currently unreachable, but worth noting for whenever the shutdown path
becomes reachable: `ServerGlobalShutdown()` → `delete GThreadManager` → `~ThreadManager()` → `Join()`.
If at that point the worker threads are still spinning in `Job()`'s `while(true)` (which, per C-NEW, is
the only way `StartServer()` returns at all — i.e. something must have already stopped them, or this
would deadlock/hang waiting on `Join()`), this is fine *if and only if* whatever causes `StartServer()`
to return also guarantees all worker threads have already exited their loops. If a future fix for
C-NEW makes `Job()` breakable but doesn't carefully sequence "set stop flag → wait for threads → then
return from StartServer," `ServerGlobalShutdown()` could hang in `Join()` indefinitely. Not a bug in
the current diff, but a constraint the eventual C-NEW fix must respect.

---

## Minor Suggestions

### M1. Header comments in `Logger.h` are a nice touch, consider mirroring in `UtilGlobal.h`/`ServerGlobal.h`

`Logger.h`'s new declarations have explanatory comments (`// main()에서 가장 먼저 호출 — 호출 전에는
GLogger가 null이라 LOG_* 매크로를 쓸 수 없다.` etc.) that make the ordering contract self-documenting at
the call site. `UtilGlobal.h` and `ServerGlobal.h` declare `XxxInit()`/`XxxShutdown()` with no such
comment. Given the whole point of this refactor is "ordering is now manual and must be respected,"
adding a one-line comment to each header (e.g. "must be called after LoggerInit(); must be called
before ServerGlobalInit()") would reduce the chance a future contributor reorders the calls in
`main.cpp` without realizing there's an implicit contract.

### M2. `UtilGlobalShutdown()`/`ServerGlobalShutdown()` have no null-check guard before `delete`

`delete GDeadLockProfiler;` when `GDeadLockProfiler` is already `nullptr` (e.g., `Shutdown()` called
twice, or called without a matching prior `Init()`) is well-defined (`delete nullptr` is a no-op in
C++), so this isn't a bug. Purely stylistic: an explicit `if (GDeadLockProfiler) { delete ...; }` guard
would make the double-shutdown-safety intent more visible to a reader, matching the existing style in
`Logger.cpp`'s `LoggerShutdown()` (`if (GLogger) GLogger->flush();`). Not required.

### M3. `main.cpp` include path style is inconsistent with sibling include

`main.cpp` adds `#include "../../DhUtil/UtilGlobal.h"` (relative path) right next to
`#include "ServerGlobal.h"` (project-relative, presumably resolved via an additional include
directory). This mirrors the existing pattern already used elsewhere in the file
(`#include "ServerSetting.h"` vs whatever resolves `DhUtil` headers project-wide), so it's consistent
with current project convention, not a new inconsistency introduced by this diff — just flagging for
awareness, no action needed.

---

## Architecture Considerations

1. **The refactor achieves its stated narrow goal** (remove the three flagged eager-global-static
   patterns, replace with explicit ordered `Init()`/`Shutdown()` calls from `main()`) correctly and
   without introducing new bugs in the converted code itself.

2. **The refactor does not achieve the broader implied goal** ("eliminate SIOF risk for
   programmer-controlled code in this codebase") because `AccountRepository.cpp`'s `g_dummy` is a
   fourth instance of the exact same anti-pattern, and it's the one instance that has a real (if rare)
   reachable crash path through `GLogger`. If the user's intent was "make sure nothing like this can
   bite us again," this file needs the same treatment, or at least a targeted fix to its `ASSERT_CRASH`
   usage.

3. **Explicit Init/Shutdown ordering is only as good as something actually calling Shutdown.** This
   codebase's main-thread model (`GThreadManager->Join()` blocking on infinite worker loops, no signal
   handler) means `main()`'s teardown code is currently decorative. This isn't something to fix in this
   diff, but it means the user should not assume "we now have guaranteed clean shutdown" — they have
   "we now have correctly-ordered shutdown code that requires a future change (signal/stop-flag
   handling) to actually execute."

4. **No other dangerous eager-global statics were found.** A codebase-wide search for anonymous
   namespaces and global object definitions found only `g_dummy` (flagged above) beyond the three
   intentionally-converted ones. `GameServer::m_singleton` (a `static GameServer m_singleton;` class
   member, not an anonymous-namespace free object) is a separate, pre-existing pattern not in scope for
   this SIOF cleanup — its constructor is trivial (sets two ints to 0) and doesn't touch `GLogger`/
   `GThreadManager`/etc., so it carries no SIOF risk itself, but it's worth knowing it's the one
   remaining "auto-constructed before main()" object in the game-server binary, for completeness.

---

## Next Steps

1. Decide whether to fix `AccountRepository.cpp`'s `g_dummy` now (recommended: convert to a
   `WarmupDummyHash()` function called explicitly from `main()` after `LoggerInit()`, or strip the
   `ASSERT_CRASH`'s dependency on `GLogger` for this one call site) or accept the residual risk and
   track it as a follow-up.
2. Decide whether to address C-NEW (unreachable shutdown path due to no signal handler / infinite
   worker loop) in a follow-up task — this affects whether the new `Shutdown()` calls in `main.cpp`
   deliver real value or remain dead code.
3. No changes needed to the Init() ordering, the Logger.cpp/UtilGlobal.cpp/ServerGlobal.cpp
   implementations, or main.cpp's call sequence as currently written — they correctly implement Option
   B for the three originally-targeted globals.
4. C2 (CRASH macro's unbounded synchronous flush) remains deferred per the user's explicit choice this
   session — not re-flagged here beyond this acknowledgment.
