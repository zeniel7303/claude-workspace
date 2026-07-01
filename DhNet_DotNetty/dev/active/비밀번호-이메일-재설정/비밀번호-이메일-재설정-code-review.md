# 코드 리뷰 — 비밀번호 이메일 재설정
Last Updated: 2026-05-22

---

## 심각도별 이슈

### Critical

#### C-1. `ResetPassword` — 비밀번호 변경과 토큰 소모가 비원자적 (TOCTOU)
**파일:** `GameServer/Web/Controllers/AuthController.cs` (85~86번째 줄)

```csharp
await DatabaseSystem.Instance.Game.Accounts.UpdatePasswordHashAsync(row.account_id, newHash);
await DatabaseSystem.Instance.Game.PasswordResetTokens.MarkUsedAsync(row.token_id);
```

두 쿼리 사이에 같은 토큰으로 두 번째 요청이 들어오면 `used_at`이 아직 NULL이므로 두 번째 요청도 유효 토큰으로 판단된다. 비밀번호가 이미 바뀐 뒤 공격자가 동일 토큰으로 다시 비밀번호를 교체할 수 있다.

**수정 방법:** `MarkUsedAsync`를 먼저 실행하고, affected rows가 1인 경우에만 `UpdatePasswordHashAsync`를 실행하는 방식으로 순서를 뒤집는다. 더 견고하게는 단일 트랜잭션으로 묶거나, `MarkUsedAsync`를 조건부 UPDATE(`WHERE used_at IS NULL`)로 변경해 낙관적 락(optimistic lock)을 적용한다.

```sql
-- MarkUsedAsync 쿼리 개선안
UPDATE `password_reset_tokens`
SET    `used_at` = UTC_TIMESTAMP()
WHERE  `token_id` = @tokenId
  AND  `used_at`  IS NULL
  AND  `expires_at` > UTC_TIMESTAMP()
```

affected rows == 0이면 이미 사용됐거나 만료된 것이므로 400을 반환한다.

---

#### C-2. `ForgotPassword` — `clientOrigin` 미검증으로 Open Redirect / 피싱 메일 생성 가능
**파일:** `GameServer/Web/Controllers/AuthController.cs` (52~55번째 줄)

```csharp
var origin   = req.ClientOrigin?.TrimEnd('/') ?? "";
var resetUrl = string.IsNullOrEmpty(origin)
    ? $"?reset_token={token}"
    : $"{origin}?reset_token={token}";
```

공격자가 `clientOrigin`에 `https://evil.com`을 넘기면 실제 사용자의 이메일에 피싱 URL이 포함된 공식 재설정 메일이 발송된다. 토큰 자체는 서버 DB에 있으므로 직접 위협은 아니지만, 브랜드 신뢰도 훼손과 피싱 경유지로 악용될 수 있다.

**수정 방법:** 서버 설정(appsettings.json)에 `AllowedOrigins` 또는 고정 `BaseUrl`을 두고, 클라이언트 제출값은 무시하거나 화이트리스트 대조 후 사용한다.

```json
// appsettings.json
"Auth": {
  "ResetPasswordBaseUrl": "http://localhost:8081"
}
```

---

### Major

#### M-1. `ResetPassword` — `NewPassword`가 null일 때 NullReferenceException 발생
**파일:** `GameServer/Web/Controllers/AuthController.cs` (71번째 줄)

```csharp
if (req.NewPassword.Length < MinPasswordLength || req.NewPassword.Length > MaxPasswordLength)
```

`ResetPasswordRequest`는 `record`로 선언되어 있으나 `NewPassword`에 `[Required]` 어트리뷰트가 없다. JSON 역직렬화 시 `"newPassword"` 키가 없거나 null이면 `NewPassword`는 `null`이 되고, `.Length` 호출에서 NRE가 발생한다.

**수정 방법:**

```csharp
public record ResetPasswordRequest(string Token, string NewPassword);
```

→ 아래 두 가지 중 하나를 선택한다.

