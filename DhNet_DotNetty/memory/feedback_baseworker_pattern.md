---
name: BaseWorker 패턴
description: BaseWorker 구현 시 record struct+TryUpdate 대신 sealed class 직접 할당 패턴 사용
type: feedback
---

`record struct WorkerEntry` + `TryUpdate` 패턴 대신 `sealed class WorkerItem` + 직접 할당 패턴을 사용한다.

**Why:** 사용자가 `record struct` + `TryUpdate(... entry with { LastTicks = nowTicks }, entry)` 조합을 "불편하고 복잡하다"고 판단. 참고 서버의 구현 방식을 기준으로 삼는다.

**How to apply:** `BaseWorker<T>` 또는 유사한 워커 클래스 작성 시:
- `LastTicks` 같은 가변 상태는 `sealed class`로 래핑해 참조 타입으로 직접 변경
- `TryUpdate` 사용 금지
- ticks→초 변환은 `1f / TimeSpan.TicksPerSecond` 상수 사용 (`10_000_000f` 하드코딩 금지)
- `nowTicks`는 항목별 루프 내에서 측정 (루프 바깥 공유 X)
