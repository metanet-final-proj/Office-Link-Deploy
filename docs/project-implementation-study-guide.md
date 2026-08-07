# Office-Link 전체 구현 학습서

> 대상: 프로젝트를 처음 인수받은 신입 개발자 또는 최종 발표 질의응답 준비자  
> 기준: 2026-08-07 로컬 저장소의 실제 코드  
> 목적: 장표 암기가 아니라, 요청이 들어와 결과가 나갈 때까지의 구현을 설명할 수 있게 하는 것

---

## 0. 이 문서를 공부하는 방법

먼저 아래 네 문장을 막힘없이 설명할 수 있어야 한다.

1. Office-Link는 사내 업무 조회와 규정 검색, 예약·등록·신청을 자연어로 처리하는 업무지원 AI 시스템이다.
2. Agent는 의도를 분류하고 조회 Tool을 호출하거나 변경 작업의 초안(Action Draft)을 만든다.
3. 실제 생성·수정·취소는 사용자가 값을 확인한 뒤 Final Backend가 Workhub API를 직접 호출해 수행한다.
4. 모든 서버 호출은 사용자 문맥, 추적 ID, 서비스 토큰을 전달하며 로그는 Kafka를 거쳐 관측 DB에 저장한다.

추천 학습 순서:

1. `1~4장`: 전체 구조와 두 가지 핵심 요청 흐름
2. `5~10장`: 서버별 구현
3. `11~17장`: 인증, 데이터, 안정성, 로그, 배포
4. `18장`: 현재 코드와 발표자료 차이
5. `19장`: 예상 질문으로 스스로 말해 보기

---

## 1. 프로젝트를 한 문장으로 설명하면

**Office-Link는 사내 업무 시스템과 문서 검색을 하나의 대화창으로 연결하고, AI의 제안과 사용자의 최종 승인을 분리한 업무지원 플랫폼이다.**

### 해결하려는 문제

- 회의실, 방문객 주차, 사무용품, 식당 정보가 서로 다른 화면과 절차에 흩어져 있다.
- 사내 규정은 문서가 많고 사용자의 부서·권한에 따라 열람 범위가 다르다.
- 자연어만으로 업무를 바로 실행하면 AI가 값을 잘못 이해했을 때 실제 데이터가 잘못 변경될 수 있다.
- 여러 서버를 거치는 구조에서는 일시적인 네트워크 오류와 중복 요청을 별도로 다뤄야 한다.

### 핵심 해결 방식

- 자연어 요청을 `Planner`가 업무 도메인으로 분류한다.
- `Action` 노드가 MCP 조회 Tool 또는 Agent 내부 Draft Tool을 선택한다.
- 조회 결과는 Compact DTO와 구조화 이벤트로 내려 화면에서 표·카드로 표시한다.
- 데이터 변경은 Action Draft로 제안하고 사용자가 최종 승인한 값만 실행한다.
- RAG는 문서 권한을 먼저 적용하고 Hybrid Search와 BGE Re-ranker로 근거를 찾는다.
- 인증, 재시도, 멱등성, 로그, 테스트 하네스를 공통 운영 기반으로 둔다.

---

## 2. 전체 시스템 구성

| 구성 요소 | 기술 | 핵심 책임 |
|---|---|---|
| Frontend | Vue 3, Vite, Pinia, Nginx | 로그인, 채팅 UI, SSE 렌더링, Draft Form, 대시보드 |
| Final Backend | Spring Boot, PostgreSQL, Redis, Kafka | 사용자·인증·채팅 관문, Draft 승인, 로그 수집·조회 |
| AI Agent | FastAPI, LangGraph, Redis | 의도 분류, Tool 선택, 응답 생성, RAG 답변 검증 |
| MCP Server | FastMCP, Python | Tool 계약, 사용자 문맥 전달, 업무 API 변환, Re-ranking |
| Workhub Backend | Spring Boot, PostgreSQL, pgvector | 업무 원장, 업무 규칙, RAG 검색, 스케줄러 |
| LLM Provider | Ollama 호환 API 또는 OpenAI API | Planner/Action/검증 모델 추론 |
| OpenAI Embedding | `text-embedding-3-small` | RAG 질의 임베딩 |
| Redis | 용도별 3개 인스턴스 | Refresh Token, Agent Checkpoint/Memory, Workhub 보조 상태 |
| Kafka | KRaft 단일 노드 구성 | 서버별 로그 이벤트 비동기 전달 |

### 통신 방향

```text
Browser
  <-> Frontend Nginx
  <-> Final Backend
  <-> AI Agent
  <-> MCP Server
  <-> Workhub Backend
  <-> Workhub PostgreSQL
```

변경 승인 경로는 다르다.

```text
Browser의 승인 버튼
  -> Final Backend
  -> Workhub Backend
  -> Workhub PostgreSQL
```

즉, 최종 변경은 Agent와 MCP를 다시 거치지 않는다.

### 왜 서버를 나눴는가

- 사용자·인증·채팅 책임과 업무 원장 책임을 분리한다.
- LLM 오케스트레이션과 Tool 어댑터를 독립적으로 교체할 수 있다.
- Workhub는 AI가 없어도 일반 REST 업무 서버로 유지된다.
- MCP는 Agent가 Backend DTO와 인증 세부사항을 직접 알지 않게 한다.
- 장애와 성능 병목을 서버별로 관측할 수 있다.

---

## 3. 핵심 흐름 1: 조회 요청

예시: `내일 오후 2시에 6명이 사용할 수 있는 회의실 보여줘`

### 순서

1. Frontend가 대화 ID와 메시지를 Final Backend SSE API에 보낸다.
2. Final Backend가 사용자 메시지를 PostgreSQL에 저장한다.
3. Final Backend가 Client Credentials로 `ai-agent.invoke` 토큰을 얻는다.
4. 사용자 ID, 부서 코드, 역할, 추적 ID를 헤더와 요청 본문에 담아 Agent를 호출한다.
5. Agent Planner가 도메인을 `meeting_room`으로 결정한다.
6. Action 노드가 `meeting_room_find_available_rooms`를 선택한다.
7. Agent의 MCP Loader가 서비스 토큰과 사용자 문맥을 자동 주입한다.
8. MCP가 Workhub용 `workhub.api` 토큰을 얻어 회의실 API를 호출한다.
9. Workhub가 날짜·시간·정원·예약 충돌을 기준으로 데이터를 조회한다.
10. MCP가 필요한 필드만 Compact DTO로 정리한다.
11. Agent가 `meeting_room_available_list` 구조화 이벤트를 생성한다.
12. Final Backend가 텍스트와 구조화 이벤트를 SSE로 중계한다.
13. 응답 완료 후 Assistant 메시지와 `chat_response_snapshots`를 저장한다.
14. Frontend는 텍스트와 회의실 표를 렌더링한다.

### 여기서 중요한 질문

**왜 LLM이 표를 Markdown으로 만들지 않는가?**

- 모델 출력에 맡기면 열 구조와 버튼 연결이 불안정하다.
- 구조화 이벤트는 타입과 데이터 계약이 명확하다.
- 새로고침 후에도 snapshot을 다시 읽어 같은 UI를 복원할 수 있다.
- LLM은 설명에 집중하고 Frontend는 표시 책임을 가진다.

---

## 4. 핵심 흐름 2: 변경 요청과 Action Draft

예시: `내일 오후 2시에 6명이 사용할 회의실 예약하고 싶어`

### 초안 생성

1. Planner가 `meeting_room`으로 분류한다.
2. Action 노드가 Agent 내부 Draft Tool을 호출한다.
3. Tool은 자연어에서 날짜·시간·인원·회의실 조건을 구조화한다.
4. 부족한 값에는 기본값을 적용하고 Workhub 조회로 예약 가능한 후보를 추천한다.
5. Agent는 Draft 이벤트를 SSE로 보낸다.
6. Final Backend가 이벤트를 DB의 `action_drafts` 레코드로 저장한다.
7. Frontend는 빠른 실행 카드와 내용 확인·수정 버튼을 표시한다.

### 최종 승인

