#!/usr/bin/env bash
#
# Publish a SymbianBoard release to GitHub.
#
#   scripts/publish_release.sh notes.md
#
# Builds the public sideload IPA (dynarmic JIT in, firmware OUT) from the
# committed HEAD in a separate release checkout, so uncommitted work in this
# folder never ships, and the Mac DMG from it (scripts/package_mac.sh). Then
# it creates the GitHub release v<version> with SymbianBoard.ipa and
# SymbianBoard-mac.dmg attached, and refreshes docs/altstore.json (the AltStore /
# SideStore source the website links to) and pushes it.
#
# Bump CFBundleShortVersionString / CFBundleVersion in
# src/emu/ios/Resources/Info.plist before each release.
#
# Environment:
#   SYMBIANBOARD_REPO          GitHub repo (default harkhowalia-1/SymbianBoard)
#   SYMBIANBOARD_RELEASE_DIR   release checkout (default ../SymbianBoard-release)

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

NOTES="${1:?usage: scripts/publish_release.sh <release-notes.md>}"
REPO="${SYMBIANBOARD_REPO:-harkhowalia-1/SymbianBoard}"
RELEASE_DIR="${SYMBIANBOARD_RELEASE_DIR:-$(dirname "${ROOT_DIR}")/SymbianBoard-release}"
PLIST="src/emu/ios/Resources/Info.plist"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "${PLIST}")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "${PLIST}")"
TAG="v${VERSION}"
COMMIT="$(git rev-parse HEAD)"

if gh release view "${TAG}" --repo "${REPO}" >/dev/null 2>&1; then
    echo "Release ${TAG} already exists: bump the version in ${PLIST} first." >&2
    exit 1
fi

echo "==> Pushing ${COMMIT:0:7} to ${REPO} main"
git push origin "HEAD:main"

# Release checkout: a worktree at the commit, sharing this folder's submodules.
if [ ! -d "${RELEASE_DIR}" ]; then
    git worktree add --detach "${RELEASE_DIR}" "${COMMIT}"
    git config -f .gitmodules --get-regexp path | awk '{print $2}' | while read -r sub; do
        rmdir "${RELEASE_DIR:?}/${sub:?}" 2>/dev/null || true
        ln -s "${ROOT_DIR}/${sub}" "${RELEASE_DIR:?}/${sub:?}"
    done
else
    git -C "${RELEASE_DIR}" checkout --quiet --detach "${COMMIT}"
fi

echo "==> Building the public IPA (JIT, no firmware) in ${RELEASE_DIR}"
(cd "${RELEASE_DIR}" && SYMBIANBOARD_BUNDLE_DEVICE=OFF EKA2L1_IOS_CONFIGURATION=Release \
    scripts/build_ios.sh ipa)

STAGE="$(mktemp -d -t symbianboard-release)"
IPA="${STAGE}/SymbianBoard.ipa"
cp "${RELEASE_DIR}/build/SymbianBoard-sideload.ipa" "${IPA}"

# Never publish Nokia firmware.
if unzip -l "${IPA}" | grep -q 'BundledDevice/'; then
    echo "The IPA contains a bundled device (firmware). Refusing to publish." >&2
    rm -rf "${STAGE}"
    exit 2
fi

echo "==> Packaging the Mac DMG"
DMG="${STAGE}/SymbianBoard-mac.dmg"
scripts/package_mac.sh "${IPA}" "${DMG}"

echo "==> Creating release ${TAG}"
gh release create "${TAG}" "${IPA}" "${DMG}" --repo "${REPO}" --target "${COMMIT}" \
    --title "SymbianBoard ${VERSION}" --notes-file "${NOTES}"

SIZE="$(stat -f %z "${IPA}")"
python3 - "${VERSION}" "${BUILD}" "${SIZE}" "${REPO}" "${TAG}" "${NOTES}" <<'EOF'
import json, sys, datetime, pathlib
version, build, size, repo, tag, notes = sys.argv[1:7]
path = pathlib.Path("docs/altstore.json")
source = json.loads(path.read_text())
app = source["apps"][0]
entry = {
    "version": version,
    "buildVersion": build,
    "date": datetime.date.today().isoformat(),
    "localizedDescription": pathlib.Path(notes).read_text().strip()[:2000],
    "downloadURL": f"https://github.com/{repo}/releases/download/{tag}/SymbianBoard.ipa",
    "size": int(size),
    "minOSVersion": "16.0",
}
app["versions"] = [entry] + [v for v in app.get("versions", []) if v.get("version") != version]
path.write_text(json.dumps(source, indent=2) + "\n")
EOF

rm -rf "${STAGE}"

git add docs/altstore.json
git commit -q -m "Publish SymbianBoard ${VERSION} to the AltStore source"
git push origin "HEAD:main"
echo "==> Published ${TAG}: https://github.com/${REPO}/releases/tag/${TAG}"
