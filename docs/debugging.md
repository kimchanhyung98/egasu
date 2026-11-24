# 디버깅 및 로그 캡처

로컬 빌드를 실행해 프로바이더 오류나 앱 시작·새로 고침 문제를 확인하는 방법.

## 로컬 빌드 실행

아래 명령은 Swift 빌드가 성공한 뒤 앱 번들을 교체하기 전에 현재 checkout의 `dist/egasu.app`, 이전 `dist/Egasu.app` 또는 `dist/OpenUsage.app` 프로세스만 종료.
Swift 빌드가 실패하면 실행 중인 앱 유지.
앱은 종료 신호를 받으면 진행 중인 Claude 토큰 갱신 저장을 대기.
20초가 지나면 경고를 기록하고, 갱신 요청이나 저장이 끝날 때까지 종료를 계속 대기.
25초 안에 앱이 종료되지 않으면 기존 앱 번들을 유지하고 스크립트 중단.
`/Applications` 등 다른 경로에서 실행 중인 앱은 종료하지 않음.
지원 모드는 `run|build|logs|verify`이며 생략 시 `run`.
잘못된 모드는 버전 스크립트 로딩·Git·서명 확인과 앱 종료·빌드 전에 사용법과 종료 코드 2로 거부.
리포지토리 루트에서 필요한 명령 하나 실행:

```sh
./script/build_and_run.sh          # dist/의 개발 앱을 빌드하고 실행
./script/build_and_run.sh build    # 빌드·스테이징만, 실행은 하지 않음
./script/build_and_run.sh verify   # 현재 checkout의 앱 실행 파일 경로로 프로세스 확인
```

`verify`는 현재 checkout의 `dist/egasu.app/Contents/MacOS/egasu`와 실행 파일 경로가 같은 프로세스만 인정.
심볼릭 링크로 연 checkout은 실제 경로를 기준으로 실행 파일을 확인.
운영 앱이나 다른 checkout의 같은 이름 프로세스는 성공으로 계산하지 않음.

스크립트는 서명된 앱 번들을 `dist/`에 생성.
서명 신원은 `CODESIGN_IDENTITY` 환경 변수, 저장소 루트의 `.env.local.codesign-identity`, Apple Development 자동 선택 순서로 결정.
팀 식별자가 있는 인증서를 사용하면 [데스크톱 위젯](/docs/desktop-widgets.md)을 함께 빌드해 앱의 `Contents/PlugIns`에 포함.
ad-hoc 서명으로 빌드하면 데스크톱 위젯이 제외되며 빌드 출력에 사유 표시.
이 Mac의 인증서를 고정하려면 `.env.local.codesign-identity`에 인증서 지문 또는 정확한 이름을 한 줄로 저장.
이 파일은 Git에서 제외되는 로컬 설정.
명시하거나 고정한 서명 신원은 임시 실행 파일 복사본에 `codesign --dryrun`을 실행해 사용 가능 여부 확인.
신원 선택은 `codesign`의 규칙을 따르며, 설정 파일이 비어 있거나 사전 확인이 실패하면 앱 종료 전에 빌드 중단.
`--dryrun`은 결과 서명을 저장하지 않지만 실제 서명 연산과 개인 키 접근 검사를 수행하므로 승인 창이 표시될 수 있음.
개발 번들 버전은 `EGASU_DEV_VERSION` 환경 변수, 저장소 루트의 `.env.local.dev-version`, 가장 가까운 릴리스 태그 순서로 결정.
`EGASU_DEV_VERSION`이 비어 있으면 호환 변수 `OPENUSAGE_DEV_VERSION`을 먼저 확인.
다음 릴리스를 준비하는 동안 버전 표기를 고정하려면 `.env.local.dev-version`에 버전을 한 줄로 저장(예: `1.0.0-beta.2`).
이 파일도 Git에서 제외되는 로컬 설정이며 릴리스 태그와 릴리스 버전은 바꾸지 않음.
번들 버전에는 항상 `-dev` 접미사 추가(예: `1.0.0-beta.2-dev`).
버전 형식이 릴리스 태그 규칙과 다르거나 파일이 비어 있으면 실행 중인 앱을 종료하기 전에 빌드 중단.
개발·릴리스 앱에는 현재 앱과 의존성의 리소스만 포함.
테스트 fixture와 이전 빌드에서 남은 다른 제품의 리소스 번들은 제외.
실행 모드에서는 해당 번들을 실행하며 `/Applications`의 앱 번들은 교체하지 않음.
기본 개발 번들 ID는 `com.kimchanhyung98.openusage.dev`.
번들 ID에 속한 앱 설정은 릴리스 빌드와 분리.
프로바이더 인증 파일·공용 Keychain 항목·로그 파일은 릴리스 빌드와 공유할 수 있으므로 별도 테스트 계정 환경으로 간주하면 안 됨.
개발 앱에는 업데이트 피드가 없으므로 업데이트 확인을 실행하지 않음.
업데이트 동작은 서명·공증된 릴리스 빌드로 테스트.
개발 빌드의 익명 분석 기본값은 꺼짐이며 내장 운영 프로젝트 토큰은 무시.
개발 분석을 검증할 때는 별도 테스트 프로젝트의 토큰을 `EGASU_POSTHOG_TOKEN`으로 지정.
값이 없거나 공백뿐이면 이전 `OPENUSAGE_POSTHOG_TOKEN`의 비어 있지 않은 값 사용.

