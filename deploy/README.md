# Office-Link 통합 배포 가이드

이 문서는 Office-Link 전체 소스 코드를 처음 받은 사람이 환경변수를 설정하고 서비스를 실행·점검할 수 있도록 작성한 통합 배포 안내서입니다.

`deploy/docker-compose.yml`은 다음 구성 요소를 하나의 Docker Compose 프로젝트로 실행합니다.

- Vue Frontend와 Nginx
- Final Backend
- AI Agent
- MCP Server
- Workhub Backend
- PostgreSQL 2개
- Redis 3개
- Kafka와 선택적 Kafka UI
- BGE Re-ranker 모델 캐시
- Cloudflare Tunnel

## 1. 디렉터리 구성

Docker Compose의 빌드 경로는 아래 구조를 기준으로 합니다. 폴더 이름과 상대 위치를 변경하지 마세요.

```text
office-link/
├─ deploy/
├─ workspace-Final-Front/
├─ workspace-Final-Backend/
├─ workspace-Final-AI/
├─ workspace-mcp-server/
└─ workspace-Workhub-Backend/
```

Git 저장소로 받는 경우 하위 서버는 Submodule이므로 다음과 같이 복제합니다.

```bash
git clone --recurse-submodules <OFFICE_LINK_DEPLOY_REPOSITORY_URL> office-link
```

상위 저장소만 받은 경우 다음 명령으로 하위 소스를 가져옵니다.

```bash
git submodule update --init --recursive
```

소스 제출용 압축 파일에 5개 서버의 실제 코드가 이미 포함돼 있다면 Submodule 명령은 필요하지 않습니다.

## 2. 배포 구성과 외부 노출

| 서비스 | Docker 내부 주소 | 기본 외부 노출 |
| --- | --- | --- |
| Frontend/Nginx | `frontend:80` | `${FRONTEND_BIND_ADDRESS}:${FRONTEND_PORT}` |
| Final Backend | `final-backend:8080` | Nginx의 `/api`, `/oauth2` 경로를 통해 접근 |
| AI Agent | `agent:8000` | 기본 비노출, Harness 사용 시 `127.0.0.1:8000` |
| MCP Server | `mcp-server:9000` | 비노출 |
| Workhub Backend | `workhub-backend:8081` | 비노출 |
| Final PostgreSQL | `final-postgres:5432` | `127.0.0.1:5432` |
| Workhub PostgreSQL | `workhub-postgres:5432` | `127.0.0.1:15432` |
| Kafka UI | `kafka-ui:8080` | Ops Profile 사용 시 `127.0.0.1:18090` |
| Cloudflare Tunnel | Cloudflare 네트워크 | 설정한 공개 도메인 |

사용자 요청은 Frontend Nginx를 단일 진입점으로 사용합니다. Final Backend, AI Agent, MCP Server, Workhub Backend는 Docker 내부 네트워크에서 서비스 이름으로 통신합니다.

## 3. 사전 요구사항

공통 요구사항:

- Docker Engine 또는 Docker Desktop
- Docker Compose v2
- Azure App Registration과 Client Secret
- OpenAI API Key: RAG 임베딩과 OpenAI 기반 기능에 사용
- OpenAI 호환 LLM API: OpenAI API 또는 온프레미스 GPU 서버
- 최초 이미지·의존성·BGE 모델 다운로드를 위한 인터넷 연결

Windows에서 보조 스크립트와 전체 테스트를 사용할 경우:

- Windows 11, WSL 2
- PowerShell 5.1 이상
- Java 25
- Python 3.13, Node.js 22

Ubuntu 서버에서는 Docker Compose 명령만으로 배포할 수 있습니다. PowerShell 스크립트는 필수가 아닙니다.

## 4. 환경변수 파일 준비

실제 실행 설정은 루트가 아니라 `deploy/.env` 한 파일에서 관리합니다. 각 서버 폴더에 별도의 `.env`를 만들 필요가 없습니다.

Windows PowerShell:

```powershell
Copy-Item .\deploy\.env.example .\deploy\.env
```

Ubuntu 또는 WSL:

```bash
cp deploy/.env.example deploy/.env
chmod 600 deploy/.env
```

`deploy/.env.example`에는 변수 설명과 예시만 유지합니다. 다음 정보는 실제 `deploy/.env`에만 입력하고 Git 또는 제출 파일에 포함하지 않습니다.

- OpenAI API Key
- Azure Client Secret
- JWT Secret
- OAuth RSA 개인키
- 서버별 OAuth Client Secret
- DB 비밀번호
- Cloudflare Tunnel Token

