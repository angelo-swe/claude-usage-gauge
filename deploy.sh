#!/usr/bin/env zsh
# deploy.sh — build, sign, and install Claude Gauge (host app + widget).
# Local ad-hoc install. The host app is NON-sandboxed so it can read the
# Claude Code OAuth token from the Keychain; the widget stays sandboxed.
set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="ClaudeGauge"
APP_DEST="$HOME/Applications/$APP_NAME.app"
BUILD_DIR="/tmp/claude-gauge-build"
HOST_ENT="$PROJECT_DIR/ClaudeGauge/ClaudeGauge.entitlements"
EXT_ENT="$PROJECT_DIR/ClaudeGaugeExtension/ClaudeGaugeExtension.entitlements"
ICON="$PROJECT_DIR/ClaudeGauge/AppIcon.icns"
EXT_BUNDLE="$APP_DEST/Contents/PlugIns/ClaudeGaugeExtension.appex"

echo "▸ Killing existing processes..."
pkill -f "$APP_NAME" 2>/dev/null || true
pkill -f "ClaudeGaugeExtension" 2>/dev/null || true
sleep 1

echo "▸ Building..."
xcodebuild build \
  -project "$PROJECT_DIR/$APP_NAME.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | grep -v "deprecated" || true

echo "▸ Installing..."
rm -rf "$APP_DEST"
cp -R "$BUILD_DIR/Build/Products/Release/$APP_NAME.app" "$APP_DEST"

echo "▸ Injecting icon..."
mkdir -p "$APP_DEST/Contents/Resources"
[ -f "$ICON" ] && cp "$ICON" "$APP_DEST/Contents/Resources/AppIcon.icns" || true

# The host reads the Keychain, so it must keep a STABLE signature or macOS
# re-prompts on every rebuild. Sign it with an Apple Development identity if
# one exists (auto-detected; override with CODESIGN_IDENTITY), so the
# "Always Allow" grant persists. The widget is sandboxed and only reads its
# own container, so ad-hoc is fine for it.
HOST_SIGN="${CODESIGN_IDENTITY:-$(security find-identity -v 2>/dev/null | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)}"
HOST_SIGN="${HOST_SIGN:--}"
echo "▸ Signing widget (ad-hoc) + host (identity: $HOST_SIGN)..."
codesign --force --sign - --entitlements "$EXT_ENT" "$EXT_BUNDLE"
codesign --force --sign "$HOST_SIGN" --entitlements "$HOST_ENT" "$APP_DEST"

echo "▸ Clearing widget cache..."
rm -rf "$HOME/Library/Containers/com.angelotrifanoff.claudegauge.widget/Data/SystemData/com.apple.chrono/" 2>/dev/null || true

echo "▸ Registering extension..."
pluginkit -r "$EXT_BUNDLE" 2>/dev/null || true
sleep 1
pluginkit -a "$EXT_BUNDLE"
sleep 1

echo "▸ Registering with Launch Services..."
/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister -f "$APP_DEST"

echo "▸ Restarting widget host..."
killall NotificationCenter 2>/dev/null || true
sleep 2

echo "▸ Launching app..."
open "$APP_DEST"

sleep 2
echo ""
echo "✓ Deployed! Extension registered:"
pluginkit -m -v | grep claudegauge || true
echo ""
echo "→ Right-click desktop → Edit Widgets → search 'Claude Gauge' → add"
echo "→ First run shows a Keychain prompt — choose 'Always Allow'."
