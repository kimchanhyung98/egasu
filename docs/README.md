# egasu 문서

문서 기본 언어는 한국어이며, `docs/` 아래에서 단일 문서로 관리.
완성된 기획서와 현재 동작 명세만 유지.
리서치 문서는 조사 중에만 임시 허용하며, 조사 완료 후 확정 내용을 정식 문서에 반영하고 삭제.
리뷰 보고서·TODO·작업 일지·검증 실행 기록은 저장하지 않음.

앱의 현재 동작과 적용 조건, 제약을 설명.
동작이 바뀌면 관련 문서를 함께 갱신.

## 앱

- [대시보드](/docs/dashboard.md) — Priority·All Usage 탭, 지표 표시·고정·순서, 키보드 단축키
- [메뉴 막대](/docs/menu-bar.md) — 표시 기준 선택과 Priority 고정
- [데스크톱 위젯](/docs/desktop-widgets.md) — 위젯 추가, Priority와 계정별 지표 선택
- [프로바이더 활성화](/docs/provider-enablement.md) — 첫 실행과 업데이트 뒤에 사용 중인 프로바이더를 감지하는 조건
- [계정](/docs/accounts.md) — 계정 추가·전환·복구, API 키, 계정 이름·순서와 지표 설정
- [설정](/docs/settings.md) — General·Display·Alerts·Advanced의 설정과 베타 업데이트를 켜면 열리는 Labs
- [새로 고침과 캐싱](/docs/refreshing.md) — 데이터가 갱신되는 시점과 가져오기 실패 시 일어나는 일
- [iCloud 동기화](/docs/icloud-sync.md) — 여러 Mac의 지출 기록을 합치는 방식
- [구독과 모델 가격](/docs/pricing.md) — 프로바이더별 구독 이름·가격과 토큰 비용 계산 방식
- [업데이트](/docs/updates.md) — 자동 업데이트, 수동 확인, 베타 채널
- [개인정보 및 사용 데이터](/docs/privacy.md) — 공유되는 익명 데이터와 끄는 방법

## 통합

- [명령줄 인터페이스](/docs/cli.md) — 에이전트와 스크립트를 위한 1회 실행 캐시 조회와 강제 조회
- [로컬 HTTP API](/docs/local-http-api.md) — `127.0.0.1:6736`에서 다른 앱이 사용량을 읽는 방법
- [프록시](/docs/proxy.md) — 프로바이더 사용량·공개 상태·모델 가격 조회와 Codex Reset Watch에 SOCKS5·HTTP·HTTPS 프록시 적용

## 프로바이더

각 프로바이더가 추적하는 항목, 인증 정보의 출처, 오류가 표시될 때 할 일.

- [Antigravity](/docs/providers/antigravity.md)
- [Claude](/docs/providers/claude.md)
- [Codex](/docs/providers/codex.md)
- [Copilot](/docs/providers/copilot.md)
- [Cursor](/docs/providers/cursor.md)
- [Devin](/docs/providers/devin.md)
- [Grok](/docs/providers/grok.md)
- [Kimi](/docs/providers/kimi.md)
- [Kiro](/docs/providers/kiro.md)
- [OpenCode](/docs/providers/opencode.md)
- [OpenRouter](/docs/providers/openrouter.md)
- [Z.ai](/docs/providers/zai.md)

## 개발자용

앱 구성과 기능 확장 방법.

- [아키텍처](/docs/architecture.md) — 구성 루트, 스토어, 프로바이더 파이프라인, AppKit 브리지
- [사용량 수집](/docs/usage-collection.md) — 지원 대상, 공통 사용 기록, 귀속·중복·가격·실패 처리 규칙
- [프로바이더 추가](/docs/adding-a-provider.md) — 지표 계약과 등록/테스트/문서화 단계
- [디버깅과 로그 캡처](/docs/debugging.md) — 로컬 빌드 실행과 로그 스트리밍
- [로깅](/docs/logging.md) — 파일 로그, 로그 레벨, 서브시스템 태그, 민감 정보 마스킹 범위