1. 사용자가 카드에서 표시값을 확인하거나 Form에서 수정한다.
2. Frontend가 Draft ID, 수정된 payload, `Idempotency-Key`를 Final Backend에 보낸다.
3. Final Backend가 Draft 상태를 `DRAFT -> EXECUTING`으로 원자적으로 변경한다.
4. Final Backend가 사용자가 확정한 값을 Workhub에 직접 전달한다.
5. Workhub가 업무 규칙과 DB 제약을 다시 검증한다.
6. 성공하면 Draft는 `COMPLETED`, 실패하면 `FAILED`가 된다.
7. 완료 결과와 목록 snapshot이 갱신되고 Frontend에 처리 결과가 표시된다.

### 설계 원칙

- 자동 추천은 **표시할 후보를 정하는 단계**에서만 사용한다.
- 사용자가 확인한 뒤 실행하는 시점에는 회의실이나 수량을 임의로 바꾸지 않는다.
- 회의실 실행 요청은 `allowFallback=false`로 전달한다.
- 추천 시점과 실행 시점 사이에 상태가 바뀔 수 있으므로 Workhub가 마지막 검증을 한다.

### Draft 상태

| 상태 | 의미 |
|---|---|
| `DRAFT` | 생성됐지만 아직 승인되지 않음 |
| `EXECUTING` | 승인 요청을 선점해 실행 중 |
| `COMPLETED` | 업무 처리 완료 |
| `FAILED` | 업무 규칙 또는 연동 문제로 실패, 조건에 따라 재시도 가능 |

5분 이상 `EXECUTING`에 머문 Draft는 비정상 종료로 보고 복구 대상으로 처리한다.

---

## 5. Final Backend 구현

### 5.1 역할

- 브라우저의 단일 API 진입점
- Azure SSO 로그인과 자체 JWT 발급
- 사용자, 조직, 역할, 권한 관리
- 채팅방과 메시지 저장
- Agent SSE 호출과 브라우저 SSE 중계
- Action Draft 생성·승인
- Workhub 직접 변경 요청
- 로그 Kafka Producer/Consumer 및 대시보드 집계

### 5.2 채팅 API

- `GET /api/v1/chat/conversations`: 내 대화 목록
- `POST /api/v1/chat/conversations`: 대화 생성
- `PATCH /api/v1/chat/conversations/{id}`: 제목 수정
- `DELETE /api/v1/chat/conversations/{id}`: 대화 삭제
- `GET /api/v1/chat/conversations/{id}/messages`: 메시지와 저장된 구조화 응답 조회
- `POST /api/v1/chat/conversations/{id}/messages`: SSE 메시지 전송

### 5.3 SSE 중계에서 하는 일

`MessageController`는 단순 프록시가 아니다.

- 사용자 메시지를 먼저 저장한다.
- 브라우저가 보내지 않으면 Idempotency Key를 생성한다.
- Agent에서 오는 `status`, `token`, `tool`, 구조화 이벤트를 해석한다.
- 텍스트 토큰을 누적한다.
- 완료 시 Assistant 메시지를 저장한다.
- Draft 이벤트를 `action_drafts`로 변환한다.
- 목록·상세 이벤트를 `chat_response_snapshots`로 저장한다.
- Agent Redis checkpoint가 없으면 DB의 최근 대화와 요약을 넣어 한 번 복구 호출한다.
- Agent 연결 오류는 지수 백오프와 jitter로 제한적으로 재시도한다.

### 5.4 왜 응답 snapshot이 필요한가

기존에는 회의실 목록, 회의실 상세, 주차 목록, 비품 목록별 테이블이 따로 있었다. 현재는 `chat_response_snapshots`로 통합됐다.

주요 컬럼:

- `assistant_message_id`
- `conversation_id`
- `user_id`
- `domain`
- `snapshot_type`
- `payload_json`
- `action_result_json`

효과:

- 새 도메인을 추가할 때 별도 snapshot 테이블이 필요하지 않다.
- 메시지와 구조화 UI를 함께 복원한다.
- 처리 완료 후 해당 메시지의 목록 상태를 갱신할 수 있다.
- 메시지 삭제 시 FK cascade로 snapshot도 정리된다.

### 5.5 Action Draft 기본값과 추천

회의실:

- 날짜: 오늘
- 시작: 다음 10분 단위 시각
- 종료: 시작 + 1시간
- 인원: 현재 코드 기본값 3명
- 회의실: 시간과 인원을 만족하는 후보 중 적합한 회의실

주차:

- 날짜: 오늘
- 담당자 또는 방문객: 로그인 사용자 이름
- 오늘이면 잔여 비율이 높은 주차장을 추천
- 미래 날짜이면 방문객 전용 주차장을 우선 기본값으로 사용
- 차량 번호가 없으면 빠른 실행은 제공하지 않고 Form만 제공

사무용품:

- 품목별 기본 수량 1개
- 한 Draft에서 최대 5개 품목
- 중복 품목 금지
- 요청 수량이 재고보다 많으면 화면 제안값을 최대 가능 수량으로 조정
- 재고가 0인 품목이 있으면 빠른 실행 불가

### 5.6 승인 동시성

Draft 승인 시 버전과 상태를 함께 검사하는 compare-and-set 방식으로 `EXECUTING`을 선점한다.

이유:

- 같은 버튼을 두 번 눌러도 두 요청이 모두 실행되면 안 된다.
- 서로 다른 브라우저 탭에서 동시에 승인해도 하나만 선점해야 한다.
- DB 상태가 최종 동시성 판단 기준이 된다.

---

## 6. AI Agent 구현

### 6.1 왜 LangGraph를 사용했는가

단일 프롬프트 체인보다 다음을 명시적으로 표현할 수 있다.

- Planner와 Action 역할 분리
- Tool 호출 반복
- RAG 위험도 검사와 조건부 Self-Correction
- Redis checkpoint를 통한 대화 상태 복원
- 노드별 로그와 지연 시간 측정

### 6.2 AgentState

대표 상태:

- `messages`: 현재 대화 메시지
- `conversation_summary`: 오래된 대화 요약
- `correlation_id`, `request_id`, `conversation_id`
- `user_id`, `department_code`, `role_codes`
- `domain`, `intent_summary`
- `short_term_context`
- RAG 검색 결과와 검증 상태
- `final_answer`

### 6.3 그래프 흐름

```text
conditional_summarizer
  -> planner
  -> agent
  -> tools
  -> tool_result_capture
       -> agent 또는 END

Tool 미호출 응답
  -> rag_guard
  -> 필요 시 rag_self_check
  -> 필요 시 rag_revise
  -> finalize
  -> END
```

### 6.4 Planner

Planner는 다음 두 값만 구조화 출력한다.

- `domain`
- `intent_summary`

도메인:

- `meeting_room`
- `parking`
- `cafeteria`
- `supply`
- `childcare`
- `policy_rag`
- `smalltalk`
- `unknown`

특정 업무 규정은 해당 업무 도메인에 남겨 Tool 선택 문맥을 유지하고, 포괄적인 사내 규정 질문은 `policy_rag`로 보낸다.

### 6.5 Action 노드

- Planner가 선택한 도메인의 Tool만 모델에 노출한다.
- 공통 메모리 Tool인 `save_memory`, `delete_memory`를 추가한다.
- 회의실·주차·사무용품의 MCP 변경 Tool은 노출하지 않는다.
- 목록 조회와 Draft 생성 결과는 추가 답변 생성 없이 종료할 수 있다.

### 6.6 현재 실제 Draft Tool

현재 체크아웃 기준으로 Agent 내부에는 도메인별 9개 Draft Tool이 존재한다.

- 회의실 생성·수정·취소 Draft
- 방문객 주차 생성·수정·취소 Draft
- 사무용품 생성·수정·취소 Draft

따라서 발표에서 “공통 `prepare_action_draft` 하나로 완전히 통합했다”고 말하면 실제 코드와 다르다. 공통화는 좋은 개선 방향이지만, 현재 구현 설명은 **공통 Draft 결과 계약을 쓰는 도메인별 Tool**이라고 표현하는 편이 정확하다.

### 6.7 Tool 결과에서 바로 종료하는 이유

