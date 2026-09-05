#!/usr/bin/env bash
set -euo pipefail

# Sign, notarize, and publish Agent Notch from this Mac.
#
#   Scripts/release.sh v1.0
#
# GitHub hosts the zip (Releases) and the Sparkle feed (Pages).
# Developer ID, the App Store Connect API key, and the Sparkle EdDSA
# private key stay on this Mac.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ -f "$ROOT/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT/.env"
  set +a
fi

TEAM_ID="K3386R8W3F"
FEED_URL="https://updates.lucabecker.dev/appcast.xml"
PAGES_FALLBACK_URL="https://itslucadev.github.io/AgentNotch/appcast.xml"
PUBLIC_ED_KEY="T3jmwY3shc3fTshx3FexcYVVrgs39iYTE01bUuAOo0E="
NOTARY_PROFILE="${NOTARY_PROFILE:-AgentNotch}"
REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"

usage() {
  echo "usage: $0 vMAJOR.MINOR[.PATCH]" >&2
  exit 1
}

TAG="${1:-}"
[[ -n "$TAG" ]] || usage
if [[ ! "$TAG" =~ ^v[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
  echo "tag must match v1.0 or v1.0.0, got: $TAG" >&2
  exit 1
fi
VERSION="${TAG#v}"
BUILD="$(date -u +%Y%m%d.%H%M)"
PREFIX="https://github.com/${REPO}/releases/download/${TAG}/"

echo "Releasing ${TAG}  marketing=${VERSION}  build=${BUILD}"

branch="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$branch" != "main" ]]; then
  echo "release from main (current branch: $branch)" >&2
  exit 1
fi
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "working tree is dirty; commit or stash first" >&2
  exit 1
fi

if git show-ref --verify --quiet "refs/tags/${TAG}" || git ls-remote --tags origin "refs/tags/${TAG}" | grep -q .; then
  echo "tag ${TAG} already exists locally or on origin." >&2
  echo "If you intend to replace that unpublished release:" >&2
  echo "  gh release delete ${TAG} --yes --cleanup-tag" >&2
  echo "  git push origin :refs/tags/${TAG}" >&2
  echo "  git tag -d ${TAG}" >&2
  exit 1
fi

if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
  echo "No Developer ID Application identity in the keychain." >&2
  echo "Run Scripts/setup-release-secrets.sh" >&2
  exit 1
fi

if [[ ! -f "$ROOT/.sparkle/ed-private-key" ]]; then
  echo "missing .sparkle/ed-private-key" >&2
  exit 1
fi

if ! curl -fsSI "$FEED_URL" | tr -d '\r' | grep -Eq '^HTTP/.* 200'; then
  echo "Feed is not live at ${FEED_URL}" >&2
  echo "Add a Hostinger CNAME: host updates  target itslucadev.github.io" >&2
  echo "Wait until GitHub issues HTTPS, then:" >&2
  echo "  curl -sI ${FEED_URL}" >&2
  echo "Do not ship a public zip until that URL returns 200." >&2
  exit 1
fi

DIST="$ROOT/dist"
APP_DIR="$DIST/export"
APP="$APP_DIR/AgentNotch.app"
ARCHIVE="$DIST/AgentNotch.xcarchive"
UPDATES="$DIST/updates"
ZIP="$UPDATES/AgentNotch.zip"
NOTARY_ZIP="$DIST/AgentNotch-notary.zip"
WT="${TMPDIR:-/tmp}/agentnotch-appcast-$$"

cleanup() {
  git worktree remove --force "$WT" >/dev/null 2>&1 || true
  rm -rf "$WT"
}
trap cleanup EXIT

rm -rf "$DIST"
mkdir -p "$APP_DIR" "$UPDATES"

echo "Archiving…"
xcodebuild archive \
  -project AgentNotch.xcodeproj \
  -scheme AgentNotch \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -archivePath "$ARCHIVE" \
  -derivedDataPath "$DIST/DerivedData" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  OTHER_CODE_SIGN_FLAGS="--timestamp"

echo "Exporting…"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$APP_DIR" \
  -exportOptionsPlist Config/ExportOptions-DeveloperID.plist

PLIST="$APP/Contents/Info.plist"
actual_ver="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
actual_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
actual_feed="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$PLIST")"
actual_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$PLIST")"
if [[ "$actual_ver" != "$VERSION" ]]; then
  echo "CFBundleShortVersionString is ${actual_ver}, expected ${VERSION}" >&2
  exit 1
