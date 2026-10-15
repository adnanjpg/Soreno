#!/bin/bash
# Build Soreno.app from SPM executable target
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

BUILD_DIR="$SCRIPT_DIR/.build"
APP_NAME="Soreno"
APP_BUNDLE="$SCRIPT_DIR/dist/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"
BUILD_CONFIGURATION="${BUILD_CONFIGURATION:-debug}"
LOCAL_BUILD="${LOCAL_BUILD:-1}"
LOCAL_BUILD_NORMALIZED="$(printf '%s' "$LOCAL_BUILD" | tr '[:upper:]' '[:lower:]')"

case "$BUILD_CONFIGURATION" in
    debug|release)
        ;;
    *)
        echo "ERROR: BUILD_CONFIGURATION must be 'debug' or 'release' (got '$BUILD_CONFIGURATION')"
        exit 1
        ;;
esac

case "$LOCAL_BUILD_NORMALIZED" in
    1|true|yes)
        LOCAL_BUILD_PLIST_VALUE="YES"
        ;;
    0|false|no)
        LOCAL_BUILD_PLIST_VALUE="NO"
        ;;
    *)
        echo "ERROR: LOCAL_BUILD must be one of 1, 0, true, false, yes, or no (got '$LOCAL_BUILD')"
        exit 1
        ;;
esac

echo "==> Building $APP_NAME ($BUILD_CONFIGURATION)..."
swift build -c "$BUILD_CONFIGURATION" 2>&1

EXECUTABLE="$BUILD_DIR/$BUILD_CONFIGURATION/$APP_NAME"
if [ ! -f "$EXECUTABLE" ]; then
    echo "ERROR: Build failed — executable not found at $EXECUTABLE"
    exit 1
fi

echo "==> Packaging $APP_NAME.app..."

# Clean previous
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

# Copy executable
cp "$EXECUTABLE" "$MACOS_DIR/$APP_NAME"

# Copy Info.plist
cp "$SCRIPT_DIR/Soreno/Resources/Info.plist" "$CONTENTS/Info.plist"
plutil -replace SorenoLocalBuild -bool "$LOCAL_BUILD_PLIST_VALUE" "$CONTENTS/Info.plist"

# Copy app icon
cp "$SCRIPT_DIR/Soreno/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"

# Copy menu bar icon
cp "$SCRIPT_DIR/Soreno/Resources/MenuBarIconTemplate.png" "$RESOURCES_DIR/MenuBarIconTemplate.png"
cp "$SCRIPT_DIR/Soreno/Resources/MenuBarIconTemplate@2x.png" "$RESOURCES_DIR/MenuBarIconTemplate@2x.png"

# Copy entitlements (used for signing)
cp "$SCRIPT_DIR/Soreno/Resources/Soreno.entitlements" "$CONTENTS/Soreno.entitlements"

# Sign with developer identity (stable signature = TCC permissions survive rebuilds)
IDENTITY_COUNT=$(security find-identity -v -p codesigning | grep -c "valid identities found" || true)
if security find-identity -v -p codesigning | grep -q '^  1)'; then
    IDENTITY=$(security find-identity -v -p codesigning | grep '^  1)' | sed 's/.*"\(.*\)"/\1/')
    echo "==> Signing with: $IDENTITY"
    codesign --force --deep --sign "$IDENTITY" \
        --entitlements "$CONTENTS/Soreno.entitlements" \
        "$APP_BUNDLE"
else
    echo "==> No signing identity found, ad-hoc signing..."
    codesign --force --deep --sign - \
        --entitlements "$CONTENTS/Soreno.entitlements" \
        "$APP_BUNDLE"
fi

echo "==> Done! App bundle at: $APP_BUNDLE"
echo "==> Local-build marker: $LOCAL_BUILD_PLIST_VALUE"
echo ""
echo "To install: cp -r \"$APP_BUNDLE\" /Applications/"
echo "To run:     open \"$APP_BUNDLE\""
