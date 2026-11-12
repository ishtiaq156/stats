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
work="$(mktemp -d "$repo/dist/.dmg-work.XXXXXX")"
stage="$work/stage"
cleanup() {
  rm -rf "$work"
}
trap cleanup EXIT
mkdir -p "$stage"

/usr/bin/ditto "$app" "$stage/StatsCompanion.app"
ln -s /Applications "$stage/Applications"

# Finder uses the volume icon when the disk image is mounted. The downloadable
# .dmg file's own Finder icon is separate and is not reliably retained by GitHub.
# Keep the original app artwork as the single branding source, rather than
# maintaining a separate icon that can drift from the installed app.
icon="$app/Contents/Resources/AppIcon.icns"
[[ -f "$icon" ]] || { echo "Missing app icon: $icon" >&2; exit 1; }
cp "$icon" "$stage/.VolumeIcon.icns"

mkdir -p "$stage/.licenses"
cp LICENSE THIRD_PARTY_NOTICES.md "$stage/.licenses/"
cp Native/Spake2Bridge/THIRD_PARTY_NOTICES.md "$stage/.licenses/Spake2Bridge-THIRD_PARTY_NOTICES.md"
/usr/bin/ditto Native/Spake2Bridge/licenses "$stage/.licenses/licenses"

output="$repo/dist/StatsCompanion-v$version-macOS-universal.dmg"
# Set the source directory's custom icon flag before imaging. Creating a
# compressed image directly avoids diskutil writable mounts that can hang on
# macOS 27 after a permission prompt. The app's own icon is independent.
/usr/bin/SetFile -a C "$stage"
/usr/bin/hdiutil create -quiet -format UDZO -fs HFS+ -nospotlight \
  -volname 'Stats Companion' -srcfolder "$stage" "$work/ready.dmg"
/usr/bin/hdiutil verify -quiet "$work/ready.dmg"
/bin/mv -f "$work/ready.dmg" "$output"
/usr/bin/hdiutil verify -quiet "$output"

echo "Packaged: $output"
/usr/bin/shasum -a 256 "$output"
