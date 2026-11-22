---
name: build-and-run-macos-app
description: Slash command that creates or updates the project-local macOS `script/build_and_run.sh` and uses it as the default build/run entrypoint. Invoke explicitly with /build-and-run-macos-app — this skill never self-triggers.
disable-model-invocation: true
---

# Build And Run macOS App

egasu에서는 기존 `script/build_and_run.sh`를 기본 빌드·실행 경로로 사용.
스크립트 생성 예시는 실행 경로가 없는 새 프로젝트에만 적용.

## Arguments

- `scheme`: Xcode scheme name (optional)
- `workspace`: path to `.xcworkspace` (optional)
- `project`: path to `.xcodeproj` (optional)
- `product`: SwiftPM executable product name (optional)
- `mode`: `run`, `build`, `logs`, `verify` 중 하나(선택, 기본값 `run`)
- `app_name`: process/app name to stop before relaunching (optional)

## Workflow

1. Detect whether the repo uses an Xcode workspace, Xcode project, or SwiftPM package.
2. If the workspace is not inside git yet, run `git init` at the project root so git-backed editor features unlock.
3. 기존 스크립트의 모드와 개발 번들·서명 계약 확인.
   `build`는 Swift 빌드 성공 후 기존 개발 앱의 정상 종료를 기다린 뒤 배치·서명만 수행.
   나머지 모드는 실행까지 수행.
4. For SwiftPM, keep raw executable launch only for true CLI tools; for AppKit/SwiftUI GUI apps, create a project-local `.app` bundle and launch it with `/usr/bin/open -n`.
5. `./script/build_and_run.sh [run|build|logs|verify]` 사용.
   `--` 접두사와 `debug`·`telemetry` 모드는 미지원.
   잘못된 모드는 저장소·서명 확인과 앱 종료·빌드 전에 사용법과 종료 코드 2로 거부.
6. Follow the canonical bootstrap contract in `../build-run-debug/references/build-script.md` for the exact script shape.
7. Run the script in the requested mode and summarize any build, script, or launch failure.

## Guardrails

- Do not initialize a nested git repo inside an existing parent checkout.
- egasu 인자 생략 경로는 Swift 빌드 → 기존 개발 앱 정상 종료 대기 → 배치·서명 → 실행 순서.
- Swift 컴파일 실패 시 실행 앱 유지.
- 종료 대기 25초 초과 시 기존 번들을 유지하고 중단.
- 세부 진단 로그는 `log stream --info` 사용.
  시작 로그 확인은 별도 터미널에서 스트림을 먼저 시작한 뒤 `run` 실행.
- `TelemetryRecorder` 이벤트는 가짜 sink·진단 observer·stub transport 테스트로 별도 확인.
  `log stream`의 진단 로그를 이벤트 전달 증거로 사용하지 않음.
- 디버거는 개발 앱 PID를 확인한 뒤 `lldb -p <개발 앱 PID>`로 연결.
- egasu의 기존 실행 스크립트를 새 프로젝트용 예시로 교체하지 않음.
