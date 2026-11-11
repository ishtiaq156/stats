# Stats for iOS

<img src="Apps/Mac/Assets.xcassets/StatsBrandMark.imageset/StatsBrandMark.png" width="88" alt="Stats blue activity chart logo" />

**See your Mac's activity from your iPhone.** Stats is a native iPhone dashboard paired with a lightweight macOS menu bar companion. Both apps communicate on your local network without an account or cloud service.

> [!NOTE]
> **Early preview.** The compact macOS menu and Settings interface have been iterated through hands-on UI feedback. Automated pairing tests pass and pairing has been exercised on a physical iPhone. Broader device testing and an independent protocol review are still needed before a stable release.

## What it does

- **Live Mac activity:** CPU utilization, memory usage, free and total startup-disk space, and network download/upload rates.
- **iPhone onboarding, overview, and charts:** First-run Mac setup and discovery, a Nearby Macs screen for returning or disconnected users, and four live metric cards with detail screens and recent readings once connected.
- **Compact Mac menu and Settings:** Network and connected-phone status, a five-digit passcode with refresh, copy, and expiry, Open at login, update checks, Dock/Menu Bar visibility, and paired-phone management. When Dock visibility is enabled, clicking the running app's Dock icon opens Settings. Tab/Shift-Tab navigate controls in both views; Settings shows its native keyboard-focus indicator when tabbing and clears the keyboard-navigation presentation after a pointer click.
- **Matching app icons:** The iPhone Home Screen, Mac Dock, menu bar, and Mac About panel share the original blue activity-chart artwork.
- **Local pairing:** Bonjour discovery plus manual IP/port fallback; a different encrypted credential is issued to every paired phone, which can be revoked independently.
- **Battery data where available:** Included in the Mac's snapshot; a dedicated battery card is not yet part of the iPhone overview.

The Mac companion and iPhone dashboard are designed as one cohesive local monitoring experience, with native interfaces, encrypted pairing and live system metrics.

## Requirements

| Component | Minimum / tool |
| --- | --- |
| Mac companion | macOS 14+ |
| iPhone dashboard | iOS 17+ |
| Development | Xcode 27.2+, Swift 6 language mode; XcodeGen for regenerating the project |
| Connection | Mac and iPhone on the same reachable local network |
| iPhone installation | Xcode signing with a free Personal Team is supported |

### macOS download

