#!/bin/sh
# Compiles the app icon (light, dark and tinted) into Resources/Assets.car.
#
# iOS only reads dark and tinted icons from a compiled asset catalog, and Apple's compiler (actool) only runs on a Mac
# with Xcode. Run this there once whenever the icon changes, then commit Resources/Assets.car; Linux builds just copy it.
#   sh scripts/build_icon_assets.sh
set -e
cd "$(dirname "$0")/.."
out=$(mktemp -d)
xcrun actool Resources/Icon/Assets.xcassets \
  --compile "$out" \
  --platform iphoneos \
  --minimum-deployment-target 17.0 \
  --target-device iphone --target-device ipad \
  --app-icon AppIcon \
  --output-partial-info-plist "$out/partial.plist" \
  --errors --warnings
cp "$out/Assets.car" Resources/Assets.car
echo "Wrote Resources/Assets.car ($(wc -c < Resources/Assets.car) bytes). Icon settings actool suggests:"
cat "$out/partial.plist"
rm -rf "$out"