```csharp
// 방법 1: null 가드 추가
if (string.IsNullOrEmpty(req.NewPassword) || ...)

// 방법 2: [Required] 어트리뷰트 (ModelState 자동 검증)
public record ResetPasswordRequest(
    [Required] string Token,
    [Required][MinLength(4)][MaxLength(16)] string NewPassword);
```

`ForgotPasswordRequest`도 동일한 문제를 갖고 있지만, `ForgotPassword`는 null 체크(`string.IsNullOrWhiteSpace`)를 앞에서 수행하므로 현재는 안전하다.

---

#### M-2. `DeleteExpiredAsync` — 매 요청마다 전체 테이블 DELETE, 레이트 리밋 없음
**파일:** `GameServer/Web/Controllers/AuthController.cs` (24번째, 75번째 줄)

`forgot-password`와 `reset-password` 엔드포인트 모두 요청마다 `DeleteExpiredAsync()`를 실행한다. 두 엔드포인트 모두 `/auth/` 하위이므로 ApiKey·IP 제한이 없다. 공격자가 수백 rps로 요청을 보내면 매 요청마다 DELETE 쿼리가 실행되어 DB에 과부하가 걸릴 수 있다.

**수정 방법:** 두 가지 방향이 있다.
1. `IMemoryCache` 또는 `Interlocked`로 마지막 실행 시각을 추적하여 최소 5~10분 간격으로만 실행한다.
2. 정리 작업을 백그라운드 `IHostedService`(주기적 삭제)로 분리하고, 엔드포인트에서는 제거한다.

---

#### M-3. `ForgotPassword` — Rate Limiting 없음 (토큰 스팸 + 메일 폭탄)
**파일:** `GameServer/Web/Controllers/AuthController.cs` (17~60번째 줄)

IP 화이트리스트와 API 키가 `/auth/` 경로에서 제외되어 있으므로, 계정 일치 조건을 충족하는 공격자는 반복 호출로 DB에 유효 토큰을 무한히 쌓고 대상 이메일 주소에 재설정 메일을 반복 발송할 수 있다.

**수정 방법:** ASP.NET Core 8+의 내장 `AddRateLimiter`를 사용하거나, IP 기반 간단한 카운터 미들웨어를 적용한다. forgot-password는 동일 username 기준으로 슬라이딩 윈도우(예: 5분에 3회)를 적용하는 것이 적절하다.

---

#### M-4. `SmtpService` — `SecureSocketOptions.StartTls` 하드코딩
**파일:** `GameServer/Auth/SmtpService.cs` (62번째 줄)

```csharp
await client.ConnectAsync(_host, _port, SecureSocketOptions.StartTls);
```

일부 SMTP 제공자(예: Gmail 465 포트)는 `SslOnConnect`를 요구한다. 현재 설정에서는 포트 465로 연결하면 실패한다. 운영 환경에 따라 연결 방식이 고정되어 있어 설정만으로 전환이 불가하다.

**수정 방법:** `Smtp:UseSsl` (bool) 설정 키를 추가하고, true이면 `SslOnConnect`, false이면 `StartTls`를 사용하도록 분기한다.

---

### Minor

#### m-1. 토큰 생성 방식 — SHA-256(Guid)은 CSPRNG 대비 엔트로피 손실
**파일:** `GameServer/Web/Controllers/AuthController.cs` (41~42번째 줄)

```csharp
var rawBytes = SHA256.HashData(Guid.NewGuid().ToByteArray());
var token    = Convert.ToHexString(rawBytes).ToLower();
```

`Guid.NewGuid()`는 122비트 엔트로피를 제공하며, SHA-256을 적용해도 엔트로피는 줄어들지 않는다. 실용적으로 안전하지만, 관용적으로는 아래가 더 명확하고 권장된다.

```csharp
var rawBytes = RandomNumberGenerator.GetBytes(32); // 256비트 직접 생성
var token    = Convert.ToHexString(rawBytes).ToLower();
```

`Convert.ToHexString`은 대문자를 반환하므로 `.ToLower()` 호출이 필요하다. 또는 처음부터 소문자 hex 포맷터를 사용해 할당을 줄일 수 있다.