## 5. 환경변수 설정 방법

### 5.1 공개 주소와 로그인 Callback

로컬 실행 예시:

```dotenv
FRONTEND_BIND_ADDRESS=127.0.0.1
FRONTEND_PORT=80
PUBLIC_BASE_URL=http://localhost
REFRESH_TOKEN_COOKIE_SECURE=false
```

Cloudflare Tunnel을 이용한 HTTPS 배포 예시:

```dotenv
FRONTEND_BIND_ADDRESS=127.0.0.1
FRONTEND_PORT=80
PUBLIC_BASE_URL=https://office-link.example.com
REFRESH_TOKEN_COOKIE_SECURE=true
CLOUDFLARE_TUNNEL_TOKEN=<발급받은_TUNNEL_TOKEN>
```

`PUBLIC_BASE_URL`은 사용자가 브라우저에서 실제로 접속하는 Origin과 정확히 같아야 합니다. Azure App Registration에는 다음 Redirect URI를 등록합니다.

```text
${PUBLIC_BASE_URL}/login/oauth2/code/azure
```

예를 들어 공개 주소가 `https://office-link.example.com`이면 다음 URI를 등록합니다.

```text
https://office-link.example.com/login/oauth2/code/azure
```

Cloudflare Tunnel의 서비스 대상은 Docker 네트워크의 Frontend입니다.

```text
http://frontend:80
```

현재 Compose에는 `cloudflared` 서비스가 기본 포함돼 있습니다. Cloudflare 배포에서는 유효한 `CLOUDFLARE_TUNNEL_TOKEN`을 반드시 입력하세요. Cloudflare를 사용하지 않는 로컬 배포에서는 Compose 실행 명령에 `--scale cloudflared=0`을 추가해 Tunnel 컨테이너를 시작하지 않습니다.

### 5.2 Planner·Action·RAG 검증 모델

OpenAI 모델 사용 예시:

```dotenv
ONPREM_LLM_BASE_URL=https://api.openai.com/v1
ONPREM_LLM_API_KEY=<OPENAI_API_KEY>
PLAN_MODEL=gpt-4.1-mini-2025-04-14
ACTION_MODEL=gpt-4.1-mini-2025-04-14
RAG_VALIDATION_MODEL=gpt-4.1-mini-2025-04-14
```

온프레미스 OpenAI 호환 모델 사용 예시:

```dotenv
ONPREM_LLM_BASE_URL=http://<GPU_SERVER_IP>:11434/v1
ONPREM_LLM_API_KEY=<LOCAL_API_KEY>
PLAN_MODEL=<MODEL_ID>
ACTION_MODEL=<MODEL_ID>
RAG_VALIDATION_MODEL=<MODEL_ID>
```

Office-Link 실행 전에 모델 목록을 확인하고 반환된 ID를 정확히 입력합니다.

```bash
curl http://<GPU_SERVER_IP>:11434/v1/models
```

모델 서버는 Docker 호스트에서 접근 가능한 주소에 바인딩돼 있어야 합니다. 컨테이너에서 `127.0.0.1`은 GPU 서버가 아니라 해당 컨테이너 자신을 뜻하므로 원격 서버 IP 또는 접근 가능한 DNS 이름을 사용합니다.

### 5.3 RAG 임베딩

주 LLM을 온프레미스로 사용해도 현재 RAG 임베딩에는 별도의 OpenAI API Key가 필요합니다.

```dotenv
OPENAI_API_KEY=<OPENAI_API_KEY>
EMBEDDING_API_BASE_URL=https://api.openai.com/v1
EMBEDDING_MODEL=text-embedding-3-small
EMBEDDING_DIMENSION=1536
RAG_REPROCESSING_ENABLED=true
```

임베딩 모델을 변경하면 기존 벡터 차원과 호환되는지 확인하고 문서 재처리를 수행해야 합니다.

### 5.4 Azure OAuth2 사용자 로그인

Azure App Registration에서 발급한 값을 입력합니다.

```dotenv
AZURE_AUTHORITY_TENANT=organizations
AZURE_CLIENT_ID=<AZURE_APPLICATION_CLIENT_ID>
AZURE_CLIENT_SECRET=<AZURE_APPLICATION_CLIENT_SECRET>
```

Client Secret의 만료일과 Azure에 등록한 Redirect URI를 함께 확인합니다.

### 5.5 사용자 JWT와 서버용 OAuth 서명키

```dotenv
JWT_SECRET=<32자_이상의_새로운_무작위_문자열>
OAUTH_JWT_KEY_ID=office-link-key-1
OAUTH_JWT_PRIVATE_KEY_BASE64=<PKCS8_PRIVATE_KEY_BASE64>
OAUTH_JWT_PUBLIC_KEY_BASE64=<X509_PUBLIC_KEY_BASE64>
```

