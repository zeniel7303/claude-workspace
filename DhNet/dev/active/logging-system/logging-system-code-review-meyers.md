# Logger Meyer's Singleton — Code Review

**Scope**: `DhUtil/Logger.h`, `DhUtil/Logger.cpp`, `DhUtil/Macro.h` (final state, this session only)
**Out of scope**: C2 (unbounded synchronous `flush()` in `LoggerShutdown()` — explicitly deferred by user)
**Reviewer**: code-architecture-reviewer persona

---

## Executive Summary

The change replaces the eagerly-constructed global `GLogger` (anonymous-namespace `LoggerInit` object) with a Meyer's Singleton: `Logger::Get()` returns a reference to a function-local `static shared_ptr<spdlog::logger>`, lazily constructed via `CreateLogger()` on first call. This correctly and completely eliminates the Static Initialization Order Fiasco (C1) that was the subject of the prior review. All 6 `LOG_*` macros and the `CRASH`/`ASSERT_CRASH` macros now route through `Logger::Get()`, preserving identical call-site syntax. No stale references to the old `GLogger` symbol remain anywhere in the codebase. The fix is minimal, idiomatic, and verifiably correct for its stated purpose. One genuine (low-severity, pre-existing-in-spirit) shutdown-order subtlety exists around `LoggerShutdownGuard` vs. other static destructors, detailed below, but it degrades gracefully rather than crashing.

## Critical Issues

None found in the scoped change.

## Important Improvements

**I1 — `LoggerShutdownGuard`'s effect is currently a no-op for the logger itself, and its destructor-order relationship with `Logger::Get()`'s static is unspecified, which could silently drop the final flushed logs at process exit.**

