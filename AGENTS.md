# AGENTS.md

egasu는 AI 프로바이더 사용량 위젯(Claude, Codex, Cursor, Grok, Devin 등)을 보여 주는 SwiftPM 기반 macOS SwiftUI 메뉴 막대 앱.

이 파일은 프로젝트의 엔지니어링 규칙 문서.
기여 전에 읽기.

## 에이전트 지침

AGENTS.md가 이 저장소 에이전트 지침의 단일 출처.
CLAUDE.md는 가장 가까운 AGENTS.md를 `@AGENTS.md`로 가리키기만 함.
CLAUDE.md에 지침·중복 지침·프로젝트 규칙 추가 금지.

> egasu의 네이티브 Swift 판은 `main` 브랜치에서 개발.
> 레거시 Tauri 판은 `tauri-legacy` 브랜치에서 보관.

### Jev MCP

사용 가능한 Jev MCP 도구와 설명을 확인한 뒤 작업에 맞는 도구를 골라 사용.
결과는 실제 코드·근거·테스트와 대조.

## 릴리스

`main`이 활성 개발 라인이며 `.github/workflows/release.yml`(Sparkle appcast, `gh-pages`)로 배포.
앱 릴리스·사이트·가격표 게시의 기준은 `main` 이력에 포함된 버전 태그.
`main` 푸시는 검증만 수행하며 자동 게시하지 않음.
수동 게시도 대상 태그 필수이며, Pages 재배포는 해당 태그의 성공한 게시 실행 결과 사용.
릴리스는 release-swift 스킬로 진행.

### 릴리스 규칙

- 버전은 `0.7.x` 이상.
  `0.6.x`는 원본 판의 릴리스 태그로 유지하며 재사용 금지.
  `tauri-legacy`의 마지막 릴리스는 `v0.6.28`.
- **태그 생성과 릴리스 전에 버전 번호를 제안하고 오너의 명시적 승인 대기.**
- 베타 릴리스는 `-beta.N` 태그를 쓰고 Sparkle 베타 채널의 GitHub pre-release로 유지.
  정식 릴리스는 일반 태그를 쓰고 GitHub "Latest"가 됨.
- 릴리스 노트를 작성하고 공개 상태로 게시.
  `release-swift` 스킬로 변경 내역을 작성하고 게시 결과 확인.
- `script/release.sh`의 appcast URL(`FEED_URL` 기본값)과 Sparkle 공개 키(`SPARKLE_PUBLIC_KEY`)는 설치된 모든 앱이 업데이트 출처를 식별하는 값.
  절대 변경 금지.

## 아키텍처

- SwiftPM 실행 타깃.
  SwiftUI 콘텐츠를 AppKit이 소유한 `NSStatusItem`과 키 입력을 받는 커스텀 `NSPanel`에 호스팅.
- Swift 6 strict concurrency.
- 프로바이더는 작은 `ProviderRuntime` 프로토콜을 구현.
  auth store는 사용자 Mac에 이미 있는 자격 증명을 읽고, usage client는 프로바이더 API를 호출하며, mapper는 응답을 `MetricLine` 값으로 정규화.
  UI는 정규화된 값을 렌더링.
- 앱과 일회성 CLI는 `Egasu` 모듈을 공유.
- 동작 문서와 개발자 문서(아키텍처 개요, 프로바이더 추가)는 `docs/` 참조.

## 프로바이더

`Sources/Egasu/Providers/<Name>/` 아래 프로바이더별 모듈 규칙.

- **구조.** 프로바이더마다 폴더 하나에 auth store(사용자 Mac에 이미 있는 자격 증명 읽기), usage client(프로바이더 API 호출), mapper(`MetricLine`으로 정규화)를 두고 `ProviderRuntime`을 준수.
  `ProviderRuntime`의 조회 메서드는 `refresh()`와 `hasLocalCredentials()`.
  `hasLocalCredentials()`는 첫 실행 감지(`FirstRunSeeder`)와 프로바이더 출시 후 첫 실행의 새 프로바이더 감지(`NewProviderSeeder`)가 쓰는 로컬 전용 자격 증명 확인.
  `refresh()`가 시작할 때와 같은 로컬 자격 증명 출처·사용 가능 여부 필터를 그대로 따르고, 두 번째 자격 증명 읽기 경로를 만들지 말고 auth store 로더를 재사용.
  `docs/adding-a-provider.md`, `docs/provider-enablement.md` 참조.
