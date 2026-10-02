# Building and packaging

## Toolchain

Use Xcode 26 or later for the `.icon` app asset. Select Xcode with `xcode-select` if your active developer directory currently points at Command Line Tools. The Swift package requires Swift 6 tooling and targets macOS 14 or later.

```sh
xcodebuild -version
swift --version
swift test
```

## Local app

`Scripts/build-app.sh` builds the SwiftPM executable, copies the model and localization bundle, compiles the Icon Composer icon, writes the app's Info.plist, and verifies its code signature. Output is `build/TapTap.app`.

`Scripts/install-app.sh` additionally stages and verifies a replacement in `/Applications`, stops only TapTap instances from the managed install/build paths, replaces the installed app, and opens settings. It preserves the previous app until the replacement is ready.

Signing selection is: explicit `SIGN_IDENTITY`, ignored local `.signing-identity`, then a valid Apple Development certificate. Missing certificates cause a clear error. `SIGN_IDENTITY=-` is an explicit ad-hoc option, not an automatic fallback; it does not replace a previously remembered development identity.

## Localization

The SwiftPM target processes `Sources/TapTapApp/Resources/{en,zh-Hans,zh-Hant}.lproj/Localizable.strings`. Packaged apps carry the resource bundle in `Contents/Resources`. `L10n` resolves that bundle independently of the source checkout.

Language selection is stored separately from the action configuration and updates the interface immediately. Existing gesture identifiers, key codes, modifier flags, and actions stay the same across languages.

For a documentation preview with clean defaults, after building:

```sh
TAPTAP_SNAPSHOT="$PWD/build/settings-en.png" \
TAPTAP_SNAPSHOT_DEFAULTS=1 \
  build/TapTap.app/Contents/MacOS/TapTap -appLanguage en
```

The preview does not start the live sensor or overwrite saved mappings. It renders settings and menu icon previews, then exits. A directly launched preview is useful for layout checks; verify Accessibility permission with the normally launched installed app, as direct shell launches can inherit the launching process's permission context.

## Public distribution

An Apple Development signature is for development and local use; it is not a notarized Developer ID distribution signature. A public binary release should use a Developer ID Application certificate, a secure signing setup, Apple notarization, and stapling. Do not publish certificates, private keys, or local notarization credentials.

The source release does not include a notarized installer or download.