- `CreateLogger()` builds the `async_logger` via `make_shared` directly and **never calls `spdlog::register_logger()`**. This means the logger is never inserted into spdlog's global `registry::loggers_` map.
- Consequently, `spdlog::shutdown()` → `registry::drop_all()` clears a registry that doesn't contain "dhnet" anyway — it has zero effect on `Logger::Get()`'s own `shared_ptr` (separate storage, a function-local static in `Logger.cpp`). The only real effect of `spdlog::shutdown()` here is resetting `tp_` (registry's `shared_ptr<thread_pool>`), which is the **same thread pool object** the async_logger references via `weak_ptr<thread_pool> thread_pool_` (set up by `spdlog::thread_pool()` in `CreateLogger()`, which returns the registry's pool).
- Static destruction order between `GLoggerShutdownGuard` (anonymous-namespace, namespace-scope static in `Logger.cpp`, constructed unconditionally at static-init time) and `Logger::Get()`'s function-local `static instance` (constructed lazily on first call, almost certainly also during static init given `g_dummy`/`GUtilGlobal`/`GServerGlobal` call `LOG_*`/`ASSERT_CRASH` from their own constructors) is **not fixed by source order** — it depends purely on which one is constructed first at runtime, since C++ destroys statics in exact reverse order of completed construction.
  - If `instance` constructs *before* `GLoggerShutdownGuard` (likely, since other eager globals tend to run early and call into the logger): `GLoggerShutdownGuard` destructs first, runs `spdlog::shutdown()`, which resets the shared thread pool. `instance`'s own destructor then runs (drops the last `shared_ptr<logger>` reference) — by this point the thread pool is already gone, but the async_logger's destructor doesn't synchronously flush, so this is harmless.
  - If anything calls `LOG_*`/`LoggerShutdown()` *after* `GLoggerShutdownGuard`'s destructor has run but *before* `instance`'s destructor runs (e.g., another global's destructor that logs during static teardown) — `async_logger::sink_it_`/`flush_` does `thread_pool_.lock()`, which now fails (pool gone), and throws `spdlog_ex` internally. This is **caught internally** by spdlog's own `SPDLOG_TRY`/`SPDLOG_LOGGER_CATCH` (confirmed in `async_logger-inl.h`) — so it does **not propagate or crash**, it just silently drops that log line.
- **Net effect**: no crash, no double-free, no UB. Worst case is a silently swallowed log message during the very tail of static destruction at process exit. This is a real but low-severity gap — recommend either (a) calling `spdlog::register_logger()` in `CreateLogger()` so `shutdown()`/`drop_all()` actually manage the logger as designed, or (b) removing `LoggerShutdownGuard` entirely and instead relying on `instance`'s own destructor (running `spdlog::shutdown()` is arguably unnecessary once nothing else can reach the logger after its own static teardown) and just letting RAII handle it. As-is it's not wrong, just slightly vestigial/inconsistent with spdlog's intended ownership model.

## Minor Suggestions

- **Returning `shared_ptr<spdlog::logger>&` instead of by value**: appropriate here. This avoids an atomic refcount increment/decrement on every single `LOG_*` call (which would be by-value's cost), at the price of handing out a reference to static storage — acceptable since the reference's lifetime is the entire program and call sites only dereference it immediately (`Get()->info(...)`) rather than storing it. No dangling risk given current usage patterns (confirmed: no call site anywhere stores the returned reference past the statement).
- `Logger.h`'s Korean comment (line 5-6) clearly documents the SIOF rationale — good practice, keep this as a permanent guardrail comment so a future contributor doesn't "simplify" this back into an eager global.
- `CreateLogger()` is anonymous-namespace-scoped (internal linkage), appropriately hidden from other TUs — good encapsulation.
- Minor naming nit: `GLoggerShutdownGuard` retains the `G`-prefix global-naming convention even though it's anonymous-namespace/internal-linkage and not really a "global" in the same sense as `GThreadManager`/`GDeadLockProfiler`. Not a real issue, just an inconsistency worth noting if the team tightens naming conventions later.

## Architecture Considerations

- **Thread-safety of the Meyer's Singleton**: `Logger::Get()`'s function-local `static std::shared_ptr<spdlog::logger> instance = CreateLogger();` is guaranteed thread-safe and exactly-once-initialized per C++11 §6.7 (dynamic initialization of function-local statics is guarded by the compiler with an internal mutex/flag on all targets this project supports — MSVC included). No subtlety found:
  - No recursive re-entrant call into `Logger::Get()` happens during `CreateLogger()`'s execution (verified: `CreateLogger()` only calls `spdlog::init_thread_pool`, sink/logger construction, and `set_level`/`set_pattern`/`flush_on`/`flush_every` — none of which call back into `Logger::Get()` or any `LOG_*` macro).
  - Exception safety: if `CreateLogger()` throws (e.g., `rotating_file_sink_mt` failing to open `logs/dhnet-server.log`), the C++11 standard guarantees the static remains "not yet initialized" and the **next** call to `Get()` will retry construction from scratch — no half-constructed/poisoned state is observable. This is strictly better than the old eager-global approach, where a throwing constructor during static init before `main()` would call `std::terminate()` with no retry possible.
  - No deadlock risk: the standard's exactly-once guard does not require recursion guarding against a *different* thread blocking on the same initialization-in-progress flag in a way that could deadlock with this codebase's own `DhUtil` Lock primitives, since `CreateLogger()` never acquires a `DhUtil::Lock`.
- **Confirms the project-wide reasoning holds**: `GUtilGlobal` (`DhUtil/UtilGlobal.cpp`), `GServerGlobal` (`DhNet_Server/ServerGlobal.cpp`), and `AccountRepository.cpp`'s `g_dummy` all remain eager anonymous/named-namespace globals, unchanged this session. Verified `g_dummy`'s constructor literally calls `ASSERT_CRASH(ok)` → `CRASH(...)` → `LOG_CRITICAL(...)` → `Logger::Get()->critical(...)` — this is precisely the call path that was unsafe under the old `GLogger` scheme (a real, not hypothetical, SIOF exposure) and is now safe under Meyer's Singleton regardless of inter-TU static-init order, because `Logger::Get()` lazily self-constructs on literally the first invocation, whichever global's constructor happens to make it. This claim is confirmed correct with no remaining counter-example found in the current codebase.
- The one residual edge case (shutdown-order interaction between `LoggerShutdownGuard` and other globals' destructors at program *exit*, see I1) is real but architecturally minor: it cannot manifest as a crash because spdlog itself swallows the resulting exception, and it was never claimed to be solved by this change — the Meyer's Singleton fix targeted construction-order (program entry), not destruction-order (program exit), and that scoping is appropriate and consistent with what was asked for this session.
- Macro call-site compatibility confirmed: `Logger::Get()` returns `shared_ptr<spdlog::logger>&`, identical to what the old `GLogger` (itself a `shared_ptr<spdlog::logger>`) supported for `->trace/debug/info/warn/error/critical(...)`. Grepped the full codebase (20 `.cpp` files using `LOG_*`/`CRASH`/`ASSERT_CRASH`) — none reference `GLogger`, `Logger::Get()`, or `LoggerShutdown()` directly except through the macros, so no call site needed updating and none was missed.

## Next Steps

1. (Optional, low priority) Decide whether `CreateLogger()` should call `spdlog::register_logger()` so `LoggerShutdownGuard`'s `spdlog::shutdown()` call has its originally-intended effect on this logger, or alternatively simplify by removing the registry-shutdown guard since it currently shuts down a registry the logger was never enrolled in.
2. No action required for the SIOF fix itself — it is complete and correct for the stated scope (C1 closed).
3. C2 (unbounded synchronous flush in `LoggerShutdown()`/`CRASH`) remains open and deferred, as agreed — no action this session.
