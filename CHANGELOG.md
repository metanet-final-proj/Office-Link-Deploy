# Changelog

이 문서는 [Keep a Changelog](https://keepachangelog.com/ko/1.1.0/) 형식을 따릅니다.

## [1.0.0] - 2026-08-05

### Added

- 회의실, 방문객 주차, 구내식당, 사무용품, 사내 규정 통합 대화 UI
- LangGraph 기반 도메인 라우팅, Tool 실행, 답변 생성·선택적 RAG 검증
- 사용자 최종 승인을 분리한 Action Draft와 빠른 실행
- FastMCP 기반 업무 조회 Tool과 Compact DTO
- Hybrid Search, 권한 필터, BGE Re-ranker를 적용한 RAG 검색
- Azure SSO와 OAuth2 Client Credentials 기반 통합 인증
- AOP/Decorator, 메모리 배치, Kafka Consumer 기반 로그 파이프라인
- Redis Checkpoint·장기 기억, 멱등성, 지수 백오프와 Jitter 재시도
- Agent/RAG 평가 하네스와 JaCoCo·pytest-cov 커버리지 측정
- Docker Compose 기반 통합 배포와 온프레미스 GPU 서버 연결

### Changed

- 생성·수정·취소 작업을 LLM 직접 실행에서 사용자 승인 후 Backend 직접 실행으로 분리
- 업무 스냅샷 저장 구조를 공통 스냅샷 테이블 중심으로 정리
- RAG 검색 설정 해석과 조회 DTO 경계를 서비스 역할에 맞게 정리
- 도메인별 Draft 생성 경로와 Frontend의 공통 Action Draft 렌더링 구조 정리
- 서비스별 비밀정보를 코드와 Docker Compose에서 `deploy/.env`로 외부화

### Fixed

- 로그 배치 적재 순서와 요청·추적 ID 전파
- 예약·등록·신청 목록의 날짜·상태 필터와 화면 갱신
- 회의실 장비 별칭, 예약 충돌·운영시간 오류 메시지 처리
- SSE 완료 처리, 채팅 전환 시 중복 응답, 구조화 카드 자동 스크롤

### Security

- OAuth Scope와 JWKS 기반 서버 호출 검증
- Tool 입력 로그의 개인정보 마스킹
- 서비스별 Client Secret 분리와 시작 전 배포 Secret 검증