Windows에서는 포함된 Java 파일로 테스트용 RSA 키 쌍을 생성할 수 있습니다.

```powershell
java .\deploy\GenerateOAuthTestKeys.java
```

첫 번째 출력은 PKCS#8 개인키, 두 번째 출력은 X.509 공개키의 한 줄 Base64 값입니다. 운영 환경에서는 별도 보안 절차로 새 키를 생성하고 개인키를 외부에 공유하지 않습니다.

### 5.6 서버 간 OAuth Client Secret

서버 간 Client Secret은 `deploy/.env`에 한 번만 정의합니다. Docker Compose가 같은 값을 인증 서버인 Final Backend와 해당 호출 서버 양쪽 컨테이너에 주입합니다. 따라서 각 서버의 개별 `.env`에 값을 중복 작성할 필요가 없습니다.

| 환경변수 | Client ID | 호출 경로 | Scope |
| --- | --- | --- | --- |
| `CHAT_BACKEND_CLIENT_SECRET` | `chat-backend-client` | Final Backend → AI Agent, 로그 API | `ai-agent.invoke`, `logs.write` |
| `CHAT_BACKEND_WORKHUB_CLIENT_SECRET` | `chat-backend-workhub-client` | Final Backend → Workhub Backend | `workhub.api`, `logs.write` |
| `AI_AGENT_CLIENT_SECRET` | `ai-agent-client` | AI Agent → MCP Server, 로그 API | `mcp.call`, `logs.write` |
| `MCP_SERVER_CLIENT_SECRET` | `mcp-server-client` | MCP Server → Workhub Backend, 로그 API | `workhub.api`, `logs.write` |
| `WORKHUB_BACKEND_CLIENT_SECRET` | `workhub-backend-client` | Workhub Backend → 로그 API | `logs.write` |

각 Client마다 서로 다른 24자 이상의 무작위 값을 사용합니다. Final Backend에 등록된 값과 호출 서버에 전달된 값이 다르면 Client Credentials 토큰 발급이 실패합니다.

### 5.7 PostgreSQL과 Docker Volume

```dotenv
FINAL_POSTGRES_DB=metanet
FINAL_POSTGRES_USER=metanet
FINAL_POSTGRES_PASSWORD=<새로운_DB_비밀번호>
WORKHUB_POSTGRES_DB=workhub
WORKHUB_POSTGRES_USER=workhub
WORKHUB_POSTGRES_PASSWORD=<새로운_DB_비밀번호>

FINAL_POSTGRES_VOLUME=office-link-demo_final-postgres-data
WORKHUB_POSTGRES_VOLUME=office-link-demo_workhub-postgres-data
```

새 환경에서는 기본 볼륨 이름을 사용합니다. 기존 데이터를 재사용할 때만 실제로 존재하는 Docker Volume 이름으로 변경합니다.

### 5.8 시뮬레이션과 운영 UI

```dotenv
REALTIME_SIMULATION_ENABLED=true
KAFKA_UI_PORT=18090
```

`REALTIME_SIMULATION_ENABLED=true`이면 Workhub Scheduler가 식당 혼잡도와 주차 입출차 샘플 데이터를 주기적으로 갱신합니다.

## 6. 설정 검증

Windows에서는 필수값 누락, 짧은 Secret, 잘못된 Base64 키를 빌드 전에 검사할 수 있습니다.

```powershell
.\deploy\start.ps1 -ValidateOnly
```

Ubuntu 또는 WSL에서는 Compose 해석 결과를 먼저 확인합니다.

```bash
docker compose \
  --env-file deploy/.env \
  -f deploy/docker-compose.yml \
  config >/dev/null
```

`config` 명령은 누락된 Compose 변수는 검사하지만 Secret 길이와 RSA 키 유효성까지 검사하지는 않습니다.

## 7. 서비스 실행

### Windows PowerShell

기본 실행:

```powershell
.\deploy\start.ps1
```

Kafka UI 포함:

```powershell
.\deploy\start.ps1 -WithOps
```

Agent 하네스용 포트까지 노출:

```powershell
.\deploy\start.ps1 -Harness
```

두 옵션을 함께 사용할 수 있습니다.

```powershell
.\deploy\start.ps1 -WithOps -Harness
```

### Ubuntu 또는 WSL

기본 실행:

```bash
docker compose \
  --env-file deploy/.env \
  -f deploy/docker-compose.yml \
  up -d --build --remove-orphans
```

