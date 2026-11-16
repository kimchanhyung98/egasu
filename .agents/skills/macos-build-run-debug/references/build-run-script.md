# Build & Run Script

egasu의 실행 계약은 기존 `script/build_and_run.sh` 기준.
지원 모드는 `run|build|logs|verify`이며 기본값은 `run`.
`build`는 개발 앱 종료 후 빌드·배치·서명만 수행하고, 나머지 모드는 실행까지 수행.
로그는 `logs`, 실행 확인은 `verify` 사용.
세부 텔레메트리는 실행 후 `log stream`으로 확인하고, 디버거는 개발 앱 PID를 확인한 뒤 `lldb -p <개발 앱 PID>`로 연결.
아래 예시는 실행 스크립트가 없는 새 프로젝트에만 적용.
egasu의 기존 스크립트에는 서명·iCloud·CLI 배치가 있으므로 이 예시로 교체하지 않음.

This is the canonical contract for a macOS app's local build/run loop.

When a project does not already have an established macOS run entrypoint:

1. Create one project-local `script/build_and_run.sh`.
2. Make it executable.
3. Use it as the single kill + build + run entrypoint.
4. `run|build|logs|verify` 모드 지원.

## `script/build_and_run.sh`

Use one project-specific script with a tiny mode switch and a default no-flag
path that just kills, builds, and launches. Keep raw executable launch only for
true command-line tools. For SwiftPM AppKit/SwiftUI GUI apps, stage a
project-local `.app` bundle and launch that bundle with `/usr/bin/open -n`.

### SwiftPM CLI executable

Use this shape for true command-line tools:

```bash
#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="MyTool"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

swift build
APP_BINARY="$(swift build --show-bin-path)/$APP_NAME"

case "$MODE" in
  run)
    "$APP_BINARY"
    ;;
  build)
    :
    ;;
  logs)
    "$APP_BINARY" &
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  verify)
    "$APP_BINARY" &
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|build|logs|verify]" >&2
    exit 2
    ;;
esac
```

### SwiftPM AppKit/SwiftUI GUI app

Use this shape for SwiftPM GUI apps so they launch as a real foreground app
bundle with Dock activation and bundle metadata:

```bash
#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="MyApp"
BUNDLE_ID="com.example.MyApp"
MIN_SYSTEM_VERSION="14.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

swift build
BUILD_BINARY="$(swift build --show-bin-path)/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  build)
    :
    ;;
  logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|build|logs|verify]" >&2
    exit 2
    ;;
esac
```

Launching a SwiftPM GUI binary directly can produce no Dock icon, no foreground
activation, and missing bundle identifier warnings. If the `.app` bundle opens
but the main window still does not come forward, the app entrypoint may need
`NSApp.setActivationPolicy(.regular)` and
`NSApp.activate(ignoringOtherApps: true)`.

Adapt the build step for Xcode projects by replacing `swift build` with
`xcodebuild -project ...` or `xcodebuild -workspace ...`, then launch the built
`.app` binary from DerivedData or a deterministic project-local build path. Keep
the one-script interface and mode flags the same.
