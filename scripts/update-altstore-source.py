#!/usr/bin/env python3
"""Update the AltStore/SideStore source from a published iPhone release IPA."""

import argparse
import hashlib
import json
import plistlib
import re
import zipfile
from pathlib import Path


REPOSITORY = "ishtiaq156/stats"
ICON_URL = ("https://raw.githubusercontent.com/ishtiaq156/stats/main/"
            "Apps/Mobile/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png")
SOURCE = {
    "name": "Stats",
    "subtitle": "Live Mac metrics on your iPhone",
    "description": "Install Stats for iPhone and connect to Stats Companion on your Mac.",
    "website": f"https://github.com/{REPOSITORY}",
    "apps": [{
        "name": "Stats",
        "bundleIdentifier": "com.ishtiaqsyed.StatsForIOS",
        "developerName": "Ishtiaq Ul Haq Syed",
        "subtitle": "Your Mac's activity, on your iPhone",
        "localizedDescription": (
            "View live CPU, memory, storage, and network activity from your Mac. "
            "Pair securely over your local network using Stats Companion."
        ),
        "iconURL": ICON_URL,
        "category": "utilities",
        "versions": [],
        "appPermissions": {"entitlements": [], "privacy": {}},
    }],
    "news": [],
}


def update(source_path: Path, release_path: Path, ipa_path: Path, tag: str) -> None:
    release = json.loads(release_path.read_text())
    match = re.fullmatch(r"v\d+\.\d+\.\d+", tag)
    if not match:
        raise ValueError(f"Unexpected release tag: {tag}")
    if not release.get("publishedAt"):
        raise ValueError("Release has no publication date")

    assets = [asset for asset in release["assets"] if asset["name"] == ipa_path.name]
    if len(assets) != 1:
        raise ValueError("Release does not contain exactly this IPA")
    asset = assets[0]
    digest = hashlib.sha256(ipa_path.read_bytes()).hexdigest()
    if asset.get("digest") != f"sha256:{digest}" or asset.get("size") != ipa_path.stat().st_size:
        raise ValueError("IPA does not match the published asset digest and size")

    with zipfile.ZipFile(ipa_path) as archive:
        if archive.testzip() is not None:
            raise ValueError("IPA ZIP integrity check failed")
        info = plistlib.loads(archive.read("Payload/Stats.app/Info.plist"))
    version = info["CFBundleShortVersionString"]
    build = str(info["CFBundleVersion"])
    if (asset["name"] != f"Stats-v{version}-iOS.ipa" or
            info["CFBundleIdentifier"] != SOURCE["apps"][0]["bundleIdentifier"] or
            "iPhoneOS" not in info["CFBundleSupportedPlatforms"]):
        raise ValueError("IPA identity, version, or platform does not match the source")

    source = json.loads(source_path.read_text()) if source_path.exists() else SOURCE
    app = source["apps"][0]
    if app["bundleIdentifier"] != info["CFBundleIdentifier"]:
        raise ValueError("Existing source has a different bundle identifier")
    existing = [item for item in app["versions"] if item["version"] == version]
    if existing and existing[0]["buildVersion"] != build:
        raise ValueError("Published version has a different build number")
    if app["versions"]:
        latest = tuple(map(int, app["versions"][0]["version"].split(".")))
        if tuple(map(int, version.split("."))) < latest:
            raise ValueError("Refusing to put an older release first")

    summary = release.get("body", "").split("\n", 1)[0].strip()
    entry = {
        "version": version,
        "buildVersion": build,
        "date": release["publishedAt"],
        "localizedDescription": summary or f"Stats for iPhone {version}",
        "downloadURL": f"https://github.com/{REPOSITORY}/releases/download/{tag}/{asset['name']}",
        "size": asset["size"],
        "sha256": digest,
        "minOSVersion": info["MinimumOSVersion"],
    }
    app["versions"] = [entry, *(item for item in app["versions"]
                                 if item["version"] != version)]
    app["appPermissions"]["privacy"] = {
        key: value for key, value in info.items() if key.endswith("UsageDescription")
    }
    source_path.write_text(json.dumps(source, indent=2, ensure_ascii=False) + "\n")
    print(f"Updated {source_path}: Stats {version} ({build}), {tag}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=Path("source.json"))
    parser.add_argument("--release", type=Path, required=True)
    parser.add_argument("--ipa", type=Path, required=True)
    parser.add_argument("--tag", required=True)
    args = parser.parse_args()
    update(args.source, args.release, args.ipa, args.tag)
