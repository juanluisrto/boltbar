# Signed macOS updates

Boltbar uses Sparkle 2. Settings → Updates controls automatic checks; the app and status menus also provide Check for Updates. Installation always requires the user to choose Install and Relaunch. Update checks are deferred during streaming, and relaunch waits for an active response to finish.

## Signing setup

Use the JUAN LUIS RTO SL Apple Developer team and a **Developer ID Application** certificate with its private key installed in the login Keychain. Apple Development certificates are only for local builds.

Sparkle's Ed25519 key was generated in the login Keychain under account `com.boltbar.native`. Only its public key is committed in `Resources/sparkle-public-key.txt`. Keep the private key in Keychain and retain a secure backup; do not regenerate it for each release.

Store Apple notarization credentials interactively (do not put passwords in shell history):

```sh
xcrun notarytool store-credentials boltbar-notary
```

Use company Team ID `Z267N8J3BU` and an Apple app-specific password, or an appropriate App Store Connect API key. This is separate from the signing certificate and Sparkle key.

## Build and package

```sh
BOLTBAR_SIGN_IDENTITY='Developer ID Application: JUAN LUIS RTO SL (Z267N8J3BU)' \
BOLTBAR_NOTARY_PROFILE=boltbar-notary \
BOLTBAR_VERSION=0.7.1 BOLTBAR_BUILD=0.7.1 \
sh scripts/package-release.sh
```

The script builds arm64 and x86_64, signs the nested Sparkle helpers and app with hardened runtime, submits the app for notarization, staples and validates it, makes ZIP/DMG artifacts, notarizes and staples the DMG, generates an Ed25519-signed update enclosure, and writes SHA256SUMS. It refuses public packaging without Developer ID signing and a notarization profile. Each release must increase `BOLTBAR_BUILD`.

Publish all four artifacts together in the matching stable GitHub release: ZIP, DMG, `appcast.xml`, and `SHA256SUMS`. The embedded feed is `https://github.com/juanluisrto/boltbar/releases/latest/download/appcast.xml`; enclosure URLs point to the immutable versioned release. Upload assets before marking the draft release public/latest. Do not publish local QA feeds or test builds. The packaging script does not publish.

Existing versions without Sparkle need one manual installation. Preserve bundle identifier `com.boltbar.native` and the signing team for future updates. Moving from old ad hoc signing can require one more Keychain approval; stable signing is expected to preserve subsequent access, but verify that during the first signed upgrade.

## Supporter licenses

A supporter license is a one-off payment; Boltbar stays MIT licensed and works the same without one. A key is `base64url(JSON payload).base64url(Ed25519 signature)`, where the payload holds `name`, `email`, `order`, `issued` (YYYY-MM-DD) and `edition`. The app checks the signature with CryptoKit against `Resources/license-public-key.txt`, which `scripts/configure-bundle.py` copies into Info.plist as `BoltbarLicensePublicKey`. `swift run` builds have no key, so they accept none and never show the reminder. Nothing is checked online.

Make a key for each order:

```sh
swift scripts/make-license.swift --name "Ada Lovelace" --email ada@example.com --order 1001
```

It prints only the license key. `--edition` defaults to `supporter` and `--issued` to today (UTC). The first run created the Ed25519 private key in the login Keychain (service `com.boltbar.license-signing`, account `ed25519`, label “Boltbar license signing key”) and wrote the public key to `Resources/license-public-key.txt`. Like the Sparkle key, it is never printed, written to the repository or regenerated: the script refuses to make a new pair while a public key is committed. Back the private key up (Keychain Access → login → Boltbar license signing key → Show password) in a password manager; losing it means reissuing every license.

The buy link is `License.buyURL` in `Sources/BoltbarNative/License.swift`: `https://juanluis.me/boltbar/buy`, which redirects to the Stripe Payment Link (Managed Payments, so Stripe handles VAT). After payment, juanluis.me signs the key with this same private key, which it holds in the Vercel environment variable `LICENSE_PRIVATE_KEY`, and shows it on the success page. A buyer who loses the key gets it back at `https://juanluis.me/boltbar/license` (`License.recoveryURL`, the "Lost your key?" button) from the email and invoice number on Stripe's receipt. The juanluis.me README covers that side. Use `make-license.swift` for orders handled by hand.

## Validation performed

- 56 existing Swift tests pass with Sparkle integrated.
- Local isolated QA bundle updated through the real Sparkle UI from 0.4.0 to 0.4.1, including download, installation, relaunch, and version verification in Settings.
- A modified 0.4.2 ZIP retaining its original signature was rejected with “The update is improperly signed and could not be validated.”
- These QA builds are ad hoc signed. Developer ID signing, notarization, public HTTPS feed, and signed-to-signed Keychain continuity must be checked before publishing.

References: https://sparkle-project.org/documentation/ and https://developer.apple.com/help/account/certificates/create-developer-id-certificates/
