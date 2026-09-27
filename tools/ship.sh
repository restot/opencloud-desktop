#!/bin/bash
# ship.sh — Bundle, sign, notarize, and package OpenCloud for distribution
#
# Configure build and signing inputs with --help or OPENCLOUD_* variables.
# --bundle-only creates and verifies an unsigned bundle without publishing it.
set -euo pipefail

# ─── CONFIG ──────────────────────────────────────────────────────────────────

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
TEAM_ID="${OPENCLOUD_TEAM_ID:-}"
SIGN_ID="${OPENCLOUD_SIGN_ID:-}"
NOTARY_PROFILE="${OPENCLOUD_NOTARY_PROFILE:-}"
CRAFT_ROOT="${OPENCLOUD_CRAFT_ROOT:-}"
BUILD_APP="${OPENCLOUD_BUILD_APP:-}"
SKIP_NOTARIZE=false
BUNDLE_ONLY=false
UPLOAD_TAG=""

usage() {
    echo "Usage: $0 --craft-root DIR --build-app APP [--team-id ID --sign-id IDENTITY]"
    echo "  [--notary-profile NAME] [--skip-notarize] [--bundle-only] [--upload TAG]"
    echo "Paths and identities may also be set with OPENCLOUD_* environment variables."
}
while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-notarize) SKIP_NOTARIZE=true; shift ;;
        --bundle-only) BUNDLE_ONLY=true; shift ;;
        --craft-root|--build-app|--team-id|--sign-id|--notary-profile|--upload)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            case "$1" in
                --craft-root) CRAFT_ROOT="$2" ;;
                --build-app) BUILD_APP="$2" ;;
                --team-id) TEAM_ID="$2" ;;
                --sign-id) SIGN_ID="$2" ;;
                --notary-profile) NOTARY_PROFILE="$2" ;;
                --upload) UPLOAD_TAG="$2" ;;
            esac
            shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done
[ -n "$CRAFT_ROOT" ] && [ -d "$BUILD_APP" ] || { usage >&2; exit 2; }
if [ "$BUNDLE_ONLY" = true ] && [ -n "$UPLOAD_TAG" ]; then
    echo "ERROR: --bundle-only cannot upload a release" >&2; exit 2
fi
if [ "$BUNDLE_ONLY" = false ]; then
    [[ "$TEAM_ID" =~ ^[A-Z0-9]+$ ]] && [ -n "$SIGN_ID" ] || { usage >&2; exit 2; }
    if [ "$SKIP_NOTARIZE" = false ] && [ -z "$NOTARY_PROFILE" ]; then
        echo "ERROR: --notary-profile is required for notarization" >&2; exit 2
    fi
fi
CRAFT_LIB="$CRAFT_ROOT/lib"
CRAFT_PLUGINS="$CRAFT_ROOT/plugins"
CRAFT_QML="$CRAFT_ROOT/qml"
BUILD_BIN=$(cd "$(dirname "$BUILD_APP")" && pwd)
STAGE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/opencloud-ship.XXXXXX")
STAGE_APP="$STAGE_DIR/OpenCloud.app"

# ─── HELPERS ─────────────────────────────────────────────────────────────────

STEP=0
step() {
    STEP=$((STEP + 1))
    echo ""
    echo "[$STEP] $1"
}

sign_binary() {
    local bin="$1"
    local entitlements="${2:-}"
    local args=(--force --options runtime --timestamp --sign "$SIGN_ID")
    if [ -n "$entitlements" ]; then
        args+=(--entitlements "$entitlements")
    fi
    codesign "${args[@]}" "$bin"
}

# ─── ENTITLEMENTS ────────────────────────────────────────────────────────────

ENTITLEMENTS_DIR="$STAGE_DIR/entitlements"
mkdir -p "$ENTITLEMENTS_DIR"

cat > "$ENTITLEMENTS_DIR/app.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.application-groups</key>
	<array>
		<string>${TEAM_ID}.eu.opencloud.desktop</string>
	</array>
</dict>
</plist>
PLIST

cat > "$ENTITLEMENTS_DIR/appex.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key>
	<true/>
	<key>com.apple.security.application-groups</key>
	<array>
		<string>${TEAM_ID}.eu.opencloud.desktop</string>
	</array>
	<key>com.apple.security.network.client</key>
	<true/>
</dict>
</plist>
PLIST

# ─── PREFLIGHT ───────────────────────────────────────────────────────────────

step "Preflight checks"

if [ ! -d "$BUILD_APP" ]; then
    echo "ERROR: Build app not found at $BUILD_APP"
    echo "Run the build first: pwsh .github/workflows/.craft.ps1 -c --compile opencloud/opencloud-desktop"
    exit 1
fi

