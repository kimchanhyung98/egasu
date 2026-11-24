#!/usr/bin/env bash
# 먼저 서명한 CLI에서 실제 팀을 읽어 호스트와 확장에 같은 macOS App Group 배정.
set -euo pipefail
app="${1:?host bundle required}"
product="${2:?extension product required}"
identity="${3:?signing identity required}"
entitlements="${4:?writable host entitlements required}"
case "${5:?development or release required}" in
  development) scheme=egasu-dev; timestamp=--timestamp=none ;;
  release) scheme=egasu; timestamp=--timestamp ;;
  *) exit 2 ;;
esac
contents="$app/Contents"
team="$(codesign -dv --verbose=4 "$contents/Helpers/egasu" 2>&1 | awk -F= '$1 == "TeamIdentifier" {print $2}')"
if ! [[ "$team" =~ ^[A-Z0-9]{10}$ ]]; then
  if [ "$5" = development ]; then
    echo "WARNING: no signing Team Identifier; the development bundle will omit desktop widgets." >&2
    exit 0
  fi
  echo "Desktop widgets need a signing certificate with a Team Identifier." >&2
  exit 1
fi
extension="$contents/PlugIns/EgasuWidgets.appex"
mkdir -p "$contents/PlugIns"
ditto "$product" "$extension"
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT

python3 - "$contents/Info.plist" "$extension/Contents/Info.plist" "$entitlements" \
  "$temporary/widget.entitlements" "$team" "$scheme" <<'PY'
import plistlib
import sys
from pathlib import Path

host_info, widget_info, host_entitlements, widget_entitlements = map(Path, sys.argv[1:5])
team, scheme = sys.argv[5:]
host = plistlib.loads(host_info.read_bytes())
widget = plistlib.loads(widget_info.read_bytes())
host_id = host["CFBundleIdentifier"]
if widget["CFBundleIdentifier"] != host_id + ".widgets" or any(
    host[key] != widget[key] for key in ("CFBundleVersion", "CFBundleShortVersionString")
):
    sys.exit("Desktop widget bundle identity or version does not match the host")
group = f"{team}.{host_id}.widgets"
for info in (host, widget):
    info["EgasuWidgetAppGroup"] = group
    info["EgasuWidgetURLScheme"] = scheme
host.setdefault("CFBundleURLTypes", []).append({
    "CFBundleURLName": host_id + ".widgets",
    "CFBundleURLSchemes": [scheme],
    "CFBundleTypeRole": "Viewer",
})
host_info.write_bytes(plistlib.dumps(host))
widget_info.write_bytes(plistlib.dumps(widget))
rights = plistlib.loads(host_entitlements.read_bytes())
rights.setdefault("com.apple.security.application-groups", []).append(group)
host_entitlements.write_bytes(plistlib.dumps(rights))
widget_entitlements.write_bytes(plistlib.dumps({
    "com.apple.security.app-sandbox": True,
    "com.apple.security.application-groups": [group],
}))
PY
codesign --force --options runtime "$timestamp" --entitlements "$temporary/widget.entitlements" \
  --sign "$identity" "$extension"
codesign --verify --strict "$extension"
