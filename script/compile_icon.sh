#!/usr/bin/env bash
# assets/AppIcon.prebuilt/에 보관하는 사전 빌드 앱 아이콘 재생성.
#
# assets/AppIcon.icon은 Icon Composer의 refractivity(Liquid Glass) 기능 사용.
# 컴파일 가능한 actool로 미리 생성한 결과를 저장소에 보관(Xcode 26.2에서 확인, Apple FB20183399).
# 릴리스 빌드는 사전 빌드한 Assets.car가 있으면 복사. AppIcon.icns도 있으면 함께 복사.
# Assets.car가 없으면 actool로 아이콘 직접 컴파일.
#
# 아이콘 변경 시 .icon을 읽을 수 있는 actool 환경에서 실행한 뒤 생성 결과를 함께 커밋.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT_DIR/assets/AppIcon.prebuilt"

rm -rf "$OUT"
mkdir -p "$OUT"
xcrun actool "$ROOT_DIR/assets/AppIcon.icon" --compile "$OUT" \
  --app-icon AppIcon --enable-on-demand-resources NO --development-region en \
  --target-device mac --platform macosx --minimum-deployment-target 15.0 \
  --output-partial-info-plist /dev/null --output-format human-readable-text --errors --warnings
rm -f "$OUT/partial.plist"

echo "Wrote $OUT/Assets.car and AppIcon.icns"
