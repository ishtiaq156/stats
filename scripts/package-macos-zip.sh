#!/usr/bin/env bash
set -euo pipefail

# A signed Mac app archive for verified, in-menu updates. Keep third-party
# license notices beside the app as in the Finder DMG.
[[ $# -eq 1 && -d "$1/Contents" ]] || {
  echo "Usage: $0 /path/to/StatsCompanion.app" >&2
  exit 2
}
app="$1"
repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"

/usr/bin/codesign --verify --deep --strict "$app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 1
archs="$(/usr/bin/lipo -archs "$app/Contents/MacOS/StatsCompanion")"
[[ " $archs " == *" arm64 "* && " $archs " == *" x86_64 "* ]] || exit 1

mkdir -p dist
work="$(mktemp -d "$repo/dist/.zip-work.XXXXXX")"
trap 'rm -rf "$work"' EXIT
stage="$work/stage"
mkdir -p "$stage/.licenses"
/usr/bin/ditto "$app" "$stage/StatsCompanion.app"
cp LICENSE THIRD_PARTY_NOTICES.md "$stage/.licenses/"
cp Native/Spake2Bridge/THIRD_PARTY_NOTICES.md "$stage/.licenses/Spake2Bridge-THIRD_PARTY_NOTICES.md"
/usr/bin/ditto Native/Spake2Bridge/licenses "$stage/.licenses/licenses"

output="$repo/dist/StatsCompanion-v$version-macOS-universal.zip"
(
  cd "$stage"
  /usr/bin/ditto -c -k --sequesterRsrc . "$output"
)
mkdir -p "$work/verify"
/usr/bin/ditto -x -k "$output" "$work/verify"
/usr/bin/codesign --verify --deep --strict "$work/verify/StatsCompanion.app"

echo "Packaged: $output"
/usr/bin/shasum -a 256 "$output"
