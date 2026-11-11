#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="/tmp/stats-smoke"
mkdir -p "$build_dir"

swift build --package-path "$repo_dir/Packages/ActivityCore"
module_dir="$repo_dir/Packages/ActivityCore/.build/out/Products/Debug"
bridge_dir="$repo_dir/Packages/ActivityCore/Vendor/Spake2FFI.xcframework/macos-arm64_x86_64"

swiftc -I "$module_dir" -I "$module_dir/include" \
  -Xcc -fmodule-map-file="$bridge_dir/Headers/module.modulemap" \
  "$repo_dir/Apps/Mac/MetricServer.swift" \
  "$repo_dir/Apps/Mac/PhoneRegistry.swift" \
  "$repo_dir/Apps/Mobile/PasscodePairer.swift" \
  "$repo_dir/Tests/Mac/PairingSmoke.swift" \
  "$module_dir/libActivityCore.a" \
  "$bridge_dir/libstats_spake2_macos.a" \
  -o "$build_dir/PairingSmoke"
"$build_dir/PairingSmoke"
