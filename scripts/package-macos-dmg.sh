#!/usr/bin/env bash
set -euo pipefail

# Package an already-built, signed Mac app without modifying its code signature.
# Finder shows only the app and a drag-to-Applications shortcut. License notices
# must accompany the redistributed third-party code, so they live in a hidden
# .licenses directory rather than cluttering the install window.

usage() {
  echo "Usage: $0 /path/to/StatsCompanion.app" >&2
  exit 2
}

[[ $# -eq 1 ]] || usage
app="$1"
[[ -d "$app/Contents" ]] || usage

repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"

/usr/bin/codesign --verify --deep --strict "$app"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "Unexpected app version: $version" >&2
  exit 1
}

archs=$(/usr/bin/lipo -archs "$app/Contents/MacOS/StatsCompanion")
[[ " $archs " == *" arm64 "* && " $archs " == *" x86_64 "* ]] || {
  echo "Expected a universal arm64 + x86_64 app; got: $archs" >&2
  exit 1
}

mkdir -p dist
stage="$(mktemp -d "$repo/dist/.dmg-stage.XXXXXX")"
trap 'rm -rf "$stage"' EXIT

/usr/bin/ditto "$app" "$stage/StatsCompanion.app"
ln -s /Applications "$stage/Applications"

mkdir -p "$stage/.licenses"
cp LICENSE THIRD_PARTY_NOTICES.md "$stage/.licenses/"
cp Native/Spake2Bridge/THIRD_PARTY_NOTICES.md "$stage/.licenses/Spake2Bridge-THIRD_PARTY_NOTICES.md"
/usr/bin/ditto Native/Spake2Bridge/licenses "$stage/.licenses/licenses"

output="$repo/dist/StatsCompanion-v$version-macOS-universal.dmg"
/usr/bin/hdiutil create -quiet -ov -format UDZO -fs HFS+ -nospotlight \
  -volname 'Stats Companion' -srcfolder "$stage" -imagekey zlib-level=9 "$output"
/usr/bin/hdiutil verify -quiet "$output"

echo "Packaged: $output"
/usr/bin/shasum -a 256 "$output"
