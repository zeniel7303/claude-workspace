# 비밀번호 이메일 재설정 — 구현 컨텍스트

Last Updated: 2026-05-22

## 현재 상태

**구현 완료** — 모든 Phase(1~5) 완료, 빌드 검증 통과 (경고 0, 오류 0).
실제 동작 테스트 및 Smtp 자격증명 설정은 사용자 처리 필요.

---

## 수정/생성된 파일 목록

### DB 스키마 (Phase 1)
- `Bin/db/schema_game.sql` — accounts.email 컬럼 + password_reset_tokens 테이블 추가

### DB 레이어 (Phase 2)
- `GameServer.Database/Rows/AccountRow.cs` — `public string? email { get; set; }` 추가
- `GameServer.Database/DbSet/AccountDbSet.cs`
  - `InsertAsync`: email 컬럼 포함
  - `SelectByUsernameAsync`: email SELECT 포함
  - `SelectByEmailAsync` 신규 추가
  - `UpdatePasswordHashAsync` 신규 추가
- `GameServer.Database/Rows/PasswordResetTokenRow.cs` — 신규 생성
- `GameServer.Database/DbSet/PasswordResetTokenDbSet.cs` — 신규 생성 (Insert, SelectByToken, MarkUsed, DeleteExpired)
- `GameServer.Database/System/GameDbContext.cs` — `PasswordResetTokenDbSet PasswordResetTokens` 추가

### Proto (Phase 3)
- `GameServer.Protocol/Protos/register.proto` — `string email = 3` 추가 (선택 필드)
- `GameServer/Auth/RegisterProcessor.cs` — `req.Email` 읽어 AccountRow.email에 저장

### 서버 HTTP (Phase 4)
- `GameServer/GameServer.csproj` — `MailKit 4.16.0` 추가
- `GameServer/Auth/SmtpService.cs` — 신규 생성 (MailKit 기반 SMTP 발송, 미설정 시 graceful 건너뜀)
- `GameServer/appsettings.json` — `Smtp` 섹션 추가 (Host/Port/Username/Password/SenderEmail/SenderName)
- `GameServer/Web/Controllers/AuthController.cs` — 신규 생성
- `GameServer/Web/WebServerHost.cs`
  - `builder.Services.AddSingleton<SmtpService>()` 추가
  - UseWhen 미들웨어 분리: RequestLogging 전체, IpWhitelist+ApiKey는 /auth/ 제외

### 웹 클라이언트 (Phase 5)
- `GameClient.Web/wwwroot/index.html`
  - 등록 폼에 이메일 필드(reg-email, 선택) 추가
  - 로그인 폼에 "비밀번호를 잊으셨나요?" 링크 추가
  - `screen-forgot-password` 패널 추가
  - `screen-reset-password` 패널 추가
- `GameClient.Web/wwwroot/js/game.js`
  - `screens` 배열에 `'forgot-password'`, `'reset-password'` 추가
  - `doRegister()` — email 필드 포함
  - `showForgotPassword()`, `doForgotPassword()`, `doResetPassword()` 함수 추가
  - `DOMContentLoaded` — reset_token 쿼리파라미터 감지 시 reset-password 화면 진입
  - `Object.assign(window, {...})` 에 새 함수 등록

---

## 핵심 아키텍처 결정사항

### 1. 공개 엔드포인트 분리
`/auth/` 경로는 ApiKeyMiddleware + IpWhitelistMiddleware를 건너뜀.
RequestLoggingMiddleware는 그대로 적용 (감사 로그 목적).

### 2. 계정 열거 공격 방지
`forgot-password` 엔드포인트: 계정 존재 여부와 무관하게 동일한 응답 반환.
username + email 양쪽이 일치해야만 토큰 생성 (단방향 조회로 보안 강화).

### 3. SmtpService 미설정 시 Graceful 처리
`Smtp:Username` 또는 `Smtp:Password`가 빈 문자열이면 SMTP 발송 비활성화.
서버 응답은 정상 반환 (개발 환경에서 실제 이메일 없이도 동작).

### 4. 리셋 URL 동적 생성
클라이언트가 `clientOrigin: window.location.origin`을 요청에 포함.
서버가 이를 사용해 `{clientOrigin}?reset_token={token}` 링크 생성.
Docker/로컬 모두 대응.

### 5. 토큰 형식
`Convert.ToHexString(SHA256.HashData(Guid.NewGuid().ToByteArray())).ToLower()` — 64자 소문자 hex.

### 6. MailKit 버전
최초 4.8.0 추가 시 보안 취약성 경고 발생 → 즉시 4.16.0으로 업그레이드.

---

## 발견된 문제 및 해결

### CS0051 접근성 오류
`AuthController.cs`의 record 타입이 `internal`이었는데 public 메서드 파라미터로 사용됨.
→ `public record ForgotPasswordRequest(...)` / `public record ResetPasswordRequest(...)` 로 수정.

---

## 사용자가 추가로 해야 할 작업

1. **Smtp 자격증명 설정**: `appsettings.json` 또는 Docker 환경변수로 Gmail App Password 입력
   - Gmail: https://myaccount.google.com/apppasswords
   - Docker 권장 방식: `docker-compose.yml`에 `Smtp__Username` / `Smtp__Password` 환경변수 추가

2. **기존 DB 마이그레이션**: 이미 생성된 gameserver DB가 있다면:
   ```sql
   ALTER TABLE `accounts` ADD COLUMN `email` VARCHAR(255) DEFAULT NULL AFTER `password_hash`;
   ALTER TABLE `accounts` ADD UNIQUE KEY `ux_accounts_email` (`email`);
   -- password_reset_tokens 테이블은 schema_game.sql 전체 재실행 또는 CREATE TABLE 직접 실행
   ```

3. **테스트 절차**:
   - 계정 생성 시 이메일 입력 후 가입
   - 로그인 화면 "비밀번호를 잊으셨나요?" 클릭
   - 이메일 수신 확인 및 링크 클릭
   - 새 비밀번호 입력 및 변경 확인

---

## 다음 작업 후보

이 기능은 완료됨. 남은 예정 작업:
- 없음 (알려진 예정 작업 소진)
