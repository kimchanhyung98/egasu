#!/usr/bin/env bash
set -euo pipefail

# 준비된 .app 번들에 Sparkle.framework를 포함하고 서명.
#
# SwiftPM은 .build/artifacts의 xcframework를 @rpath로 연결하지만 앱 번들로 복사하지 않음.
# Contents/Frameworks에 복사하고 실행 경로 추가 후 프레임워크 서명.
# 호출자는 이 서명을 유지하도록 앱 번들을 나중에 --deep 없이 서명.
#
# 사용법: embed_sparkle.sh <app_bundle> <app_binary> [signing_identity] [extra_codesign_flags]
#   signing_identity      서명 이름·해시, 생략하거나 빈 값이면 ad-hoc("-")
#   extra_codesign_flags  예: "--options runtime --timestamp". 의도적으로 공백 단위 분리.

APP_BUNDLE="$1"
APP_BINARY="$2"
SIGN_ID="${3:--}"
EXTRA_FLAGS="${4:-}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# macOS용 프레임워크 우선 선택, 없으면 다른 경로의 Sparkle.framework 탐색.
SPARKLE_FW="$(/usr/bin/find "$ROOT_DIR/.build/artifacts" -type d -name "Sparkle.framework" -path "*macos*" 2>/dev/null | head -n1)"
if [ -z "$SPARKLE_FW" ]; then
  SPARKLE_FW="$(/usr/bin/find "$ROOT_DIR/.build/artifacts" -type d -name "Sparkle.framework" 2>/dev/null | head -n1)"
fi
if [ -z "$SPARKLE_FW" ]; then
  echo "Sparkle.framework not found under .build/artifacts — run 'swift build' first." >&2
  exit 1
fi

FRAMEWORKS="$APP_BUNDLE/Contents/Frameworks"
mkdir -p "$FRAMEWORKS"
rm -rf "$FRAMEWORKS/Sparkle.framework"
# ditto로 프레임워크의 버전 심볼릭 링크와 서명 구조 보존.
ditto "$SPARKLE_FW" "$FRAMEWORKS/Sparkle.framework"

# egasu는 샌드박스를 사용하지 않아 Sparkle의 XPC 서비스 불필요.
# XPC 서비스를 제거해 중첩 서명·권한 처리와 launchd 거부에 따른 설치 프로그램 실행 실패 방지.
# 버전 문자가 B가 아니어도 제거되도록 와일드카드 사용.
rm -rf "$FRAMEWORKS"/Sparkle.framework/Versions/*/XPCServices
rm -f  "$FRAMEWORKS/Sparkle.framework/XPCServices"

# SwiftPM의 @loader_path에 더해 Contents/Frameworks를 찾는 실행 경로 필요.
# 재실행 시 중복 오류를 막도록 없을 때만 추가하며 install_name_tool의 실패는 그대로 전달.
if ! otool -l "$APP_BINARY" | grep -q "@executable_path/../Frameworks"; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BINARY"
fi

# 프레임워크와 내부 Autoupdate·Updater.app을 같은 인증서로 서명해 공증 시 팀 일치.
# --deep 대상에서 제외해야 하는 XPC 서비스는 위에서 제거한 상태.
# shellcheck disable=SC2086
codesign --force --deep $EXTRA_FLAGS --sign "$SIGN_ID" "$FRAMEWORKS/Sparkle.framework"

echo "==> embedded + signed Sparkle.framework (identity: $SIGN_ID)"
