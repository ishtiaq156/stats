#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
temp="$(mktemp -d /tmp/stats-menu-label.XXXXXX)"
trap 'rm -rf "$temp"' EXIT

xcrun swiftc -swift-version 6 \
  "$repo/Apps/Mac/CompanionMenuBarLabel.swift" \
  "$repo/Tests/Mac/MenuBarLabelTests.swift" \
  -o "$temp/menu-label-tests"
"$temp/menu-label-tests" "$repo/Apps/Mac/Assets.xcassets"
