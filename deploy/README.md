## .env 생성

```powershell
Copy-Item .\deploy\.env.example .\deploy\.env
```
## 실행

```powershell
C:\dev\final-project\deploy\start.ps1
```
## 정지

```powershell
C:\dev\final-project\deploy\stop.ps1 
```



## 사전 준비

1. 발표 노트북과 GPU 서버의 유선 NIC에 고정 IP를 설정합니다.

```text
발표 노트북: 192.168.50.10/24
GPU 서버:    192.168.50.20/24
```

2. GPU 서버에서 모델 API를 외부 인터페이스에 바인딩합니다.

```text
http://192.168.1.147:11434/v1
```

3. GPU 서버 방화벽은 발표 노트북 IP에서 오는 모델 API 포트만 허용합니다.
4. 기존 프로젝트별 `.env`에서 Azure, OAuth 클라이언트, OpenAI 음성 인식·임베딩 키가 설정되어 있는지 확인합니다.
5. Azure Redirect URI에 다음 주소를 등록합니다.

```text
http://localhost/login/oauth2/code/azure
```



Kafka UI까지 실행하려면 다음 명령을 사용합니다.

```powershell
.\deploy\start.ps1 -WithOps
```

## 종료

```powershell
.\deploy\stop.ps1
```

`docker compose down`은 데이터 Volume을 삭제하지 않습니다. 발표 데이터 초기화가 필요한 경우에만 Volume 삭제 여부를 별도로 판단합니다.

## 발표 전 점검

- `http://localhost` 로그인과 OAuth Callback
- 채팅 SSE가 한 번에 출력되지 않고 스트리밍되는지 확인
- GPU 서버 `/v1/models` 또는 모델 Health API 확인
- Gemma 모델 사전 호출로 메모리 로드
- 회의실, 방문객 주차, 사무용품 빠른 실행 확인
- RAG 검색과 OpenAI 임베딩 인터넷 연결 확인
- Docker 재시작 후 PostgreSQL, Redis, Kafka 데이터 유지 확인
