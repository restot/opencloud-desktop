# Testing

Running and adding tests for OpenCloud Desktop.

## Running tests

```bash
# From Craft
pwsh .github/workflows/.craft.ps1 -c --test opencloud/opencloud-desktop

# From a configured build directory
ctest --output-on-failure
ctest -R testname --output-on-failure
ctest -V
./bin/testsyncengine
```

Test binaries are in the configured build directory's `bin/` folder and generally follow the pattern `test<classname>`.

## macOS FileProvider regression checks

The PR review's final selected CTest run passed all 11 suites on September 26, 2026. Run the same selection from the configured build directory:

```bash
ctest --output-on-failure -R '^(testcrashserver|testmacosbundle|testutility|testdownload|testfolderman|testsyncproviderselection|testfileproviderlifecycle|testmacsocketapi|testfileprovider_database|testfileprovider_webdav|testfileprovider_sockets)$'
```

The Swift and helper suites can also run from the repository root:

```bash
bash tools/test-fileprovider-database.sh
bash tools/test-fileprovider-webdav.sh
bash tools/test-fileprovider-sockets.sh
python3 -m unittest discover -s test -p test_crash_server.py
python3 -m unittest discover -s test -p test_macos_bundle.py
```

The Swift scripts need macOS and Xcode command-line tools. The database script includes observer tests for paging, cancellation, identity recovery, and change enumeration. The WebDAV suite uses controlled transport responses. Native domain/XPC tests inject lifecycle failures without configuring real accounts. Bundle tests compile small fixtures and verify relocation and dependency rejection.

To check both extension architectures without signing:

```bash
xcodebuild \
  -project shell_integration/MacOSX/OpenCloudFinderExtension/OpenCloudFinderExtension.xcodeproj \
  -target FileProviderExt -configuration Debug \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO

xcodebuild \
  -project shell_integration/MacOSX/OpenCloudFinderExtension/OpenCloudFinderExtension.xcodeproj \
  -target FinderSyncExt -configuration Debug \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO
```

These builds check compilation and linking. They do not exercise Keychain access, signed XPC authorization, or Finder's provider lifecycle.

## Signed Finder exercise

Use the disposable signed host to test the extension without real account credentials. Prerequisites are a built FileProviderExt.appex, an available signing identity, its Team ID, Xcode tools, and an interactive macOS session.

```bash
python3 tools/test-fileprovider-signed.py \
  --extension "/absolute/path/to/FileProviderExt.appex" \
  --sign-id "Developer ID Application: YOUR NAME (TEAMID)" \
  --team-id "TEAMID" \
  --interactive \
  --bundle-id eu.opencloud.desktop.review.local
```

When prompted, enable **OpenCloud Isolated Test** under **System Settings > General > Login Items & Extensions > File Providers**. Reusing the isolated bundle ID avoids creating a new provider preference for each run. The script requires the `eu.opencloud.desktop.review.` prefix for an explicitly supplied bundle ID.

The script creates a temporary host, signs a copy of the extension, starts a loopback DAV fixture, and registers two disposable domains. It checks trusted and foreign XPC callers, Keychain configuration, Finder enumeration/hydration, account isolation, upload/rename/delete, offline hydrated reads, eviction/relaunch, credential revocation and fresh sign-in, disconnect/reconnect, and removal. Cleanup removes its domains and unregisters the temporary bundle.

Omit `--interactive` for the native service exercise without the Finder I/O portion. `--probe-missing-extension` additionally inspects discovery after temporarily removing the test extension. Run `--help` for all arguments. This signed test is intentionally separate from unattended CTest because provider activation requires a user session and may require the Settings step.

The final interactive run passed on the development Mac. Its scope is the signed fixture host and local DAV server. It is not a clean-machine, notarization, production-server, or shipped Settings UI certification. See [macos-vfs-review.md](macos-vfs-review.md) for the verified scope and identity limitations.

## Adding tests

C++ tests use `opencloud_add_test()` from `test/opencloud_add_test.cmake`:

```cmake
opencloud_add_test(MyNewFeature)
```

This expects `test/testmynewfeature.cpp` with a Qt Test class. It links against `OpenCloudGui`, `syncenginetestutils`, `testutilsloader`, and `Qt::Test`.

Tests are built with `QT_FORCE_ASSERTS`. Linux/Windows tests run with `QT_QPA_PLATFORM=offscreen`. macOS FileProvider scripts and Python helper checks are registered separately in `test/CMakeLists.txt`.

For full-client manual tests, install each build at the same local app path and keep the same signing identity. Switching from Apple Development to Developer ID changes the app's Keychain trust requirement. Approve credential access with Always Allow after checking the app identity; repeated launches from temporary bundle locations are unsuitable for testing persistent Keychain access.
