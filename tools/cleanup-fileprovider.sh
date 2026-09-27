#!/bin/bash
# cleanup-fileprovider.sh — Full cleanup, build, sign, deploy of OpenCloud FileProvider
#
# Usage:
#   tools/cleanup-fileprovider.sh          # cleanup + build + deploy + launch
#   tools/cleanup-fileprovider.sh --clean   # cleanup only (no build)
#   tools/cleanup-fileprovider.sh --build   # build + sign + deploy + launch only (no cleanup)
set -euo pipefail

APP_GROUP="S6P3V9X548.eu.opencloud.desktop"
BUNDLE_ID="eu.opencloud.desktop"
SIGN_ID="Apple Development: 92ilya.icom@gmail.com (6WXWTD3UHN)"
CRAFT_BASE="$HOME/Documents/craft/macos-clang-arm64"
BUILD_APP="$CRAFT_BASE/build/opencloud/opencloud-desktop/work/build/bin/OpenCloud.app"
APP_BINARY="${OPENCLOUD_APP:-$BUILD_APP/Contents/MacOS/OpenCloud}"
DEPLOY_APP="/Applications/OpenCloud.app"

EXT_ENTITLEMENTS='<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>com.apple.security.app-sandbox</key><true/><key>com.apple.security.application-groups</key><array><string>S6P3V9X548.eu.opencloud.desktop</string></array><key>com.apple.security.network.client</key><true/></dict></plist>'

APP_ENTITLEMENTS='<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>com.apple.security.application-groups</key><array><string>S6P3V9X548.eu.opencloud.desktop</string></array></dict></plist>'

MODE="${1:-all}"
DO_CLEAN=true
DO_BUILD=true
case "$MODE" in
    --clean) DO_BUILD=false ;;
    --build) DO_CLEAN=false ;;
    all|"")  ;; # both
    *) echo "Usage: $0 [--clean|--build]"; exit 1 ;;
esac

# ─── CLEANUP ─────────────────────────────────────────────────────────────────