## Worktree 검사

pre-commit 훅은 `make check` 실행 전에 Git의 저장소별 환경 변수 제거.
연결된 작업 트리에서 커밋할 때도 SwiftPM이 각 의존성의 저장소를 올바르게 검사하도록 처리.
검사 실패 시 커밋 차단 유지.

## Swift 포매팅

[swift-format](https://github.com/swiftlang/swift-format)의 `.swift-format` 규칙 사용.
들여쓰기 4칸, 줄 길이 기준 120자, 기존 줄바꿈 우선 유지.
별도 구문 변환 규칙은 끄고, 여러 줄 문자열의 내용과 줄바꿈 유지.
대상은 `Package.swift`와 `Sources/`·`Tests/` 아래 Swift 파일.
의존성·빌드 산출물·웹 사이트 파일은 대상에서 제외.

베타 작업 중 전체 포매팅은 보류.
`make check`와 기존 CI는 포맷 검사 없이 빌드·테스트 유지.
포매터 워크플로의 `main` push 트리거는 주석 상태이며, 베타 종료 후 첫 실행은 수동으로 진행.

1. 베타 작업을 `main`에 병합.
2. GitHub Actions의 **Format Swift → Run workflow**에서 `main` 선택.
3. 실행 결과와 `style: format Swift sources` 봇 커밋 확인.
4. 릴리스할 때는 검증된 최종 커밋에 버전 태그 생성.

워크플로는 Xcode 26.6에 포함된 포매터로 정리 후 포맷 검사·빌드·테스트 실행.
모두 통과하고 변경이 있을 때만 Swift 파일을 커밋·푸시.
변경이 없으면 새 커밋 없이 종료.
`GITHUB_TOKEN`으로 푸시한 커밋은 일반 push CI를 다시 실행하지 않으므로 같은 작업에서 검증.
브랜치 보호 규칙이 봇의 직접 푸시를 금지하면 푸시 단계 실패.
실행 중 `main`이 바뀌어도 강제 푸시하지 않으며, 최신 `main`에서 다시 실행.

로컬에서 같은 규칙을 사용할 때는 다음 명령 중 하나 실행.
워크플로와 결과를 비교할 때는 같은 Xcode 버전 선택.

```sh
make format-check   # 검사만 실행
make format         # 베타 종료 후 전체 Swift 파일 정리
```

## 로그 스트리밍

개발 앱을 다시 빌드·실행하고 Info 수준까지 로그를 수집하려면 다음 명령 실행:

```sh
./script/build_and_run.sh logs
```

`logs` 모드는 앱 실행 후 스트림을 시작.
시작 로그가 필요하면 별도 터미널에서 아래 스트림을 먼저 시작한 뒤, 다른 터미널에서 `./script/build_and_run.sh run` 실행.
이미 실행 중인 앱의 로그만 수집할 때도 같은 스트림 사용:

```sh
log stream --info --style compact --predicate 'process == "egasu"'
```

Debug 로그가 필요하면 먼저 **Settings → Advanced → Log Level**에서 **Debug** 선택.
그다음 Debug 이벤트를 포함하는 명령 실행:

```sh
log stream --level debug --style compact --predicate 'process == "egasu"'
```

최근 10분의 저장된 로그를 확인하려면 다음 명령 실행:

```sh
log show --last 10m --info --debug --predicate 'process == "egasu"'
```

앱에서 기록을 꺼 둔 레벨은 위 명령으로 복구할 수 없음.

## 로그 파일

앱은 통합 로그와 별도로 `~/Library/Logs/egasu/egasu.log`에 파일 로그 기록.
일반적으로 파일당 약 10 MB를 유지하며 `egasu.1.log` 아카이브 하나 보관.
지원 요청에 사용할 기록은 [오류 제보용 로그 수집](/docs/logging.md#오류-제보용-로그-수집) 참조.

로그 레벨·태그·마스킹 범위는 [로깅](/docs/logging.md) 참조.

## 계정 로그 라인

앱 시작 시 Claude/Codex 기본 설정 홈의 로그인 계정을 확인하며 다음 로그 기록:

- `accounts: claude default identity resolved` — 기본 로그인의 계정이 확인된 경우.
  이 메시지에는 계정 식별자와 해시를 기록하지 않음.
- `accounts: codex default identity unresolved — …` — 로그인은 있지만 이번 실행에서 계정을 확실히 특정할 수 없는 경우(계정 ID가 없는 인증 파일, 또는 실행 시 비밀 값을 읽지 않는 키체인 인증 정보).
  계정 신원을 확인하지 못했다는 의미이며, 이 로그만으로 사용량 조회 성공 여부를 판단할 수 없음.
- `stale account cache discarded for claude` — 실행 사이에 기본 홈의 계정이 바뀌어, 새 로그인 아래에 이전 계정의 캐시 스냅샷을 그리는 대신 폐기한 경우.
- `account identity read skipped for claude, codex: login shell cold and no shell-environment snapshot exists yet` — 로그인 셸 환경 수집이 끝나지 않았고 이전 환경 스냅샷도 없어 해당 프로바이더 계열의 계정 확인을 건너뛴 경우.
  이후 셸 환경 수집에 성공하면 스냅샷을 저장해 다음 실행에 사용.
  수집에 실패하면 새 스냅샷을 저장하지 않으므로 다음 실행에서도 같은 로그가 나올 수 있음.

## 로컬 진단 이벤트 검증

`AppLog`는 통합 로그와 파일 로그에 진단 메시지 기록.
`AppDiagnostics`는 failure·degraded 결과만 로그로 기록하며 다른 결과는 observer 경로로 전달.
`TelemetryRecorder`는 sink를 통해 PostHog 이벤트를 전달하므로 로그 스트림만으로 모든 이벤트 발생을 확인할 수 없음.
이벤트 전달은 가짜 sink·진단 observer·stub transport를 사용하는 회귀 테스트로 별도 확인.

회귀 테스트는 가짜 인증 정보·격리된 SDK 요청·임시 파일 사용:

```sh
CFFIXED_USER_HOME=/tmp/egasu-telemetry-tests EGASU_POSTHOG_TOKEN=phc_REPLACE_ME swift test --filter 'Telemetry|AppDiagnostics|LogFile|WidgetDataStoreNotification|CodexResetClaimRouter'
```

검증 범위는 SDK에 전달할 데이터의 마스킹, 공유 중지 이후 대기 이벤트, 재시작, 집계 날짜·버전, 로그 동시 기록, 계정 전환.
`telemetry event submitted to SDK`는 로컬 SDK에 이벤트를 전달했다는 의미.
수집 서버의 응답 여부는 별도 HTTP 로그로 확인.
두 메시지 모두 운영 대시보드 표시의 증거는 아님.

네이티브 크래시 수집에는 PostHog 프로젝트의 `exception autocapture` 설정과 디버거가 연결되지 않은 앱 필요.
크래시 수집 동의를 변경한 뒤 네이티브 크래시 핸들러를 검증하려면 앱 재시작.
폐기 가능한 테스트 앱·테스트 프로젝트에서 크래시 수집·재실행 전송·심볼 해석 검증.
릴리스 스크립트는 dSYM에 앱 번들 ID·버전·빌드 기록.
릴리스 워크플로는 고정 버전의 PostHog CLI로 dSYM 업로드.
dSYM 생성·업로드 성공만으로 심볼 해석을 보장하지 않음.

## Codex Soft Limit 연동 검증

테스트 서버의 요청별 집계는 Node.js로 검증:

```sh
node --test script/fixtures/codex_soft_limit_server.test.mjs
```

실제 연동 검증에는 설치된 Codex CLI, Node.js, macOS의 `/usr/bin/expect` 필요:

```sh
EGASU_RUN_CODEX_CONTROL_TEST=1 swift test --filter CodexSoftLimitNativeTests
```

임시 `CODEX_HOME`과 로컬 응답 서버를 사용하며, 기존 사용자 세션과 인증 정보는 사용하지 않음.
App Server와 터미널에서 시작한 두 사용자 turn의 `thread_id`·`turn_id`로 응답 연결 추적.
각 turn의 응답이 실제로 시작된 뒤 취소하고, 재시도를 포함한 해당 turn의 모든 연결 종료 확인.
제목 생성 같은 보조 요청은 별도 집계하며, 전체 연결 개수만으로 성공 여부를 판단하지 않음.
취소 후 서버·터미널 생존과 대화 보존도 확인.
이 테스트의 성공은 현재 앱에서 차단된 자동 취소 기능을 활성화한다는 의미가 아님.

## 팁

- **프로바이더에 오류가 표시됨.**
  로그 수집을 시작한 뒤 문제 재현.
  `docs/providers/`의 해당 프로바이더 페이지에서 오류 의미와 인증 정보 출처 확인.
- **아무것도 갱신되지 않음.**
  자동 새로 고침은 주기와 캐시·재시도 대기 조건을 따름.
  수동 조회를 요청하려면 행의 컨텍스트 메뉴에서 **Refresh** 사용.
  수동 조회에서도 유지되는 대기 조건은 [새로 고침 및 캐싱](/docs/refreshing.md) 참조.
- **리빌드마다 권한/키체인 프롬프트가 뜸.**
  같은 인증서와 번들 ID를 유지하도록 로컬 서명 신원 고정.
  Apple Development 또는 Developer ID Application 인증서 사용 가능.
  기존 애드혹 빌드에서 전환할 때는 저장 항목마다 한 번 **항상 허용** 승인이 필요할 수 있음.
  고정 설정과 사용 가능한 Apple Development 인증서가 모두 없으면 애드혹 서명으로 전환하며 경고 출력.
- **로컬 API 확인.**
  앱이 실행 중일 때 `curl 127.0.0.1:6736/v1/usage`로 사용량 스냅샷 조회.
  UI와 같은 데이터 스토어의 결과이므로 수집·매핑 문제와 화면 표시 문제를 구분하는 데 사용 가능.
