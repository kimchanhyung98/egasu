# egasu

Track your AI coding subscriptions from the macOS menu bar — native Swift edition.

egasu shows how much of your AI coding plans you've used: session and weekly limits, credits, and spend, all in one popover. Pin your most important metrics straight into the menu bar.

<p align="center">
  <img src="assets/screenshot.jpg?v=20260706" alt="egasu menu bar tracker showing Claude and Codex session, weekly, and spend usage" width="900">
</p>

## Installation

Download the latest universal DMG from the [GitHub releases page](https://github.com/kimchanhyung98/egasu/releases/latest), open it, and drag egasu to your Applications folder.

The app updates itself in place via signed, notarized [Sparkle](docs/updates.md) updates. Requires macOS 15 (Sequoia) or later.

## Supported Providers

- **[Antigravity](docs/providers/antigravity.md)** — shared Gemini and Claude pool quotas, 5-hour and weekly windows
- **[Claude](docs/providers/claude.md)** — session, weekly, model-specific limits, extra usage, local daily spend
- **[Codex](docs/providers/codex.md)** — session, weekly, credits, local daily spend
- **[Copilot](docs/providers/copilot.md)** — AI credits, extra usage, organization billing, chat and completions
- **[Cursor](docs/providers/cursor.md)** — credits, total/auto/API usage, requests, on-demand, per-day spend
- **[Devin](docs/providers/devin.md)** — weekly and daily quota, extra usage balance
- **[Grok](docs/providers/grok.md)** — weekly shared pool, pay-as-you-go, local daily spend
- **[Kimi](/docs/providers/kimi.md)** — 5시간·주간·월간 총한도, 추가 지출·잔액.
- **[Kiro](docs/providers/kiro.md)** — coding credits and subscription plan
- **[OpenCode](docs/providers/opencode.md)** — Go session/weekly/monthly caps, Zen spend, local daily spend
- **[OpenRouter](docs/providers/openrouter.md)** — credit balance, daily/weekly/monthly spend (API key)
- **[Z.ai](docs/providers/zai.md)** — session, weekly, web-search quotas (GLM Coding Plan, API key)

Most providers read the credentials already on your machine (keychain, auth files, app state) — no extra login. OpenRouter and Z.ai are the exceptions: they have no local credential to reuse, so you supply an API key (see [OpenRouter setup](docs/providers/openrouter.md) or [Z.ai setup](docs/providers/zai.md)). Credentials are used only for the corresponding provider requests. egasu's separate anonymous summaries and public pricing downloads are documented under [Privacy & usage data](docs/privacy.md).

## Features

- **Menu bar pins.** Pin metrics to the menu bar (up to 2 per provider); render as compact text or mini bars. The strip hides metrics with no data instead of showing placeholders.
- **Dashboard popover.** Provider-grouped meters with live reset countdowns and pace indicators. Click usage or reset values to flip their display everywhere; right-click a row to hide or star it, refresh its provider, or open Customize.
- **[계정 전환](/docs/cli.md#계정).** Claude·Codex의 기본 인증 저장소를 쓰는 새 CLI 세션에 선택한 로그인 적용.
  셸 설정 파일·터미널 환경을 유지하며, Claude 첫 등록·외부 로그인과 전환 중 보존할 변경된 인증은 토큰의 계정·조직을 검증한 뒤 저장본에 반영.
  선택된 Claude 공유 로그인은 사용량 조회에서도 계정·조직 일치 검증.
- **Global shortcut.** Toggle the popover from anywhere — record any combo in Settings.
- **Customize.** Turn providers and metrics on or off, choose which rows stay Always Visible or On Demand, and drag-reorder both.
- **Stale-while-revalidate.** Cached values display instantly at launch; refresh runs every 5 minutes (15 minutes for Claude).
- **[iCloud 동기화](/docs/icloud-sync.md).** 여러 Mac의 사용 내역을 선택적으로 합산.
  현재·기존 저장 위치를 함께 읽고 기기별 최신 기록 사용.
- **[One-shot CLI](docs/cli.md).** Agents can read stable limit JSON through the same five-minute cache (15 minutes for Claude) with `egasu`, or bypass freshness with `egasu --force`; the menu-bar app does not need to be running.
  CLI가 포함된 앱의 설정·저장 경로 사용.
  첫 조회 전에 기존 API 키와 Claude의 조회 대기·마지막 정상 사용량 이전.
  기존 Claude 조회가 진행 중이면 완료 후 재시도.
- **[Local HTTP API](docs/local-http-api.md).** Other local apps can read machine-friendly limits from `127.0.0.1:6736/v1/limits`; the legacy `/v1/usage` UI contract remains supported. It is loopback-only, rejects browser-origin requests, and never serves credentials.
- **[Proxy support](docs/proxy.md).** Route provider requests through SOCKS5 or HTTP(S) via `~/.openusage/config.json`.
- **Native settings.** Launch at login, global shortcut, icon style, theme, density, 12/24-hour time — see [Settings](docs/settings.md).
- **[Automatic updates](docs/updates.md).** Signed, notarized in-app updates via Sparkle, with an optional beta channel.



## Documentation

Behavior docs live in [docs/](docs/README.md): the [dashboard](docs/dashboard.md), [menu bar pins](docs/menu-bar.md), [settings](docs/settings.md), [refresh & caching](docs/refreshing.md), the [CLI](docs/cli.md), the [local HTTP API](docs/local-http-api.md), the [proxy](docs/proxy.md), and one page per provider.

For working on the code, see the developer docs: [architecture](docs/architecture.md), [adding a provider](docs/adding-a-provider.md), and [debugging & capturing logs](docs/debugging.md).

## Requirements

- macOS 15 (Sequoia) or later
- Universal binary — runs natively on both Apple Silicon and Intel Macs

The Today / Yesterday / Last 30 Days spend tiles are computed natively from local CLI logs (Claude,
Codex, and Grok) or Cursor's usage export — no Node.js or other runtime needed. Dollars are estimated
with [dynamically refreshed model pricing](docs/pricing.md).



## Building

```sh
swift build            # debug build
swift test             # run the test suite
./script/build_and_run.sh   # build and launch the dev app from dist/ (no install)
```

개발 서명과 버전은 저장소별 로컬 설정으로 고정 가능.
설정 방법과 베타 종료 후 수동 포매팅 절차는 [디버깅 문서](/docs/debugging.md) 참조.



## Architecture

SwiftPM package, SwiftUI content hosted in an AppKit-owned `NSStatusItem` + custom key-capable `NSPanel`, Swift 6 strict concurrency. The app and CLI share one module: providers implement a small `ProviderRuntime` protocol (auth store → usage client → mapper → `ProviderSnapshot`), and both surfaces read the same normalized data — see the [architecture overview](docs/architecture.md) for how the pieces fit together and [AGENTS.md](AGENTS.md) for engineering conventions.

사용량 갱신은 큐·실제 작업 수명·예약·계정별 캐시·표시 데이터 변환 모듈로 분리.
화면과 로컬 API는 `WidgetDataStore`를 통해 같은 결과 사용.
자세한 연결은 [사용량 처리 모듈](/docs/architecture.md#사용량-처리-모듈) 참조.

## Releasing

Releases are automated: pushing a `v*` tag on `main` builds, signs, notarizes, and publishes a new version. A plain tag (`v0.10.0`) ships to everyone; a pre-release suffix (`v0.10.0-beta.1`) ships to the beta channel. The pipeline lives in [.github/workflows/release.yml](.github/workflows/release.yml), and the step-by-step is in the `release-swift` skill.

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


Export the Developer ID Application cert (with its private key) from Keychain Access as a `.p12`, then `base64 -i DeveloperID.p12 | pbcopy`. App-specific passwords come from appleid.apple.com → Sign-In and Security → App-Specific Passwords. Generate the Sparkle EdDSA key pair once with Sparkle's `generate_keys` tool; the public and private values must be a matching pair or signing is silently skipped.

For iCloud Sync, store the original development and Developer ID provisioning profiles in 1Password as secure documents. Install the development profile on each registered Mac; base64-encode the Developer ID profile and store it only in the `APPLE_DEVELOPER_ID_ICLOUD_PROFILE` Actions secret. See [iCloud Sync](/docs/icloud-sync.md#개발-및-릴리스-설정) for the container identifiers, build command, and file-inspection command.

The two `POSTHOG_CLI_*` secrets are only used to upload debug symbols (dSYMs) so PostHog can symbolicate crash reports: `POSTHOG_CLI_API_KEY` is a PostHog personal API key (PostHog → Settings → Personal API keys) and `POSTHOG_CLI_PROJECT_ID` is the numeric ID from your project URL. The upload host is hardcoded in the workflow (`https://us.i.posthog.com`), so there is no `POSTHOG_CLI_HOST` secret. Unlike the secrets above these don't block a release — if `POSTHOG_CLI_API_KEY` is unset the workflow skips the upload with a warning and the release still ships, but crash reports for that version show raw addresses instead of symbolicated stack traces.

The repository must be public (Sparkle fetches the DMG and appcast anonymously), and the appcast is served from GitHub Pages — confirm Settings → Pages uses **GitHub Actions** as the deployment source after the first release.

## Contributing

Issues are welcome. Pull requests are **strict and issue-first**: external PRs must link an issue a maintainer has approved with the `approved` label, and automation closes anything that doesn't follow the rules — so **most external PRs are closed by design**. Read [CONTRIBUTING.md](CONTRIBUTING.md) before opening one. Report security issues privately per [SECURITY.md](SECURITY.md). The upstream OpenUsage brand is covered by its [trademark policy](TRADEMARK.md).

## License

[MIT](LICENSE)
