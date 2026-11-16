---
name: build-run-debug
description: Build, run, and debug local macOS apps and desktop executables using shell-first Xcode and Swift workflows. Use when asked to build a Mac app, launch it, diagnose compiler or linker failures, inspect startup problems, or debug desktop-only runtime issues.
---

# Build / Run / Debug

## Quick Start

egasu에서는 기존 `script/build_and_run.sh`를 기본 빌드·실행 경로로 사용.
지원 모드는 `run|build|logs|verify`이며 인자 생략 시 `run`.
`--` 접두사와 `debug`·`telemetry` 모드는 미지원.
새 프로젝트에 스크립트가 없을 때만 참조 문서의 생성 예시 적용.

Prefer shell-first workflows:

- `./script/build_and_run.sh` as the single kill + build + run entrypoint once it exists
- `xcodebuild` for Xcode workspaces or projects
- `swift build` plus raw executable launch inside that script for true SwiftPM command-line tools
- `swift build` plus project-local `.app` bundle staging and `/usr/bin/open -n` launch for SwiftPM AppKit/SwiftUI GUI apps
- `logs`·`verify` 모드로 로그·프로세스 확인, 디버거와 세부 로그 필터는 별도 명령 사용

Do not assume simulators, touch interaction, or mobile-specific tooling.

If an Xcode-aware MCP surface is already available and the user explicitly wants
it, use it only where it fits. Keep that usage narrow and honest: prefer it for
Xcode-oriented discovery, logging, or debugging support, and do not force
simulator-specific workflows onto pure macOS tasks.

## Workflow

1. Discover the project shape.
   - Check whether the workspace is already inside a git repo with `git rev-parse --is-inside-work-tree`.
   - If no git repo is present, run `git init` at the project/workspace root before building so git-backed editor features unlock. Never run `git init` inside a nested subdirectory when the current workspace already belongs to a parent repo.
   - Look for `.xcworkspace`, `.xcodeproj`, and `Package.swift`.
   - If more than one candidate exists, explain the default choice and the ambiguity.

2. Resolve the runnable target and process name.
   - For Xcode, list schemes and prefer the app-producing scheme unless the user names another one.
   - For SwiftPM, identify executable products when possible.
   - Split SwiftPM launch handling by product type:
     - use raw executable launch only for true command-line tools,
     - use a generated project-local `.app` bundle for AppKit/SwiftUI GUI apps.
   - Determine the app/process name to kill before relaunching.

3. 기존 `script/build_and_run.sh`의 계약 확인.
   - egasu에서는 기존 개발 번들·서명·iCloud·CLI 배치 흐름 유지.
   - 아래 생성 지침은 실행 스크립트가 없는 새 프로젝트에만 적용.
   - Make the script project-specific and executable.
   - It should always:
     1. stop the existing running app/process if present,
     2. build the macOS target,
     3. `build`를 제외한 모드에서 새 앱 또는 실행 파일 시작.
   - 모드별 계약:
     - `run`: 기존 개발 앱 종료 후 빌드·서명·실행.
     - `build`: 기존 개발 앱 종료 후 빌드·배치·서명만 수행.
     - `logs`: 빌드·실행 후 프로세스 로그 스트리밍.
     - `verify`: 빌드·실행 후 `pgrep -x <AppName>`로 프로세스 존재 확인.
   - Keep the default no-flag path simple: kill, build, run.
   - Prefer writing one script that owns this workflow instead of repeatedly asking the agent to manually run `swift build`, locate the artifact, then invoke an ad hoc run command.
   - For SwiftPM GUI apps, make the script build the product, create `dist/<AppName>.app`, copy the binary to `Contents/MacOS/<AppName>`, generate a minimal `Contents/Info.plist` with `CFBundlePackageType=APPL`, `CFBundleExecutable`, `CFBundleIdentifier`, `CFBundleName`, `LSMinimumSystemVersion`, and `NSPrincipalClass=NSApplication`, then launch with `/usr/bin/open -n <bundle>`.
   - SwiftPM GUI의 `logs` 모드는 `/usr/bin/open -n`으로 번들을 시작한 뒤 `/usr/bin/log stream --info ...` 실행.
   - Do not recommend direct SwiftPM executable launch for AppKit/SwiftUI GUI apps.
   - Use `references/build-script.md` as the canonical source for the script shape. Do not fork a second authoritative snippet in another skill or command.
   - Keep the run script outside app source. It belongs in `script/build_and_run.sh`, not in `App/`, `Views/`, `Models/`, `Stores/`, `Services/`, or `Support/`.