Cloudflare Tunnel을 사용하지 않는 로컬 실행:

```bash
docker compose \
  --env-file deploy/.env \
  -f deploy/docker-compose.yml \
  up -d --build --remove-orphans --scale cloudflared=0
```

Kafka UI 포함:

```bash
docker compose \
  --env-file deploy/.env \
  -f deploy/docker-compose.yml \
  --profile ops \
  up -d --build --remove-orphans
```

최초 실행은 Docker 이미지, Java·Node·Python 의존성, BGE Re-ranker 모델을 준비하므로 시간이 걸릴 수 있습니다.

## 8. 상태 확인

```bash
docker compose \
  --env-file deploy/.env \
  -f deploy/docker-compose.yml \
  ps
```

전체 로그:

```bash
docker compose \
  --env-file deploy/.env \
  -f deploy/docker-compose.yml \
  logs -f --tail=200
```

주요 서비스만 확인:

```bash
docker compose \
  --env-file deploy/.env \
  -f deploy/docker-compose.yml \
  logs --tail=200 frontend final-backend agent mcp-server workhub-backend
```

Frontend Health 확인:

```bash
curl -i http://127.0.0.1:${FRONTEND_PORT:-80}/health
```

정상 상태에서는 주요 애플리케이션과 데이터 저장소가 `healthy` 또는 `running`으로 표시됩니다.

## 9. 종료와 재실행

Windows:

```powershell
.\deploy\stop.ps1
.\deploy\start.ps1
```

Ubuntu 또는 WSL:

```bash
docker compose \
  --env-file deploy/.env \
  -f deploy/docker-compose.yml \
  --profile ops \
  down

docker compose \
  --env-file deploy/.env \
  -f deploy/docker-compose.yml \
  up -d --build --remove-orphans
```

`docker compose down`은 기본적으로 Volume을 삭제하지 않으므로 PostgreSQL, Redis, Kafka 데이터와 Re-ranker 캐시가 유지됩니다. `down -v`는 데이터를 삭제하므로 백업 없이 실행하지 마세요.

환경변수를 변경했다면 단순 재시작보다 컨테이너를 다시 생성해야 합니다.

```bash
docker compose \
  --env-file deploy/.env \
  -f deploy/docker-compose.yml \
  up -d --force-recreate
```

애플리케이션 코드나 Dockerfile을 변경했다면 `--build`도 함께 사용합니다.

## 10. 최초 실행 검증 순서

1. 모든 주요 컨테이너의 Health 상태를 확인합니다.
2. Frontend `/health` 응답을 확인합니다.
3. Azure 로그인을 수행합니다.
4. 일반 질문의 SSE 응답을 확인합니다.
5. 회의실 예약 등 Action Draft와 사용자 승인 실행을 확인합니다.
6. 사내 규정 질문의 RAG 출처와 권한 필터를 확인합니다.
7. Workhub Scheduler 로그와 샘플 데이터 생성을 확인합니다.
8. 로그 테이블과 관리자 대시보드의 집계를 확인합니다.
9. 컨테이너 재시작 후 DB와 Redis 데이터가 유지되는지 확인합니다.

## 11. 테스트와 커버리지

Windows에서 Frontend를 제외한 4개 서버의 테스트와 커버리지를 한 번에 실행합니다.

```powershell
.\deploy\coverage.ps1
```

Python 의존성을 처음 설치하는 경우:

```powershell
.\deploy\coverage.ps1 -InstallPythonDependencies
```

| 대상 | 도구 | HTML 리포트 |
| --- | --- | --- |
| Final Backend | JUnit, JaCoCo | `workspace-Final-Backend/build/reports/jacoco/test/html/index.html` |
| Workhub Backend | JUnit, JaCoCo | `workspace-Workhub-Backend/build/reports/jacoco/test/html/index.html` |
| AI Agent | pytest, pytest-cov | `workspace-Final-AI/build/coverage/html/index.html` |
| MCP Server | pytest, pytest-cov | `workspace-mcp-server/build/coverage/html/index.html` |

## 12. 장애 해결

### Docker Compose 실행 전에 필수 환경변수 오류가 발생함

- 명령에 `--env-file deploy/.env`가 포함됐는지 확인합니다.
- `.env.example`이 아니라 실제 `deploy/.env`가 존재하는지 확인합니다.
- 빈 값이나 `<PLACEHOLDER>`가 남아 있는지 확인합니다.

### Azure 로그인 후 Redirect URI 오류가 발생함