**Stats Companion** is available for macOS 14 or later on Apple Silicon and Intel Macs. Download the universal macOS DMG from the [GitHub Releases page](https://github.com/ishtiaq156/stats-for-ios/releases):

1. Open the DMG and drag `StatsCompanion.app` to the **Applications** shortcut.
2. Launch Stats Companion from Applications, then open its menu bar panel. Install Stats for iPhone from the unsigned IPA described below or build it in Xcode using [Get started](#get-started).
3. Connect the Mac and iPhone to the same reachable local network. Select the Mac on your iPhone and enter the five-digit passcode from the Mac menu.

This download contains the Mac companion only. Move the app to Applications **before enabling Open at login**.

The DMG includes a hidden folder with the required open-source license notices. It does not include a separate installation README.

The current build is signed with an Apple Development identity, without Developer ID notarization. On Macs where Gatekeeper blocks the downloaded app, use the app-specific **Open** / **Open Anyway** control in macOS after verifying the source of the download. Do not disable Gatekeeper globally. Keep this preview on a trusted local network while protocol review and broader testing continue.

### iPhone download

**Stats for iPhone** is available as an **unsigned IPA** on the [GitHub Releases page](https://github.com/ishtiaq156/stats-for-ios/releases). Download `Stats-v0.3.0-iOS.ipa` for the current iPhone build (**0.3.0, build 3; iOS 17+**).

The IPA contains only `Payload/Stats.app`. It has **no code signature or provisioning profile**, so it cannot be installed directly on a stock iPhone. Sign the IPA with your own credentials through a compatible sideloading tool (such as SideStore) before installation, or build and sign the app in Xcode using a free Personal Team. The iPhone and companion must share a reachable local network for pairing.

## Get started

1. Open **`StatsForIOS.xcodeproj`** in Xcode. Run the **`StatsCompanion`** scheme on your Mac and open **Stats Companion** from the menu bar.
2. Select the **`Stats`** scheme, choose your iPhone, configure your **Personal Team** for signing (see below), and run it. Allow **Local Network** access when prompted.
3. Follow the iPhone welcome screens, then select the Mac in **Nearby Macs** and enter the **five-digit passcode** shown at the top of the Mac menu. If discovery fails, open the connection settings and expand **Connect using IP address**; click the **info icon beside Network status** in the companion's Settings and use the circular copy icon beside the local address and port, then enter the passcode.
4. View live CPU, Memory, Storage, and Network values. Tap any card for details and recent history. After reopening the iPhone app or losing the connection, select a reachable Mac from **Nearby Macs** to return to the dashboard.

The passcode lasts five minutes; the **refresh** icon (to the left of Copy in both Mac views) generates a different code and invalidates the old one. The old digits remain visible until the replacement is available, avoiding UI flicker. One successful pairing also consumes the code. Three failed attempts pause pairing until refresh. The Mac remembers each paired phone, and **Settings** lets you revoke individual access.

> [!TIP]
> Stats Companion tries TCP port **8888** first and chooses an available port if it is occupied. Use the port shown in the menu or Settings for manual pairing. For **Open at login**, install the built Mac app in Applications before enabling the setting.

### Signing is local to each developer

No development team, Apple account, or personal signing certificate is checked into this repository. A fresh clone builds the **Mac companion** with Xcode's default ad-hoc signature and builds the **iPhone simulator** without a developer account. Installing on a physical iPhone requires configuring your own free Personal Team and, if necessary, a bundle identifier available to that team.

For developer-specific signing, create either or both of these **optional, gitignored** files:

`Config/MacSigning.local.xcconfig`:

```xcconfig
CODE_SIGN_IDENTITY = Apple Development
DEVELOPMENT_TEAM = YOUR_TEAM_ID
```

`Config/iOSSigning.local.xcconfig`:

```xcconfig
DEVELOPMENT_TEAM = YOUR_TEAM_ID
```

Xcode reads these through the tracked `Config/MacSigning.xcconfig` and `Config/iOSSigning.xcconfig` files. **Do not commit** the `.local.xcconfig` files. Using a consistent Apple Development signature for the Mac companion helps Keychain remember the application's access to existing pairing credentials across rebuilds; an ad-hoc signature can trigger repeated **Always Allow** requests. The XcodeGen project regenerates these references automatically from `project.yml`.

## Build and test

Choose the appropriate Xcode in `xcode-select`, or set `DEVELOPER_DIR` if you keep Xcode outside Applications (for example, `/Volumes/SSD WD/Applications/Xcode.app/Contents/Developer`).

```sh
# Run when sources are added/removed or project.yml changes.
xcodegen generate

# Build without a signing identity.
xcodebuild -project StatsForIOS.xcodeproj -scheme StatsCompanion -sdk macosx CODE_SIGNING_ALLOWED=NO build
xcodebuild -project StatsForIOS.xcodeproj -scheme Stats -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO build
xcodebuild -project StatsForIOS.xcodeproj -scheme Stats -sdk iphoneos CODE_SIGNING_ALLOWED=NO build

# Packet, pairing, encryption, and end-to-end local pairing checks.
swift test --package-path Packages/ActivityCore
scripts/test-pairing-smoke.sh
```

XcodeGen reads [`project.yml`](project.yml). The shared Swift package includes a prebuilt SPAKE2 XCFramework. To rebuild it from pinned Rust dependencies, use `scripts/build-spake2.sh` and the [Rust dependency notices](Native/Spake2Bridge/THIRD_PARTY_NOTICES.md).

The app icons, menu bar status icon, and About artwork are generated from one original CoreGraphics drawing (not an SF Symbol). The native unavailable-Help alert explicitly loads the same compiled macOS app icon. To regenerate the artwork for both platforms, run:

```sh
swift scripts/generate-app-icons.swift
xcodegen generate
```

The generated Xcode project includes explicit shared **Stats** and **StatsCompanion** schemes. The in-app Changelog uses Apple's native soft scroll-edge effect on macOS 26+, and glass navigation buttons where supported. The Changelog title uses the regular system font, matching the rest of Settings. The native Help alert keeps its unavailable-help message and explicitly uses the application's blue icon. The Mac About window shows the app version, build, and © 2026 Ishtiaq Ul Haq Syed. All Rights Reserved. See the [UI acceptance checklist](docs/UI-TEST.md) for interactions that still require manual verification.

## How it works

| Part | Responsibility |
| --- | --- |
| [`Apps/Mac`](Apps/Mac) | Menu bar UI, macOS metrics sampler, Bonjour advertisement, authenticated TCP service, paired-phone registry |
| [`Apps/Phone`](Apps/Phone) | Discovery and pairing, Keychain credential storage, overview and detail screens, recent-history charts |
| [`Packages/ActivityCore`](Packages/ActivityCore) | Versioned metric snapshots, packet framing, AES-GCM protection, and SPAKE2 pairing exchange |
| [`Native/Spake2Bridge`](Native/Spake2Bridge) | Pinned Rust implementation and Swift-compatible FFI |
| [`Tests`](Tests) | Local pairing smoke test, including code rotation, authenticated metric fetch, and phone revocation |

The Mac samples about every **two seconds** and holds approximately **30 minutes** of readings in memory. The iPhone requests encrypted snapshots and history from the selected Mac. Passcode pairing derives a temporary session key using SPAKE2; the Mac then issues a distinct 256-bit phone credential stored in Keychain. Subsequent requests use AES-GCM authenticated encryption. Phones paired before the version 0.3 passcode redesign must pair again.

## Current limitations

- Local-network access only. Bonjour may be blocked by guest Wi-Fi, firewall configuration, or iOS privacy settings; manual IP/port pairing is the fallback.
- The Mac companion must be running in a logged-in session. Sleep stops live reporting; restart clears the in-memory history.
- CPU and network rates require two samples, so the first reading may be unavailable. Battery values depend on the Mac hardware.
- Network connectivity measurements use one background ICMP echo to `1.1.1.1` roughly every ten seconds while the companion samples the primary physical network interface (including the interface beneath a VPN default route when identifiable). Reachability and latency describe that test endpoint, not every Internet destination; jitter requires multiple successful checks. Network process totals are system-wide, while main rates and cumulative traffic refer to the selected interface. Public IP addresses are not fetched from an external service. To display the connected Wi-Fi network name, select **Allow Wi-Fi network name** in the Mac companion's Settings and approve macOS Location permission. If access was denied, **Open Location Settings** takes you to the macOS permission controls. The companion does not request coordinates or track location.
- iOS background monitoring, widgets, alerts, extra sensors, and remote access are future work.
- Update checks currently see stable GitHub Releases only. For preview releases, check the [Releases page](https://github.com/ishtiaq156/stats-for-ios/releases) manually; automatic in-app installation is not implemented.
- Free Personal Team signing generally requires rebuilding and reinstalling the iPhone app after seven days. TestFlight and App Store distribution require paid developer enrollment.
- The pairing implementation needs an independent protocol review and physical-device testing before public deployment. See [security guidance](SECURITY.md).

For the next round of UI work and verification, see the [UI test checklist](docs/UI-TEST.md), [Mac companion design](docs/COMPANION-DESIGN.md), [pairing decision](docs/adr/0001-passcode-pairing.md), and [roadmap](PLAN.md). The [release notes template](docs/RELEASE_TEMPLATE.md) is used for GitHub releases.