구조화 목록이나 Draft를 이미 만들었는데 다시 LLM에게 답변을 맡기면 다음 문제가 생긴다.

- 같은 Tool을 반복 호출할 수 있다.
- 고정 문구와 모델 문구가 중복된다.
- 표에 있는 데이터를 장문의 텍스트로 다시 나열한다.
- 토큰과 지연 시간이 증가한다.

그래서 terminal presentation Tool과 Action Draft는 Tool 결과를 캡처한 뒤 그래프를 종료하고 SSE 계층이 고정 안내 문구를 스트리밍한다.

### 6.8 모델 설정

- OpenAI 호환 `/v1` API 사용
- Planner, Action, RAG Validation 모델을 환경변수로 각각 지정
- 로컬 Ollama 모델과 OpenAI 모델을 같은 인터페이스로 교체 가능
- temperature 0
- stream usage 활성화
- SDK 자체 재시도는 끄고 그래프 또는 호출 계층에서 재시도 정책을 통제

---

## 7. MCP Server 구현

### 7.1 역할

MCP는 단순 REST 프록시가 아니다.

- 모델이 이해할 Tool 이름·설명·입력 스키마를 제공한다.
- 사용자 ID, 부서, 역할, 추적 ID를 Workhub에 전달한다.
- Workhub 응답에서 불필요한 필드를 제거한다.
- 날짜·시간과 장비 별칭 같은 입력을 정규화한다.
- 업무 오류를 표준 `success/message/data/error_code` 형태로 반환한다.
- RAG 질의 임베딩과 Re-ranking을 수행한다.

### 7.2 실제 노출 Tool

회의실:

- 예약 가능 회의실 목록
- 회의실 상세
- 내 예약 목록

주차:

- 주차장 현황
- 내 방문객 주차 목록

식당:

- 식당 목록
- 운영 시간
- 날짜별 메뉴
- 혼잡도

사무용품:

- 품목 목록
- 내 신청 목록

사내 문서:

- `policy_search_document`
- `policy_get_source`

어린이집 전용 Tool 등록은 현재 비활성화되어 있고 문서 검색 경로를 사용한다.

### 7.3 Tool 동적 로딩

Agent의 MCP Loader는 서버에서 Tool 목록과 JSON Schema를 읽는다.

1. JSON Schema를 Pydantic 모델로 변환한다.
2. LangChain `StructuredTool`로 감싼다.
3. `user_id`, `department_code`, `role_codes`는 모델이 생성하지 않아도 실행 시 자동 주입한다.
4. 서비스 토큰과 추적 헤더를 붙여 MCP를 호출한다.

이 구조 덕분에 조회 Tool 추가는 Agent 코드의 HTTP 클라이언트를 직접 추가하는 방식보다 변경 범위가 작다.

### 7.4 Compact DTO

예를 들어 회의실 원본에는 운영 JSON, 장비 객체, 내부 상태 등 많은 데이터가 있지만 모델과 UI에는 다음 정도만 보낸다.

- roomId
- roomName
- location
- capacity
- equipment
- availabilityDate
- availableTimeRanges

효과:

- 입력 토큰 감소
- 모델이 잘못 해석할 필드 감소
- Frontend가 기대하는 구조 안정화
- Backend 내부 DTO 변경 영향 축소

### 7.5 재시도

재시도 대상:

- 네트워크 연결 오류
- 429
- 502, 503, 504

재시도하지 않는 대상:

- 400 입력 오류
- 401/403 인증·권한 오류(토큰 갱신 후 한정 재호출은 별도)
- 409 업무 충돌
- 422 검증 오류

대기 시간은 exponential backoff에 0.8~1.2 범위의 random jitter를 곱하고, `Retry-After`가 있으면 우선한다.

---

## 8. Workhub Backend 구현

### 8.1 역할

- 회의실, 주차, 식당, 사무용품 원장 데이터 보유
- 최종 업무 규칙 검증
- 트랜잭션과 DB 제약으로 동시성 보장
- RAG 문서·청크·권한·벡터 검색 제공
- 식당·주차 시뮬레이션 스케줄러 실행

### 8.2 회의실 업무 규칙

- 회의실이 존재하고 활성 상태여야 한다.
- 요청 인원이 정원을 넘으면 안 된다.
- 요청 시간이 운영 시간 안에 있어야 한다.
- 시작은 현재보다 미래여야 한다.
- 같은 회의실의 `CONFIRMED` 예약과 겹치면 안 된다.
- 수정·취소는 본인 예약이어야 한다.

중요한 점은 애플리케이션 조회만으로 충돌을 막지 않는다는 것이다. PostgreSQL exclusion constraint로 시간 겹침을 DB에서도 막아 경쟁 조건을 방어한다.

### 8.3 방문객 주차 규칙

- 방문 날짜는 오늘 이후여야 한다.
- 차량 번호를 검증한다.
- 수정·취소는 본인의 등록이어야 한다.
- 상태를 `REGISTERED` 등으로 관리한다.
- 주차장 만차는 빠른 등록 추천에 반영하지만 등록을 강제로 차단하지 않는다.

이유: 미래 시점의 실제 점유율은 확정할 수 없고 방문객 등록은 예약 좌석제와 다르기 때문이다.

### 8.4 사무용품 규칙

- 신청 가능한 활성 품목이어야 한다.
- 요청 수량은 양수이며 재고 이하여야 한다.
- 여러 품목 일괄 신청은 최대 5개, 중복 품목을 허용하지 않는다.
- 생성 시 재고를 차감한다.
- 수정 시 기존 수량과 새 수량의 차이만큼 재고를 증감한다.
- 취소 시 재고를 되돌린다.
- 변경 사항이 전혀 없는 수정은 정상 수정으로 표시하지 않고 업무 거절로 처리한다.
- 재고 확인과 변경은 트랜잭션 및 잠금으로 보호한다.

### 8.5 스케줄러

`RealtimeSimulationScheduler`가 설정에 따라 주기적으로 다음을 갱신한다.

- 식당별 혼잡도
- 주차장 입차·출차 로그

발표 시 “실제 센서 연동”이라고 말하면 안 된다. 현재는 데모 환경에서 실시간 변화를 보여주기 위한 시뮬레이션 데이터다.

---

## 9. RAG 구현

### 9.1 문서 모델

주요 테이블:

- `rag_documents`: 문서 메타데이터
- `rag_document_versions`: 버전과 처리 상태
- `rag_document_permissions`: 사용자·부서·역할별 권한
- `rag_document_chunks`: 본문 청크, 메타데이터, 임베딩
- `rag_document_aliases`: 문서명 별칭
- `rag_retrieval_logs`: 검색 이력

### 9.2 임베딩 입력

본문만 임베딩하지 않고 다음을 결합한다.

```text
문서명 + 섹션명 + 본문
```

이유:

- 짧은 청크는 제목 문맥이 없으면 의미가 모호하다.
- 사용자가 문서명이나 섹션명으로 질문할 때 검색 가능성이 높아진다.

### 9.3 검색 순서

1. MCP가 질의를 `text-embedding-3-small`로 1536차원 벡터로 변환한다.
2. Workhub가 사용자·부서·역할로 열람 가능한 문서를 먼저 제한한다.
3. pgvector cosine 유사도 검색을 수행한다.
4. `pg_trgm` 기반 제목·섹션·본문 키워드 유사도 검색을 수행한다.
5. Vector 0.6, Keyword 0.4로 weighted reciprocal rank fusion한다.
6. 도메인과 카테고리는 hard filter가 아니라 작은 점수 boost로 사용한다.
7. 상위 후보 10개를 MCP의 BGE Cross Encoder로 다시 정렬한다.
8. 최종 상위 5개 청크를 Agent에 돌려준다.

### 9.4 임계값

- Vector threshold: 0.45
- Keyword threshold: 0.20
- 후보: 10개
- 최종: 5개
- Re-ranker 입력 최대 길이: 256 tokens

### 9.5 권한을 검색 전에 적용하는 이유

검색 후 결과에서 권한 없는 문서를 제거하면 다음 위험이 있다.