4. Build and run through the script.
   - Default to `./script/build_and_run.sh`.
   - 로그 확인은 `./script/build_and_run.sh logs`, 실행 확인은 `./script/build_and_run.sh verify` 사용.
   - 실행 없이 빌드·서명만 필요하면 `./script/build_and_run.sh build` 사용.
   - 잘못된 모드는 개발 앱 종료·빌드·서명 뒤 거부되므로 지원 인자를 먼저 확인.

5. Summarize failures correctly.
   - Classify the blocker as compiler, linker, signing, build settings, missing SDK/toolchain, script bug, or runtime launch.
   - Quote the smallest useful error snippet and explain what it means.

6. Debug the right way.
   - 설정·권한·동작 확인에는 `logs` 모드 사용.
   - 더 좁은 텔레메트리 필터가 필요하면 앱 실행 후 `log stream`의 subsystem/category 조건 사용.
   - For SwiftPM GUI apps, if the app bundle launches but its window still does not come forward, check whether the entrypoint needs `NSApp.setActivationPolicy(.regular)` and `NSApp.activate(ignoringOtherApps: true)`.
   - 디버거가 필요하면 개발 앱의 PID를 확인한 뒤 `lldb -p <개발 앱 PID>`로 연결.
   - If the user needs to instrument and verify specific window, sidebar, menu, or menu bar actions, switch to `telemetry`.
   - Keep evidence tight and user-facing.

7. Use Xcode-aware MCP tooling only when it helps.
   - If the user explicitly asks for XcodeBuildMCP and it is already available, prefer it over ad hoc setup.
   - Use the MCP for Xcode-aware discovery or debug/logging workflows when the available tool surface clearly matches the task.
   - Fall back to shell commands immediately when the MCP does not provide a clean macOS path.

## Preferred Commands

- Project discovery:
  - `find . -name '*.xcworkspace' -o -name '*.xcodeproj' -o -name 'Package.swift'`
- Scheme discovery:
  - `xcodebuild -list -workspace <workspace>`
  - `xcodebuild -list -project <project>`
- Build/run:
  - `./script/build_and_run.sh`
  - `./script/build_and_run.sh build`
  - `./script/build_and_run.sh logs`
  - `./script/build_and_run.sh verify`

## References

- `references/build-script.md`: canonical `script/build_and_run.sh` shapes for SwiftPM CLI tools and SwiftPM AppKit/SwiftUI GUI apps.

## Guardrails

- Prefer the narrowest command that proves or disproves the current theory.
- Do not leave the user with a one-off manual command chain once a stable `build_and_run.sh` script can own the workflow.
- Do not launch a SwiftUI/AppKit SwiftPM GUI app as a raw executable unless the user explicitly wants to diagnose that failure mode: it can produce no Dock icon, no foreground activation, and missing bundle identifier warnings. Keep raw executable launch only for true command-line tools.
- Do not claim UI state you cannot inspect directly.
- Do not describe mobile or simulator workflows as if they apply to macOS.
- If build output is huge, summarize the first real blocker and point to follow-up commands.

## Output Expectations

Provide:
- the detected project type
- the script path you configured, if applicable
- the command you ran
- whether build and launch succeeded
- the top blocker if they failed
- the smallest sensible next action
