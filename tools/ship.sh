#!/bin/bash
# ship.sh — Bundle, sign, notarize, and package OpenCloud for distribution
#
# Usage:
#   tools/ship.sh                    # full pipeline: bundle → sign → notarize → DMG
#   tools/ship.sh --skip-notarize    # bundle + sign + DMG (no notarization)
#   tools/ship.sh --upload v0.2      # full pipeline + upload DMG to GitHub release
set -euo pipefail

# ─── CONFIG ──────────────────────────────────────────────────────────────────

TEAM_ID="S6P3V9X548"
SIGN_ID="Developer ID Application: Illia Barkov ($TEAM_ID)"
NOTARY_PROFILE="OpenCloud"

CRAFT_LIB="$HOME/Documents/craft/macos-clang-arm64/lib"
CRAFT_PLUGINS="$HOME/Documents/craft/macos-clang-arm64/plugins"
CRAFT_QML="$HOME/Documents/craft/macos-clang-arm64/qml"
BUILD_BIN="$HOME/Documents/craft/macos-clang-arm64/build/opencloud/opencloud-desktop/work/build/bin"
BUILD_APP="$BUILD_BIN/OpenCloud.app"

STAGE_DIR="/tmp/opencloud-ship"
STAGE_APP="$STAGE_DIR/OpenCloud.app"

# ─── PARSE ARGS ──────────────────────────────────────────────────────────────

SKIP_NOTARIZE=false
UPLOAD_TAG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-notarize) SKIP_NOTARIZE=true; shift ;;
        --upload) UPLOAD_TAG="$2"; shift 2 ;;
        *) echo "Usage: $0 [--skip-notarize] [--upload TAG]"; exit 1 ;;
    esac
done

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

ENTITLEMENTS_DIR="/tmp/opencloud-entitlements"
mkdir -p "$ENTITLEMENTS_DIR"

cat > "$ENTITLEMENTS_DIR/app.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.application-groups</key>
	<array>
		<string>S6P3V9X548.eu.opencloud.desktop</string>
	</array>
</dict>
</plist>
PLIST

cat > "$ENTITLEMENTS_DIR/appex.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key>
	<true/>
	<key>com.apple.security.application-groups</key>
	<array>
		<string>S6P3V9X548.eu.opencloud.desktop</string>
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

if ! security find-identity -v -p codesigning 2>&1 | grep -q "Developer ID Application"; then
    echo "ERROR: No 'Developer ID Application' certificate found in keychain"
    exit 1
fi

