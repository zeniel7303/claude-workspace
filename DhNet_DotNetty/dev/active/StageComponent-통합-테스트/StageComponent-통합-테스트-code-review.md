# 코드 리뷰
Last Updated: 2026-05-29

## 발견사항

### 1. IRoomContext 인터페이스 설계 — 범위 적절, 단 `internal` 일관성 주의

**판정: 양호 (경미한 개선 가능)**

`IRoomContext`가 노출하는 3개 멤버(`RoomId`, `GetPlayers()`, `BroadcastPacket()`)는 `StageComponent`가 실제로 사용하는 최소 집합과 정확히 일치한다. ISP(Interface Segregation Principle) 관점에서 적절하다.

단, 주의할 점:

- `GetPlayers()`의 반환 타입이 `IReadOnlyList<PlayerComponent>`인데, `PlayerComponent`는 `public` 클래스다. `internal interface`가 `public` 타입을 반환하는 구조는 모순이 없지만, 장기적으로 인터페이스를 `internal`로 유지하는 한 외부 어셈블리에서 `IRoomContext`를 구현할 수 없다. 현재 테스트 전용 목적에서는 문제없으나, 추후 확장 시 `public`으로 격상할 필요가 생길 수 있다.
- `StageComponent` 클래스 자체는 `public`인데 생성자가 `internal`이다(`internal StageComponent(IRoomContext room)`). `InternalsVisibleTo`로 테스트 프로젝트에서 접근하는 구조는 올바르지만, `StageComponent`를 `public`으로 유지하면서 생성자만 `internal`인 비대칭이 API 혼란을 줄 수 있다. `StageComponent`를 `internal sealed`로 격상하거나, 생성자를 `public`으로 열고 `IRoomContext`도 `public`으로 올리는 방향을 고려할 수 있다.

---

### 2. `SessionComponent`에 `virtual` 추가 — 안전하나 봉인 미흡

**판정: 양호 (개선 권장)**

`IsConnected`, `SendAsync`, `ClearPacketQueue` 세 멤버에 `virtual`을 추가한 것은 `FakeSession : SessionComponent` 패턴을 위한 최소 변경으로 적절하다.

문제:
- `SessionComponent`는 `sealed`가 아니므로 기존에도 상속이 열려 있었지만, `virtual` 추가로 의도치 않은 파생 클래스에서 오버라이드가 가능해졌다. `Channel`을 `null`로 전달했을 때 `Dispose()`에서 `Channel.CloseAsync()`를 호출하면 `NullReferenceException`이 발생한다. `FakeSession`은 `Dispose()`를 오버라이드하지 않으므로, 테스트에서 `FakeSession.Dispose()`가 호출될 경우 NPE 위험이 있다.

권장 수정:
```csharp
// SessionComponent.Dispose()에 null 가드 추가
if (Channel != null)
{
    _ = Channel.CloseAsync().ContinueWith(...);
}
```
또는 `FakeSession`에서 `Dispose()`를 오버라이드하여 기반 클래스 호출을 막는다.

---

### 3. `FakeSession base(null!)` 패턴의 안전성 — 조건부 안전

**판정: 주의 필요**

`internal FakeSession() : base(null!)` 은 컴파일러 null 검사를 억제하는 패턴이다. 현재는 안전한데 그 이유는:
- `SessionComponent` 생성자가 `channel`을 `Channel` 프로퍼티에 저장만 하고 즉시 사용하지 않기 때문이다.
- `FakeSession`이 채널 접근 경로(`IsConnected`, `SendAsync`, `ClearPacketQueue`)를 모두 오버라이드한다.

위험 경로:
- `SessionComponent.Dispose()`가 `Channel.CloseAsync()`를 호출한다 (위 2번과 동일).
- `ProcessPacket()`은 오버라이드되지 않았으나 `Channel`에 접근하지 않으므로 현재는 안전하다.

리뷰 결론: 현재 테스트에서 `FakeSession.Dispose()`가 호출되지 않는 한 안전하다. 그러나 `IClassFixture` 또는 `xUnit` teardown 경로에서 묵시적으로 호출될 가능성을 배제하기 위해 다음을 추가하는 것이 방어적이다:

```csharp
internal sealed class FakeSession : SessionComponent
{
    // ... 기존 코드 ...

    // Channel=null이므로 기반 Dispose()의 Channel.CloseAsync() NPE 방지
    protected override void Dispose(bool disposing) { /* no-op */ }
}
```

