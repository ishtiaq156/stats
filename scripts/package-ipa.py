#!/usr/bin/env python3
"""Package an unsigned iPhone .app into a clean IPA for on-device signing."""

import argparse
import os
import plistlib
import stat
import zipfile
from pathlib import Path


def archive_path(app: Path, path: Path) -> str:
    return "Payload/" + str(path.relative_to(app.parent)).replace(os.sep, "/")


def pack(app: Path, destination: Path) -> None:
    if app.suffix != ".app" or not app.is_dir():
        raise ValueError(f"Expected an .app directory: {app}")

    plist_path = app / "Info.plist"
    with plist_path.open("rb") as source:
        info = plistlib.load(source)
    executable = info.get("CFBundleExecutable")
    if info.get("CFBundlePackageType") != "APPL" or not executable or not (app / executable).is_file():
        raise ValueError("The .app bundle has no valid iPhone executable")

    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        raise FileExistsError(f"Will not overwrite an existing IPA: {destination}")

    try:
        with zipfile.ZipFile(destination, "x", compression=zipfile.ZIP_DEFLATED, compresslevel=9,
                             allowZip64=True) as ipa:
            # Both directory entries are explicit for tools that scan ZIP entries.
            for directory in ("Payload/", f"Payload/{app.name}/"):
                entry = zipfile.ZipInfo(directory)
                entry.create_system = 3
                entry.external_attr = ((stat.S_IFDIR | 0o755) << 16) | 0x10
                ipa.writestr(entry, b"")

            for root, directories, filenames in os.walk(app):
                directories[:] = sorted(name for name in directories
                                        if name != "__MACOSX" and not name.startswith("._"))
                for name in sorted(filenames):
                    if name.startswith("._") or name == ".DS_Store":
                        continue
                    source = Path(root) / name
                    target = archive_path(app, source)
                    if source.is_symlink():
                        entry = zipfile.ZipInfo(target)
                        entry.create_system = 3
                        entry.external_attr = (stat.S_IFLNK | 0o777) << 16
                        ipa.writestr(entry, os.readlink(source).encode())
                    else:
                        ipa.write(source, target)

        with zipfile.ZipFile(destination) as ipa:
            entries = ipa.namelist()
            expected = {f"Payload/{app.name}/Info.plist", f"Payload/{app.name}/{executable}"}
            if not expected.issubset(entries) or any("/._" in name or "__MACOSX" in name
                                                      for name in entries) or ipa.testzip() is not None:
                raise ValueError("IPA failed bundle or ZIP integrity validation")
            with ipa.open(f"Payload/{app.name}/Info.plist") as source:
                if plistlib.load(source).get("CFBundleExecutable") != executable:
                    raise ValueError("IPA has an unexpected executable declaration")
    except BaseException:
        destination.unlink(missing_ok=True)
        raise


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path, help="Built iPhone .app directory")
    parser.add_argument("output", type=Path, help="New .ipa output path")
    args = parser.parse_args()
    pack(args.app.resolve(), args.output.expanduser())
    print(f"Validated IPA: {args.output.expanduser()}")
