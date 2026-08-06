# Office-Link 통합 배포 가이드

이 디렉터리는 Frontend, Final Backend, AI Agent, MCP Server, Workhub Backend와 PostgreSQL·Redis·Kafka를 하나의 Docker Compose 프로젝트로 실행합니다.

## 배포 구성

| 서비스 | 내부 주소 | 외부 노출 |
| --- | --- | --- |
| Frontend/Nginx | `frontend:80` | `http://localhost` |
| Final Backend | `final-backend:8080` | Nginx를 통해 접근 |
| AI Agent | `agent:8000` | 기본 비노출 |
| MCP Server | `mcp-server:9000` | 기본 비노출 |
| Workhub Backend | `workhub-backend:8081` | 기본 비노출 |
| Final PostgreSQL | `final-postgres:5432` | `127.0.0.1:5432` |
| Workhub PostgreSQL | `workhub-postgres:5432` | `127.0.0.1:15432` |
| Kafka UI | `kafka-ui:8080` | `-WithOps` 사용 시 `127.0.0.1:18090` |

## 사전 요구사항

- Docker Desktop, WSL 2, Docker Compose v2
- PowerShell 5.1 이상
- Azure OAuth 애플리케이션과 Redirect URI
- OpenAI API Key
- OpenAI 호환 LLM API 또는 온프레미스 GPU 서버
- Java 25: OAuth RSA key 생성과 Java 테스트를 직접 실행할 때 사용

## 1. 환경변수 설정

```powershell
Copy-Item .\deploy\.env.example .\deploy\.env
```

`deploy/.env` 하나가 통합 배포의 기준입니다. 각 서비스의 개별 `.env`는 Compose 실행에서 사용하지 않습니다.

### 필수 설정 그룹

| 구분 | 환경변수 |
| --- | --- |
| 공개 주소 | `FRONTEND_BIND_ADDRESS`, `FRONTEND_PORT`, `PUBLIC_BASE_URL` |
| Agent LLM | `ONPREM_LLM_BASE_URL`, `ONPREM_LLM_API_KEY`, `PLAN_MODEL`, `ACTION_MODEL`, `RAG_VALIDATION_MODEL` |
| 음성·임베딩 | `OPENAI_API_KEY`, `EMBEDDING_API_BASE_URL`, `EMBEDDING_MODEL`, `EMBEDDING_DIMENSION` |
| Azure | `AZURE_AUTHORITY_TENANT`, `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET` |
| JWT·OAuth | `JWT_SECRET`, `OAUTH_JWT_KEY_ID`, `OAUTH_JWT_PRIVATE_KEY_BASE64`, `OAUTH_JWT_PUBLIC_KEY_BASE64` |
| 서버 Client | `CHAT_BACKEND_CLIENT_SECRET`, `CHAT_BACKEND_WORKHUB_CLIENT_SECRET`, `AI_AGENT_CLIENT_SECRET`, `MCP_SERVER_CLIENT_SECRET`, `WORKHUB_BACKEND_CLIENT_SECRET` |
| 데이터베이스 | `FINAL_POSTGRES_*`, `WORKHUB_POSTGRES_*` |

실제 Secret은 `.env.example`에 넣지 말고 `deploy/.env`에만 저장합니다. 서비스별 Client Secret은 24자 이상의 서로 다른 무작위 값을 권장합니다.

### OAuth RSA key 생성

```powershell
java .\deploy\GenerateOAuthTestKeys.java
```

첫 번째 출력은 PKCS#8 private key, 두 번째 출력은 X.509 public key의 Base64 값입니다. 각각 `OAUTH_JWT_PRIVATE_KEY_BASE64`, `OAUTH_JWT_PUBLIC_KEY_BASE64`에 입력하고 외부에 공유하지 않습니다.

### 설정 검증

```powershell
.\deploy\start.ps1 -ValidateOnly
```

필수값 누락, placeholder, 짧은 Secret, 잘못된 Base64 key를 컨테이너 빌드 전에 확인합니다.

## 2. 실행

기본 서비스:

```powershell
.\deploy\start.ps1
```

Kafka UI 포함:

```powershell
.\deploy\start.ps1 -WithOps
```

Agent 하네스가 로컬에서 접근할 8080·8000 포트까지 노출:

```powershell
.\deploy\start.ps1 -Harness
```

두 옵션을 함께 사용할 수도 있습니다.

```powershell
.\deploy\start.ps1 -WithOps -Harness
```

## 3. 종료와 재실행

```powershell
.\deploy\stop.ps1
```

`stop.ps1`은 `docker compose down`만 실행하며 volume을 삭제하지 않습니다. 다음 데이터는 유지됩니다.

- Final/Workhub PostgreSQL
- Final/Agent/Workhub Redis
- Kafka 로그
- Re-ranker 모델 캐시

환경변수나 Compose 설정을 변경한 경우:

```powershell
.\deploy\stop.ps1
.\deploy\start.ps1
```