cleanup() {
    echo "=== OpenCloud FileProvider Cleanup ==="
    echo ""

    # Step 1: Kill OpenCloud and extension processes
    echo "[1/7] Killing OpenCloud processes..."
    pkill -x OpenCloud 2>/dev/null && echo "  Killed OpenCloud" || echo "  OpenCloud not running"
    pkill -f "FileProviderExt" 2>/dev/null && echo "  Killed FileProviderExt" || echo "  FileProviderExt not running"
    pkill -f "FinderSyncExt" 2>/dev/null && echo "  Killed FinderSyncExt" || echo "  FinderSyncExt not running"
    sleep 1

    # Step 2: Remove duplicate app bundles that confuse macOS extension discovery.
    echo ""
    echo "[2/7] Removing duplicate app bundles..."
    if [ -d "$DEPLOY_APP" ]; then
        echo "  Removing: $DEPLOY_APP (deploy copy)"
        rm -rfv "$DEPLOY_APP"
    fi
    for search_id in "$BUNDLE_ID" "eu.opencloud.desktopclient"; do
        while IFS= read -r app_path; do
            [ -z "$app_path" ] && continue
            if [ "$app_path" != "$BUILD_APP" ]; then
                echo "  Removing: $app_path"
                rm -rfv "$app_path"
            else
                echo "  Keeping:  $app_path (build dir)"
            fi
        done < <(mdfind "kMDItemCFBundleIdentifier == '$search_id'" 2>/dev/null)
    done
    for dd in ~/Library/Developer/Xcode/DerivedData/OpenCloudFinderExtension-*/; do
        [ -d "$dd" ] || continue
        echo "  Removing DerivedData: $dd"
        rm -rfv "$dd"
    done

    echo "  Resetting LaunchServices database..."
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
        -kill -r -domain local -domain system -domain user 2>/dev/null && echo "  Done" || echo "  lsregister not available"

    # Step 3: Remove all FileProvider domains
    echo ""
    echo "[3/7] Removing FileProvider domains..."
    if [ -x "$APP_BINARY" ]; then
        "$APP_BINARY" --clear-fileprovider-domains 2>&1 | while read -r line; do echo "  $line"; done
        echo "  Done"
    else
        echo "  WARNING: App binary not found at $APP_BINARY — skipping domain removal."
    fi

    echo "  Restarting fileproviderd to release CloudStorage locks..."
    killall fileproviderd 2>/dev/null && echo "  Restarted fileproviderd" || echo "  fileproviderd not running"
    sleep 3

    # Step 4: Clean up item databases
    echo ""
    echo "[4/7] Cleaning item databases..."
    DB_DIR="$HOME/Library/Group Containers/$APP_GROUP/FileProvider"
    if [ -d "$DB_DIR" ]; then
        find "$DB_DIR" -name "items-*.sqlite" -exec rm -v {} \;
    else
        echo "  No database directory found"
    fi

    # Step 5: Clear cached credentials
    echo ""
    echo "[5/7] Clearing cached credentials..."
    defaults delete "$APP_GROUP" 2>/dev/null && echo "  Cleared UserDefaults for $APP_GROUP" || echo "  No cached credentials found"

    # Step 6: Clean up CloudStorage folders
    echo ""
    echo "[6/7] Cleaning CloudStorage folders..."
    CLOUD_DIR="$HOME/Library/CloudStorage"
    if [ -d "$CLOUD_DIR" ]; then
        removed=0
        failed=0
        for folder in "$CLOUD_DIR"/OpenCloud-*; do
            [ -e "$folder" ] || continue
            if [ -d "$folder/.Trash" ]; then
                rm -rfv "$folder/.Trash"/* 2>/dev/null || true
                rm -rfv "$folder/.Trash" 2>/dev/null || true
            fi
            if rm -rfv "$folder" 2>/dev/null; then
                echo "  Removed: $folder"
                removed=$((removed + 1))
            else
                echo "  FAILED: $folder (still locked by fileproviderd)"
                failed=$((failed + 1))
            fi
        done
        if [ $removed -eq 0 ] && [ $failed -eq 0 ]; then
            echo "  No OpenCloud CloudStorage folders found"
        fi
        if [ $failed -gt 0 ]; then
            echo "  Retrying after fileproviderd restart..."
            killall fileproviderd 2>/dev/null || true
            sleep 3
            for folder in "$CLOUD_DIR"/OpenCloud-*; do
                [ -e "$folder" ] || continue
                rm -rfv "$folder" 2>/dev/null && echo "  Removed (retry): $folder" || echo "  STILL LOCKED: $folder — reboot may be required"
            done
        fi
    else
        echo "  No CloudStorage directory"
    fi

    # Step 7: Final fileproviderd restart
    echo ""
    echo "[7/7] Restarting fileproviderd..."
    killall fileproviderd 2>/dev/null && echo "  Restarted fileproviderd (system will auto-relaunch)" || echo "  fileproviderd already restarted"

    echo ""
    echo "=== Cleanup complete ==="
}

# ─── BUILD + SIGN + DEPLOY ───────────────────────────────────────────────────

build_and_deploy() {
    echo ""
    echo "=== Build, Sign & Deploy ==="
    echo ""

    # Kill if still running
    pkill -x OpenCloud 2>/dev/null || true
    sleep 1

    # Build
    echo "[1/5] Building with Craft..."
    pwsh .github/workflows/.craft.ps1 -c --compile opencloud/opencloud-desktop

    # Copy dylibs
    echo ""
    echo "[2/5] Copying dylibs..."
    find "$CRAFT_BASE/build/opencloud/opencloud-desktop/work/build/bin" \
        -maxdepth 1 -name "libOpenCloud*.dylib" -exec cp {} "$CRAFT_BASE/lib/" \;
    echo "  Done"

    # Re-sign extension (no get-task-allow — required for pluginkit discovery)
    echo ""
    echo "[3/5] Re-signing extension..."
    codesign --force --sign "$SIGN_ID" \
        --entitlements /dev/stdin --timestamp=none \
        "$BUILD_APP/Contents/PlugIns/FileProviderExt.appex" <<< "$EXT_ENTITLEMENTS"
    echo "  Done"

    # Re-sign app
    echo ""
    echo "[4/5] Re-signing app..."
    codesign --force --sign "$SIGN_ID" \
        --entitlements /dev/stdin --timestamp=none \
        "$BUILD_APP" <<< "$APP_ENTITLEMENTS"
    echo "  Done"

    # Deploy to /Applications (pluginkit only finds extensions from registered locations)
    echo ""
    echo "[5/5] Deploying to $DEPLOY_APP..."
    rm -rf "$DEPLOY_APP"
    cp -R "$BUILD_APP" "$DEPLOY_APP"
    echo "  Done"

    # Launch
    echo ""
    echo "=== Launching OpenCloud ==="
    open "$DEPLOY_APP"
    echo ""
    echo "NOTE: FileProvider extensions only work from /Applications (registered location)."
    echo "Log in to register the FileProvider domain."
}

# ─── MAIN ────────────────────────────────────────────────────────────────────

if $DO_CLEAN; then
    cleanup
fi

if $DO_BUILD; then
    build_and_deploy
fi
