#!/usr/bin/env bash
#
# Turn the sideload IPA into a Mac app (Apple silicon) and wrap it in a DMG.
#
# The iOS build already targets arm64, so the Mac app is the same binary
# re-tagged as Mac Catalyst (vtool), with a Finder icon, and ad-hoc signed
# into the App Sandbox (so its data lives in ~/Library/Containers, not
# ~/Documents). Nothing is recompiled.
#
# Usage:
#   scripts/package_mac.sh <SymbianBoard.ipa> <out.dmg>
#
# The DMG carries whatever the IPA carries: an IPA built with the bundled
# device (SYMBIANBOARD_BUNDLE_DEVICE=ON) makes a personal DMG with firmware
# inside — never publish one of those.

set -euo pipefail

IPA="${1:?usage: package_mac.sh <ipa> <out.dmg>}"
DMG="${2:?usage: package_mac.sh <ipa> <out.dmg>}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIN_MACOS="${SYMBIANBOARD_MAC_MIN:-14.0}"
SDK_MACOS="$(xcrun --sdk macosx --show-sdk-version)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/symbianboard-mac.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT

echo "==> Unpacking ${IPA}"
ditto -x -k "${IPA}" "${WORK}/ipa"
SRC_APP="$(find "${WORK}/ipa/Payload" -maxdepth 1 -name '*.app' | head -1)"
APP="${WORK}/dmg/SymbianBoard.app"
mkdir -p "${WORK}/dmg"
mv "${SRC_APP}" "${APP}"
rm -rf "${WORK}/ipa"

echo "==> Re-tagging Mach-O files as Mac Catalyst ${MIN_MACOS}"
while IFS= read -r -d '' file; do
    if file -b "${file}" | grep -q 'Mach-O'; then
        vtool -set-build-version maccatalyst "${MIN_MACOS}" "${SDK_MACOS}" -replace \
            -output "${file}" "${file}"
    fi
done < <(find "${APP}" -type f \( -perm -u+x -o -name '*.dylib' \) -not -path '*/BundledDevice/*' -print0)

echo "==> Info.plist and icon"
PLIST="${APP}/Info.plist"
plutil -remove LSRequiresIPhoneOS "${PLIST}" 2>/dev/null || true
plutil -remove UIRequiredDeviceCapabilities "${PLIST}" 2>/dev/null || true
plutil -replace CFBundleSupportedPlatforms -json '["MacOSX"]' "${PLIST}"
plutil -replace LSMinimumSystemVersion -string "${MIN_MACOS}" "${PLIST}"
plutil -replace LSApplicationCategoryType -string "public.app-category.utilities" "${PLIST}"
plutil -replace CFBundleIconFile -string "AppIcon" "${PLIST}"

ICONSET="${WORK}/AppIcon.iconset"
mkdir -p "${ICONSET}"
for size in 16 32 128 256 512; do
    sips -z "${size}" "${size}" "${ROOT_DIR}/docs/assets/icon-mac.png" \
        --out "${ICONSET}/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "${ROOT_DIR}/docs/assets/icon-mac.png" \
        --out "${ICONSET}/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "${ICONSET}" -o "${APP}/AppIcon.icns"

echo "==> Signing (ad-hoc, App Sandbox)"
ENT="${WORK}/mac.entitlements"
cat > "${ENT}" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key><true/>
    <key>com.apple.security.network.client</key><true/>
    <key>com.apple.security.files.user-selected.read-only</key><true/>
    <key>com.apple.security.files.downloads.read-only</key><true/>
    <key>com.apple.security.personal-information.photos-library</key><true/>
    <key>com.apple.security.assets.music.read-only</key><true/>
    <key>com.apple.security.device.audio-input</key><true/>
    <key>com.apple.security.device.camera</key><true/>
</dict>
</plist>
EOF
find "${APP}" -name '_CodeSignature' -type d -prune -exec rm -rf {} +
rm -f "${APP}/embedded.mobileprovision"
# Inner code first, then the app with its entitlements.
find "${APP}" \( -name '*.dylib' -o -name '*.framework' -o -name '*.appex' \) -prune -print0 |
    xargs -0 -I{} codesign --force --sign - {} 2>/dev/null || true
codesign --force --sign - --entitlements "${ENT}" "${APP}"

echo "==> Building ${DMG}"
ln -s /Applications "${WORK}/dmg/Applications"
rm -f "${DMG}"
hdiutil create -volname SymbianBoard -srcfolder "${WORK}/dmg" -fs APFS -format ULMO "${DMG}" >/dev/null
ls -lh "${DMG}"
