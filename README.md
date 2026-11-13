<div align="center">
  <img src="Apps/Mac/Assets.xcassets/StatsBrandMark.imageset/StatsBrandMark.png" alt="Stats blue activity chart logo" width="96" />

  <h1>Stats</h1>

  <p><strong>Your Mac's activity, at a glance.</strong></p>

  <p>A native, local-first system monitor with a lightweight Mac companion and a mobile dashboard.</p>

  <p><a href="https://github.com/ishtiaq156/stats/releases">Download</a> · <a href="#quick-start">Quick start</a> · <a href="#build-from-source">Build from source</a></p>
</div>

Stats lets you check what your Mac is doing from a paired device on the same local network. No account, hosted server, or cloud connection is required for monitoring.

> [!NOTE]
> **Early preview.** The mobile app currently supports **iPhone (iOS 17+)**. Native **iPadOS support is planned**, but is not available yet. The pairing protocol has not received an independent security audit.

## Features

- **Live system metrics:** CPU, memory, storage, and network activity, with detailed readings and recent history.
- **Native Mac companion:** A compact menu bar app with pairing controls, connection status, and optional launch at login.
- **Simple discovery:** Find your Mac using Bonjour or connect using its local IP address and port.
- **Encrypted pairing:** A temporary five-digit code establishes a secure connection; paired devices receive separate credentials and can be revoked individually.
- **Local by design:** No account or relay server; the companion owns the metric data and serves it to authorized devices.

## Downloads

The Mac release also includes a signed ZIP archive. Companion prefers this archive for in-menu updates so it can install without mounting a disk image; the DMG remains the normal first-install option.

Get both apps from the [GitHub Releases](https://github.com/ishtiaq156/stats/releases) page. They share a repository but have independent version numbers.

| App | Current supported platform | Download |
| --- | --- | --- |
| **Stats Companion** | macOS 14+, Apple Silicon and Intel | Universal `.dmg` |
| **Stats** | iPhone, iOS 17+ | Unsigned `.ipa` |

> [!IMPORTANT]
> The mobile IPA must be **signed before installation** using a compatible sideloading tool or your own Apple development signing. The Mac DMG currently uses an Apple Development signature and is **not notarized**; macOS may require the app-specific **Open Anyway** option. Do not disable Gatekeeper globally.

## Quick start

After the first Mac installation, future releases can be downloaded and installed from **Stats Companion's menu bar** using **Download update** and **Install update & Restart**. If macOS prevents installation into the current application folder, choose **Open downloaded installer** from the menu to finish manually.

1. Download the **Stats Companion** DMG, open it, and drag `StatsCompanion.app` to **Applications**.
2. Install **Stats** on a supported mobile device: sign the downloaded IPA with your own credentials, or build and install it through Xcode using a free Personal Team.
3. Launch Stats Companion. Connect both devices to the same reachable local network.
4. Open Stats, find your Mac, and enter the **five-digit pairing code** shown in the Mac menu bar. If discovery is unavailable, use the Mac's address and port from Companion Settings.
5. Open a metric to see current readings and recent history.

> [!TIP]
> Pairing codes expire after five minutes or one successful use. Stats Companion tries TCP port **8888** first and selects an available port if needed.

## Build from source

Requires **Xcode 27.2+**, **Swift 6**, and [XcodeGen](https://github.com/yonaskolb/XcodeGen). The included SPAKE2 XCFramework is prebuilt, so Rust is only needed if rebuilding that dependency.

```sh
git clone https://github.com/ishtiaq156/stats.git
cd stats
xcodegen generate
open Stats.xcodeproj
```

The Xcode project has two schemes: **`StatsCompanion`** (macOS) and **`Stats`** (mobile). For unsigned local builds and the shared tests:

```sh
xcodebuild -project Stats.xcodeproj -scheme StatsCompanion -sdk macosx CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Stats.xcodeproj -scheme Stats -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO build
swift test --package-path Packages/ActivityCore
scripts/test-pairing-smoke.sh
```

For installation on a physical device, select your own **Personal Team** in Xcode. Developer-specific signing overrides belong in the gitignored `Config/iOSSigning.local.xcconfig` and `Config/MacSigning.local.xcconfig`; do not commit personal signing details. Retaining a consistent Mac signing identity helps preserve Keychain access to pairing credentials across builds.

For an unsigned device IPA to sign with AltStore, SideStore, or import as a LiveContainer guest, run `scripts/build-ios-ipa.sh`. It builds for iPhoneOS arm64, validates the archive, and writes `dist/Stats-vX.Y.Z-iOS.ipa` without replacing an existing release artifact. Signing and installation depend on the sideloading app and device setup. LiveContainer signs guests using its host setup; [Bonjour discovery inside LiveContainer](docs/LIVECONTAINER-BONJOUR.md) explains the host allowlist and manual IP fallback.

## Project structure

| Location | Purpose |
| --- | --- |
| [Mac companion](Apps/Mac) | Menu bar UI, metrics collection, discovery, and pairing server |
| [Mobile app](Apps/Mobile) | Current dashboard, discovery, pairing, and detail views |
| [Shared core](Packages/ActivityCore) | Metric models, protocol messages, and authenticated transport |
| [SPAKE2 bridge](Native/Spake2Bridge) | Native cryptography interoperability |
| [`Tests`](Tests) | End-to-end pairing smoke tests |

Stats Companion samples the Mac approximately every two seconds and retains around 30 minutes of history in memory. Pairing uses SPAKE2 and key confirmation, followed by per-device credentials and AES-GCM-protected requests. Monitoring traffic remains local; the companion separately probes `1.1.1.1` for connectivity and latency readings.

## Status and roadmap

- **Available now:** Local Mac monitoring, mobile dashboard on iPhone, encrypted pairing, recent history, and per-device revocation.
- **Planned:** Native iPadOS layouts and device support, along with additional alerts and widgets. The existing mobile target is not yet configured for iPadOS.
- **Current constraints:** The Mac must be awake with Stats Companion running; background monitoring on the mobile device and remote access are not supported. Some hardware readings may be unavailable.

For implementation details and ongoing validation, see the [roadmap](PLAN.md), [UI test checklist](docs/UI-TEST.md), [companion design](docs/COMPANION-DESIGN.md), and [security guidance](SECURITY.md).
