# Security Policy

## 지원 버전

현재 보안 수정 대상은 최종 발표·배포 버전인 `1.0.x`입니다.

## 취약점 제보

보안 취약점이나 비밀정보 노출을 발견하면 공개 Issue에 내용을 남기지 마세요. 저장소 관리자를 통해 비공개로 전달하거나 GitHub의 Private Vulnerability Reporting/Security Advisory를 사용합니다.

제보에는 다음 정보를 포함합니다.

- 영향받는 저장소와 버전 또는 commit
- 재현 절차와 예상 영향
- 민감정보를 제거한 로그 또는 화면
- 가능한 경우 완화 방법

## 비밀정보 관리

- API Key, Client Secret, DB 비밀번호, JWT Secret, RSA 개인키는 `.env` 또는 배포 시스템의 Secret 저장소에서만 관리합니다.
- `.env.example`에는 변수 이름과 안전한 기본값·빈 placeholder만 유지합니다.
- 실제 `.env`, 인증서, 개인키, 토큰, 운영 DB 덤프는 커밋하지 않습니다.
- 노출이 의심되면 Git 기록 삭제보다 먼저 해당 값을 폐기하고 재발급합니다.
- 서비스별 OAuth Client Secret은 서로 다른 무작위 값으로 생성합니다.

## 인증과 권한

- 사용자 로그인은 Azure OAuth2/OIDC와 Final Backend의 JWT를 사용합니다.
- 서버 간 호출은 OAuth2 Client Credentials, 짧은 수명의 JWT, Scope, JWKS 검증을 사용합니다.
- 사용자 ID, 부서, 역할은 인증된 서버 컨텍스트에서 전달하며 클라이언트 입력을 권한 판단에 직접 사용하지 않습니다.
- 변경 작업은 Action Draft와 사용자 최종 승인을 거쳐 실행합니다.

## 로그와 개인정보

- 차량 번호, 전화번호, 사용자 입력 등 개인정보가 Tool 인자나 오류 메시지에 그대로 남지 않도록 마스킹합니다.
- 운영 로그에는 Access Token, Refresh Token, Client Secret, API Key, Cookie를 기록하지 않습니다.
- 진단 자료를 공유할 때 URL query, header, payload의 민감정보를 제거합니다.

## 배포 권장사항

- 외부 배포에서는 HTTPS와 `REFRESH_TOKEN_COOKIE_SECURE=true`를 사용합니다.
- 온프레미스 LLM 포트는 신뢰할 수 있는 유선 네트워크와 허용된 IP에만 개방합니다.
- Kafka UI, PostgreSQL, Redis는 공용 네트워크에 노출하지 않습니다.
- 의존성 이미지와 패키지 버전을 정기적으로 점검하고 최종 배포 전 테스트·커버리지·하네스를 실행합니다.
