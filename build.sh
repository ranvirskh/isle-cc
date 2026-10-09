#!/bin/zsh
# Builds Isle.app.
#   ./build.sh            release build, assembled and signed at build/Isle.app
#   ./build.sh --test     run the unit tests
#   ./build.sh --install  build, copy to /Applications, relaunch
#   ./build.sh --debug    debug build (faster) into build/Isle.app
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Isle"
BUNDLE_ID="local.isle.app"
VERSION="1.1.1"
IDENTITY="Isle Local Signing"
KEYCHAIN="$HOME/Library/Keychains/isle-signing.keychain-db"
KEYCHAIN_PASSWORD="isle-local-signing"
APP="build/$APP_NAME.app"

MODE="release"
INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --test) swift test; exit $? ;;
    --install) INSTALL=1 ;;
    --debug) MODE="debug" ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

# A stable self-signed identity keeps the app's code signature the same across rebuilds, so macOS
# remembers the Calendar / Automation / Bluetooth permissions instead of asking again after every build.
# It lives in its own keychain with a known password so signing never needs a GUI prompt.
ensure_identity() {
  if [[ -f "$KEYCHAIN" ]]; then
    security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN" 2>/dev/null || true
    if security find-certificate -c "$IDENTITY" "$KEYCHAIN" >/dev/null 2>&1; then return 0; fi
  fi
  echo "Creating local signing identity \"$IDENTITY\"..."
  local tmp; tmp="$(mktemp -d)"
  cat > "$tmp/cert.conf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $IDENTITY
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$tmp/cert.conf" \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem" >/dev/null 2>&1 || return 1
  /usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -name "$IDENTITY" \
    -out "$tmp/identity.p12" -passout pass:isle >/dev/null 2>&1 || return 1
  [[ -f "$KEYCHAIN" ]] || security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN" || return 1
  security set-keychain-settings "$KEYCHAIN" || true           # no auto-lock
  security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN" || return 1
  security import "$tmp/identity.p12" -k "$KEYCHAIN" -P isle -T /usr/bin/codesign >/dev/null || return 1
  security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null 2>&1 || true
  # Add to the search list (keeping what is already there) so codesign can find it.
  local existing; existing=(${(f)"$(security list-keychains -d user | sed -e 's/^ *"//' -e 's/"$//')"})
  if [[ ! " ${existing[*]} " == *"$KEYCHAIN"* ]]; then
    security list-keychains -d user -s "${existing[@]}" "$KEYCHAIN" || return 1
  fi
  rm -rf "$tmp"
}

echo "Building ($MODE)..."
swift build -c "$MODE" 2>&1 | grep -E "error|warning: unused|Compiling|Build complete" | tail -5 || true
BIN="$(swift build -c "$MODE" --show-bin-path)/$APP_NAME"
[[ -x "$BIN" ]] || { echo "build failed: $BIN not found" >&2; swift build -c "$MODE" 2>&1 | grep -E "error" | head -20; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
# System Now Playing helper: loaded into /usr/bin/perl at runtime (see Helper/isle_nowplaying.m). Signed ad-hoc on
# purpose: the host process is Apple's perl, not Isle, so Isle's local identity is irrelevant to it.
clang -dynamiclib -fobjc-arc -O2 -framework Foundation -o "$APP/Contents/Resources/libisle_nowplaying.dylib" Helper/isle_nowplaying.m
codesign --force -s - "$APP/Contents/Resources/libisle_nowplaying.dylib" >/dev/null
cp Helper/launcher.pl "$APP/Contents/Resources/launcher.pl"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSSupportsSuddenTermination</key><false/>
  <key>NSCalendarsUsageDescription</key><string>Isle shows today's calendar events in the island.</string>
  <key>NSCalendarsFullAccessUsageDescription</key><string>Isle shows today's calendar events in the island.</string>
  <key>NSAppleEventsUsageDescription</key><string>Isle reads the current track from Spotify and Music and sends play, pause, skip, seek and shuffle commands.</string>
  <key>NSLocationUsageDescription</key><string>Isle uses your location only to show the weather where you are.</string>
  <key>NSLocationWhenInUseUsageDescription</key><string>Isle uses your location only to show the weather where you are.</string>
  <key>NSBluetoothAlwaysUsageDescription</key><string>Isle shows a brief pop-up when a Bluetooth device connects.</string>
</dict>
</plist>
EOF

cat > build/Isle.entitlements <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.network.client</key><true/>
  <key>com.apple.security.automation.apple-events</key><true/>
  <key>com.apple.security.personal-information.calendars</key><true/>
  <key>com.apple.security.device.bluetooth</key><true/>
  <key>com.apple.security.personal-information.location</key><true/>
</dict>
</plist>
EOF

SIGNED_WITH="ad-hoc"
if ensure_identity && codesign --force --options runtime --entitlements build/Isle.entitlements \
     --keychain "$KEYCHAIN" -s "$IDENTITY" "$APP" 2>build/codesign.log; then
  SIGNED_WITH="$IDENTITY (stable; permissions persist across rebuilds)"
else
  echo "note: could not use the local signing identity ($(head -1 build/codesign.log 2>/dev/null)); falling back to ad-hoc."
  echo "      With ad-hoc signing macOS asks for permissions again after each rebuild."
  codesign --force --options runtime --entitlements build/Isle.entitlements -s - "$APP"
fi
codesign --verify --strict "$APP"
echo "Built $APP  [signed: $SIGNED_WITH]"

if [[ $INSTALL -eq 1 ]]; then
  pkill -x "$APP_NAME" 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x "$APP_NAME" >/dev/null || break; sleep 0.2; done
  rm -rf "/Applications/$APP_NAME.app"
  ditto "$APP" "/Applications/$APP_NAME.app"
  open "/Applications/$APP_NAME.app"
  echo "Installed to /Applications/$APP_NAME.app and relaunched."
fi
