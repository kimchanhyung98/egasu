# Changelog

This changelog starts with v0.8.0, the first release of this fork.

## v1.0.0-beta.5

### New Features

- Codex Business의 개인 크레딧 사용량·상한을 일반 월간 한도 바로 아래 표시. All Usage의 Minimal·Cards에서 상한과 사용률·잔여율 표시. 계정별 고정·숨김, CLI와 로컬 HTTP 조회 지원. [#221](https://github.com/kimchanhyung98/egasu/pull/221) · [#232](https://github.com/kimchanhyung98/egasu/pull/232) by @kimchanhyung98
- OpenCode Go 서버에서 세션·주간·월간 사용률과 초기화 시각 조회. Soft Limit은 주간·월간 실측값 사용. [#223](https://github.com/kimchanhyung98/egasu/pull/223) by @kimchanhyung98
- Cursor 통합 계정에서 주간 공유 한도, 선불 잔액, 월간 추가 지출을 각각 표시. [#220](https://github.com/kimchanhyung98/egasu/pull/220) by @kimchanhyung98
- Claude·Codex·Cursor에서 같은 계정의 소진된 한도를 다시 사용할 수 있을 때 알림 선택 가능. [#224](https://github.com/kimchanhyung98/egasu/pull/224) by @kimchanhyung98
- 빈 Priority 화면에서 전체 사용량으로 이동. 메뉴 막대 표시 설정의 ⓘ에서 지표 고정 방법 안내. [#225](https://github.com/kimchanhyung98/egasu/pull/225) by @kimchanhyung98
- macOS Spotlight가 앱을 색인한 뒤 `openusage`와 `usage`로 egasu 검색 가능. [#216](https://github.com/kimchanhyung98/egasu/pull/216) by @kimchanhyung98

### Bug Fixes

- 가격표 본문이 없거나 손상됐으면 다시 다운로드. 사용할 수 없는 304 응답 뒤에도 마지막 정상 가격을 유지하고 본문 재조회. [#231](https://github.com/kimchanhyung98/egasu/pull/231) by @kimchanhyung98
- 공개 가격표의 잘못된 단가 제외. 개별 비용을 계산할 수 없는 기록도 유효한 토큰은 유지하고 비용만 미확정 처리. [#230](https://github.com/kimchanhyung98/egasu/pull/230) by @kimchanhyung98
- Claude의 조회 권한이 없는 저장 로그인 뒤에도 같은 계정의 Desktop 로그인으로 사용량 조회. 조회 중 CLI 로그인이 바뀌면 새 로그인 우선. [#228](https://github.com/kimchanhyung98/egasu/pull/228) by @kimchanhyung98
- Cursor 회복 알림에서 구독·요청 수와 개인·팀 한도를 각각 비교. 주간 지표가 없어도 월간 추가 지출 상한의 회복 감지. [#229](https://github.com/kimchanhyung98/egasu/pull/229) by @kimchanhyung98
- Claude OAuth 갱신 시 기존 권한 범위를 유지하고 서버가 반환한 범위 저장. 조회 권한이 없으면 사용 가능한 다른 로그인 확인. 대체 로그인이 없으면 로컬 기록과 재로그인 안내 표시. [#219](https://github.com/kimchanhyung98/egasu/pull/219) by @kimchanhyung98
- Cursor 조회 중 로그인이 바뀌면 이전 계정의 사용량·잔액 폐기. [#220](https://github.com/kimchanhyung98/egasu/pull/220) by @kimchanhyung98
- OpenCode Go 인증 JSON·파일·환경 변수의 우선순위를 OpenCode와 일치시킴. 키가 바뀐 응답과 시작 시 이전 한도 캐시 제외. 프로젝트·플러그인의 키 재지정은 미지원. [#223](https://github.com/kimchanhyung98/egasu/pull/223) by @kimchanhyung98
- 프록시 설정의 유효 포트를 1~65535로 제한. 포트를 생략하면 해당 방식의 기본값 사용. [#217](https://github.com/kimchanhyung98/egasu/pull/217) by @kimchanhyung98
- 같은 커밋의 베타·정식 승격에 별도 Sparkle 빌드 번호 부여. 재시도는 공개 DMG를 재사용하고 과거 피드 항목과 서명 보존. 후속 버전 게시 후에도 DMG만 공개된 이전 태그의 피드 복구 가능. [#226](https://github.com/kimchanhyung98/egasu/pull/226) by @kimchanhyung98

### Chores

- 프로바이더 추가 안내의 OpenCode 예시 갱신. 최신 Codex·Cursor·OpenCode Go·Priority 안내 이미지 무손실 압축. [#222](https://github.com/kimchanhyung98/egasu/pull/222) by @imgbot, @kimchanhyung98
- 오프라인 사용량 추정에 쓰는 LiteLLM·models.dev 번들 가격표 갱신. [#227](https://github.com/kimchanhyung98/egasu/pull/227) · [#233](https://github.com/kimchanhyung98/egasu/pull/233) by @kimchanhyung98
- 사이트 CI에서 검증할 커밋의 잠금 파일로 Playwright 1.65.0 컨테이너 선택. [#168](https://github.com/kimchanhyung98/egasu/pull/168) by @dependabot, @kimchanhyung98
- Copilot의 GitHub 인증 출처와 Z.ai API 호스트 안내 보완. [#218](https://github.com/kimchanhyung98/egasu/pull/218) by @kimchanhyung98
- Astro를 7.4.11로 갱신. [#167](https://github.com/kimchanhyung98/egasu/pull/167) by @dependabot
- PostHog SDK를 3.97.0으로 갱신. [#169](https://github.com/kimchanhyung98/egasu/pull/169) by @dependabot
- Kimi·실험실·숨긴 지표 안내 이미지 용량 최적화. [#215](https://github.com/kimchanhyung98/egasu/pull/215) by @imgbot

---

### Changelog

**Full Changelog**: [v1.0.0-beta.4...v1.0.0-beta.5](https://github.com/kimchanhyung98/egasu/compare/ed0a6826c565131a6225be0cb208c14710226d1a...f9cfe8df9cde0735f2d43d9a0dad9eadef0e6aea)

## v1.0.0-beta.4

### New Features

- 베타 업데이트를 켜면 설정에 실험실 탭 표시. 기존 Soft Limit과 Terminal Helper를 실험실로 이동. 실측한 주간·월간 한도에 Soft Limit 적용. 경고와 위험을 포함해 Priority 표시 조건을 개별 설정하고, 모든 조건을 끄면 전체 사용량만 표시. ([#208](https://github.com/kimchanhyung98/egasu/pull/208)) by @kimchanhyung98
- 실험실에서 Codex·Claude·Kimi의 한도를 확인한 뒤 새 CLI를 시작하는 명령 복사. 그 외 지원 프로바이더는 한도 확인 명령 제공. 이미 실행 중인 작업은 계속 진행. ([#210](https://github.com/kimchanhyung98/egasu/pull/210)) by @kimchanhyung98

### Bug Fixes

- Kimi 세션 사용량이 0%여도 서버가 제공한 초기화 시각을 표시하고, 시각이 없거나 유효하지 않으면 사용량만 표시. ([#214](https://github.com/kimchanhyung98/egasu/pull/214)) by @kimchanhyung98
- Cursor 조회 시간 초과 후 승인 창 없이 계정을 재확인. 같은 계정의 마지막 사용량과 지출 이력을 유지하고 이전 한도 측정값은 자동화 판단에서 제외. ([#211](https://github.com/kimchanhyung98/egasu/pull/211)) by @kimchanhyung98
- OpenRouter·Z.ai에서 API 키를 저장·삭제할 때 손상된 JSON, 한 줄 설정과 기존 구조화된 필드 보존. 기존 파일 형식 때문에 저장할 수 없으면 오류 안내. ([#212](https://github.com/kimchanhyung98/egasu/pull/212)) by @kimchanhyung98
- 복사한 CLI 시작 명령에서 셸 별칭·함수로 로그인이 바뀌는 문제 수정. Codex 시작 명령은 파일 인증을 사용하며 Keychain 전용 로그인과 인증 저장소를 강제하는 관리자 정책은 지원 범위에서 제외. Kimi는 기본 모델의 서비스와 인증을 확인할 수 있을 때만 시작 허용. ([#213](https://github.com/kimchanhyung98/egasu/pull/213)) by @kimchanhyung98
- 이전 OpenUsage의 Claude 셸 함수를 사용하는 환경에서 기본 CLI 로그인 이전과 검증 후 함수 제거. 토큰 갱신과 계정 전환이 겹치거나 전환 중 앱이 종료된 경우의 복구 개선. 확인할 수 없는 로그인은 보존하고 이전 보류. ([#206](https://github.com/kimchanhyung98/egasu/pull/206)) by @kimchanhyung98
- OpenRouter·Z.ai API 키 읽기 오류를 표시하고, 키 삭제가 실패하면 계정 추적 유지. ([#207](https://github.com/kimchanhyung98/egasu/pull/207)) by @kimchanhyung98
- Cursor 계정별 캐시와 사용 이력 복구, Kimi 일부 응답 처리 개선. ([#201](https://github.com/kimchanhyung98/egasu/pull/201)) by @kimchanhyung98
- 구독 타이머 실행 직전 한도와 로그인 재확인. 한도 기간이 바뀌면 새 기간의 잔량 알림 재개. ([#202](https://github.com/kimchanhyung98/egasu/pull/202)) by @kimchanhyung98
- 셸 시작 파일이 배너를 출력하는 환경에서 PATH를 보존해 Codex 실행 파일 탐색 오류 수정. ([#204](https://github.com/kimchanhyung98/egasu/pull/204)) by @shlifedev
- CLI를 먼저 사용한 경우에도 앱 첫 실행 시 로컬 프로바이더 탐지. ([#199](https://github.com/kimchanhyung98/egasu/pull/199)) by @kimchanhyung98
- 사이트 미리보기에서 계정 이름 중복 방지 및 숨긴 지표를 다시 표시하는 방법 안내. ([#198](https://github.com/kimchanhyung98/egasu/pull/198)) by @kimchanhyung98
- 사용량 조회·인증·계정 전환 실패를 진단 로그에서 구분. 오류 신고용 로그의 민감 정보 보호 개선. ([#205](https://github.com/kimchanhyung98/egasu/pull/205)) by @kimchanhyung98

### Chores

- 첫 실행·오프라인 비용 추정에 사용하는 LiteLLM·models.dev 번들 단가표 갱신. ([f8a068e](https://github.com/kimchanhyung98/egasu/commit/f8a068ec42572d80e927509896c48187641d6d94)) by @kimchanhyung98
- 문서와 사이트 이미지의 색상 정보를 보존하면서 파일 크기 축소. ([#197](https://github.com/kimchanhyung98/egasu/pull/197)) by @kimchanhyung98
- 계정 이름 숨김 표시 검증 및 기존 레이아웃 설정 이전 조건 문서화. ([#200](https://github.com/kimchanhyung98/egasu/pull/200)) by @kimchanhyung98
- 설치·업데이트 절차와 프로바이더 설명을 한국어로 정리. ([#209](https://github.com/kimchanhyung98/egasu/pull/209)) by @kimchanhyung98

---

### Changelog

**Full Changelog**: [v1.0.0-beta.3...v1.0.0-beta.4](https://github.com/kimchanhyung98/egasu/compare/0702b04e0ffab90ca6c8a8e2a6db5e29a3a0dd90...f8a068ec42572d80e927509896c48187641d6d94)

## v1.0.0-beta.3

### New Features

- Claude·Kimi·Antigravity·Z.ai 활성 계정의 지원 한도에 구독 타이머 자동 시작 추가. 실행 전에 최신 한도와 인증을 확인하며, 전송하는 짧은 메시지는 구독 사용량을 소모할 수 있음. ([#183](https://github.com/kimchanhyung98/egasu/pull/183)) by @kimchanhyung98
- Priority와 macOS 알림에 남은 한도, 예상 소진 속도, 초기화까지 남은 시간과 잔량을 반영. 빠른 소진과 초기화 전 사용의 Priority 표시·알림을 각각 설정. ([#185](https://github.com/kimchanhyung98/egasu/pull/185)) by @kimchanhyung98
- Accounts에서 계정 추가와 순서를 관리. Claude·Codex 등록 계정의 이름 변경·재로그인·저장 로그인 전환·Keychain 접근 재시도 지원. OpenRouter·Z.ai는 API 키 관리 지원. Customize·Increase Transparency·Party Mode 제거. ([#186](https://github.com/kimchanhyung98/egasu/pull/186)) by @kimchanhyung98
- All Usage에 기존 Density 설정을 대체하는 Minimal 목록과 계정별 Cards 추가. 계정별 조회 상태와 한도 지표의 초기화 시각 표시. 계정과 지표의 표시 순서는 Accounts에서 관리. ([#188](https://github.com/kimchanhyung98/egasu/pull/188)) by @kimchanhyung98
- 저장한 기본 탭이 없으면 처음 여는 대시보드에 Priority 표시. 메뉴 막대에서 Running Out·Priority·Pinned Only 기준으로 지표를 최대 5개 표시. 저장한 Priority 고정 목록이 없고 기존 별표 설정이 기본값과 다르면, 표시 중이며 고정 가능한 별표 지표를 한 번 이전. 새 설치와 레이아웃 초기화에서 Codex Reset Watch 표시를 기본으로 켬. 알림은 별도 설정에서 켤 수 있으며 기본값은 꺼짐. ([#189](https://github.com/kimchanhyung98/egasu/pull/189)) by @kimchanhyung98
- 기간별 내역에서 비용·토큰 상위 모델을 확인하고, Total Spend의 도넛 중앙이나 범례 값에서 비용·백만 토큰당 비용·토큰을 전환. Priority·프로바이더 섹션·Total Spend·기간별 내역을 PNG로 복사. 공유 이미지에서는 이메일이 포함된 계정명을 생략하거나 프로바이더명으로 표시. On Demand 지표를 일반 지표 뒤에 통합하며 각 구역의 상대 순서와 숨김 설정 유지. 오류·경고 없이 수집한 기록에서 빠진 기간은 지원 항목에 0을 표시. 실패·부분 수집에서 빠진 기간은 No data로 표시. ([#190](https://github.com/kimchanhyung98/egasu/pull/190)) by @kimchanhyung98
- Settings를 General·Display·Alerts·Advanced로 재구성. 기본 탭, 로그인 시 실행, 전역 단축키, 대시보드와 메뉴 막대 표시, 알림을 각 탭에서 설정. 업데이트 피드가 없는 개발 빌드에서도 Beta Updates 선택은 저장하며 자동·수동 업데이트 확인은 비활성. ([#192](https://github.com/kimchanhyung98/egasu/pull/192)) by @kimchanhyung98
- 사이트의 대시보드 미리보기와 기능 투어를 현재 앱에 맞게 갱신. 데스크톱과 모바일에서 예시 데이터로 Priority·All Usage·Total Spend와 기간별 내역을 탐색. ([#193](https://github.com/kimchanhyung98/egasu/pull/193)) by @kimchanhyung98
- 웹 미리보기의 Customize를 Accounts와 Settings로 교체. 예시 계정명·순서·지표 표시·고정과 언어 설정을 같은 브라우저에서 복원. Privacy Mode에서 대시보드의 예시 계정명과 이메일을 가림. 예시 사용량이 없는 프로바이더는 Mac 앱 로그인 안내를 표시하며 미리보기에서 제거하거나 다시 추가할 수 있음. ([#194](https://github.com/kimchanhyung98/egasu/pull/194)) by @kimchanhyung98

### Bug Fixes

- 업데이트 배너를 닫으면 메뉴 막대의 업데이트 표시도 숨김. 자동 확인이 켜져 있고 업데이트가 계속 제공되면 다음 예약 확인에서 다시 표시. Beta Updates를 끄면 대기 중인 베타 제안을 철회하고 이미 시작한 다운로드·설치는 계속 진행. ([#191](https://github.com/kimchanhyung98/egasu/pull/191)) by @kimchanhyung98
- 이전 카드 표시 설정이 남아 있어도 정상적인 계정 순서를 불러오고 다시 정렬할 수 있도록 수정. 순서 데이터를 읽을 수 없으면 기존 값을 보존하고 오류 표시. 같은 앱 실행 중 Settings로 돌아왔을 때 해결되지 않은 로그인 시 실행·언어 재시작·Terminal Helper 오류를 다시 표시. Codex 5시간·주간 구독 타이머의 공통 오류 안내를 영어·한국어·일본어에서 수정. ([#195](https://github.com/kimchanhyung98/egasu/pull/195)) by @kimchanhyung98

### Refactor

- 기존 Codex 기본 풀의 주간 타이머를 공통 처리 경로로 옮기고, 기본 풀의 5시간 타이머와 Spark 풀의 5시간·주간 타이머 자동 시작을 추가. 기존 전송 기록을 이어 읽고 계정·한도별 전송 상한 적용. ([#182](https://github.com/kimchanhyung98/egasu/pull/182)) by @kimchanhyung98
- 기존 egasu·OpenUsage의 지표 표시·숨김·순서를 이전. 계정별 한도 지표와 같은 프로바이더의 계정이 공유하는 사용 이력의 표시·순서를 각각 관리. ([#184](https://github.com/kimchanhyung98/egasu/pull/184)) by @kimchanhyung98

### Chores

- CI에서 Intel 실행기로 Swift 테스트를 실행하고 ARM64 앱과 테스트를 교차 빌드. Swift·GitHub Actions·JavaScript/TypeScript의 CodeQL 검사 추가. ([#185](https://github.com/kimchanhyung98/egasu/pull/185)) by @kimchanhyung98
- 사용량 수집·프로바이더·프록시·설정 가이드를 현재 앱에 맞게 정리. All Usage의 Minimal·Cards 화면 예시를 라이트·다크 모드로 갱신하고 개발 주석과 기여 지침 정리. ([#196](https://github.com/kimchanhyung98/egasu/pull/196)) by @kimchanhyung98

---

### Changelog

**Full Changelog**: [v1.0.0-beta.2...v1.0.0-beta.3](https://github.com/kimchanhyung98/egasu/compare/432a4bcc51dc213dd01b2b86eaf87610491a6922...9b2ae9568db23b3d58ea6af3b82d8f54e0c20068)

## v1.0.0-beta.2

### New Features

- Kimi CLI 설정의 공식 서버와 OAuth·API 키 인증을 지원하고 Total Usage·Extra Usage·Extra Balance 지표 추가. 요청 상세가 없는 로컬 기록의 토큰·모델별 추정 비용도 집계. ([#178](https://github.com/kimchanhyung98/egasu/pull/178)) by @kimchanhyung98
- Cursor 사용 이력을 사용 이벤트 API로 수집하고 서버가 보고한 추가 과금액 표시. 무료·포함 사용의 토큰을 유지하며 이력 조회 실패 시 동일 계정의 기존 이력 보존. ([#180](https://github.com/kimchanhyung98/egasu/pull/180)) by @kimchanhyung98
- 웹사이트 로고에 마우스를 올리거나 키보드로 선택하면 egasu가 usage로 바뀌는 애니메이션 추가. ([90a9bea](https://github.com/kimchanhyung98/egasu/commit/90a9bea377b75120a90cb3ee6f9e55db091e5a6b)) by @kimchanhyung98

### Bug Fixes

- Codex Rosalind 장문 요율과 Grok 모델 별칭의 가격 누락 수정. Z.ai 무료 캐시 사용이 섞인 비용 합계와 Copilot Free 플랜·한도 표시 보정. ([#163](https://github.com/kimchanhyung98/egasu/pull/163)) by @kimchanhyung98
- 기존 OpenUsage 데이터·인증 정보를 egasu 저장 위치로 이전하고 개발 앱·CLI 저장 공간 분리. 이전 실패 시 기존 데이터를 보존하고 다음 실행에서 재시도. ([#172](https://github.com/kimchanhyung98/egasu/pull/172)) by @kimchanhyung98
- HTTP 응답 본문을 로그에서 제외하고 네트워크 오류 구분 개선. 테스트 진단 로그 격리와 로컬 HTTP 서버 참조 수명 수정. ([#173](https://github.com/kimchanhyung98/egasu/pull/173)) by @kimchanhyung98
- 별도 셸 설정 없이 기본 Claude CLI 로그인과 등록 계정 선택을 반영하고 첫 계정 등록 실패의 재로그인 복구 개선. 계정 전환·사용량 조회 중 계정과 조직을 검증해 기존 인증 정보 보호. ([#174](https://github.com/kimchanhyung98/egasu/pull/174)) by @kimchanhyung98
- iCloud 사용 이력의 기존·새 저장 위치를 함께 읽고 기기별 최신 기록만 반영. 앱 전용 영역의 변경 감지와 파일 정리 재시도 개선. 계속 동기화할 모든 Mac에 새 버전 설치 필요. ([#176](https://github.com/kimchanhyung98/egasu/pull/176)) by @kimchanhyung98
- Claude Fable·Mythos 5.2와 Gemini 신규 모델 별칭 지원 및 GPT-5.6 Sol·Gemini의 일반 정가 추정 보정. Fast·캐시·장문 요율을 유지하고 번들 가격표와 Cursor 모델명 표시 갱신. 정가 환산액은 한시 할인 청구액과 다를 수 있음. ([#177](https://github.com/kimchanhyung98/egasu/pull/177)) by @kimchanhyung98

- Antigravity 한도 조회의 서버 우선순위와 클라이언트 식별을 보정하고 Argon Weekly 지표 추가. 비활성·잘못된 한도를 제외하고 소량 사용 시 재설정 카운트다운 유지. 원본 DB 변경 없이 종료된 대화 이력 수집 개선. ([#179](https://github.com/kimchanhyung98/egasu/pull/179)) by @kimchanhyung98

### Refactor

- 프로바이더 갱신 조정·작업·스냅샷 처리를 분리하고 계정별 갱신 상태 관리 정리. 부분 실패 시 마지막 정상 한도를 보존하고 로컬 이력과 동기화 표시 결과 분리. ([#175](https://github.com/kimchanhyung98/egasu/pull/175)) by @kimchanhyung98

### Chores

- 앱·사이트·가격표 게시 기준을 버전 태그로 통일하고 수동 게시·Pages 재배포를 검증된 소스와 산출물에 연결. ([#170](https://github.com/kimchanhyung98/egasu/pull/170)) by @kimchanhyung98
- 개발 빌드의 서명·버전 설정과 실행 전 검사를 보강하고 수동 Swift 포맷 워크플로 추가. ([#171](https://github.com/kimchanhyung98/egasu/pull/171)) by @kimchanhyung98
- 웹사이트의 Astro를 7.4.4에서 7.4.5로 업데이트. ([#164](https://github.com/kimchanhyung98/egasu/pull/164)) by @dependabot[bot]
- PostHog SDK를 3.92.7에서 3.93.6으로 업데이트. ([#165](https://github.com/kimchanhyung98/egasu/pull/165)) by @dependabot[bot]
- 기존 변경 이력의 v1.0.0 표기를 v1.0.0-beta.1로 정정. ([b8313cf](https://github.com/kimchanhyung98/egasu/commit/b8313cf0ba7abec12e868130054c37f9bffba1c9)) by @kimchanhyung98

---

### Changelog

**Full Changelog**: [v1.0.0-beta.1...v1.0.0-beta.2](https://github.com/kimchanhyung98/egasu/compare/9402b49bc1dbcdef5c6eec4c53b25a84a17c7c78...3c51519e95ed37477deaf59d213081f324505af8)

## v1.0.0-beta.1

### 새 기능

- Z.ai 기간별 토큰·추정 비용 통계 추가 ([#140](https://github.com/kimchanhyung98/egasu/pull/140)) by @kimchanhyung98.
- Kimi CLI 토큰·추정 비용 통계 추가 ([#141](https://github.com/kimchanhyung98/egasu/pull/141)) by @kimchanhyung98.
- Devin CLI 사용량 기반 기간별 통계 추가 ([#142](https://github.com/kimchanhyung98/egasu/pull/142)) by @kimchanhyung98.
- Kiro 로컬 크레딧·토큰 추정 통계 추가 ([#143](https://github.com/kimchanhyung98/egasu/pull/143)) by @kimchanhyung98.
- 여러 도구의 사용 기록을 함께 처리하는 공통 수집 모듈 추가 ([#155](https://github.com/kimchanhyung98/egasu/pull/155)) by @kimchanhyung98.
- Gemini CLI·Qwen CLI 세션 사용량 수집 추가 ([#158](https://github.com/kimchanhyung98/egasu/pull/158)) by @kimchanhyung98.
- OpenClaw·Hermes Agent·DeepSeek Harness 사용 기록 수집 추가 ([#159](https://github.com/kimchanhyung98/egasu/pull/159)) by @kimchanhyung98.
- Kilo Code·Kilo CLI·Junie 및 Kimi·Kiro 보충 기록 수집 추가 ([#160](https://github.com/kimchanhyung98/egasu/pull/160)) by @kimchanhyung98.

### 오류 수정

- 스냅샷 갱신 시 공개 피드에서 삭제된 과거 모델의 단가 보존 ([#162](https://github.com/kimchanhyung98/egasu/pull/162)) by @kimchanhyung98.
- Claude·Codex 사용량 알림에 계정명 표시 ([#133](https://github.com/kimchanhyung98/egasu/pull/133)) by @kimchanhyung98.
- 상단 통계 안내문의 프로바이더 이름 중복 제거 ([#134](https://github.com/kimchanhyung98/egasu/pull/134)) by @kimchanhyung98.
- Codex 재로그인·계정 전환 시 인증 충돌 방지 ([#139](https://github.com/kimchanhyung98/egasu/pull/139)) by @kimchanhyung98.
- Codex 압축·중단 응답 사용량의 누락과 중복 수정 ([#144](https://github.com/kimchanhyung98/egasu/pull/144)) by @kimchanhyung98.
- OpenCode fork 사용량 중복 집계 수정 ([#145](https://github.com/kimchanhyung98/egasu/pull/145)) by @kimchanhyung98.
- Grok 세션 간 모델 혼동에 따른 비용 집계 오류 수정 ([#146](https://github.com/kimchanhyung98/egasu/pull/146)) by @kimchanhyung98.
- Pi 사용량의 독립 집계 및 압축 호출 모델 오귀속 수정 ([#147](https://github.com/kimchanhyung98/egasu/pull/147)) by @kimchanhyung98.
- 배포 앱에 필요한 리소스 번들만 포함 ([#149](https://github.com/kimchanhyung98/egasu/pull/149)) by @kimchanhyung98.
- 현재 요금제 정보와 모델 가격 매칭 갱신 ([#150](https://github.com/kimchanhyung98/egasu/pull/150)) by @kimchanhyung98.
- 프로바이더별 인증·할당량·잔액 처리 수정 ([#151](https://github.com/kimchanhyung98/egasu/pull/151)) by @kimchanhyung98.
- 백그라운드 작업 순차 실행 및 갱신 대기 상태 표시 ([#152](https://github.com/kimchanhyung98/egasu/pull/152)) by @kimchanhyung98.
- 가격이 없는 모델의 토큰 보존 및 불완전한 총비용 표시 방지 ([#153](https://github.com/kimchanhyung98/egasu/pull/153)) by @kimchanhyung98.
- 프로바이더 내부 분석 요청을 순차 실행하도록 수정 ([#154](https://github.com/kimchanhyung98/egasu/pull/154)) by @kimchanhyung98.
- 기존 CLI 원장과 특수 사용량 기록 보존 ([#157](https://github.com/kimchanhyung98/egasu/pull/157)) by @kimchanhyung98.
- 수집 실패 시 정상 사용 이력 보존 및 조치가 필요 없는 경고 축소 ([#161](https://github.com/kimchanhyung98/egasu/pull/161)) by @kimchanhyung98.

### 구조 개선

- 앱·CLI·사이트 이름을 egasu로 변경. 기존 계정·설정·iCloud 이력과 이전 CLI 명령 유지, 업데이트 시 앱 이름 이전 및 중단 후 복구 지원 ([#148](https://github.com/kimchanhyung98/egasu/pull/148)) by @kimchanhyung98.

### 유지보수

- Node.js 타입 정의 26.6.6으로 갱신 ([#135](https://github.com/kimchanhyung98/egasu/pull/135)) by @dependabot[bot].
- Astro 7.4.4로 갱신 ([#136](https://github.com/kimchanhyung98/egasu/pull/136)) by @dependabot[bot].
- PostHog 3.92.7로 갱신 ([#137](https://github.com/kimchanhyung98/egasu/pull/137)) by @dependabot[bot].
- Sparkle 2.10.1로 갱신 ([#138](https://github.com/kimchanhyung98/egasu/pull/138)) by @dependabot[bot].
- 오래된 조사 문서 정리 ([#156](https://github.com/kimchanhyung98/egasu/pull/156)) by @kimchanhyung98.
- 동작 설명과 공식 근거 링크 정리 ([e25e935](https://github.com/kimchanhyung98/egasu/commit/e25e935b3c6431208a778a91018e34e081c168c7)) by @kimchanhyung98.
- 오프라인 가격 조회용 LiteLLM·models.dev 스냅샷 갱신 by @kimchanhyung98.

---

### 변경 이력

**전체 변경 이력**: [v0.14.3...v1.0.0-beta.1](https://github.com/kimchanhyung98/egasu/compare/aad6ff61e2a07ed58499c9843059aff7d1ccf103...0158a488cc2c68e5a006fb3f7f9430ae0d7e0979)

## v0.11.3

### New Features

- feat(codex): show scheduled resets as 99% forecasts ([#35](https://github.com/kimchanhyung98/openusage/pull/35)) by @kimchanhyung98.
- feat(site): add an interactive Korean landing page ([#34](https://github.com/kimchanhyung98/openusage/pull/34)) by @kimchanhyung98.

---

### Changelog

**Full Changelog**: [v0.11.2...v0.11.3](https://github.com/kimchanhyung98/openusage/compare/v0.11.2...v0.11.3)

## v0.11.2

### Bug Fixes

- fix(codex): show zero reset chance when no active signal exists ([#25](https://github.com/kimchanhyung98/openusage/pull/25)) by @kimchanhyung98.
- fix(telemetry): harden diagnostics, consent, and account isolation ([#24](https://github.com/kimchanhyung98/openusage/pull/24)) by @kimchanhyung98.
- fix(git-hooks): isolate repository environment in pre-commit ([#26](https://github.com/kimchanhyung98/openusage/pull/26)) by @kimchanhyung98.
- fix(local-api): handle empty paths and peer disconnects ([#27](https://github.com/kimchanhyung98/openusage/pull/27)) by @kimchanhyung98.
- fix(accounts): guard cache and refreshes across credential changes ([#28](https://github.com/kimchanhyung98/openusage/pull/28)) by @kimchanhyung98.
- fix(usage-logs): preserve failure state until confirmed recovery ([#29](https://github.com/kimchanhyung98/openusage/pull/29)) by @kimchanhyung98.
- fix(telemetry): retain crash locations and Swift exception types ([#30](https://github.com/kimchanhyung98/openusage/pull/30)) by @kimchanhyung98.
- fix(diagnostics): classify installer, updater, and pricing failures ([#31](https://github.com/kimchanhyung98/openusage/pull/31)) by @kimchanhyung98.
- fix(accounts): show actual session status in settings ([#32](https://github.com/kimchanhyung98/openusage/pull/32)) by @kimchanhyung98.
- fix(tokscale): add result dismissal and sync cooldown ([#33](https://github.com/kimchanhyung98/openusage/pull/33)) by @kimchanhyung98.

---

### Changelog

**Full Changelog**: [v0.11.1...v0.11.2](https://github.com/kimchanhyung98/openusage/compare/v0.11.1...v0.11.2)

## v0.11.1

### Bug Fixes

- fix(accounts): hide unregistered shared-home account cards ([#23](https://github.com/kimchanhyung98/openusage/pull/23)) by @kimchanhyung98.

---

### Changelog

**Full Changelog**: [v0.11.0...v0.11.1](https://github.com/kimchanhyung98/openusage/compare/v0.11.0...v0.11.1)

## v0.11.0

### New Features

- feat(release): derive bundle versions from git tags ([#16](https://github.com/kimchanhyung98/openusage/pull/16)) by @kimchanhyung98.
- feat(codex): add Reset Watch forecast ([#17](https://github.com/kimchanhyung98/openusage/pull/17)) by @kimchanhyung98.
- feat(tokscale): add CLI sync settings ([#19](https://github.com/kimchanhyung98/openusage/pull/19)) by @kimchanhyung98.
- feat(status): add provider server status indicators ([#20](https://github.com/kimchanhyung98/openusage/pull/20)) by @kimchanhyung98.
- feat(accounts): add shared card modes and account ordering ([#21](https://github.com/kimchanhyung98/openusage/pull/21)) by @kimchanhyung98.
### Bug Fixes

- fix(codex): show Reset Watch only on the main account card ([#22](https://github.com/kimchanhyung98/openusage/pull/22)) by @kimchanhyung98.

---

### Changelog

**Full Changelog**: [v0.9.5...v0.11.0](https://github.com/kimchanhyung98/openusage/compare/v0.9.5...v0.11.0)

## v0.9.5

### Bug Fixes

- Retry durable iCloud usage-history deletions after a transient failure ([#15](https://github.com/kimchanhyung98/openusage/pull/15)) by @kimchanhyung98.
- Conceal menu-bar usage while the screen is being captured ([#14](https://github.com/kimchanhyung98/openusage/pull/14)) by @kimchanhyung98.
- Reject symlinked account sign-in workspaces ([#11](https://github.com/kimchanhyung98/openusage/pull/11)) by @kimchanhyung98.
- Bind Cursor SQLite values instead of interpolating authentication tokens ([#12](https://github.com/kimchanhyung98/openusage/pull/12)) by @kimchanhyung98.
- Redact account names at the local HTTP API boundary ([#13](https://github.com/kimchanhyung98/openusage/pull/13)) by @kimchanhyung98.

---

### Changelog

**Full Changelog**: [v0.9.4...v0.9.5](https://github.com/kimchanhyung98/openusage/compare/cf33dbd890b9b9b3e2d78e1cfd0774616e29cb3c...ade70bb8e24955cd50de4572337311b63d73450d)

## v0.9.4

### Bug Fixes

- Update GPT-5.6 pricing and aliases ([#10](https://github.com/kimchanhyung98/openusage/pull/10)) by @kimchanhyung98.
- Map Daybreak Blue usage to GPT-5.6 Sol ([219e88c](https://github.com/kimchanhyung98/openusage/commit/219e88cab0a3d12a4b9840383d9621718499f269)) by @kimchanhyung98.

### Chores

- Optimize bundled images ([#2](https://github.com/kimchanhyung98/openusage/pull/2)) by @imgbot[bot].

---

### Changelog

**Full Changelog**: [v0.9.3...v0.9.4](https://github.com/kimchanhyung98/openusage/compare/a5ee0028817e617db1dd501912c5e2a5b3b413fe...cf33dbd890b9b9b3e2d78e1cfd0774616e29cb3c)

## v0.9.3

### Bug Fixes

- Keep one shared customizable card for each provider across managed accounts ([#9](https://github.com/kimchanhyung98/openusage/pull/9)) by @kimchanhyung98.

---

### Changelog

**Full Changelog**: [v0.9.2...v0.9.3](https://github.com/kimchanhyung98/openusage/compare/edfee95e71fa1c5b835386266595cb11fa2da868...a5ee0028817e617db1dd501912c5e2a5b3b413fe)

## v0.9.2

### Bug Fixes

- Keep account-card layout, notifications, and menu-bar pins scoped to their provider ([d25f6dc](https://github.com/kimchanhyung98/openusage/commit/d25f6dcf344988a0fb716d3506bd78f00fb66b43)) by @kimchanhyung98.
- Store layout per provider and hide unregistered logins ([076871f](https://github.com/kimchanhyung98/openusage/commit/076871f55be91c6dc2dd7d78658afb2a56239629)) by @kimchanhyung98.
- Harden Claude reauthentication reconciliation ([e8403f3](https://github.com/kimchanhyung98/openusage/commit/e8403f3abdb4b61a265cae9eb1a52dfdda5544eb)) by @kimchanhyung98.

---

### Changelog

**Full Changelog**: [v0.9.1...v0.9.2](https://github.com/kimchanhyung98/openusage/compare/21427211078a7a31ab8e2d4bd160115647e12c3c...edfee95e71fa1c5b835386266595cb11fa2da868)

## v0.9.1

### Bug Fixes

- Reconcile Claude terminal reauthentication without mixing account identities ([#8](https://github.com/kimchanhyung98/openusage/pull/8)) by @kimchanhyung98.

### Documentation

- Standardize documentation and code-comment style ([#7](https://github.com/kimchanhyung98/openusage/pull/7)) by @kimchanhyung98.

---

### Changelog

**Full Changelog**: [v0.9.0...v0.9.1](https://github.com/kimchanhyung98/openusage/compare/5ed3693ced27839379f1eb35659be3a02613718f...21427211078a7a31ab8e2d4bd160115647e12c3c)

## v0.9.0

### New Features

- Add managed Claude and Codex account switching, per-account dashboard cards, and read-only account CLI commands ([#6](https://github.com/kimchanhyung98/openusage/pull/6)) by @kimchanhyung98.

---

### Changelog

**Full Changelog**: [v0.8.2...v0.9.0](https://github.com/kimchanhyung98/openusage/compare/e6ec605d77d12243ebfb16f947c72bfff139968b...5ed3693ced27839379f1eb35659be3a02613718f)

## v0.8.2

### Bug Fixes

- Unblock the release pipeline and retarget telemetry ([#5](https://github.com/kimchanhyung98/openusage/pull/5)) by @kimchanhyung98.

---

### Changelog

**Full Changelog**: [v0.8.1...v0.8.2](https://github.com/kimchanhyung98/openusage/compare/aee49294353255825585fc88cb1548ec2ea74c03...e6ec605d77d12243ebfb16f947c72bfff139968b)

## v0.8.1

### Chores

- Retarget app identifiers, signing, iCloud containers, and the update feed ([#4](https://github.com/kimchanhyung98/openusage/pull/4)) by @kimchanhyung98.
- Make compact density the default dashboard layout ([0865c1f](https://github.com/kimchanhyung98/openusage/commit/0865c1f0159778d23538d9b6822f8d3a282ca702)) by @kimchanhyung98.

---

### Changelog

**Full Changelog**: [v0.8.0...v0.8.1](https://github.com/kimchanhyung98/openusage/compare/3fdbef4e0076e8493a4be634dcf51d0917166ead...aee49294353255825585fc88cb1548ec2ea74c03)

## v0.8.0

### New Features

- Add Kimi and Kiro usage tracking ([#1](https://github.com/kimchanhyung98/openusage/pull/1)) by @kimchanhyung98.

### Bug Fixes

- Add Claude Opus 5 pricing and native fast-mode pricing ([#3](https://github.com/kimchanhyung98/openusage/pull/3)) by @kimchanhyung98.

---

### Changelog

**Release Commit**: [3fdbef4e](https://github.com/kimchanhyung98/openusage/commit/3fdbef4e0076e8493a4be634dcf51d0917166ead)