VERSION=$(defaults read "$BUILD_APP/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "unknown")
ARCH=$(uname -m)
DMG_NAME="OpenCloud-v${VERSION}-macOS-${ARCH}.dmg"
DMG_PATH="$STAGE_DIR/$DMG_NAME"

echo "  Version: $VERSION"
echo "  Arch:    $ARCH"
echo "  Output:  $DMG_PATH"

# ─── STAGE ───────────────────────────────────────────────────────────────────

step "Staging app bundle"

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
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
        echo "  WARNING: $src_dir not found"
    fi
done

# ─── QML MODULES ────────────────────────────────────────────────────────────

step "Bundling QML modules"

QML_DIR="$STAGE_APP/Contents/Resources/qml"
mkdir -p "$QML_DIR"

# Copy required QML module trees
QML_MODULES=(QtQuick QtQml QtCore eu)

for mod in "${QML_MODULES[@]}"; do
    if [ -d "$CRAFT_QML/$mod" ]; then
        cp -R "$CRAFT_QML/$mod" "$QML_DIR/"
        echo "  + $mod/"
    else
        echo "  WARNING: QML module $mod not found"
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

# Copy a dylib: only the exact requested file and its real target (resolve symlink chain)
copy_dylib() {
    local name="$1"

    # Already present
    [ -f "$FW_DIR/$name" ] || [ -L "$FW_DIR/$name" ] && return 0

    for src in "$BUILD_BIN" "$CRAFT_LIB"; do
        if [ -f "$src/$name" ] || [ -L "$src/$name" ]; then
            # Resolve the symlink chain to find the real file
            local current="$src/$name"
            local -a seen
            seen=()
            while [ -L "$current" ]; do
                seen+=("$current")
                local target
                target=$(readlink "$current")
                if [[ "$target" != /* ]]; then
                    target="$(dirname "$current")/$target"
                fi
                current="$target"
            done
            # Copy the real file
            cp "$current" "$FW_DIR/$(basename "$current")" 2>/dev/null || true
            # Recreate each symlink in the chain
            if [ ${#seen[@]} -gt 0 ]; then
                for link in "${seen[@]}"; do
                    local link_name
                    link_name=$(basename "$link")
                    local link_target
                    link_target=$(readlink "$link")
                    ln -sf "$link_target" "$FW_DIR/$link_name" 2>/dev/null || true
                done
            fi
            # Ensure the originally-requested name exists
            if [ ! -e "$FW_DIR/$name" ]; then
                ln -sf "$(basename "$current")" "$FW_DIR/$name" 2>/dev/null || true
            fi
            echo "  + $name (from $src)"
            return 0
        fi
    done
    echo "  WARNING: $name not found"
    return 0  # Don't fail the script
}

# Copy a Qt framework
copy_framework() {
    local fw_name="$1"
    [ -d "$FW_DIR/$fw_name" ] && return 0

    if [ -d "$CRAFT_LIB/$fw_name" ]; then
        cp -R "$CRAFT_LIB/$fw_name" "$FW_DIR/"
        echo "  + $fw_name (framework)"
    else
        echo "  WARNING: $fw_name not found in $CRAFT_LIB"
    fi
    return 0
}

# Find all Mach-O binaries (cached per pass to avoid repeated scanning)
find_machos() {
    find "$1" -type f -print0 | xargs -0 -P8 file 2>/dev/null | grep 'Mach-O' | cut -d: -f1
}

# Collect all deps: both @rpath and absolute Craft paths (parallelized)
collect_deps() {
    local dir="$1"
    find_machos "$dir" | xargs -P8 -I{} otool -L {} 2>/dev/null | awk -v home="$HOME" '
        /@rpath\// { sub(/^[[:space:]]+/, ""); sub(/ \(.*/, ""); sub(/@rpath\//, ""); print }
        index($0, home"/Documents/craft/") { sub(/^[[:space:]]+/, ""); sub(/ \(.*/, ""); n=split($0, a, "/"); print a[n] }
    ' | sort -u || true
}

RPATH_NEW="@executable_path/../Frameworks"

# Rewrite absolute paths and rpaths on a single Mach-O binary
fix_one_binary() {
    local bin="$1"
    local home="$2"
    local rpath_new="$3"
    # Remove old absolute rpaths (LC_RPATH entries)
    for old_rpath in $(otool -l "$bin" 2>/dev/null | grep -A2 LC_RPATH | grep 'path /Users' | awk '{print $2}' || true); do
        install_name_tool -delete_rpath "$old_rpath" "$bin" 2>/dev/null || true
    done
    # Rewrite absolute Craft lib paths in LC_LOAD_DYLIB to @rpath/name
    for abs_dep in $(otool -L "$bin" 2>/dev/null | grep "$home/Documents/craft/" | awk '{print $1}' || true); do
        local_name=$(basename "$abs_dep")
        install_name_tool -change "$abs_dep" "@rpath/$local_name" "$bin" 2>/dev/null || true
    done
    # Rewrite the library's own install name if it's an absolute craft path
    old_id=$(otool -D "$bin" 2>/dev/null | tail -1 || true)
    if [[ "$old_id" == *"/Documents/craft/"* ]]; then
        install_name_tool -id "@rpath/$(basename "$old_id")" "$bin" 2>/dev/null || true
    fi
    # Add @executable_path/../Frameworks if missing
    if ! otool -l "$bin" 2>/dev/null | grep -q "$rpath_new"; then
        install_name_tool -add_rpath "$rpath_new" "$bin" 2>/dev/null || true
    fi
}
export -f fix_one_binary

# Rewrite absolute paths and rpaths on all Mach-O binaries (parallelized)
fix_paths() {
    find_machos "$STAGE_APP" | xargs -P8 -I{} bash -c 'fix_one_binary "$@"' _ {} "$HOME" "$RPATH_NEW"
}

# Iteratively: copy deps → fix paths → check for new deps → repeat
for pass in 1 2 3 4 5 6 7 8; do
    deps=$(collect_deps "$STAGE_APP")
    [ -z "$deps" ] && break

    while IFS= read -r dep; do
        [ -z "$dep" ] && continue
        if [[ "$dep" == *.framework/* ]]; then
            copy_framework "${dep%%/*}"
        else
            copy_dylib "$dep"
        fi
    done <<< "$deps"

    # Fix paths after each copy pass so newly copied libs get rewritten
    fix_paths

    # Check for unresolved @rpath deps (absolute paths already rewritten)
    missing=""
    new_deps=$(collect_deps "$STAGE_APP")
    while IFS= read -r dep; do
        [ -z "$dep" ] && continue
        if [[ "$dep" == *.framework/* ]]; then
            [ ! -d "$FW_DIR/${dep%%/*}" ] && missing="$missing $dep"
        else
            [ ! -f "$FW_DIR/$dep" ] && [ ! -L "$FW_DIR/$dep" ] && missing="$missing $dep"
        fi
    done <<< "$new_deps"

    if [ -z "$missing" ]; then
        echo "  All dependencies resolved (pass $pass)"
        break
    fi

    if [ "$pass" -eq 8 ]; then
        echo "  WARNING: Unresolved after 8 passes:$missing"
    fi
done

# ─── CODESIGN ────────────────────────────────────────────────────────────────

step "Signing with Developer ID (inside-out)"

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
    sign_binary "$STAGE_APP/Contents/PlugIns/FinderSyncExt.appex"
fi

# 5. FileProviderExt.appex (with entitlements)
if [ -d "$STAGE_APP/Contents/PlugIns/FileProviderExt.appex" ]; then
    echo "  Signing FileProviderExt.appex..."
    sign_binary "$STAGE_APP/Contents/PlugIns/FileProviderExt.appex" "$ENTITLEMENTS_DIR/appex.plist"
fi

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
    echo "  https://github.com/restot/opencloud-desktop/releases/tag/$UPLOAD_TAG"
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
