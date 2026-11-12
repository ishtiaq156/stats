#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
binary="$(mktemp "$repo/dist/.bonjour-retry-test.XXXXXX")"
trap 'rm -f "$binary"' EXIT

xcrun swiftc -swift-version 6 -o "$binary" \
  "$repo/Apps/Mac/BonjourRetryBackoff.swift" \
  "$repo/Tests/Mac/BonjourRetryTests.swift"
"$binary"