- **모델 가격.** 토큰 기반 지출 추정(Claude, Codex, Grok 등)은 `Sources/Egasu/Pricing/`의 공용 엔진으로 가격을 매김(`docs/pricing.md` 참조).
  Cursor는 서버 보고 비용을 사용하며, 구버전용 단가와 모델 표시 별칭 규칙은 `Sources/Egasu/Resources/pricing_supplement.json`에 있음.
  새 모델이나 바뀐 모델은 [Cursor models & pricing](https://cursor.com/docs/models-and-pricing.md)에서 동기화(`updated_at`, 가격 항목, 모델 slug용 `alias_rules` 갱신).
  버전 태그를 푸시하거나 해당 태그로 수동 게시하면 gh-pages와 Pages에 반영.
  설치된 앱은 앱 업데이트 없이 다음 가격표 갱신에서 반영.
  번들된 LiteLLM/models.dev 스냅샷은 `script/update_pricing_snapshots.sh`로 다시 생성(릴리스 시점 작업).
- **기본 순서.** `ProviderCatalog.make()`의 프로바이더 순서는 Claude, Codex, Cursor 다음에 나머지 표시 이름을 알파벳순으로 배치.
  새 프로바이더는 이 뒤쪽 목록에서 표시 이름 순서에 맞춰 추가.
  기본 순서는 `LayoutStore`의 초기 설정과 전체 레이아웃 재설정에 사용.
  사용자가 정한 순서는 유지하고 새 계정은 해당 프로바이더 목록 끝에 추가.
- **지표 배치 기본값.** 모든 지표는 기본 켜짐이며, 사용자가 숨긴 지표만 저장.
  기존 egasu·OpenUsage에서 이전한 표시·숨김 설정 우선.
  새 지표의 순서(`widgetDescriptors` 선언 순서)는 오너와 확인한 뒤 선택.

  메뉴 막대 항목은 **Menu Bar Items**의 기준에 따라 Priority 보드에서 선택.
  지표별 메뉴 막대 표시 기본값은 두지 않음.
  `DefaultLayout.pinnedMetricIDs`는 이전 별표를 Priority 고정으로 옮기는 1회 이전의 비교에만 사용.

## 변경 실행·테스트

```sh
swift build
swift test            # make check는 위 두 명령을 순서대로 실행
./script/build_and_run.sh run
```

스크립트는 `build`, `logs`, `verify` 모드도 지원.

- 핫 리로드 없음.
  테스트 전에 실행 중인 앱을 종료하고 변경한 코드를 빌드한 뒤 앱 재실행.
- 기본 개발 번들 ID는 `com.kimchanhyung98.openusage.dev`.
  기본 개발 설정은 운영 앱의 설정과 Keychain 항목에서 격리.

## 풀 리퀘스트

- 이 프로젝트는 `kimchanhyung98/egasu` fork(`origin`)로 유지보수.
  PR은 기본적으로 이 fork의 `main` 브랜치를 대상으로 생성.
- 원본 저장소 `robinebers/openusage`(`upstream`)는 기본 PR 대상이 아님.
  사용자가 upstream 기여를 명시적으로 요청할 때만 그곳에 PR 생성.
- `gh pr` 명령에는 항상 저장소를 명시.
  기본값으로 `--repo kimchanhyung98/egasu`를 사용하고 upstream 기여를 요청받은 경우에는 요청한 저장소 지정.
  PR 생성 전에 대상 저장소, base 브랜치, head 브랜치를 확인.

모든 PR 설명은 다음 순서로 작성하며 머리글은 영어로 유지.

- **TL;DR** — 변경을 한두 문장의 쉬운 영어로 요약하며 시작.
- **What was happening** — 변경의 계기가 된 이전 동작·버그·공백을 쉬운 영어 글머리표로 설명.
- **What this changes** — PR이 실제로 바꾸는 내용을 글머리표로 설명.
- **Heads-up** (선택) — 리뷰어나 이후 유지보수자가 고려할 점(위험, 후속 작업, 트레이드오프).
- **Tests** (선택) — 변경을 확인한 방법.
- **Screenshots** (보통은 선택, **시각 변경이 있는 PR은 필수**) — 변경 후 해당 UI 이미지.

## 문서

- 로직 변경은 해당 동작을 설명하는 `README.md`와 `docs/` 페이지를 함께 갱신.
- 문서는 쉽고 짧고 훑어보기 쉽게 작성하며 시각 디자인 세부는 제외.
  더 이상 없는 기능의 문서는 삭제.
- 동작 문서는 현재 상태와 조건을 설명.
  완료한 작업·수정 이력·이전 구현과의 비교는 제외.
  현재도 적용되는 호환성·이전 조건·제약은 유지.
- 모든 문서 페이지에서 문장·목록 항목마다 줄바꿈.
- `docs/`는 한국어가 기본 언어이며 별도 영어 문서나 `docs/ko/` 미러 없음.
- 한국어 페이지는 간결한 개조식(명사형)으로 작성.
  문장 예시는 "계정 전환 시 공유 홈의 인증만 교체. MCP 설정·메모리·세션 유지."
- 새 내부 문서 링크는 저장소 루트 기준 절대 경로(`/docs/...`) 사용.
- 외부 문서 링크는 해당 프로바이더·기능의 공식 문서만 가리킴.

## 코드 규칙

- 버그 수정이나 동작 변경에는 맞는 곳에 집중된 회귀 테스트 추가.
- 파일은 약 500줄 이하로 유지하고 필요하면 분할·리팩터링.
- 명확한 필요 없이 의존성 추가 금지.
- 기존 Swift 포매팅과 strict concurrency 규칙을 따름.
- Swift 포매터는 `.swift-format` 규칙 사용.
  베타 작업 중 전체 포매팅과 자동 트리거는 보류.
  베타 종료 후 `Format Swift` 워크플로를 `main`에서 수동 실행.
- 프로바이더를 추가할 때는 "프로바이더" 절의 규칙을 따름.

### 주석

- 주석은 한국어로 간결한 개조식으로 작성.
  주석 예시는 `/// 계정 전환 트랜잭션 — 공유 홈 인증만 교체, 실패 시 롤백.`
- 선언 문서는 `///` 한 줄 요약을 쓰고, 코드로 드러나지 않는 계약·불변식이 있을 때만 상세 줄 추가.
  구현 메모는 한 줄 `//` 사용.
  `// MARK: -` 구분선 유지(라벨은 영어).
- 주석에는 코드에서 드러나지 않는 계약과 불변식만 기록.
- 주석은 필요한 설명을 자체에 담고 저장소 문서나 외부 페이지 링크를 넣지 않음.
- 사용자 표시 문자열은 영어 원문 키와 영어·한국어·일본어 번역 리소스로 관리.
- 로그·식별자·저장값·API 필드와 단위는 기존 영문 계약 유지.

## 오류 처리

- 오류가 발생하면 로그 파일에 기록하고 사용자에게 이해하기 쉬운 문구 표시.
- PostHog에는 **Share Anonymous Usage**를 켰을 때만 [개인정보 보호 설정](/docs/settings.md#개인정보-보호)에서 정한 범위의 진단 이벤트 전송.
- 실제 문제를 숨기는 조용한 fallback 추가 금지.
- 프로바이더 API 실패는 계정별로 친절한 오류로 표시.
- 자격 증명과 응답 본문은 로그에 남기지 않음.
- 검증은 시스템 경계(사용자 입력, 외부 API)에서만 수행하고, 내부 코드와 프레임워크 보장은 신뢰.

## UI

- 제목으로 쓰는 하드코딩 영어 문구는 title case 사용.
- 기존 macOS와 egasu의 디자인 규칙을 따름.
- 툴팁(`hoverTooltip`)은 명시적 요청이 있을 때만 추가.
  Settings 행 설명은 제목 옆 ⓘ에 배치하고 행 아래에 별도 설명을 두지 않음.
  기존 상태 표시(갱신 중·오래됨·서비스 장애)에는 툴팁 사용 가능.