데이터 초기화가 필요하더라도 발표·운영 데이터를 확인한 뒤 volume을 개별적으로 삭제하세요. 이 문서에서는 자동 삭제 명령을 제공하지 않습니다.

## 4. 온프레미스 GPU 서버

1. 발표 노트북과 GPU 서버를 같은 유선 네트워크에 연결합니다.
2. GPU 서버의 OpenAI 호환 API를 `0.0.0.0:<MODEL_PORT>`에 바인딩합니다.
3. 발표 노트북에서 `/v1/models`를 호출해 연결을 확인합니다.
4. `deploy/.env`를 설정합니다.

```env
ONPREM_LLM_BASE_URL=http://<GPU_SERVER_IP>:11434/v1
ONPREM_LLM_API_KEY=<LOCAL_API_KEY>
PLAN_MODEL=<MODEL_NAME>
ACTION_MODEL=<MODEL_NAME>
RAG_VALIDATION_MODEL=<MODEL_NAME>
```

5. GPU 서버 방화벽은 발표 노트북 IP의 모델 API 포트만 허용합니다.

OpenAI API 모델로 전환할 때는 `ONPREM_LLM_BASE_URL=https://api.openai.com/v1`과 유효한 API Key·모델명을 사용한 뒤 컨테이너를 재생성합니다.

## 5. 상태 확인

```powershell
docker compose --env-file .\deploy\.env -f .\deploy\docker-compose.yml ps
docker compose --env-file .\deploy\.env -f .\deploy\docker-compose.yml logs --tail 100 agent
```

| 확인 항목 | 주소·방법 |
| --- | --- |
| 사용자 화면 | `http://localhost` |
| Kafka UI | `http://localhost:18090` (`-WithOps`) |
| Final DB | `127.0.0.1:5432` |
| Workhub DB | `127.0.0.1:15432` |
| Agent Health | `http://127.0.0.1:8000/health` (`-Harness`) |

## 6. 테스트와 커버리지

```powershell
.\deploy\coverage.ps1
```

Python 의존성 설치가 필요한 최초 실행:

```powershell
.\deploy\coverage.ps1 -InstallPythonDependencies
```

## 장애 해결

### 로그인 후 callback에서 멈춤

- Azure Redirect URI가 `${PUBLIC_BASE_URL}/login/oauth2/code/azure`와 일치하는지 확인합니다.
- `PUBLIC_BASE_URL`은 브라우저가 실제로 접속하는 주소여야 합니다.
- 외부 HTTPS 배포에서는 Cookie secure 설정도 함께 변경합니다.

### 채팅 목록 또는 SSE 요청이 연결 거부됨

- 브라우저 개발자 도구에서 요청이 `localhost:8080`이 아니라 같은 origin의 `/api`로 가는지 확인합니다.
- `frontend`, `final-backend`, `agent` health와 Nginx 로그를 확인합니다.
- 환경변수 변경 후 기존 컨테이너를 재생성했는지 확인합니다.

### 로컬 LLM만 응답하지 않음

- 발표 노트북에서 `http://<GPU_SERVER_IP>:<PORT>/v1/models`를 확인합니다.
- 모델 서버가 loopback이 아닌 외부 인터페이스에 바인딩되었는지 확인합니다.
- 모델명과 `PLAN_MODEL`, `ACTION_MODEL`, `RAG_VALIDATION_MODEL`이 일치하는지 확인합니다.
- 방화벽, 유선 NIC IP, 서브넷을 확인합니다.

### MCP 시작이 오래 걸림

- 최초 실행은 BGE Re-ranker를 준비합니다.
- `reranker-cache` volume이 유지되는지 확인합니다.
- 애플리케이션 코드 변경만으로 volume을 삭제하지 않습니다.

### Workhub 데이터가 생성되지 않음

- `REALTIME_SIMULATION_ENABLED=true`인지 확인합니다.
- Workhub 로그의 scheduler 실행과 DB timezone을 확인합니다.
- 환경변수를 수정했다면 Workhub 컨테이너를 재생성합니다.

### Kafka 로그가 보이지 않음

- `kafka`, `final-backend` health와 Consumer group을 확인합니다.
- `-WithOps`로 Kafka UI를 실행해 Topic·DLT·Consumer offset을 확인합니다.
- 각 서비스의 메모리 배치는 건수 또는 flush interval에 도달한 뒤 전송됩니다.

## 발표 전 점검

1. Secret 검증과 전체 컨테이너 health 통과
2. Azure 로그인과 Refresh Token 갱신
3. 일반 질문 SSE와 Action Draft 빠른 실행
4. 회의실·주차·사무용품 변경 결과의 목록 반영
5. RAG 출처와 권한 필터
6. GPU 모델 사전 로드와 Re-ranker 캐시
7. Kafka 로그 적재와 관리자 대시보드
8. Docker 재시작 후 PostgreSQL·Redis·Kafka 데이터 유지
