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

# Collect all deps: both @rpath and absolute Craft paths
collect_deps() {
    local dir="$1"
    local deps=""
    while IFS= read -r bin; do
        local bin_deps
        # @rpath deps → strip prefix
        bin_deps=$(otool -L "$bin" 2>/dev/null | grep '@rpath/' | awk '{print $1}' | sed 's|@rpath/||' || true)
        if [ -n "$bin_deps" ]; then
            deps="$deps"$'\n'"$bin_deps"
        fi
        # Absolute Craft lib paths → extract basename
        bin_deps=$(otool -L "$bin" 2>/dev/null | grep "$HOME/Documents/craft/" | awk '{print $1}' || true)
        if [ -n "$bin_deps" ]; then
            while IFS= read -r abspath; do
                deps="$deps"$'\n'"$(basename "$abspath")"
            done <<< "$bin_deps"
        fi
    done < <(find "$dir" -type f -exec sh -c 'file "$1" 2>/dev/null | grep -q "Mach-O"' _ {} \; -print)
    echo "$deps" | sort -u | grep -v '^$' || true
}

RPATH_NEW="@executable_path/../Frameworks"

# Rewrite absolute paths and rpaths on all Mach-O binaries in the staged app
fix_paths() {
    while IFS= read -r bin; do
        # Remove old absolute rpaths (LC_RPATH entries)
        for old_rpath in $(otool -l "$bin" 2>/dev/null | grep -A2 LC_RPATH | grep 'path /Users' | awk '{print $2}' || true); do
            install_name_tool -delete_rpath "$old_rpath" "$bin" 2>/dev/null || true
        done
        # Rewrite absolute Craft lib paths in LC_LOAD_DYLIB to @rpath/name
        for abs_dep in $(otool -L "$bin" 2>/dev/null | grep "$HOME/Documents/craft/" | awk '{print $1}' || true); do
            local_name=$(basename "$abs_dep")
            install_name_tool -change "$abs_dep" "@rpath/$local_name" "$bin" 2>/dev/null || true
        done
        # Rewrite the library's own install name if it's an absolute craft path
        old_id=$(otool -D "$bin" 2>/dev/null | tail -1 || true)
        if [[ "$old_id" == *"/Documents/craft/"* ]]; then
            install_name_tool -id "@rpath/$(basename "$old_id")" "$bin" 2>/dev/null || true
        fi
        # Add @executable_path/../Frameworks if missing
        if ! otool -l "$bin" 2>/dev/null | grep -q "$RPATH_NEW"; then
            install_name_tool -add_rpath "$RPATH_NEW" "$bin" 2>/dev/null || true
        fi
    done < <(find "$STAGE_APP" -type f -exec sh -c 'file "$1" 2>/dev/null | grep -q "Mach-O"' _ {} \; -print)
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

# 2. PlugIns — standalone binaries
echo "  Signing plugins..."
for so in "$STAGE_APP/Contents/PlugIns"/*.so; do
    [ -f "$so" ] || continue
    sign_binary "$so"
done

# 3. FinderSyncExt.appex
if [ -d "$STAGE_APP/Contents/PlugIns/FinderSyncExt.appex" ]; then
    echo "  Signing FinderSyncExt.appex..."
    sign_binary "$STAGE_APP/Contents/PlugIns/FinderSyncExt.appex"
fi

# 4. FileProviderExt.appex (with entitlements)
if [ -d "$STAGE_APP/Contents/PlugIns/FileProviderExt.appex" ]; then
    echo "  Signing FileProviderExt.appex..."
    sign_binary "$STAGE_APP/Contents/PlugIns/FileProviderExt.appex" "$ENTITLEMENTS_DIR/appex.plist"
fi

# 5. Helper executables
echo "  Signing helper executables..."
for helper in "$STAGE_APP/Contents/MacOS/opencloudcmd" "$STAGE_APP/Contents/MacOS/opencloud_crash_reporter"; do
    [ -f "$helper" ] || continue
    sign_binary "$helper"
done

# 6. Main app (last)
echo "  Signing OpenCloud.app..."
sign_binary "$STAGE_APP" "$ENTITLEMENTS_DIR/app.plist"

# Verify
codesign --verify --deep --strict "$STAGE_APP" 2>&1
echo "  Signature verified"

# ─── CREATE DMG ──────────────────────────────────────────────────────────────

step "Creating DMG"

rm -f "$DMG_PATH"
hdiutil create -volname "OpenCloud" -srcfolder "$STAGE_APP" -ov -format UDZO "$DMG_PATH" 2>&1
sign_binary "$DMG_PATH"
echo "  Created: $DMG_PATH"
ls -lh "$DMG_PATH"

# ─── NOTARIZE ────────────────────────────────────────────────────────────────

if [ "$SKIP_NOTARIZE" = false ]; then
    step "Submitting for notarization"

    xcrun notarytool submit "$DMG_PATH" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait 2>&1

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
