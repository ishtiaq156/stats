#!/bin/bash
# Build the release iPhone app for sideloaders that accept a standard unsigned IPA.
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
output_dir="${1:-$repo_dir/dist}"
derived_data="${STATS_IOS_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/StatsSideloadRelease}"
developer_dir="${DEVELOPER_DIR:-/Volumes/SSD WD/Applications/Xcode.app/Contents/Developer}"

DEVELOPER_DIR="$developer_dir" xcodebuild \
  -project "$repo_dir/Stats.xcodeproj" -scheme Stats -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath "$derived_data" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO 'CODE_SIGN_IDENTITY=' build

app="$derived_data/Build/Products/Release-iphoneos/Stats.app"
plist="$app/Info.plist"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
platform="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleSupportedPlatforms:0' "$plist")"
identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")"
[[ "$platform" == iPhoneOS && "$identifier" == com.ishtiaqsyed.StatsForIOS ]] || {
  echo 'Built app has the wrong platform or bundle identifier' >&2
  exit 1
}
lipo -verify_arch arm64 "$app/Stats"

mkdir -p "$output_dir"
ipa="$output_dir/Stats-v$version-iOS.ipa"
python3 "$repo_dir/scripts/package-ipa.py" "$app" "$ipa"
shasum -a 256 "$ipa"
