#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"
mkdir -p dist
binary="$(mktemp "$repo/dist/.update-release-test.XXXXXX")"
trap 'rm -f "$binary"' EXIT

xcrun swiftc -swift-version 6 -o "$binary" \
  Apps/Mac/CompanionUpdateRelease.swift Tests/Mac/UpdateReleaseTests.swift
"$binary" "$@"