- 권한 없는 청크가 후보 점수나 LLM 컨텍스트에 이미 노출될 수 있다.
- 접근 가능한 결과가 밀려 검색 품질이 왜곡된다.
- 로그에 민감 문서 식별자가 남을 수 있다.

따라서 SQL 검색 조건 자체에서 ACL을 적용한다.

### 9.6 Domain과 Category를 soft boost로 둔 이유

Hard filter는 Planner가 도메인을 한 번 잘못 분류하면 정답 문서를 후보에서 완전히 제거한다. Soft boost는 관련 도메인을 우대하면서도 다른 문서가 높은 근거 점수를 가지면 살아남게 한다.

### 9.7 BGE Re-ranker

- 모델: `BAAI/bge-reranker-v2-m3`
- 실행: OpenVINO FP32
- 목적: 질의와 후보 청크를 함께 읽어 정답 근거를 상위로 재배치
- 모델 캐시는 Docker 영구 볼륨에 저장해 재시작마다 다운로드하지 않는다.
- Re-ranker 장애 시 Hybrid 순위를 그대로 사용하는 fail-open 방식이다.

### 9.8 답변 검증

모든 답변을 다시 LLM으로 재작성하지 않는다.

1차 코드 검사:

- 인용 chunk ID가 검색 결과에 존재하는가
- 문서명이 실제 결과와 일치하는가
- 특정 문서를 요청했는데 그 문서가 검색됐는가
- 검색 결과가 비었는데 규정을 단정했는가
- 출처가 누락됐는가

위험 신호가 있을 때만 2차 LLM 검사를 한다.

- 답변 주장과 원문 근거가 의미적으로 일치하는지 검사
- 불일치하면 원본 청크를 다시 제공하고 한 번만 재작성
- 재작성은 새로운 지식을 만드는 것이 아니라 근거 범위 안으로 답변을 축소·교정하는 과정

### 9.9 출처 조회 Tool 분리

- `policy_search_document`: 질문에 답할 근거 검색
- `policy_get_source`: 이미 찾은 문서의 메타데이터와 선택적 원문 조회

`document_id`는 필수이고 `chunk_id`는 선택이다. 문서 정보만 물으면 문서 메타데이터만, 원문을 물으면 청크 원문까지 가져온다.

---

## 10. Frontend 구현

### 10.1 인증 상태

- Access Token은 브라우저 메모리에만 저장한다.
- Refresh Token은 HttpOnly Cookie에 저장해 JavaScript가 읽지 못하게 한다.
- 앱 재진입 시 refresh API로 Access Token을 복구한다.
- 만료 직전 갱신 요청은 하나의 Promise로 합쳐 동시 refresh 폭주를 막는다.

### 10.2 라우팅

- `/login`
- `/auth/callback`
- `/chat/:conversationId?`
- `/mypage`
- `/admin`

채팅방마다 URL이 달라 새로고침해도 같은 대화로 복구된다. 마이페이지와 관리자 페이지도 고유 URL을 사용한다.

### 10.3 SSE 처리

브라우저는 `fetch`의 `ReadableStream`을 직접 읽는다.

- 빈 줄 단위로 SSE event block을 분리한다.
- `status`: 작업 과정 표시
- `token`: Assistant 텍스트 누적
- 구조화 이벤트: 표·카드·Draft UI 추가
- `assistant_message`: 임시 메시지를 서버 메시지 ID로 확정
- `done`: 생성 상태 종료
- `error`: 오류 표시와 상태 복구

### 10.4 자동 스크롤

- 사용자가 하단 근처에 있을 때는 새 토큰과 카드 높이를 따라간다.
- wheel, touch, scrollbar 조작으로 위를 보면 자동 고정을 해제한다.
- 다시 하단으로 이동하면 auto-follow를 복구한다.
- `MutationObserver`와 `ResizeObserver`를 함께 사용해 늦게 렌더링되는 표·Draft 크기 변화까지 추적한다.

### 10.5 Draft Form

회의실, 주차, 사무용품은 입력 구조가 다르므로 도메인별 Renderer가 존재한다.

- 회의실: 날짜, 회의실, 인원, 시작·종료 시각
- 주차: 날짜, 주차장, 담당자/방문객, 차량 번호, 전화번호
- 사무용품: 최대 5개 품목과 수량, 신청 사유

공통 UX:

- 최종 확인 제목
- 닫기와 확정 버튼
- 검증 오류
- 실행 중·완료·실패 상태
- 처리 완료 후 재실행 방지

---

## 11. 인증과 권한

### 11.1 사용자 로그인

```text
Browser
 -> Final Backend /oauth2/authorization/azure
 -> Microsoft Entra ID
 -> Final Backend /login/oauth2/code/azure
 -> 일회용 Login Code 발급
 -> Frontend /auth/callback?code=...
 -> /api/v1/auth/token/exchange
 -> Access Token + HttpOnly Refresh Cookie
```

왜 토큰을 Redirect URL에 직접 넣지 않는가:

- 브라우저 기록, 프록시 로그, Referer에 토큰이 노출될 수 있다.
- 짧은 수명의 일회용 코드만 URL에 넣고 서버 API에서 토큰으로 교환한다.

### 11.2 Refresh Token 회전

- Refresh Token은 Redis에서 유효 상태를 관리한다.
- 갱신할 때 기존 Token을 폐기하고 새 Token으로 교체한다.
- 탈취된 이전 Token 재사용을 막는다.
- Refresh API는 Cookie 기반이므로 CSRF Token을 요구한다.

### 11.3 서버 간 인증

Final Backend가 자체 OAuth2 Authorization Server 역할도 수행한다.

| 호출 | Client | Scope |
|---|---|---|
| Final Backend -> AI Agent | `chat-backend-client` | `ai-agent.invoke` |
| AI Agent -> MCP | `ai-agent-client` | `mcp.call` |
| MCP -> Workhub | `mcp-server-client` | `workhub.api` |
| Final Backend -> Workhub | `chat-backend-workhub-client` | `workhub.api` |
| 각 서버 -> Log API | 각 서비스 client | `logs.write` |

Client Credentials를 쓰는 이유:

- 서버 자체의 신원을 증명한다.
- 사용자 Access Token을 여러 서버에 그대로 전달하지 않는다.
- 호출 가능한 API를 Scope로 최소화한다.

사용자 권한은 서비스 토큰과 별개로 `user_id`, `department_code`, `role_codes` 문맥을 전달해 검사한다.

---

## 12. 데이터 저장소

### 12.1 Final PostgreSQL

- 사용자, SSO 계정, 직원 프로필
- 조직, 역할, 권한, 연결 테이블
- 채팅방, 메시지
- Action Draft
- 통합 Chat Response Snapshot
- 멱등성 요청
- 인증·관측·Tool·LLM·RAG 로그

### 12.2 Workhub PostgreSQL

- 회의실, 장비, 별칭, 예약
- 주차장, 입출차 로그, 방문객 등록
- 식당, 메뉴, 운영 시간, 혼잡도
- 사무용품, 신청, 신청 품목
- RAG 문서, 버전, 권한, 별칭, 청크, 검색 로그
- Workhub 멱등성 요청

### 12.3 Redis

Final Backend Redis:

- Refresh Token 유효 상태
- OAuth Login Code

Agent Redis:

- LangGraph Checkpoint
- 사용자 장기 기억 Store

Workhub Redis:

- 현재 구성의 보조 캐시·상태 저장 용도

### 12.4 장기 기억과 Checkpoint 차이

- Checkpoint: 특정 대화의 AgentState. 메시지 흐름을 이어가기 위한 실행 상태다.
- Memory: 대화를 넘어 유지할 사용자 사실과 선호다. 예: 자주 오는 방문객 차량 번호.

둘을 합치면 대화 상태와 사용자 프로필 성격의 정보가 섞여 만료·삭제 정책을 관리하기 어렵다.

---

## 13. 멱등성과 재시도

### 13.1 멱등성

같은 변경 요청이 네트워크 재전송이나 더블 클릭으로 여러 번 도착해도 업무는 한 번만 실행돼야 한다.

식별:

- `Idempotency-Key`
- operation
- user ID
- 요청 내용 SHA-256 hash

판정:

