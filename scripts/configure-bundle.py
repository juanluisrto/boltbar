#!/usr/bin/env python3
"""Configure versioning and the public Sparkle and license trust anchors; never handles private keys."""
import os
import plistlib
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
info = plistlib.loads(path.read_bytes())
version = os.environ.get("BOLTBAR_VERSION", "0.7.4")
build = os.environ.get("BOLTBAR_BUILD", version)
if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,3}", build):
    raise SystemExit("BOLTBAR_BUILD must be a numeric, increasing version")
info.update(CFBundleShortVersionString=version, CFBundleVersion=build)
key_path = Path("Resources/sparkle-public-key.txt")
key = os.environ.get("BOLTBAR_SPARKLE_PUBLIC_KEY") or (key_path.read_text().strip() if key_path.exists() else "")
if key:
    import base64
    if len(base64.b64decode(key, validate=True)) != 32:
        raise SystemExit("Invalid Sparkle public key")
    info.update(
        SUPublicEDKey=key,
        SUFeedURL=os.environ.get("BOLTBAR_UPDATE_FEED", "https://github.com/juanluisrto/boltbar/releases/latest/download/appcast.xml"),
        SUEnableAutomaticChecks=True,
        SUAutomaticallyUpdate=False,
        SUAllowsAutomaticUpdates=False,
        SUSendProfileInfo=False,
        SUVerifyUpdateBeforeExtraction=True,
        SUShowReleaseNotes=False,
    )
license_path = Path("Resources/license-public-key.txt")
license_key = license_path.read_text().strip() if license_path.exists() else ""
if license_key:
    import base64
    if len(base64.b64decode(license_key, validate=True)) != 32:
        raise SystemExit("Invalid license public key")
    info.update(BoltbarLicensePublicKey=license_key)
path.write_bytes(plistlib.dumps(info))
