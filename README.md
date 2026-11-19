# egasu

macOS 메뉴 막대에서 AI 코딩 구독 사용량을 확인하는 Swift 앱.

세션·주간 한도, 크레딧과 지출을 한 패널에서 확인.
메뉴 막대에는 소진 임박, Priority, 직접 고정한 지표 중 선택한 기준으로 표시.

| Minimal | Cards |
|---|---|
| ![All Usage Minimal](/docs/assets/all-usage-light.png) | ![All Usage Cards](/docs/assets/all-usage-cards-light.png) |

## Installation

Download the latest universal DMG from the [GitHub releases page](https://github.com/kimchanhyung98/egasu/releases/latest), open it, and drag egasu to your Applications folder.

The app updates itself in place via signed, notarized [Sparkle](docs/updates.md) updates. Requires macOS 15 (Sequoia) or later.

## Supported Providers

- **[Antigravity](docs/providers/antigravity.md)** — 공유 Gemini·Claude의 5시간·주간 한도, 계정별 Argon 주간 한도와 로컬 사용 이력
- **[Claude](docs/providers/claude.md)** — session, weekly, model-specific limits, extra usage, local daily spend
- **[Codex](docs/providers/codex.md)** — session, weekly, credits, local daily spend
- **[Copilot](docs/providers/copilot.md)** — AI credits, extra usage, organization billing, chat and completions
- **[Cursor](/docs/providers/cursor.md)** — 전체·Auto·API 사용량, 요청·크레딧, 추가 사용량, 서버 보고 기반 일별 추가 과금·토큰.
  이력 조회 실패 시 같은 계정으로 확인한 마지막 정상 이력 유지.
- **[Devin](docs/providers/devin.md)** — weekly and daily quota, extra usage balance
- **[Grok](docs/providers/grok.md)** — weekly shared pool, pay-as-you-go, local daily spend
- **[Kimi](/docs/providers/kimi.md)** — 5시간·주간·월간 총한도, 추가 지출·잔액.
- **[Kiro](docs/providers/kiro.md)** — coding credits and subscription plan
- **[OpenCode](/docs/providers/opencode.md)** — Go의 세션·주간·월간 한도 추정치, Console과 Go의 로컬 지출·토큰.
  과거 Zen 기록도 Console 집계에 포함.
- **[OpenRouter](docs/providers/openrouter.md)** — credit balance, daily/weekly/monthly spend (API key)
- **[Z.ai](docs/providers/zai.md)** — session, weekly, web-search quotas (GLM Coding Plan, API key)

대부분의 프로바이더는 Mac의 Keychain, 인증 파일 또는 앱에 저장된 로그인 정보 재사용.
[OpenRouter](/docs/providers/openrouter.md)와 [Z.ai](/docs/providers/zai.md)는 앱에 저장하거나 지원 환경 변수로 제공한 API 키 사용.
인증 정보는 해당 프로바이더 요청에만 사용.
익명 요약과 공개 가격표 다운로드는 [개인정보 및 사용 데이터](/docs/privacy.md) 참조.

## Features

- **[메뉴 막대](/docs/menu-bar.md).** 소진 임박·Priority·직접 고정한 항목 중 표시 기준 선택.
  텍스트 또는 막대로 최대 5개 표시.
- **[Priority](/docs/dashboard.md#priority).** 고정한 지표, 소진 임박·초기화 전 사용·소진 완료에 해당하는 한도, 확인이 필요한 계정 표시.
- **[All Usage](/docs/dashboard.md#all-usage).** 등록 계정별 사용량·초기화 시각·사용 속도 표시.
  Minimal은 프로바이더별 계정 묶음, Cards는 계정별 독립 카드.
  행 우클릭으로 지표 숨기기·Priority 고정·새로 고침·Accounts 관리 연결.
  [프로바이더 섹션 공유 이미지](/docs/dashboard.md#공유)는 표시 중인 모든 계정과 지표 순서를 반영.
- **[계정 전환](/docs/cli.md#계정).** Claude·Codex의 기본 인증 저장소를 쓰는 새 CLI 세션에 선택한 로그인 적용.
  셸 설정 파일·터미널 환경을 유지하며, Claude 첫 등록·외부 로그인과 전환 중 보존할 변경된 인증은 토큰의 계정·조직을 검증한 뒤 저장본에 반영.
  선택된 Claude 공유 로그인은 사용량 조회에서도 계정·조직 일치 검증.
- **[구독 타이머](/docs/refreshing.md#구독-타이머-자동-시작).** Codex·Claude·Antigravity·Kimi·Z.ai의 지원 한도를 확인하고 짧은 구독 메시지로 시작 유도.
  Claude·Antigravity·Kimi·Z.ai는 CLI 준비가 끝난 뒤 서버 한도를 다시 조회.
  전송 예약 후 한도 관측값이 바뀌면 메시지를 생략하고 예약 횟수 유지.
  계정·풀·기간별 전송 상한과 기록은 앱 재시작 뒤에도 유지.
- **[알림](/docs/settings.md#alerts).** 잔량 부족·빠른 소진·기간 종료 전 남은 할당량과 Codex Reset Watch 통지.
  다섯 조건을 개별 선택하며 기본값은 꺼짐.
  기간 종료 전 잔량 알림은 한도별로 한 기간에 한 번 통지.
- **[전역 단축키](/docs/settings.md#general).** Settings → General에서 지정한 키 조합으로 패널 열기·닫기.
- **Accounts.** 계정 추가·전환·재로그인·API 키와 계정별 지표 표시·순서 관리.
  숨긴 계정 복원과 이름 변경·중단된 Claude 전환 복구 지원.
- **Stale-while-revalidate.** Cached values display instantly at launch; refresh runs every 5 minutes (15 minutes for Claude).
- **[iCloud 동기화](/docs/icloud-sync.md).** 여러 Mac의 사용 내역을 선택적으로 합산.
  현재·기존 저장 위치를 함께 읽고 기기별 최신 기록 사용.
- **[One-shot CLI](docs/cli.md).** Agents can read stable limit JSON through the same five-minute cache (15 minutes for Claude) with `egasu`, or bypass freshness with `egasu --force`; the menu-bar app does not need to be running.
  CLI가 포함된 앱의 설정·저장 경로 사용.
  첫 조회 전에 기존 API 키와 Claude의 조회 대기·마지막 정상 사용량 이전.
  기존 Claude 조회가 진행 중이면 완료 후 재시도.
- **[Local HTTP API](docs/local-http-api.md).** Other local apps can read machine-friendly limits from `127.0.0.1:6736/v1/limits`; the legacy `/v1/usage` UI contract remains supported. It is loopback-only, rejects browser-origin requests, and never serves credentials.
- **[Proxy support](docs/proxy.md).** Route provider requests through SOCKS5 or HTTP(S) via `~/.openusage/config.json`.
- **[네이티브 설정](/docs/settings.md).** General·Display·Alerts·Advanced에서 로그인 시 실행, 단축키, 표시, 알림과 진단 설정.
- **[Automatic updates](docs/updates.md).** Signed, notarized in-app updates via Sparkle, with an optional beta channel.



## Documentation

Behavior docs live in [docs/](docs/README.md): the [dashboard](docs/dashboard.md), [menu bar display](/docs/menu-bar.md), [settings](docs/settings.md), [refresh & caching](docs/refreshing.md), the [CLI](docs/cli.md), the [local HTTP API](docs/local-http-api.md), the [proxy](docs/proxy.md), and one page per provider.

For working on the code, see the developer docs: [architecture](docs/architecture.md), [adding a provider](docs/adding-a-provider.md), and [debugging & capturing logs](docs/debugging.md).

## Requirements

- macOS 15 (Sequoia) or later
- Universal binary — runs natively on both Apple Silicon and Intel Macs

비용·토큰의 기간별 집계는 프로바이더마다 로컬 기록 또는 서버 사용량을 사용.
[집계 범위](/docs/dashboard.md#총-지출) 참조.
Cursor 비용은 서버가 보고한 추가 과금액 사용.
로컬 토큰 기반 비용은 [동적으로 갱신되는 모델 가격](/docs/pricing.md)으로 추정.



## Building

```sh
swift build            # debug build
swift test             # run the test suite
./script/build_and_run.sh   # build and launch the dev app from dist/ (no install)
```

개발 서명과 버전은 저장소별 로컬 설정으로 고정 가능.
설정 방법과 베타 종료 후 수동 포매팅 절차는 [디버깅 문서](/docs/debugging.md) 참조.



## Architecture

앱과 CLI는 SwiftPM의 `Egasu` 모듈과 Swift 6 strict concurrency 사용.
메뉴 막대는 AppKit의 `NSStatusItem`, 패널 화면은 키 입력을 받는 `NSPanel`의 SwiftUI 콘텐츠로 구성.
각 프로바이더는 `ProviderRuntime`을 구현하고 인증 정보로 조회한 데이터를 `ProviderSnapshot`으로 변환.
[아키텍처](/docs/architecture.md)와 [AGENTS.md](AGENTS.md) 참조.

사용량 갱신은 큐·실제 작업 수명·예약·계정별 캐시·표시 데이터 변환 모듈로 분리.
화면과 로컬 API는 `WidgetDataStore`를 통해 같은 결과 사용.
자세한 연결은 [사용량 처리 모듈](/docs/architecture.md#사용량-처리-모듈) 참조.

## Releasing

앱 릴리스는 [.github/workflows/release.yml](.github/workflows/release.yml)에서 빌드·서명·공증 후 게시.
일반 태그(`v0.10.0`)는 정식 채널, `-beta.N` 접미사 태그(`v0.10.0-beta.1`)는 베타 채널로 배포.
배포 절차는 `release-swift` 스킬 참조.

앱·사이트·가격표는 `main` 이력에 포함된 버전 태그를 기준으로 게시.
`main` 푸시는 CI 검증만 수행하며, 수동 게시에도 대상 태그 필수.
Pages 재배포는 해당 태그의 성공한 게시 실행 결과 사용.
자세한 조건은 [게시 버전 보호](/docs/updates.md#유지-관리자-게시-버전-보호) 참조.

### Release setup (one-time)

The release workflow needs these repository secrets (Settings → Secrets and variables → Actions):


| Secret                       | What it is                                                            |
| ---------------------------- | --------------------------------------------------------------------- |
| `APPLE_CERTIFICATE`          | base64 of your Developer ID Application `.p12`                        |
| `APPLE_CERTIFICATE_PASSWORD` | the password set when exporting that `.p12`                           |
| `APPLE_ID`                   | the Apple ID email used for notarization                              |
| `APPLE_PASSWORD`             | an app-specific password for that Apple ID                            |
| `APPLE_TEAM_ID`              | your Apple Developer team ID                                          |
| `APPLE_DEVELOPER_ID_ICLOUD_PROFILE` | base64 Developer ID provisioning profile for the production iCloud container |
| `SPARKLE_PUBLIC_KEY`         | base64 EdDSA public key, baked into the build as `SUPublicEDKey`      |
| `SPARKLE_PRIVATE_KEY`        | base64 EdDSA private key used to sign the DMG                         |
| `POSTHOG_CLI_API_KEY`        | PostHog personal API key used to upload dSYMs for crash symbolication |
| `POSTHOG_CLI_PROJECT_ID`     | numeric PostHog project ID the dSYMs upload to                        |


Export the Developer ID Application cert (with its private key) from Keychain Access as a `.p12`, then `base64 -i DeveloperID.p12 | pbcopy`. App-specific passwords come from appleid.apple.com → Sign-In and Security → App-Specific Passwords. Generate the Sparkle EdDSA key pair once with Sparkle's `generate_keys` tool.

워크플로는 GitHub Release에 DMG를 먼저 게시하고, 해당 DMG의 appcast 항목에 `sparkle:edSignature` 속성이 있는지 확인.
검사에 실패하면 Pages의 appcast는 갱신되지 않으며, 이미 게시된 GitHub Release와 DMG는 공개 상태로 유지.
GitHub Release와 DMG를 확인한 뒤 서명 설정이 원인이면 수정하고 같은 태그로 릴리스 워크플로를 다시 실행.

For iCloud Sync, store the original development and Developer ID provisioning profiles in 1Password as secure documents. Install the development profile on each registered Mac; base64-encode the Developer ID profile and store it only in the `APPLE_DEVELOPER_ID_ICLOUD_PROFILE` Actions secret. See [iCloud Sync](/docs/icloud-sync.md#개발-및-릴리스-설정) for the container identifiers, build command, and file-inspection command.

The two `POSTHOG_CLI_*` secrets are only used to upload debug symbols (dSYMs) so PostHog can symbolicate crash reports: `POSTHOG_CLI_API_KEY` is a PostHog personal API key (PostHog → Settings → Personal API keys) and `POSTHOG_CLI_PROJECT_ID` is the numeric ID from your project URL. The upload host is hardcoded in the workflow (`https://us.i.posthog.com`), so there is no `POSTHOG_CLI_HOST` secret. Unlike the secrets above these don't block a release — if `POSTHOG_CLI_API_KEY` is unset the workflow skips the upload with a warning and the release still ships, but crash reports for that version show raw addresses instead of symbolicated stack traces.

The repository must be public (Sparkle fetches the DMG and appcast anonymously), and the appcast is served from GitHub Pages — confirm Settings → Pages uses **GitHub Actions** as the deployment source after the first release.

## Contributing

Issues are welcome. Pull requests are **strict and issue-first**: external PRs must link an issue a maintainer has approved with the `approved` label, and automation closes anything that doesn't follow the rules — so **most external PRs are closed by design**. Read [CONTRIBUTING.md](CONTRIBUTING.md) before opening one. Report security issues privately per [SECURITY.md](SECURITY.md). The upstream OpenUsage brand is covered by its [trademark policy](TRADEMARK.md).

## License

[MIT](LICENSE)
