#!/bin/zsh
# Rebuild, verify, and update the copy used by Finder and login items.
set -euo pipefail
cd "$(dirname "$0")/.."

DESTINATION=/Applications/TapTap.app
if [[ -e "$DESTINATION" && "$(plutil -extract CFBundleIdentifier raw "$DESTINATION/Contents/Info.plist")" != app.taptap.TapTap ]]; then
    print -u2 "A different app exists at $DESTINATION; leaving it unchanged."
    exit 1
fi

Scripts/build-app.sh
INSTALL_STAGE=$(mktemp -d /Applications/.taptap-install.XXXXXX)
trap 'if [[ ! -e "$DESTINATION" && -d "$INSTALL_STAGE/previous.app" ]]; then mv "$INSTALL_STAGE/previous.app" "$DESTINATION"; fi; rm -rf "$INSTALL_STAGE"' EXIT
ditto build/TapTap.app "$INSTALL_STAGE/TapTap.app"
codesign --verify --deep --strict "$INSTALL_STAGE/TapTap.app"

# Only stop TapTap instances running from the paths this script manages.
for app_pid in ${(f)"$(pgrep -x TapTap || true)"}; do
    executable=$(ps -p "$app_pid" -o comm=)
    if [[ "$executable" == "$DESTINATION/Contents/MacOS/TapTap" || "$executable" == "$PWD/build/TapTap.app/Contents/MacOS/TapTap" ]]; then
        kill -TERM "$app_pid"
        for attempt in {1..20}; do
            if ! kill -0 "$app_pid" 2>/dev/null; then break; fi
            sleep 0.1
        done
    fi
done

if [[ -e "$DESTINATION" ]]; then mv "$DESTINATION" "$INSTALL_STAGE/previous.app"; fi
mv "$INSTALL_STAGE/TapTap.app" "$DESTINATION"
codesign --verify --deep --strict "$DESTINATION"
open "$DESTINATION" --args --settings
print "installed $DESTINATION"