- 같은 키 + 같은 요청 + 완료: 저장된 결과 재생
- 같은 키 + 처리 중: 202와 재시도 안내
- 같은 키 + 다른 요청 내용: 409 충돌
- 이전 업무 실패: 저장된 업무 오류를 일관되게 반환

### 13.2 왜 Retry와 Idempotency를 같이 써야 하는가

- Retry만 있으면 POST가 중복 실행될 수 있다.
- Idempotency만 있으면 일시 장애 후 자동 복구가 되지 않는다.
- 조회는 비교적 자유롭게 재시도하고, 변경은 멱등키가 있을 때만 안전하게 재시도한다.

### 13.3 업무 거절과 시스템 실패

| 상태 | 의미 | 예시 |
|---|---|---|
| `success` | 업무 완료 | 예약 성공 |
| `rejected` | 시스템은 정상이나 업무 규칙 위반 | 예약 충돌, 재고 부족 |
| `failure` | 시스템·연동 장애 | DB 오류, 500, MCP 연결 실패 |
| `timeout` | 제한 시간 초과 | Agent 응답 시간 초과 |

409를 무조건 장애로 계산하지 않고 업무 코드로 구분한다.

---

## 14. 로그와 관측

### 14.1 로그 종류

- `auth_audit_log`: 로그인, 로그아웃, 인증 실패
- `observability_event`: 공통 요청·응답·업무 이벤트
- `tool_call_log`: Tool 입력 요약, 결과, 지연, 상태
- `llm_usage_log`: 모델, prompt/completion/total token, 지연
- `rag_search_log`: 질의, 검색 설정, 후보와 결과, 지연

### 14.2 전달 방식

```text
AOP / Python Decorator
 -> 프로세스 메모리 Queue
 -> 크기 또는 시간 기준 Batch
 -> Final Backend Log API
 -> Kafka Topic
 -> Consumer
 -> Log Table
```

메모리 배치를 쓰는 이유:

- 모든 로그마다 동기 HTTP를 보내면 사용자 응답 지연이 증가한다.
- Batch로 네트워크 호출 횟수를 줄인다.
- 로그 장애가 업무 실패로 전파되지 않도록 fail-open으로 처리한다.

### 14.3 추적 ID

- `trace_id`: 한 사용자 요청의 전체 흐름
- `request_id`: 개별 HTTP 요청
- `conversation_id`: 대화
- `user_id`: 사용자
- `tool_call_id`: Tool 호출
- `draft_id`: 변경 초안
- `idempotency_key`: 중복 실행 판정

이 값들을 함께 보면 Browser 요청부터 Workhub 처리까지 연결해 장애를 분석할 수 있다.

### 14.4 대시보드 집계 원칙

- 요청량은 동일한 완료 이벤트를 기준으로 집계해야 한다.
- 답변 성공률은 Agent가 사용자에게 최종 응답을 전달했는지로 계산한다.
- Workhub의 정상 업무 거절을 답변 실패로 포함하지 않는다.
- 평균 토큰은 그룹 평균의 평균이 아니라 전체 토큰 합계 / 유효 요청 수로 계산한다.

---

## 15. 테스트와 평가

### 15.1 코드 테스트

| 서버 | 도구 | 측정 |
|---|---|---|
| Final Backend | JUnit, JaCoCo | 라인·분기 |
| Workhub Backend | JUnit, JaCoCo | 라인·분기 |
| AI Agent | pytest, pytest-cov | statement·branch |
| MCP Server | pytest, pytest-cov | statement·branch |

최근 장표 기준 통합 커버리지 표기는 73.63%다. 단, 발표에서는 단순 네 서버 백분율 평균인지, 전체 실행 가능 라인 수로 가중 계산한 값인지 산식을 명확히 해야 한다.

### 15.2 Agent 하네스

개발용 73개와 최종 평가용 60개 데이터셋이 있다.

검증 항목:

- 도메인 정확도
- 필수·금지 Tool
- Tool 호출 순서
- 필수 인자와 날짜 해석
- 구조화 출력 타입
- 정상 완료 여부
- prompt/completion/total token
- 첫 화면 표시, 첫 token, 전체 응답, Tool 지연

Agent는 최종 DB 변경을 직접 하지 않으므로 하네스의 기본 Tool 평가는 DB mutation을 검사하지 않는다. 업무 규칙과 실제 DB 변경은 Final Backend·Workhub 통합 테스트 책임이다.

### 15.3 개발용과 Holdout

- 개발용: 실패 원인을 보고 프롬프트·코드·데이터를 반복 개선한다.
- Holdout: 모델이나 릴리스 후보의 최종 일반화 성능을 확인한다.
- Holdout 결과를 보고 직접 튜닝했다면 더 이상 순수 Holdout이 아니므로 회귀 세트로 옮기고 새 Holdout을 만든다.

### 15.4 RAG 평가

300개 평가 데이터:

- 개발용 50개
- 최종 평가용 250개
- 정답 문서·청크
- 무응답 여부
- 권한 조건

검색 지표:

- Recall@K
- Precision@K
- MRR@K
- nDCG@K
- 관련 문서 미검색률
- 무응답 질문 오답 반환률
- 권한 없는 문서 노출률
- P95 지연

답변 지표:

- 사실 정확성
- Faithfulness
- 질문 의도 충족
- 논리 일관성
- 설명 명확성
- 출처 정확성

### 15.5 모델 비교 시 주의

- 같은 데이터셋, 같은 평가 기준, 같은 시간 기준을 사용한다.
- 모델만 바꾸고 프롬프트나 Tool 목록을 동시에 바꾸면 공정한 비교가 아니다.
- 평균뿐 아니라 P95와 실패 상위 사례를 본다.
- 긴 지연은 LLM 자체뿐 아니라 반복 Tool 호출, 재시도, RAG Re-ranking을 분해해 봐야 한다.

---

## 16. Docker 배포와 운영

### 16.1 기본 서비스

- frontend
- final-backend
- agent
- mcp-server
- workhub-backend
- final-postgres
- workhub-postgres
- final-redis
- agent-redis
- workhub-redis
- kafka

Kafka UI는 선택 profile이다.

### 16.2 네트워크

- 컨테이너끼리는 Compose 서비스 이름으로 통신한다.
- `localhost`는 각 컨테이너 자신을 의미하므로 내부 호출에 쓰면 안 된다.
- 브라우저는 Frontend Nginx 한 곳으로 접속하고 `/api`, `/oauth2`, `/login/oauth2`를 Final Backend로 프록시한다.

### 16.3 볼륨

- 두 PostgreSQL 데이터
- Redis 데이터
- Kafka 데이터
- Hugging Face Re-ranker 모델 캐시

`docker compose down`은 볼륨을 유지한다. `down -v`는 DB까지 지우므로 초기화가 목적일 때만 사용한다.

### 16.4 환경변수

주요 비밀정보:

- Azure Client ID/Secret
- OpenAI API Key
- 로컬 LLM API Key
- JWT Secret
- OAuth RSA Private/Public Key
- 서비스별 Client Secret
- DB Password

`.env`는 커밋하지 않고 `.env.example`에는 실제 값 대신 placeholder만 둔다.

### 16.5 GPU 서버 연결

Agent는 `ONPREM_LLM_BASE_URL`로 Ollama의 OpenAI 호환 API를 호출한다. 모델명은 `/v1/models`가 반환하는 정확한 ID와 일치해야 한다. 예를 들어 서버가 `gemma4-finetuned-q4:latest`를 반환하면 설정도 그 ID를 기준으로 확인해야 한다.

---

## 17. 장애 분석 체크리스트

### 답변 생성 실패

1. Agent `/health` 확인
2. `ONPREM_LLM_BASE_URL`, 모델 ID 확인
3. Agent 컨테이너 안에서 `/v1/models` 호출
4. Final Backend -> Agent OAuth 토큰 발급 확인
5. Agent 로그에서 Planner structured output 오류 확인
6. `trace_id`로 LLM/Tool 로그 연결

### RAG가 모두 무응답

