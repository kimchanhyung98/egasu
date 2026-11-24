#!/usr/bin/env bash
# 위젯의 App Intents 메타데이터와 지역화 리소스 생성. 실제 서명은 호스트 번들에 배치할 때 수행.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bundle_id="${1:?host bundle identifier required}"
version="${2:?host version required}"
build="${3:?host build number required}"
case "${4:?configuration required}" in
  debug) configuration=Debug ;;
  release) configuration=Release ;;
  *) echo "Unknown build configuration: $4" >&2; exit 1 ;;
esac
read -ra architectures <<< "${5:?architectures required}"
derived="$root/.build/widget-extension/$bundle_id"
xcodebuild -quiet -project "$root/EgasuWidgets.xcodeproj" -scheme EgasuWidgets \
  -configuration "$configuration" -destination 'generic/platform=macOS' -derivedDataPath "$derived" \
  "ARCHS=${architectures[*]}" ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO \
  "PRODUCT_BUNDLE_IDENTIFIER=$bundle_id.widgets" "MARKETING_VERSION=$version" \
  "CURRENT_PROJECT_VERSION=$build" build >&2
product="$derived/Build/Products/$configuration/EgasuWidgets.appex"
slices="$(lipo -archs "$product/Contents/MacOS/EgasuWidgets")"
for architecture in "${architectures[@]}"; do
  case " $slices " in
    *" $architecture "*) ;;
    *) echo "Missing $architecture desktop widget slice: $slices" >&2; exit 1 ;;
  esac
done
if [ ! -s "$product/Contents/Resources/Metadata.appintents/extract.actionsdata" ]; then
  echo "Missing desktop widget configuration metadata" >&2
  exit 1
fi
printf '%s\n' "$product"