단, `SessionComponent`가 현재 `IDisposable`을 직접 구현하며 `Dispose(bool)` 패턴을 사용하지 않는다(단일 `public void Dispose()` 메서드). 이 경우 오버라이드가 불가하므로 `SessionComponent.Dispose()`에 null 가드를 추가하는 것이 근본 해결책이다.

---

### 4. `RuntimeHelpers.GetUninitializedObject` 남용 여부 — 필요악, 허용 가능

**판정: 허용 (단, 주석 충분히 유지)**

`PlayerComponent`는 생성자에서 `WorkerSystem`, `SessionComponent`, DB 레이어를 초기화하며 테스트 환경에서 실행이 불가하다. `GetUninitializedObject`로 생성자를 건너뛰고 리플렉션으로 필드를 주입하는 방식은 이 상황에서 합리적인 선택이다.

다만 주의 사항:

1. **컴파일러 생성 필드명 의존**: `<AccountId>k__BackingField` 형식의 필드명은 컴파일러 구현 세부사항이다. `PlayerComponent`의 auto-property가 `{ get; set; }`로 변경되거나 필드가 명시적으로 리팩토링되면 `null` 반환 시 런타임 `NullReferenceException`으로 테스트가 깨진다. 현재 `!` 연산자로 null을 억제하고 있어 디버깅이 어려울 수 있다.

권장: 필드 조회 실패 시 명시적 오류를 던지는 헬퍼로 보강한다.
```csharp
private static FieldInfo RequireField(Type type, string name, BindingFlags flags)
    => type.GetField(name, flags)
       ?? throw new InvalidOperationException($"리플렉션 필드 '{name}' 없음 — PlayerComponent 구조 변경 확인 필요");
```

2. **`PlayerSaveComponent(null!)`**: `MakePlayer`에서 `SaveField.SetValue(p, new PlayerSaveComponent(null!))` 패턴이 쓰인다. `PlayerSaveComponent._player`가 `null`인 상태에서 `MarkDirty()` 이외의 메서드가 호출되면 NPE가 발생한다. 현재 테스트 범위에서는 `Save`에 접근하는 경로가 없으므로 안전하지만, 향후 테스트 확장 시 위험 요소다.

---

### 5. 테스트 코드 품질

**판정: 양호**

**잘 된 점:**
- TC-1~TC-4가 명확한 Given/When/Then 구조를 따른다.
- `IClassFixture<GameDataFixture>`로 `GameDataTable` 로드를 1회만 수행하는 설계가 올바르다.
- `FakeRoomContext.Broadcasts`를 통한 패킷 캡처 방식이 깔끔하다.
- `_endedFlag` 멱등성(TC-2)을 별도 케이스로 분리한 것은 동시성 회귀를 방지하는 좋은 관행이다.

**누락된 테스트 케이스:**

| 시나리오 | 우선순위 | 설명 |
|---|---|---|
| ProcessAttack 입력 큐 경계 | 중 | `_endedFlag=1` 후 `ProcessAttack` 호출 시 큐에 적재되지 않음을 검증 |
| ClearMonsters 후 전원 생존 | 낮 | 몬스터 없는 상태에서 Update()가 정상 종료되는지 |
| 생존 타이머 10초 알림 | 낮 | `NotiSurvivalTime` 패킷이 10초마다 브로드캐스트되는지 |
| ProcessMove 위치 갱신 | 중 | `NotiMove` 패킷에 플레이어 좌표가 포함되는지 |
| UnregisterPlayer | 낮 | 퇴장 플레이어가 다음 틱 무기 계산에서 제외되는지 |

---

### 6. `AssemblyInfo.cs` 위치 — 적절

**판정: 양호**

`GameServer/AssemblyInfo.cs`에 `[assembly: InternalsVisibleTo("GameServer.Tests")]`를 별도 파일로 분리한 것은 올바른 관행이다. 다만 `GameServer.Tests` 프로젝트가 서명(strong name)된다면 public key token도 함께 지정해야 한다. 현재는 서명 미사용이므로 무관하다.

---

## 총평

전체적으로 완성도 높은 테스트 인프라다. 인터페이스 추출 → `InternalsVisibleTo` → Fake 구현체 패턴이 일관성 있게 적용되었다.

**필수 수정 (즉시):**
- `SessionComponent.Dispose()`에 `Channel != null` 가드 추가 → `FakeSession` NPE 위험 제거

**권장 수정 (다음 PR):**
- `StageTestHelpers`의 리플렉션 필드 조회에 명시적 null 체크 + 오류 메시지 추가
- TC 추가: `ProcessAttack`의 `_endedFlag=1` 조기 반환 경로, `NotiMove` 패킷 검증
