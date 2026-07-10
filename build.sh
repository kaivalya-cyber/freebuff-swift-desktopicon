#!/usr/bin/env bash
# ============================================================
# Build & bundle Freebuff.app
# ============================================================
set -euo pipefail

APP_NAME="Freebuff"
BUILD_DIR=".build"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
CONTENTS="${APP_BUNDLE}/Contents"
MACOS="${CONTENTS}/MacOS"
RESOURCES="${CONTENTS}/Resources"

echo "=== Building ${APP_NAME} ==="

# 1. Compile with SwiftPM in release mode
swift build -c release

# 2. Create .app bundle structure
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS}"
mkdir -p "${RESOURCES}"

# 3. Copy the binary
cp "${BUILD_DIR}/release/${APP_NAME}" "${MACOS}/${APP_NAME}"

# 3b. Copy the agent bridge script into Resources
cp cli/handle-prompt.py "${RESOURCES}/handle-prompt.py"

# 4. Create Info.plist with LSUIElement=YES (hide from Dock)
cat > "${CONTENTS}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>com.freebuff.app</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# 5. Ad-hoc codesign
codesign --force --deep --sign - "${APP_BUNDLE}" 2>/dev/null || true

echo ""
echo "=== Done ==="
echo "App bundle: ${APP_BUNDLE}"
echo ""
echo "To run: open ${APP_BUNDLE}"
echo ""
echo "To install: cp -r ${APP_BUNDLE} /Applications/"