1. MCP 컨테이너의 `OPENAI_API_KEY` 확인
2. 임베딩 호출 성공과 차원 1536 확인
3. Workhub DB의 문서 version이 READY인지 확인
4. 청크 embedding이 null인지 확인
5. 사용자 부서·역할 문맥이 MCP와 Workhub까지 전달됐는지 확인
6. ACL 조건으로 모두 제거됐는지 확인
7. `rag_retrieval_logs`, `rag_search_log` 확인
8. threshold와 Re-ranker 이전 후보를 분리해 확인

### 로그인 Callback 오류

1. 브라우저가 실제 접속한 origin 확인
2. `FRONTEND_OAUTH_SUCCESS_REDIRECT_URI` 확인
3. Azure Redirect URI와 `/login/oauth2/code/azure` 일치 확인
4. HTTP/HTTPS, 80/3000 포트 혼용 확인
5. Nginx `X-Forwarded-Proto`, `Host` 헤더 확인

### 구조화 카드가 새로고침 후 사라짐

1. Assistant 메시지가 저장됐는지 확인
2. `chat_response_snapshots`에 message ID와 snapshot type이 있는지 확인
3. 메시지 조회 응답에 snapshot이 attach되는지 확인
4. Frontend store가 이벤트와 조회 응답을 같은 모델로 변환하는지 확인

### 같은 변경이 두 번 실행됨

1. Frontend가 같은 요청에 같은 Idempotency Key를 유지했는지 확인
2. Final Backend Draft 상태와 version 확인
3. Workhub `idempotency_request` 확인
4. 요청 hash가 불안정한 필드 순서 때문에 달라졌는지 확인
5. DB 고유·배제 제약이 마지막 방어를 하는지 확인

---

## 18. 발표 전에 반드시 정리할 현재 코드 차이

이 항목은 결함 목록이라기보다 “현재 코드 기준으로 무엇을 말해야 하는가”를 정리한 것이다.

### 18.1 Draft Tool 완전 통합 여부

- 현재 코드: 도메인별 생성·수정·취소 Draft Tool 9개
- 공통점: 모두 공통 Action Draft 결과 계약과 승인 경로 사용
- 안전한 발표 표현: “변경 Tool을 MCP에서 숨기고, Agent 내부 Draft 결과 계약과 Backend 승인 경로로 통일했다.”
- 피할 표현: “Agent에는 Draft Tool이 하나만 있다.”

### 18.2 어린이집

- Planner에는 `childcare` 도메인이 있다.
- MCP 어린이집 전용 Tool 등록은 비활성화되어 있다.
- 실제 안내는 사내 문서 RAG를 이용한다.

### 18.3 쿼리·임베딩 Redis 캐시

현재 체크아웃에서 OAuth/JWKS/장비 카탈로그 캐시는 확인되지만, RAG 질의 임베딩 결과를 Redis에서 읽고 쓰는 완성된 경로는 명확히 확인되지 않는다. FR-17 완료를 주장하려면 캐시 키, TTL, hit/miss 로그와 실제 호출 경로를 다시 확인해야 한다.

### 18.4 임베딩 자동 재처리

DB migration에는 문서 버전의 임베딩 처리 상태가 있지만, 현재 Workhub에서 주기적으로 PENDING/FAILED 버전을 찾아 재임베딩하는 Scheduler 구현은 확인되지 않는다. 실시간 시뮬레이션 Scheduler와 혼동하면 안 된다.

### 18.5 Agent Health/State API

현재 Agent에는 health와 state/session 관련 API가 남아 있다. 명세서에서 제거했다고 작성했다면 실제 라우터 등록과 배포 healthcheck 용도를 다시 대조해야 한다. health는 Docker가 컨테이너 준비 상태를 확인하는 데 사용한다.

### 18.6 조직 삭제 API

Final Backend 조직 Controller에는 삭제 API가 남아 있는지 현재 코드와 최종 기능 명세서를 다시 맞춰야 한다.

### 18.7 Agent LLM-as-a-Judge

Agent 하네스의 결정적 Tool 평가는 구현돼 있다. 현재 체크아웃에서는 Judge 코드가 실행 경로에 완전히 연결됐다는 근거가 뚜렷하지 않다. 반면 MCP RAG 평가에는 답변 평가 구조가 있다. 발표에서는 실제 생성된 Judge 리포트가 있는 범위만 완료라고 말한다.

### 18.8 모델 평가 수치

일부 장표의 Gemma Tool argument 정확도가 99.30%와 98.63%로 다르다. 동일 run과 동일 분모인지 확인하고 하나로 통일한다.

---

## 19. 신입 개발자 기준 예상 질문과 답변

### A. 전체 구조

**Q1. 왜 Backend가 두 개인가요?**  
Final Backend는 사용자·인증·채팅·승인 관문이고 Workhub는 업무 원장과 업무 규칙을 담당한다. 사용자 경험 계층과 업무 도메인을 분리해 독립 배포·테스트·확장이 가능하다.

**Q2. MCP 없이 Agent가 Workhub REST API를 직접 호출하면 안 되나요?**  
가능하지만 Agent가 인증, URL, Backend DTO, 오류 형식을 모두 알아야 한다. MCP가 Tool 계약과 Compact DTO를 제공하면 모델과 업무 API의 결합도가 낮아진다.

**Q3. 왜 모든 서버를 하나로 합치지 않았나요?**  
개발 규모만 보면 모놀리식이 단순하지만, 프로젝트 목표가 AI 오케스트레이션·업무 서버·인증·관측 책임을 분리하고 교체 가능성을 보여주는 데 있다. 대신 분산 시스템 복잡성은 인증, 멱등성, 추적 로그로 보완했다.

**Q4. 이 구조에서 가장 중요한 경계는 무엇인가요?**  
AI 제안과 실제 업무 변경의 경계다. Agent는 Draft를 만들고, Final Backend가 사용자 승인 이후 정확한 값을 실행한다.

**Q5. Agent가 장애 나면 기존 업무 API도 못 쓰나요?**  
대화형 기능은 영향받지만 Workhub REST API와 데이터 모델 자체는 독립적이다. 구조적으로 일반 UI나 다른 클라이언트를 붙일 수 있다.

### B. Agent

**Q6. Planner와 Action을 왜 분리했나요?**  
Planner는 도메인만 좁히고 Action은 해당 도메인의 Tool과 응답을 처리한다. 한 모델 호출에 모든 Tool을 노출하는 것보다 선택 공간과 프롬프트 복잡도를 줄인다.

**Q7. Planner가 잘못 분류하면 어떻게 되나요?**  
잘못된 도메인의 Tool만 노출돼 실패할 수 있다. 그래서 분류 프롬프트에 도메인 경계를 명시하고, RAG domain/category는 hard filter가 아니라 soft boost로 둬 검색 단계에서 완전 탈락을 막았다.

**Q8. `smalltalk`과 `unknown`은 같은가요?**  
아니다. smalltalk은 인사·잡담처럼 의도가 명확한 일반 대화이고, unknown은 지원 범위 밖이거나 판단하기 어려운 요청이다. 둘 다 업무 Tool을 호출하지 않을 수 있지만 응답 정책이 다르다.

**Q9. Tool을 여러 번 호출할 수 있나요?**  
일반 정보 조합은 가능하다. 하지만 구조화 목록이나 Draft처럼 결과가 완성된 terminal Tool은 캡처 후 종료해 불필요한 반복을 막는다.

**Q10. 왜 Agent 답변을 항상 LLM으로 마무리하지 않나요?**  
고정 안내와 구조화 UI는 LLM이 다시 작성할 필요가 없다. 반복 호출, 중복 문구, 토큰 낭비를 막기 위해 SSE 계층에서 결정적 문구를 스트리밍한다.

**Q11. 장기 기억에는 무엇을 저장하나요?**  
사용자가 명시적으로 기억하라고 한 사실이나 선호다. 현재 업무 요청의 임시 값은 checkpoint에 두고 장기 기억에 자동 저장하지 않는다.

**Q12. 대화가 길어지면 어떻게 하나요?**  
조건부 summarizer가 오래된 대화를 요약해 state 크기와 토큰을 줄인다. 최근 메시지와 summary를 함께 사용한다.

### C. Action Draft