---

#### m-2. `PasswordResetTokenRow.expires_at` — `DateTime` vs `DateTime UTC` 일관성 주의
**파일:** `GameServer.Database/Rows/PasswordResetTokenRow.cs` (10번째 줄)  
**파일:** `GameServer/Web/Controllers/AuthController.cs` (79번째 줄)

```csharp
|| row.expires_at < DateTime.UtcNow
```

Dapper가 `DATETIME` 컬럼을 읽으면 `DateTimeKind.Unspecified`로 반환한다. `DateTime.UtcNow`는 `DateTimeKind.Utc`다. `DateTimeKind`가 다른 두 값을 `<` 비교하면 값은 같지만 Kind가 다르므로 비교 자체는 내부적으로 Ticks 기준으로 동작해 현재는 정상 작동하지만, 혼동 가능성이 있다.

**수정 방법:** `SelectByTokenAsync`에서 Dapper 컬럼 매핑 후 `expires_at`에 `DateTime.SpecifyKind(row.expires_at, DateTimeKind.Utc)`를 적용하거나, `PasswordResetTokenRow`의 프로퍼티를 `DateTimeOffset`으로 변경한다.

---

#### m-3. `AuthController` — `DatabaseSystem.Instance` 정적 접근 (DI 일관성)
**파일:** `GameServer/Web/Controllers/AuthController.cs` (전반)

`SmtpService`는 생성자 DI로 주입받지만, `DatabaseSystem.Instance`는 직접 정적 접근한다. 테스트 작성 시 DB를 모킹할 수 없다. 프로젝트 전반의 패턴이 정적 싱글톤이라면 일관성은 있으나, 컨트롤러만큼은 인터페이스 DI를 고려할 가치가 있다.

---

#### m-4. `SmtpService` — 메일 발송 로그에 이메일 주소 전체 노출
**파일:** `GameServer/Auth/SmtpService.cs` (66번째 줄)

```csharp
GameLogger.Info("Smtp", $"비밀번호 재설정 메일 발송: {toEmail}");
```

운영 로그에 이메일 주소가 평문으로 기록된다. GDPR/개인정보보호 관점에서 `toEmail`을 마스킹(`a***@example.com`)하거나 hash prefix만 기록하는 것이 권장된다.

---

#### m-5. `ForgotPassword` — `clientOrigin` 값이 URL 인젝션에 취약
**파일:** `GameServer/Web/Controllers/AuthController.cs` (52~55번째 줄)

`origin`에 공백·개행 문자가 포함되면 메일 클라이언트에 따라 헤더 인젝션과 유사한 렌더링 문제가 발생할 수 있다. C-2 수정(서버 측 고정 URL)으로 자동 해소되지만, 현재 코드 기준으로는 `Uri.IsWellFormedUriString(origin, UriKind.Absolute)` 검증을 추가해야 한다.

---

#### m-6. `game.js` — `doResetPassword`에서 비밀번호 길이를 클라이언트에서만 1차 검증
**파일:** `GameClient.Web/wwwroot/js/game.js` (1801번째 줄)

```javascript
if (!newPassword) { setStatus('reset-status', '새 비밀번호를 입력해주세요.'); return; }
```

빈 문자열 체크만 있고 4~16자 범위 검증이 클라이언트에 없다. 서버에서는 검증하지만, 사용자 경험 차원에서 클라이언트 측 길이 검증도 추가하는 것이 좋다.

---

#### m-7. `WebServerHost` — DEBUG/Release 스코프 중복 (`#if DEBUG` + `if Development`)
**파일:** `GameServer/Web/WebServerHost.cs` (44~53번째 줄)

```csharp
#if DEBUG
    app.UseSwagger();
    app.UseSwaggerUI();
#else
    if (app.Environment.IsDevelopment())
    {
        app.UseSwagger();
        app.UseSwaggerUI();
    }
#endif
```