fi
if [[ "$actual_build" != "$BUILD" ]]; then
  echo "CFBundleVersion is ${actual_build}, expected ${BUILD}" >&2
  exit 1
fi
if [[ "$actual_feed" != "$FEED_URL" ]]; then
  echo "SUFeedURL is ${actual_feed}, expected ${FEED_URL}" >&2
  exit 1
fi
if [[ "$actual_key" != "$PUBLIC_ED_KEY" ]]; then
  echo "SUPublicEDKey does not match the expected public key" >&2
  exit 1
fi

authority="$(codesign -dvv "$APP" 2>&1 || true)"
if ! grep -q "Developer ID Application" <<<"$authority"; then
  echo "exported app is not signed with Developer ID Application" >&2
  echo "$authority" >&2
  exit 1
fi
if ! grep -q "$TEAM_ID" <<<"$authority"; then
  echo "exported app is not signed with team ${TEAM_ID}" >&2
  exit 1
fi

echo "Notarizing…"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$NOTARY_ZIP"
xcrun notarytool submit "$NOTARY_ZIP" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl -a -vv -t install "$APP"

echo "Zipping…"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "Preparing appcast worktree…"
git fetch origin appcast:appcast 2>/dev/null || true
if git show-ref --verify --quiet refs/heads/appcast; then
  git worktree add "$WT" appcast
else
  git worktree add --detach "$WT" HEAD
  git -C "$WT" checkout --orphan appcast
  git -C "$WT" rm -rf --ignore-unmatch . >/dev/null 2>&1 || true
  find "$WT" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
fi

if [[ -f "$WT/appcast.xml" ]]; then
  cp "$WT/appcast.xml" "$UPDATES/appcast.xml"
fi

Scripts/sparkle-appcast.sh "$UPDATES" "$PREFIX"

rm -rf "$UPDATES"/*.delta "$UPDATES"/old_updates
cp "$UPDATES/appcast.xml" "$WT/appcast.xml"
printf 'updates.lucabecker.dev\n' > "$WT/CNAME"
git -C "$WT" add appcast.xml CNAME
if git -C "$WT" diff --cached --quiet; then
  echo "appcast.xml unchanged" >&2
  exit 1
fi
git -C "$WT" commit -m "Update appcast to ${TAG}"

echo "Publishing tag and zip…"
git tag -a "$TAG" -m "Agent Notch ${VERSION}"
git push origin "refs/tags/${TAG}"

if gh release view "$TAG" >/dev/null 2>&1; then
  gh release upload "$TAG" "$ZIP" --clobber
else
  gh release create "$TAG" "$ZIP" \
    --title "$VERSION" \
    --generate-notes \
    --draft
fi

gh release edit "$TAG" --draft=false

echo "Publishing feed…"
git -C "$WT" push origin HEAD:appcast

gh workflow run pages.yml --ref main
echo "Waiting for Pages workflow…"
sleep 8
RUN_ID="$(gh run list --workflow pages.yml --limit 1 --json databaseId --jq '.[0].databaseId')"
gh run watch "$RUN_ID" --exit-status

feed_has_build() {
  local url="$1"
  curl -fsSL "$url" | grep -q "<sparkle:version>${BUILD}</sparkle:version>"
}

echo "Waiting for live feed…"
ok_custom=0
ok_pages=0
for _ in $(seq 1 24); do
  if feed_has_build "$FEED_URL"; then ok_custom=1; fi
  if feed_has_build "$PAGES_FALLBACK_URL"; then ok_pages=1; fi
  if [[ "$ok_custom" -eq 1 ]]; then
    break
  fi
  sleep 5
done

if [[ "$ok_custom" -ne 1 ]]; then
  echo "Live feed does not yet list build ${BUILD} at ${FEED_URL}" >&2
  if [[ "$ok_pages" -eq 1 ]]; then
    echo "GitHub Pages is serving the new item at ${PAGES_FALLBACK_URL}." >&2
    echo "Finish the Hostinger CNAME (updates -> itslucadev.github.io) and HTTPS." >&2
  fi
  echo "The zip is already on the GitHub release. Sparkle cannot see it until the custom domain returns this build." >&2
  exit 1
fi

echo "Release ${TAG} is live."
echo "Feed: ${FEED_URL}"
echo "Zip:  ${PREFIX}AgentNotch.zip"
