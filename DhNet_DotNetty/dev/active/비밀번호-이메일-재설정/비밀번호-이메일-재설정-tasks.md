# 비밀번호 이메일 재설정 — 체크리스트

Last Updated: 2026-05-22

## Phase 1: DB 스키마
- ✅ `Bin/db/schema_game.sql`: accounts.email 컬럼 추가
- ✅ `Bin/db/schema_game.sql`: password_reset_tokens 테이블 추가

## Phase 2: DB 레이어
- ✅ `AccountRow.cs`: email 필드 추가
- ✅ `AccountDbSet.cs`: UpdatePasswordHashAsync, SelectByEmailAsync 추가 + InsertAsync/SelectByUsernameAsync에 email 포함
- ✅ `PasswordResetTokenRow.cs` 신규
- ✅ `PasswordResetTokenDbSet.cs` 신규
- ✅ `GameDbContext.cs`: PasswordResetTokens 추가

## Phase 3: Proto
- ✅ `register.proto`: email = 3 추가
- ✅ `RegisterProcessor.cs`: email 저장

## Phase 4: 서버 HTTP
- ✅ `GameServer.csproj`: MailKit 4.16.0 NuGet 추가
- ✅ `SmtpService.cs` 신규
- ✅ `appsettings.json`: Smtp 섹션 추가
- ✅ `AuthController.cs` 신규 (POST /auth/forgot-password, POST /auth/reset-password)
- ✅ `WebServerHost.cs`: /auth/ 경로 미들웨어 제외

## Phase 5: 웹 클라이언트
- ✅ `index.html`: 등록 폼 이메일 필드, 비밀번호 찾기 링크, forgot-password/reset-password 화면 추가
- ✅ `game.js`: screens 배열 확장, doRegister email, showForgotPassword/doForgotPassword/doResetPassword 함수, reset_token 쿼리파라미터 감지

## 코드 리뷰 수정 (Critical/Major)
- ✅ C-1: ResetPassword TOCTOU — MarkUsedConditionalAsync로 교체, 순서 역전 (소모→해시→업데이트)
- ✅ C-2: clientOrigin 피싱 취약점 — appsettings `Auth:ResetPasswordBaseUrl` 서버설정으로 교체
- ✅ M-1: NewPassword null 가드 추가
- ✅ M-4: SmtpService SecureSocketOptions 설정 가능하게 변경 (StartTls/SslOnConnect/None)

## 빌드 검증
- ✅ 경고 0, 오류 0 (dotnet build Release, 최종 검증)

## 후속 필요 작업
- ⬜ appsettings.json Smtp 섹션에 실제 Gmail App Password 입력 (사용자가 직접)
- ⬜ Docker 환경에서 Smtp 자격증명을 환경변수로 주입 고려 (보안)
- ⬜ 기존 accounts 테이블에 email 컬럼 마이그레이션 (스키마 재실행 or ALTER TABLE)