if [ "$BUNDLE_ONLY" = false ] && ! security find-identity -v -p codesigning | grep -Fq -- "$SIGN_ID"; then
    echo "ERROR: Requested signing identity not found: $SIGN_ID" >&2
    exit 1
fi

VERSION=$(defaults read "$BUILD_APP/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "unknown")
ARCH=$(lipo -archs "$BUILD_APP/Contents/MacOS/OpenCloud" | tr ' ' '+')
DMG_NAME="OpenCloud-v${VERSION}-macOS-${ARCH}.dmg"
DMG_PATH="$STAGE_DIR/$DMG_NAME"

echo "  Version: $VERSION"
echo "  Arch:    $ARCH"
echo "  Output:  $DMG_PATH"

# ─── STAGE ───────────────────────────────────────────────────────────────────

step "Staging app bundle"

cp -R "$BUILD_APP" "$STAGE_APP"
echo "  Copied to $STAGE_APP"

# ─── QT PLUGINS ─────────────────────────────────────────────────────────────

step "Bundling Qt plugins"

PLUGIN_DIR="$STAGE_APP/Contents/PlugIns"

# Qt plugin categories needed at runtime
QT_PLUGIN_DIRS=(platforms imageformats styles tls iconengines sqldrivers)

for plugin_cat in "${QT_PLUGIN_DIRS[@]}"; do
    src_dir="$CRAFT_PLUGINS/$plugin_cat"
    dst_dir="$PLUGIN_DIR/$plugin_cat"
    if [ -d "$src_dir" ]; then
        mkdir -p "$dst_dir"
        for dylib in "$src_dir"/*.dylib; do
            [ -f "$dylib" ] || continue
            cp "$dylib" "$dst_dir/"
            echo "  + $plugin_cat/$(basename "$dylib")"
        done
    else
        echo "ERROR: Required Qt plugin directory missing: $src_dir" >&2
        exit 1
    fi
done

# ─── QML MODULES ────────────────────────────────────────────────────────────

step "Bundling QML modules"

QML_DIR="$STAGE_APP/Contents/Resources/qml"
mkdir -p "$QML_DIR"

# Copy required QML module trees
QML_MODULES=(QtQuick QtQml QtCore eu)

for mod in "${QML_MODULES[@]}"; do
    if [ "$mod" = eu ] && [ -d "$BUILD_BIN/eu" ]; then
        cp -R "$BUILD_BIN/eu" "$QML_DIR/"
        echo "  + eu/ (current build)"
    elif [ -d "$CRAFT_QML/$mod" ]; then
        cp -R "$CRAFT_QML/$mod" "$QML_DIR/"
        echo "  + $mod/"
    else
        echo "ERROR: Required QML module missing: $mod" >&2
        exit 1
    fi
done

# Also copy top-level qmldir/qmltypes if present
for f in "$CRAFT_QML"/builtins.qmltypes "$CRAFT_QML"/jsroot.qmltypes; do
    [ -f "$f" ] && cp "$f" "$QML_DIR/"
done

# qt.conf tells Qt where to find plugins and QML modules
mkdir -p "$STAGE_APP/Contents/Resources"
cat > "$STAGE_APP/Contents/Resources/qt.conf" << 'QTCONF'
[Paths]
Plugins = PlugIns
QmlImports = Resources/qml
QTCONF

echo "  Created qt.conf"

# ─── BUNDLE DYLIBS ──────────────────────────────────────────────────────────

step "Bundling dylibs and frameworks"

FW_DIR="$STAGE_APP/Contents/Frameworks"
mkdir -p "$FW_DIR"

python3 "$SCRIPT_DIR/macos_bundle.py" "$STAGE_APP" --search "$BUILD_BIN" --search "$CRAFT_LIB"
if [ "$BUNDLE_ONLY" = true ]; then
    echo "Verified unsigned bundle: $STAGE_APP"
    exit 0
fi

# ─── CODESIGN ────────────────────────────────────────────────────────────────

step "Signing with Developer ID (inside-out)"

# Re-signing with another team must also update extension container metadata.
python3 - "$STAGE_APP" "$TEAM_ID" <<'PYINFO'
from pathlib import Path
import plistlib
import sys
app = Path(sys.argv[1])
group = sys.argv[2] + '.eu.opencloud.desktop'
host_info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
for name in ('FileProviderExt', 'FinderSyncExt'):
    path = app / 'Contents/PlugIns' / (name + '.appex') / 'Contents/Info.plist'
    if not path.exists():
        raise SystemExit(f'Required extension is missing: {name}')
    info = plistlib.loads(path.read_bytes())
    for key in ('CFBundleVersion', 'CFBundleShortVersionString'):
        info[key] = host_info[key]
    if name == 'FileProviderExt':
        info['AppGroupIdentifier'] = group
        info['NSExtension']['NSExtensionFileProviderDocumentGroup'] = group
    else:
        info['SocketApiPrefix'] = group
    path.write_bytes(plistlib.dumps(info))
PYINFO


# 1. Frameworks and dylibs
echo "  Signing frameworks and dylibs..."
for fw in "$FW_DIR"/*.framework; do
    [ -d "$fw" ] || continue
    sign_binary "$fw"
done
for lib in "$FW_DIR"/*.dylib; do
    [ -f "$lib" ] || continue
    sign_binary "$lib"
done

# 2. Qt plugins (in subdirectories)
echo "  Signing Qt plugins..."
for plugin_cat in "${QT_PLUGIN_DIRS[@]}"; do
    for plib in "$STAGE_APP/Contents/PlugIns/$plugin_cat"/*.dylib; do
        [ -f "$plib" ] || continue
        sign_binary "$plib"
    done
done

# 2b. QML module dylibs
echo "  Signing QML module plugins..."
while IFS= read -r qml_dylib; do
    sign_binary "$qml_dylib"
done < <(find "$STAGE_APP/Contents/Resources/qml" -name '*.dylib' -type f 2>/dev/null)

# 3. PlugIns — standalone binaries (.so)
echo "  Signing VFS plugins..."
for so in "$STAGE_APP/Contents/PlugIns"/*.so; do
    [ -f "$so" ] || continue
    sign_binary "$so"
done

# 4. FinderSyncExt.appex
if [ -d "$STAGE_APP/Contents/PlugIns/FinderSyncExt.appex" ]; then
    echo "  Signing FinderSyncExt.appex..."
    sign_binary "$STAGE_APP/Contents/PlugIns/FinderSyncExt.appex" "$ENTITLEMENTS_DIR/appex.plist"
fi

# 5. FileProvider extension uses the standard macOS Keychain for Developer ID builds.
sign_binary "$STAGE_APP/Contents/PlugIns/FileProviderExt.appex" "$ENTITLEMENTS_DIR/appex.plist"

# 6. Helper executables
echo "  Signing helper executables..."
for helper in "$STAGE_APP/Contents/MacOS/opencloudcmd" "$STAGE_APP/Contents/MacOS/opencloud_crash_reporter"; do
    [ -f "$helper" ] || continue
    sign_binary "$helper"
done

# 7. Main app (last)
echo "  Signing OpenCloud.app..."
sign_binary "$STAGE_APP" "$ENTITLEMENTS_DIR/app.plist"

# Verify
codesign --verify --deep --strict "$STAGE_APP" 2>&1
echo "  Signature verified"

# ─── CREATE DMG ──────────────────────────────────────────────────────────────

step "Creating DMG"

rm -f "$DMG_PATH"

# Build a temp folder with app + Applications symlink for drag-to-install
DMG_STAGE="$STAGE_DIR/dmg-stage"
rm -rf "$DMG_STAGE"
mkdir -p "$DMG_STAGE"
cp -R "$STAGE_APP" "$DMG_STAGE/"
ln -s /Applications "$DMG_STAGE/Applications"

hdiutil create -volname "OpenCloud" -srcfolder "$DMG_STAGE" -ov -format UDZO "$DMG_PATH" 2>&1
rm -rf "$DMG_STAGE"
sign_binary "$DMG_PATH"
echo "  Created: $DMG_PATH"
ls -lh "$DMG_PATH"

# ─── NOTARIZE ────────────────────────────────────────────────────────────────

if [ "$SKIP_NOTARIZE" = false ]; then
    step "Submitting for notarization"

    xcrun notarytool submit "$DMG_PATH" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait --verbose 2>&1

    step "Stapling notarization ticket"
    xcrun stapler staple "$DMG_PATH" 2>&1
    echo "  Done"
else
    echo ""
    echo "  (Skipping notarization — use without --skip-notarize for full pipeline)"
fi

# ─── UPLOAD ──────────────────────────────────────────────────────────────────

if [ -n "$UPLOAD_TAG" ]; then
    step "Uploading to GitHub release $UPLOAD_TAG"
    gh release upload "$UPLOAD_TAG" "$DMG_PATH" --clobber 2>&1
    echo "  Uploaded: $DMG_NAME"
    gh release view "$UPLOAD_TAG" --json url --jq .url
fi

# ─── DONE ────────────────────────────────────────────────────────────────────

echo ""
echo "=== Ship complete ==="
echo "  DMG: $DMG_PATH"
echo "  Size: $(du -h "$DMG_PATH" | awk '{print $1}')"
if [ "$SKIP_NOTARIZE" = false ]; then
    echo "  Notarized: yes"
fi
if [ -n "$UPLOAD_TAG" ]; then
    echo "  Uploaded: $UPLOAD_TAG"
fi