- `PUBLIC_BASE_URL`과 실제 브라우저 접속 주소가 같은지 확인합니다.
- Azure에 `${PUBLIC_BASE_URL}/login/oauth2/code/azure`가 정확히 등록됐는지 확인합니다.
- HTTPS 환경에서 `REFRESH_TOKEN_COOKIE_SECURE=true`인지 확인합니다.
- Azure Client Secret이 만료되지 않았는지 확인합니다.

### 다른 기기에서 접속할 수 없음

- 내부망 직접 접속이라면 `FRONTEND_BIND_ADDRESS=0.0.0.0`과 호스트 방화벽을 확인합니다.
- Cloudflare 배포라면 Tunnel 상태, Public Hostname, `CLOUDFLARE_TUNNEL_TOKEN`을 확인합니다.
- 공개 주소를 사용할 때 `PUBLIC_BASE_URL`도 같은 주소로 설정해야 합니다.

### 서버 간 OAuth 토큰 발급이 401로 실패함

- 호출 서버의 Client ID와 Scope를 확인합니다.
- Final Backend와 호출 서버에 같은 Client Secret이 주입됐는지 확인합니다.
- `deploy/.env` 변경 후 관련 컨테이너를 재생성했는지 확인합니다.
- Final Backend의 `/oauth2/token` 로그를 확인합니다.

### 채팅 목록 또는 SSE 요청이 연결 거부됨

- 브라우저 요청이 별도 `localhost:8080`이 아니라 같은 Origin의 `/api`로 전달되는지 확인합니다.
- `frontend`, `final-backend`, `agent`의 Health와 로그를 확인합니다.
- Nginx가 Final Backend로 프록시하는지 확인합니다.

### 온프레미스 LLM만 응답하지 않음

- Docker 호스트에서 `<LLM_BASE_URL>/models`가 응답하는지 확인합니다.
- 컨테이너에서도 해당 IP와 포트에 접근할 수 있는지 확인합니다.
- 반환 모델 ID와 `PLAN_MODEL`, `ACTION_MODEL`, `RAG_VALIDATION_MODEL`이 일치하는지 확인합니다.
- 모델 서버가 `127.0.0.1`이 아니라 외부 인터페이스에 바인딩됐는지 확인합니다.

### RAG가 항상 검색 결과 없음으로 응답함

- `OPENAI_API_KEY`가 Workhub Backend에 주입됐는지 확인합니다.
- `EMBEDDING_MODEL`과 `EMBEDDING_DIMENSION`이 저장된 벡터 설정과 일치하는지 확인합니다.
- Workhub 로그에서 임베딩 API 오류와 문서 재처리 상태를 확인합니다.
- RAG 문서, 청크, 권한 데이터가 Workhub PostgreSQL에 존재하는지 확인합니다.

### MCP Server 최초 시작이 오래 걸림

- 최초 실행에서는 BGE Re-ranker 모델을 내려받고 OpenVINO 실행 파일을 준비할 수 있습니다.
- `reranker-cache` Volume을 유지하면 재실행 때 다시 다운로드하지 않습니다.
- 코드 변경만으로 해당 Volume을 삭제하지 마세요.

### Workhub 샘플 데이터가 갱신되지 않음

- `REALTIME_SIMULATION_ENABLED=true`인지 확인합니다.
- Workhub 로그에서 Scheduler 실행 여부를 확인합니다.
- 환경변수 변경 후 Workhub 컨테이너를 재생성합니다.

### Kafka 로그가 적재되지 않음

- Kafka와 Final Backend의 Health를 확인합니다.
- Ops Profile로 Kafka UI를 실행해 Topic과 Consumer Offset을 확인합니다.
- 각 서비스의 로그는 메모리 Batch 크기 또는 Flush 주기에 도달한 뒤 전송됩니다.

## 13. 보안과 제출 주의사항

다음 파일과 데이터는 소스 제출물이나 Git 저장소에 포함하지 않습니다.

- `deploy/.env`
- API Key, Azure Client Secret, OAuth Client Secret
- OAuth RSA 개인키와 인증서 개인키
- DB Dump와 실제 사용자·로그 데이터
- Docker Volume 데이터
- `.git`, `.venv`, `node_modules`, `build`, `dist`, 캐시 및 커버리지 결과

제출물에는 비밀값이 비어 있는 `deploy/.env.example`, 이 문서, Docker Compose, Dockerfile, Flyway 마이그레이션, 테스트 코드를 포함합니다.

비밀값이 외부에 노출된 경우 파일에서 지우는 것만으로 충분하지 않습니다. 해당 키와 Secret을 폐기하고 새로 발급한 뒤 실행 환경을 갱신해야 합니다.
