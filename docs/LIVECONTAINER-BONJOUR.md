# Bonjour discovery inside LiveContainer

Stats discovers the companion using the Bonjour service `_macactivity._tcp`.
Direct installations signed through SideStore can browse it because
`Apps/Mobile/Info.plist` declares the service. A guest inside LiveContainer
inherits the **host** app's system-level Bonjour service allowlist. If the host
does not list `_macactivity._tcp` in `NSBonjourServices`, iOS can deny the
browser before it ever discovers the Mac. A Local Network permission toggle
alone does not add the missing service declaration.

To enable automatic discovery, use the exact LiveContainer IPA that you
currently install, including any combined **LiveContainer + SideStore** variant.
On your Mac, run:

```sh
python3 scripts/enable-livecontainer-bonjour.py \
  '/path/to/your/current-LiveContainer-host.ipa' \
  '/path/to/LiveContainer-with-Stats-Bonjour.ipa'
```

The script copies the original IPA entries, adds `_macactivity._tcp` to the
host's `NSBonjourServices` array, and validates the result. It does not alter
the guest Stats IPA. The result is **unsigned** until your sideloading workflow
signs it again. Install it as an **update to the same host app identity** with
the same Apple team to preserve the installed host and its data. Keep a backup
of your current combined host IPA. Do not substitute a different LiveContainer
release for your current SideStore combination.

Allow LiveContainer local network access in iPhone Settings → Privacy &
Security → Local Network. Relaunch LiveContainer, then Stats. The Mac companion
should advertise `_macactivity._tcp`; it does not need an update for this fix.

If your installed host cannot be updated, Stats already supports pairing using
the Mac's IP address and port. In Stats, choose **Connect using IP address**;
read the local address and port under the companion's network information on
your Mac and enter its five-digit passcode. That uses an ordinary TCP connection
and does not depend on Bonjour browsing.