**Q13. Draft가 필요한 가장 큰 이유는 무엇인가요?**  
자연어 해석 결과를 실제 업무 실행과 분리해 사용자가 최종값을 확인·수정하게 하기 위해서다.

**Q14. 빠른 실행은 안전한가요?**  
필수값이 모두 채워진 제안만 보여주지만 버튼을 누르는 행위 자체가 승인이다. 실행 시 Workhub가 다시 검증하고 추천값을 임의 변경하지 않는다.

**Q15. 추천한 회의실이 승인 순간 예약됐다면?**  
Workhub가 409 업무 충돌로 거절한다. 실행 시 다른 회의실로 몰래 바꾸지 않는다.

**Q16. 왜 최종 실행에서 Agent를 다시 부르지 않나요?**  
이미 구조화된 확정값이 있고 LLM을 다시 거치면 값이 변형될 위험과 지연·토큰 비용이 생긴다.

**Q17. Draft를 두 번 승인하면?**  
상태 CAS와 Idempotency Key가 중복 실행을 막고 완료된 결과를 재생한다.

**Q18. EXECUTING에서 서버가 죽으면?**  
일정 시간 이상 정체된 실행을 실패 상태로 복구해 사용자가 다시 시도할 수 있게 한다. Workhub 멱등성 기록이 실제 중복도 막는다.

### D. MCP와 Tool

**Q19. Tool Schema가 왜 중요한가요?**  
모델이 어떤 인자를 어떤 타입으로 생성할지 결정하는 계약이다. 설명과 예시가 부족하면 차량 번호 일부 누락처럼 argument 오류가 생긴다.

**Q20. 사용자 ID를 모델이 생성하게 하지 않는 이유는?**  
모델이 다른 사용자의 ID를 만들 수 있기 때문이다. 인증 문맥에서 서버가 주입해야 신뢰할 수 있다.

**Q21. 사용하지 않는 변경 Tool을 숨긴 이유는?**  
모델이 승인 없이 Workhub 변경 Tool을 선택할 가능성을 제거하고 Tool 선택 공간도 줄인다.

**Q22. Compact DTO가 토큰 외에 주는 장점은?**  
내부 스키마 노출 감소, 모델 혼동 감소, UI 계약 안정화, 서버 간 결합도 감소다.

**Q23. 장비명 검색은 어떻게 처리하나요?**  
요청과 DB 값을 완전 일치시키지 않고 Workhub 장비 카탈로그와 별칭을 읽어 표준명으로 정규화한다.

### E. RAG

**Q24. 왜 Vector Search만 쓰지 않았나요?**  
문서 번호·규정명·고유 용어는 키워드 검색이 강하고 자연어 의미는 Vector가 강하다. 둘을 결합해 서로의 약점을 보완한다.

**Q25. RRF는 무엇인가요?**  
서로 다른 점수 척도를 직접 합치지 않고 각 검색 결과의 순위를 이용해 결합하는 방식이다. 프로젝트에서는 Vector와 Keyword 가중치를 0.6:0.4로 사용한다.

**Q26. Re-ranker는 Retriever와 무엇이 다른가요?**  
Retriever는 전체 청크에서 빠르게 후보를 찾고 Re-ranker는 소수 후보와 질의를 함께 읽어 더 정확하게 순서를 재배치한다.

**Q27. 왜 BGE를 MCP에서 실행하나요?**  
검색 Tool의 후처리 책임으로 묶어 Agent가 Re-ranker 실행 세부사항을 몰라도 되게 하기 위해서다.

**Q28. Re-ranker가 느리면 어떻게 했나요?**  
후보 수와 max length를 평가하고 OpenVINO FP32로 실행해 품질을 유지하며 CPU P95를 낮췄다.

**Q29. 권한 필터가 정말 안전한가요?**  
SQL 후보 조회 전에 사용자·부서·역할 ACL을 적용한다. 평가 데이터에서도 권한 노출률을 측정한다.

**Q30. 검색 결과가 없으면 왜 LLM 일반 지식으로 답하지 않나요?**  
사내 규정은 최신성과 권한이 중요하다. 근거가 없을 때 추측하면 잘못된 업무 안내가 되므로 명시적으로 fallback한다.

**Q31. Self-Correction이 환각을 완전히 막나요?**  
아니다. 코드 검사와 위험 답변 대상 LLM 검증으로 위험을 줄이는 장치다. 원문과 출처를 제공하고 무응답 정책을 유지하는 것이 함께 필요하다.

**Q32. 왜 모든 RAG 답변을 다시 검사하지 않나요?**  
비용과 지연이 두 배 가까이 증가할 수 있다. 결정적 코드 검사로 위험 신호를 선별한 뒤 필요한 답변만 LLM 검증한다.

### F. 업무 규칙과 DB

**Q33. 회의실 충돌을 Java 코드만으로 막으면 안 되나요?**  
동시 요청이 조회와 저장 사이에 들어올 수 있다. DB exclusion constraint가 최종 경쟁 조건을 막는다.

**Q34. 사무용품 재고는 어떻게 동시성을 보장하나요?**  
트랜잭션 안에서 품목을 잠그고 재고를 검사·변경한다. 배치 신청은 전체 조건을 확인한 뒤 원자적으로 처리한다.

**Q35. 주차장이 만차인데 등록을 허용하는 이유는?**  
방문객 등록은 현재 점유 좌석을 즉시 확보하는 예약이 아니다. 만차 정보는 추천에 쓰되 업무 규칙으로 강제 차단하지 않았다.

**Q36. 업무 오류에 409를 쓰면 장애율이 올라가지 않나요?**  
HTTP 상태만 보지 않고 outcome code와 `rejected` 상태를 기록한다. 답변 실패율에는 실제 응답 전달 실패만 포함한다.

### G. 인증과 보안

**Q37. Access Token을 localStorage에 저장하지 않은 이유는?**  
XSS 발생 시 지속적으로 탈취될 수 있다. 메모리 저장은 새로고침 시 사라지지만 HttpOnly Refresh Cookie로 복구한다.

**Q38. HttpOnly Cookie면 CSRF 위험이 있지 않나요?**  
있다. 그래서 refresh endpoint에 Cookie CSRF Token 검증을 적용하고 SameSite=Lax를 사용한다.

**Q39. 서비스 토큰과 사용자 토큰의 차이는?**  
서비스 토큰은 어느 서버가 호출했는지를 증명하고, 사용자 문맥은 누구의 권한으로 작업하는지를 나타낸다.

**Q40. Scope가 왜 서버마다 다른가요?**  
침해 시 피해 범위를 줄이는 최소 권한 원칙 때문이다. Agent 토큰으로 Workhub API를 바로 호출할 수 없게 한다.

**Q41. JWT 서명키는 왜 비대칭키인가요?**  
Authorization Server만 Private Key로 서명하고 다른 서버는 Public Key/JWKS로 검증할 수 있다. 검증 서버에 서명 권한을 주지 않는다.

### H. 안정성과 관측

**Q42. 왜 409는 재시도하지 않나요?**  
일시 장애가 아니라 동일 시간 예약 충돌 같은 업무 조건이므로 다시 호출해도 자동으로 해결되지 않는다.

**Q43. Jitter는 왜 필요한가요?**  
여러 요청이 같은 지수 백오프 시점에 동시에 재시도하는 thundering herd를 줄인다.

**Q44. 로그 전송 실패가 업무를 막지 않으면 로그를 잃을 수 있지 않나요?**  
그렇다. 업무 가용성을 우선한 trade-off다. 메모리 큐, 배치 재시도, 종료 flush로 손실 가능성을 줄이되 완전한 전달 보장은 별도 로그 브로커 직접 생산 구조가 필요하다.

**Q45. Kafka를 왜 썼나요?**  
로그 생성 속도와 DB 적재 속도를 분리하고, 서버별 이벤트를 topic과 consumer로 비동기 처리하기 위해서다.

**Q46. trace ID만 있으면 충분한가요?**  
아니다. 재시도된 HTTP 요청, Tool 호출, 대화, 사용자를 구분하려면 request/tool/conversation/user ID도 필요하다.

### I. Frontend

