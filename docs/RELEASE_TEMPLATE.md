<!--
Reusable GitHub release body. The tag vX.Y.Z identifies the project release.
Mac Companion and iPhone Stats maintain independent app versions and builds;
use each component's actual version in its asset filename and download label.
Before releasing a meaningful batch of commits, decide whether each affected
app needs a version bump. Increase MARKETING_VERSION and CURRENT_PROJECT_VERSION
for every changed app in project.yml, regenerate Stats.xcodeproj, and add a
new dated CompanionRelease.notes entry for a Mac release. Include mobile changes
in release notes, too. Keep released versions and binaries immutable.
For every mobile release, run scripts/build-ios-ipa.sh and attach its validated
Stats-vA.B.C-iOS.ipa to that release. Verify the IPA version, iPhoneOS platform,
arm64 executable, ZIP integrity, and SHA-256 digest before publishing. Direct
AltStore/SideStore installs and LiveContainer guest imports use the same IPA;
LiveContainer host Bonjour restrictions are covered in docs/LIVECONTAINER-BONJOUR.md.
Once development changes pass their relevant builds/tests, commit and push
the reviewed source to origin/main. User policy: every version bump must also
finish with a published GitHub release and pushed version tag containing the
verified installers and release notes. Never stop at a source-only push when
a version was bumped. For versioned distributions, publish the new release/tag
only after the exact versioned artifacts have been verified.
An updated Mac build is needed before the new menu bar update-arrow can appear:
the published v0.3.2 binary has no arrow and checks only stable releases.
The release status is set in GitHub (Pre-release or Latest), not in the title,
tag, download filename, or in-app changelog. Once a version/tag is published,
use a new version for any changed binary rather than silently replacing it.

Keep notes short and user-facing. Include only sections with actual changes;
remove unused feature/fix categories. For later releases, link the previous and
current tags in Full Changelog and credit contributors from merged PRs.
The first release can link its full commit history instead of a comparison.
GitHub already displays asset digests beside downloads, so omit a separate
checksums section from the release body.
Keep installation steps, system requirements and ongoing limitations in the
README, and security details in SECURITY.md. A version-specific breaking change
or critical upgrade warning should still be called out in its release notes.
-->

One or two sentences describing what this release delivers.

## What's Changed

### Features

- Add meaningful feature changes here.

### Improvements and Fixes

- Add verified improvements or bug fixes here.

## Download

For Mac releases, publish both the signed universal DMG for Finder installs and the signed universal ZIP used by the inline updater. Verify each after packaging, and upload both to the same release.

- **Mac companion · X.Y.Z:** `StatsCompanion-vX.Y.Z-macOS-universal.dmg` (Apple Silicon and Intel).
- **iPhone app · A.B.C:** `Stats-vA.B.C-iOS.ipa` (iOS 17+, arm64; unsigned, requires signing before installation).
- See the [README](https://github.com/ishtiaq156/stats#quick-start) for installation and pairing instructions.

**Full Changelog:** Link to the comparison between previous and current tags, or to the commit history for the first release.
