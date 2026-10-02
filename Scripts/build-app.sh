#!/bin/zsh
# Builds build/TapTap.app (menu bar app) from the SwiftPM target, compiles the
# Icon Composer icon, and signs it.
#
# Signing identity: $SIGN_IDENTITY, else the locally pinned certificate, else the
# first "Apple Development" certificate. SIGN_IDENTITY=- explicitly opts in to
# an ad-hoc build for contributors/CI. Never silently fall back to ad-hoc:
# keeping the signing identity and bundle ID preserves the app's designated
# requirement across ordinary rebuilds.
set -euo pipefail
cd "$(dirname "$0")/.."

REQUESTED_IDENTITY=${SIGN_IDENTITY:-}
if [[ -z "$REQUESTED_IDENTITY" && -f .signing-identity ]]; then
    REQUESTED_IDENTITY=$(<.signing-identity)
fi
if [[ "$REQUESTED_IDENTITY" == "-" ]]; then
    IDENTITY=-
else
    IDENTITIES=$(security find-identity -v -p codesigning)
    if [[ -z "$REQUESTED_IDENTITY" ]]; then
        REQUESTED_IDENTITY=$(awk '/"Apple Development:/ { print $2; exit }' <<< "$IDENTITIES")
    fi
    IDENTITY=$(awk -v requested="$REQUESTED_IDENTITY" '
        /"/ {
            name = $0
            sub(/^[^"]*"/, "", name)
            sub(/".*$/, "", name)
            if (requested != "" && ($2 == requested || name == requested)) {
                print $2
                exit
            }
        }
    ' <<< "$IDENTITIES")
    if [[ -z "$IDENTITY" ]]; then
        print -u2 "Signing certificate unavailable. Set SIGN_IDENTITY to a valid certificate, or use SIGN_IDENTITY=- for an explicit ad-hoc build."
        exit 1
    fi
fi

swift build -c release --product TapTapApp

mkdir -p build
STAGING_DIR=$(mktemp -d build/.taptap-build.XXXXXX)
trap 'rm -rf "$STAGING_DIR"' EXIT
APP="$STAGING_DIR/TapTap.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/TapTapApp "$APP/Contents/MacOS/TapTap"
cp model/tapmodel.json "$APP/Contents/Resources/"
ditto .build/release/TapTap_TapTapApp.bundle "$APP/Contents/Resources/TapTap_TapTapApp.bundle"

# Icon Composer (.icon) -> Assets.car (Liquid Glass) + AppIcon.icns (older macOS)
xcrun actool Resources/AppIcon.icon --compile "$APP/Contents/Resources" \
    --app-icon AppIcon --platform macosx --minimum-deployment-target 14.0 \
    --output-partial-info-plist "$STAGING_DIR/icon-partial.plist" >/dev/null

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>          <string>app.taptap.TapTap</string>
    <key>CFBundleName</key>                <string>TapTap</string>
    <key>CFBundleDisplayName</key>         <string>TapTap</string>
    <key>CFBundleDevelopmentRegion</key>   <string>en</string>
    <key>CFBundleLocalizations</key>       <array><string>en</string><string>zh-Hans</string><string>zh-Hant</string></array>
    <key>CFBundleExecutable</key>          <string>TapTap</string>
    <key>CFBundleIconFile</key>            <string>AppIcon</string>
    <key>CFBundleIconName</key>            <string>AppIcon</string>
    <key>CFBundlePackageType</key>         <string>APPL</string>
    <key>CFBundleShortVersionString</key>  <string>0.1.0</string>
    <key>CFBundleVersion</key>             <string>1</string>
    <key>LSMinimumSystemVersion</key>      <string>14.0</string>
    <key>LSApplicationCategoryType</key>   <string>public.app-category.utilities</string>
    <key>LSUIElement</key>                 <true/>
    <key>NSHighResolutionCapable</key>     <true/>
</dict>
</plist>
PLIST

plutil -lint "$APP/Contents/Info.plist"
codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

# Replace the previous build only after compiling and verifying the new bundle.
rm -rf build/TapTap.app
mv "$APP" build/TapTap.app
mv "$STAGING_DIR/icon-partial.plist" build/icon-partial.plist
if [[ "$IDENTITY" != "-" ]]; then print -r -- "$IDENTITY" > .signing-identity; fi
print "signed with: $IDENTITY"
print "built build/TapTap.app"
