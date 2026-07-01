# 비밀번호 이메일 재설정 — 구현 계획

Last Updated: 2026-05-22

## Executive Summary

회원가입 시 이메일을 등록하고, 비밀번호 분실 시 이메일로 재설정 링크를 받는 기능.
WebSocket/proto 흐름이 아닌 HTTP(port 8080) 기반. 웹 클라이언트(8081)가 토큰을 받아 재설정 폼을 표시.

---

## 흐름

```
[로그인 화면] → '비밀번호 찾기' 클릭
  → 이메일 입력 폼
  → POST http://host:8080/auth/forgot-password { username, email }
  → 서버: token 생성 → DB 저장 → 이메일 발송
  → 사용자: 이메일 링크 클릭 → http://host:8081?reset_token=xxx
  → 웹 클라이언트: 토큰 감지 → 새 비번 입력 폼 표시
  → POST http://host:8080/auth/reset-password { token, newPassword }
  → 서버: 토큰 검증 → BCrypt 해시 → DB 업데이트 → 토큰 소비
```

---

## 구현 단계

### Phase 1 — DB 스키마
- `accounts` 테이블: `email VARCHAR(255) DEFAULT NULL UNIQUE` 추가
- `password_reset_tokens` 테이블 신규:
  - `token_id` BIGINT PK AUTO_INCREMENT
  - `account_id` BIGINT NOT NULL
  - `token` CHAR(64) NOT NULL UNIQUE  (SHA-256 hex)
  - `expires_at` DATETIME NOT NULL
  - `used_at` DATETIME DEFAULT NULL

### Phase 2 — DB 레이어 (C#)
- `AccountRow`: `email` 필드 추가
- `AccountDbSet`: `UpdatePasswordHashAsync`, `SelectByEmailAsync` 추가
- `PasswordResetTokenRow` 신규
- `PasswordResetTokenDbSet` 신규 (Insert, SelectByToken, MarkUsed, DeleteExpired)
- `GameDbContext`: `PasswordResetTokens` 추가

### Phase 3 — Proto (회원가입 이메일 필드)
- `register.proto`: `email = 3` 추가 (선택 필드)
- `RegisterProcessor`: email 저장 처리

### Phase 4 — 서버 HTTP 엔드포인트
- `SmtpService`: SMTP 이메일 발송 (MailKit 사용)
- `AuthController`: POST /auth/forgot-password, POST /auth/reset-password
- `WebServerHost`: /auth/ 경로 ApiKeyMiddleware 제외
- `appsettings.json`: Smtp 섹션 추가

### Phase 5 — 웹 클라이언트 UI
- `index.html`: forgot-password 화면, reset-password 화면 추가
- `game.js`: 폼 로직, reset_token 쿼리파라미터 감지, HTTP 호출

---

## 핵심 결정사항

- 토큰 유효시간: **1시간**
- 토큰 형식: `Convert.ToHexString(SHA256(Guid.NewGuid().ToByteArray()))` — 64자
- SMTP: Gmail OAuth2가 아닌 App Password 방식 (MailKit)
- 리셋 링크 호스트: `window.location.origin` 기반 (Docker/로컬 모두 대응)
- 이메일은 회원가입 시 필수가 아닌 **선택 필드** (기존 계정 호환)

---

## 위험 요소

| 위험 | 완화 |
|------|------|
| 토큰 재사용 | `used_at` 확인 후 소비, 1회용 |
| 계정 열거 공격 | forgot-password 성공/실패 응답 동일하게 반환 |
| 만료 토큰 누적 | `DeleteExpiredAsync` 주기적 호출 (요청마다 실행) |
| SMTP 자격증명 노출 | appsettings.json 미커밋 or Docker env var |
