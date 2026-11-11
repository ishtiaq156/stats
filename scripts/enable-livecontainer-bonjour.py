#!/usr/bin/env python3
"""Allow Stats Bonjour browsing in an existing LiveContainer host IPA.

Re-sign the resulting host IPA through the user's usual sideloading workflow.
This does not modify the Stats guest IPA or any installed app.
"""

import argparse
import copy
import plistlib
import shutil
import zipfile
from pathlib import Path


SERVICE = "_macactivity._tcp"


def patch_livecontainer(source: Path, destination: Path) -> tuple[str, str, bool]:
    if not source.is_file() or source.suffix.lower() != ".ipa":
        raise ValueError(f"Expected a LiveContainer host IPA: {source}")
    if source.resolve() == destination.resolve():
        raise ValueError("Input and output IPA paths must differ")
    if destination.exists():
        raise FileExistsError(f"Will not replace an existing IPA: {destination}")

    with zipfile.ZipFile(source, "r") as original:
        infos = original.infolist()
        paths = [info.filename for info in infos]
        if len(paths) != len(set(paths)):
            raise ValueError("IPA contains duplicate ZIP entries")
        plist_paths = [name for name in paths if len(name.split("/")) == 3
                       and name.startswith("Payload/") and name.endswith(".app/Info.plist")]
        if len(plist_paths) != 1:
            raise ValueError("Expected exactly one Payload/<host>.app/Info.plist")

        plist_path = plist_paths[0]
        raw = original.read(plist_path)
        properties = plistlib.loads(raw)
        if not isinstance(properties, dict) or properties.get("CFBundlePackageType") != "APPL":
            raise ValueError("IPA has no valid host app declaration")
        if "LCVersionInfo" not in properties and "livecontainer" not in str(
                properties.get("CFBundleName", "")).lower():
            raise ValueError("The host app does not look like LiveContainer")
        executable = properties.get("CFBundleExecutable")
        if not isinstance(executable, str) or not executable or (
                plist_path.removesuffix("Info.plist") + executable) not in paths:
            raise ValueError("Host app executable is missing")

        services = properties.get("NSBonjourServices", [])
        if not isinstance(services, list) or not all(isinstance(item, str) for item in services):
            raise ValueError("Unexpected NSBonjourServices value in host app")
        added = SERVICE not in services
        if added:
            properties["NSBonjourServices"] = [*services, SERVICE]
        updated = plistlib.dumps(properties, fmt=plistlib.FMT_BINARY if raw.startswith(b"bplist")
                                else plistlib.FMT_XML, sort_keys=False)

        destination.parent.mkdir(parents=True, exist_ok=True)
        try:
            with zipfile.ZipFile(destination, "x", allowZip64=True) as patched:
                patched.comment = original.comment
                for info in infos:
                    entry = copy.copy(info)
                    if info.filename == plist_path:
                        patched.writestr(entry, updated)
                    else:
                        with original.open(info) as reader, patched.open(entry, "w") as writer:
                            shutil.copyfileobj(reader, writer, length=1024 * 1024)
            with zipfile.ZipFile(destination) as check:
                if (set(check.namelist()) != set(paths) or check.testzip() is not None or
                        SERVICE not in plistlib.loads(check.read(plist_path))["NSBonjourServices"]):
                    raise ValueError("Patched IPA failed ZIP or Bonjour declaration validation")
        except BaseException:
            destination.unlink(missing_ok=True)
            raise

    return str(properties.get("CFBundleIdentifier", "")), str(properties.get("CFBundleShortVersionString", "")), added


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("host_ipa", type=Path, help="Your current LiveContainer or combined SideStore host IPA")
    parser.add_argument("output_ipa", type=Path, help="New, unsigned IPA path")
    args = parser.parse_args()
    identifier, version, added = patch_livecontainer(args.host_ipa.expanduser(), args.output_ipa.expanduser())
    print(f"LiveContainer host: {identifier} ({version})")
    print(f"{SERVICE}: {'added' if added else 'already declared'}")
    print(f"Validated unsigned host IPA: {args.output_ipa.expanduser()}")
    print("Re-sign and install it using the same host bundle ID and Apple team as your existing installation.")
