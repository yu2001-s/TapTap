# Contributing

Build with Xcode 26 or later and run `swift test` before submitting changes. Use `SIGN_IDENTITY=- Scripts/build-app.sh` for a development build without a certificate, or choose your own stable signing certificate.

Keep serialized gesture/action identifiers stable. Old settings must continue loading. Localize user-facing app text through `L10n`; add the same keys and format placeholders to English, Simplified Chinese, and Traditional Chinese resources. Localization tests check resource parity.

For keyboard changes, test modifier press/release ordering, single keys, Fn, keypad keys, and app-directed delivery. Verify a receiving app's actual behavior instead of assuming a posted event succeeded. Hardware detection requires testing on a supported Mac; hosted CI cannot validate palm-rest recognition.

Include your macOS version, Mac hardware model, threshold, and steps to reproduce when reporting recognition problems. Share raw recordings only if you have reviewed their metadata and intend to publish them. Do not include signing identities, credentials, or personal action configuration.

Contributions are accepted under the repository's MIT license.