**Q47. SSE와 WebSocket 중 SSE를 선택한 이유는?**  
주요 실시간 방향이 서버에서 브라우저로의 단방향 token stream이고 HTTP 인프라와 재연결 처리가 단순하기 때문이다.

**Q48. EventSource를 쓰지 않고 fetch stream을 쓰는 이유는?**  
메시지 본문을 POST로 보내고 Authorization/Idempotency 헤더를 세밀하게 제어해야 하기 때문이다.

**Q49. 자동 스크롤을 항상 하단으로 고정하지 않은 이유는?**  
사용자가 이전 답변을 읽는 중 강제로 내려가면 사용성이 나쁘다. 사용자 조작을 감지해 follow를 해제한다.

**Q50. Form Renderer를 완전히 하나로 합치지 않은 이유는?**  
회의실 시간, 차량 번호, 다중 사무용품처럼 입력 구조와 검증이 다르다. 공통 상태·스타일은 공유하고 도메인 입력은 분리하는 것이 유지보수에 유리하다.

### J. 테스트와 배포

**Q51. 코드 커버리지 70%면 품질이 보장되나요?**  
아니다. 커버리지는 실행된 코드 비율이다. 핵심 업무 규칙, 경계값, 실패·동시성 경로를 어떤 테스트가 덮는지가 더 중요하다.

**Q52. Agent 하네스와 단위 테스트 차이는?**  
단위 테스트는 함수와 서비스 계약을 검증하고 하네스는 실제 모델이 도메인·Tool·인자를 올바르게 선택하는지를 검증한다.

**Q53. 왜 Holdout을 자주 보면 안 되나요?**  
결과를 보고 튜닝하면 해당 데이터에 과적합돼 실제 일반화 성능을 과대평가한다.

**Q54. Docker Compose를 선택한 이유는?**  
발표용 단일 서버에서 여러 서비스, DB, Redis, Kafka를 재현 가능하게 기동하기에 충분하고 Kubernetes보다 운영 복잡도가 낮다.

**Q55. 한 이미지로 모두 합치지 않은 이유는?**  
서비스마다 런타임과 의존성이 다르고 독립 빌드·캐시·재시작이 필요하다. 하나의 Compose 프로젝트이지 하나의 이미지가 아니다.

---

## 20. 주말 학습 일정

### 1일차 오전: 전체 구조

- 2개의 핵심 흐름을 손으로 그린다.
- 다섯 서버의 책임을 한 문장씩 말한다.
- 조회와 변경 경로가 갈라지는 지점을 설명한다.

### 1일차 오후: Agent, MCP, RAG

- LangGraph 노드를 순서대로 설명한다.
- Tool 노출 정책과 Draft Tool 차이를 설명한다.
- ACL -> Hybrid -> Re-rank -> 답변 검증 순서를 말한다.

### 2일차 오전: Backend, 업무 규칙, DB

- 회의실 충돌과 사무용품 재고 동시성을 설명한다.
- Draft 상태와 멱등성 판정을 설명한다.
- snapshot이 새로고침을 어떻게 복원하는지 설명한다.

### 2일차 오후: 인증, 로그, 테스트, 장애 대응

- Azure 로그인과 서버 간 Client Credentials 흐름을 그린다.
- AOP -> Batch -> Kafka -> DB를 설명한다.
- Agent 하네스, RAG 평가, 코드 커버리지의 차이를 말한다.
- 17장의 장애 시나리오를 실제 명령과 로그 위치까지 연습한다.

---

## 21. 발표 직전 암기 카드

### 가장 중요한 설계 선택 5개

1. AI 제안과 실제 변경 실행 분리
2. 사용자 승인 기반 Action Draft
3. MCP Compact DTO와 Tool Governance
4. 권한 선필터 + Hybrid Search + BGE Re-ranking
5. Retry + Idempotency + 분산 추적 로그

### 수치 8개

- RAG 평가 데이터 300개: 개발 50, 최종 250
- Vector:Keyword = 0.6:0.4
- Vector threshold 0.45
- Keyword threshold 0.20
- 후보 10개 -> 최종 5개
- BGE max length 256
- Agent 하네스: 개발 73, Holdout 60
- 코드 통합 커버리지 장표 값 73.63%

### 절대 혼동하지 말 것

- MCP는 조회 중심, 최종 변경은 Final Backend 승인 경로
- 자동 대체는 제안 단계, 승인 후 실행값 자동 변경 금지
- Workhub 409 업무 거절은 시스템 장애가 아님
- RAG 권한은 검색 후가 아니라 검색 전에 적용
- Checkpoint와 장기 기억은 다른 저장 목적
- Compose는 하나의 이미지가 아니라 여러 컨테이너의 통합 실행 정의

---

## 22. 주요 코드 탐색 경로

Final Backend:

- `workspace-Final-Backend/src/main/java/com/metanet/finalbackend/domain/message/controller/MessageController.java`
- `workspace-Final-Backend/src/main/java/com/metanet/finalbackend/domain/actiondraft/ActionDraftService.java`
- `workspace-Final-Backend/src/main/java/com/metanet/finalbackend/domain/chatresponsesnapshot/ChatResponseSnapshotService.java`
- `workspace-Final-Backend/src/main/java/com/metanet/finalbackend/global/config/SecurityConfig.java`
- `workspace-Final-Backend/src/main/java/com/metanet/finalbackend/global/config/OAuth2AuthorizationServerConfig.java`

AI Agent:

- `workspace-Final-AI/orchestrator_agent/graph.py`
- `workspace-Final-AI/orchestrator_agent/schema.py`
- `workspace-Final-AI/orchestrator_agent/action_draft_tools.py`
- `workspace-Final-AI/orchestrator_agent/api/sse.py`
- `workspace-Final-AI/orchestrator_agent/mcp_loader.py`
- `workspace-Final-AI/orchestrator_agent/prompts/`

MCP:

- `workspace-mcp-server/app/main.py`
- `workspace-mcp-server/app/tools/meeting_room_tools.py`
- `workspace-mcp-server/app/tools/parking_tools.py`
- `workspace-mcp-server/app/tools/cafeteria_tools.py`
- `workspace-mcp-server/app/tools/supply_tools.py`
- `workspace-mcp-server/app/tools/policy_tools.py`
- `workspace-mcp-server/app/rag/policy_reranker.py`

Workhub:

- `workspace-Workhub-Backend/src/main/java/com/metanet/workhub/domain/meeting/service/`
- `workspace-Workhub-Backend/src/main/java/com/metanet/workhub/domain/parking/service/`
- `workspace-Workhub-Backend/src/main/java/com/metanet/workhub/domain/supply/service/`
- `workspace-Workhub-Backend/src/main/java/com/metanet/workhub/domain/rag/`
- `workspace-Workhub-Backend/src/main/resources/mapper/rag/`

Frontend:

- `workspace-Final-Front/src/views/ChatView.vue`
- `workspace-Final-Front/src/api/chatApi.js`
- `workspace-Final-Front/src/stores/chatStore.js`
- `workspace-Final-Front/src/components/chat/`
- `workspace-Final-Front/src/router/`

Deployment:

- `deploy/docker-compose.yml`
- `deploy/.env.example`
- `deploy/start.ps1`
- `deploy/stop.ps1`
- `workspace-Final-Front/nginx.conf`

---

## 마무리

이 프로젝트를 잘 설명한다는 것은 사용 기술을 나열하는 것이 아니다. 다음 질문에 일관되게 답하는 것이다.

> 자연어의 불확실성을 어디까지 AI에게 맡기고, 어느 지점부터 결정적 코드와 데이터베이스가 책임지는가?

Office-Link의 답은 다음과 같다.

- 이해·검색·추천은 Agent와 MCP가 담당한다.
- 권한과 업무 규칙은 서버와 DB가 검증한다.
- 실제 변경은 사용자가 확인한 값만 실행한다.
- 실패와 중복은 재시도·멱등성으로 통제한다.
- 결과는 추적 가능한 로그와 반복 가능한 테스트로 검증한다.

이 원칙을 중심으로 답하면 개별 기술 질문이 들어와도 전체 설계와 연결해 설명할 수 있다.