Release 빌드에서 `DOTNET_ENVIRONMENT=Development`로 실행 시 Swagger가 노출된다. 의도한 동작이라면 주석으로 명시가 필요하고, 의도하지 않았다면 `#if DEBUG`만 남기고 else 분기를 삭제한다.

---

#### m-8. `AccountDbSet.SelectByEmailAsync` — 현재 미사용
**파일:** `GameServer.Database/DbSet/AccountDbSet.cs` (39~48번째 줄)

`ForgotPassword`에서 `SelectByUsernameAsync`를 사용하고 `SelectByEmailAsync`는 사용하지 않는다. 사용 계획이 없다면 제거하거나 `// Reserved for future use` 주석을 추가한다.

---

## 긍정적 평가

1. **계정 열거 방지 완벽 적용** — `ForgotPassword`에서 계정 일치 여부와 무관하게 항상 동일한 `genericOk` 문자열을 반환한다. 응답 시간 차이도 SMTP 발송 유무에 의존하지만, 서버는 결과를 기다리지 않는다 (`await smtp.SendPasswordResetAsync`는 반환값을 무시). 이 패턴은 올바르다.

2. **BCrypt workFactor 중앙화** — `AuthConstants.BcryptWorkFactor = 11`로 단일 소스 관리. `RegisterProcessor`, `LoginProcessor`, `AuthController` 모두 동일 상수를 참조한다.

3. **토큰 1회용 보장 (used_at 컬럼)** — `used_at IS NOT NULL`을 애플리케이션 레이어에서 체크하고, DB에도 `used_at` 컬럼을 두어 이중 보호. C-1 이슈를 수정하면 완전해진다.

4. **`Task.Run`으로 BCrypt 블로킹 분리** — BCrypt (~200ms)를 `Task.Run`으로 ThreadPool에 위임해 ASP.NET Core의 요청 처리 스레드를 블로킹하지 않는다.

5. **토큰 만료 + used_at 이중 검증** — `row.used_at.HasValue || row.expires_at < DateTime.UtcNow` 두 조건 모두 확인한다.

6. **만료 토큰 정리 전략 존재** — `DeleteExpiredAsync()`로 누적 방지 로직 보유. M-2에서 개선 방향을 제시했지만 설계 의도 자체는 올바르다.

7. **SmtpService 비활성화 graceful 처리** — SMTP 설정 누락 시 false 반환, 호출자는 무시하고 정상 응답. 개발 환경에서 SMTP 없이도 동작 가능.

8. **DB 레이어 SQL 파라미터화** — Dapper 바인딩 전용 (`@token`, `@accountId`). SQL 인젝션 없음.

9. **클라이언트 측 reset_token 자동 감지** — `DOMContentLoaded`에서 URL 파라미터를 확인해 재설정 화면으로 자동 라우팅. 사용자 경험 양호.

---

## 최종 판정

| 항목 | 평가 |
|------|------|
| 보안 설계 | 기본 골격은 견고하나 C-1, C-2 두 Critical 이슈 수정 필요 |
| C# 패턴 | async/await, DI, ThreadPool 분리 모두 올바름 |
| DB 레이어 | Dapper 파라미터화, INSERT IGNORE 활용 양호 |
| 엣지 케이스 | NRE 리스크(M-1) 및 Race Condition(C-1) 보완 필요 |
| 전체 | **수정 후 머지 권장 (Conditional Approve)** |

### 필수 수정 (머지 전)
- **C-1**: `MarkUsedAsync` 조건부 UPDATE + 순서 역전 (토큰 소모 → 비밀번호 변경)
- **C-2**: `clientOrigin` 서버 측 화이트리스트 또는 고정 설정키로 대체
- **M-1**: `req.NewPassword` null 가드 또는 `[Required]` 어트리뷰트 추가

### 권장 수정 (머지 후 가능)
- M-2: `DeleteExpiredAsync` 호출 빈도 제한 또는 백그라운드 서비스 분리
- M-3: `/auth/forgot-password` Rate Limiting 적용
- m-1: `RandomNumberGenerator.GetBytes(32)` 직접 사용
- m-4: 로그 내 이메일 마스킹
