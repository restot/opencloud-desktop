# Changelog

## [0.2](https://github.com/restot/opencloud-desktop/releases/tag/v0.2) - 2026-02-18

### 🍎 macOS FileProvider VFS

Initial implementation of macOS FileProvider integration, enabling native Finder integration with OpenCloud via the FileProvider framework.

### 🐛 Bug Fixes

- Fix non-blocking XPC connection: use `dispatch_group_notify` instead of `dispatch_group_wait` to avoid deadlocking the Qt main thread [[31887066a](https://github.com/restot/opencloud-desktop/commit/31887066a)]
- Don't disconnect/unauthenticate FileProvider domain on transient `Disconnected` state — network hiccups cause rapid state cycling that disables the extension [[31887066a](https://github.com/restot/opencloud-desktop/commit/31887066a)]
- Don't clear registered domains on `removeAllDomains` timeout to prevent duplicate domain registrations [[31887066a](https://github.com/restot/opencloud-desktop/commit/31887066a)]
- Fix `dispatch_group_wait` indefinite blocking in XPC connection setup [[c191763dd](https://github.com/restot/opencloud-desktop/commit/c191763dd)]
- Fix NULL crash and O(n) recursive delete in ItemDatabase [[daa8cb6ee](https://github.com/restot/opencloud-desktop/commit/daa8cb6ee)]
- Fix ARC bridging cast errors in FileProvider .mm files [[8e2142118](https://github.com/restot/opencloud-desktop/commit/8e2142118)]
- Correct bandwidth typo and revert propagator to unique_ptr [[c29d24c1d](https://github.com/restot/opencloud-desktop/commit/c29d24c1d)]

### 📈 Enhancement

- FileProvider item capabilities: reading is always implicit for PROPFIND-returned items; folders always get content enumeration [[31887066a](https://github.com/restot/opencloud-desktop/commit/31887066a)]
- Add explicit `authType` (bearer/basic) to XPC credential protocol [[e3666c957](https://github.com/restot/opencloud-desktop/commit/e3666c957), [8c66ef5e5](https://github.com/restot/opencloud-desktop/commit/8c66ef5e5)]
- Auto-authenticate FileProvider domains after XPC connections are established [[31887066a](https://github.com/restot/opencloud-desktop/commit/31887066a)]
- Enable ARC for all FileProvider .mm files [[49986a4bb](https://github.com/restot/opencloud-desktop/commit/49986a4bb)]
- Set `DEVELOPMENT_TEAM` in Xcode project for all targets [[31887066a](https://github.com/restot/opencloud-desktop/commit/31887066a)]

### 🔧 Tooling

- Add `tools/cleanup-fileprovider.sh`: all-in-one cleanup, build, sign, and deploy script with `--clean` and `--build` modes

## [3.0.0](https://github.com/opencloud-eu/desktop/releases/tag/v3.0.0) - 2025-11-25

### ❤️ Thanks to all contributors! ❤️

@Copilot, @K900, @Svanvith, @TheOneRing, @anon-pradip, @fschade, @individual-it, @jnweiger, @kulmann, @prashant-gurung899, @saw-jan

### 💥 Breaking changes

- Remove unused code from UploadInfo [[#637](https://github.com/opencloud-eu/desktop/pull/637)]
- Implement a beta channel branding [[#489](https://github.com/opencloud-eu/desktop/pull/489)]
- Use utf16 for the rotating log, to reduce string conversions [[#467](https://github.com/opencloud-eu/desktop/pull/467)]
- Remove unused fields in sqlite table [[#419](https://github.com/opencloud-eu/desktop/pull/419)]
- Add Windows VFS [[#305](https://github.com/opencloud-eu/desktop/pull/305)]
- Enable http2 support by default [[#333](https://github.com/opencloud-eu/desktop/pull/333)]

### 🐛 Bug Fixes

- Terminate sync before an account is removed [[#699](https://github.com/opencloud-eu/desktop/pull/699)]
- Abort if tus did not receive a location header and the upload is not … [[#693](https://github.com/opencloud-eu/desktop/pull/693)]
- Ensure that a retry happens after the minimal ignorelist timeout [[#664](https://github.com/opencloud-eu/desktop/pull/664)]
- Eit error if .well-known was not found [[#663](https://github.com/opencloud-eu/desktop/pull/663)]
- Fix enqueing of paused folders [[#662](https://github.com/opencloud-eu/desktop/pull/662)]
- Pause sync before we terminate [[#642](https://github.com/opencloud-eu/desktop/pull/642)]
- Make sync scheduling more predictable [[#641](https://github.com/opencloud-eu/desktop/pull/641)]
- Don't persist invalid upload info [[#638](https://github.com/opencloud-eu/desktop/pull/638)]
- Fix quota not display until folder synced [[#622](https://github.com/opencloud-eu/desktop/pull/622)]
- Don't use mtime -1  [[#616](https://github.com/opencloud-eu/desktop/pull/616)]
- Properly abort sync on error [[#611](https://github.com/opencloud-eu/desktop/pull/611)]
- Fix plugin loading with ecm 6.19 [[#608](https://github.com/opencloud-eu/desktop/pull/608)]
- Modify APPLICATION_REV_DOMAIN in beta builds to make coinstallable [[#587](https://github.com/opencloud-eu/desktop/pull/587)]
- Only count enabled spaces when computing the number of spaces to sync [[#571](https://github.com/opencloud-eu/desktop/pull/571)]
- Abort sync if connection is lost [[#562](https://github.com/opencloud-eu/desktop/pull/562)]
- Fix: Attempted sync on non syncable Folder [[#533](https://github.com/opencloud-eu/desktop/pull/533)]
- Don't mark restorations as excluded [[#498](https://github.com/opencloud-eu/desktop/pull/498)]
- Sync Scheduler: Ensure the current sync is actually running [[#452](https://github.com/opencloud-eu/desktop/pull/452)]
- Fix leak of accountstates [[#445](https://github.com/opencloud-eu/desktop/pull/445)]
- Fix color for selected space [[#437](https://github.com/opencloud-eu/desktop/pull/437)]
- Don't truncate inode on Windows [[#412](https://github.com/opencloud-eu/desktop/pull/412)]
- Fix printing of duration [[#400](https://github.com/opencloud-eu/desktop/pull/400)]
- Don't try LockFile on directories [[#366](https://github.com/opencloud-eu/desktop/pull/366)]
- OAuth: Only display user name in an error if we have one [[#355](https://github.com/opencloud-eu/desktop/pull/355)]

### 📈 Enhancement

- Ensure the version is included in the crash log [[#691](https://github.com/opencloud-eu/desktop/pull/691)]
- change help URL to the right docs URL [[#466](https://github.com/opencloud-eu/desktop/pull/466)]
- Folder watcher: ignore changes in short lived files [[#455](https://github.com/opencloud-eu/desktop/pull/455)]
- Fix assert in httplogger if a cached request is actuall send [[#456](https://github.com/opencloud-eu/desktop/pull/456)]
- Sync description and space name to Windows [[#443](https://github.com/opencloud-eu/desktop/pull/443)]
- Replace csync C code with std::filesystem [[#393](https://github.com/opencloud-eu/desktop/pull/393)]
- Remove margins around the content widgets [[#377](https://github.com/opencloud-eu/desktop/pull/377)]

### 📦️ Dependencies

- Bump actions/checkout from 5 to 6 [[#709](https://github.com/opencloud-eu/desktop/pull/709)]
- Bump actions/upload-artifact from 4 to 5 [[#620](https://github.com/opencloud-eu/desktop/pull/620)]
- Bump actions/checkout from 4 to 5 [[#502](https://github.com/opencloud-eu/desktop/pull/502)]
- Bump actions/stale from 9 to 10 [[#520](https://github.com/opencloud-eu/desktop/pull/520)]

## [2.0.0](https://github.com/opencloud-eu/desktop/releases/tag/v2.0.0) - 2025-07-03

### ❤️ Thanks to all contributors! ❤️

@TheOneRing, @anon-pradip, @individual-it, @michaelstingl, @prashant-gurung899

### 💥 Breaking changes

- Enable http2 support by default [[#333](https://github.com/opencloud-eu/desktop/pull/333)]
- Since Qt 6.8 network headers are normalized to lowercase [[#308](https://github.com/opencloud-eu/desktop/pull/308)]
- Remove Theme::linkSharing and Theme::userGroupSharing [[#279](https://github.com/opencloud-eu/desktop/pull/279)]
- Remove unsupported solid avatar color branding [[#280](https://github.com/opencloud-eu/desktop/pull/280)]
- Remove Theme::wizardUrlPostfix [[#278](https://github.com/opencloud-eu/desktop/pull/278)]
- Read preconfigured server urls [[#275](https://github.com/opencloud-eu/desktop/pull/275)]
- Require global settings to always be located in /etc/ [[#268](https://github.com/opencloud-eu/desktop/pull/268)]
- Move default exclude file to a resource [[#266](https://github.com/opencloud-eu/desktop/pull/266)]

### 🐛 Bug Fixes

- OAuth: Only display user name in an error if we have one [[#355](https://github.com/opencloud-eu/desktop/pull/355)]
- Fix reuse of existing Space folders [[#311](https://github.com/opencloud-eu/desktop/pull/311)]
- Retry oauth refresh if wellknown request failed [[#310](https://github.com/opencloud-eu/desktop/pull/310)]
- Update KDSingleApplication to 1.2.0 [[#293](https://github.com/opencloud-eu/desktop/pull/293)]
- Fix casing of Spaces [[#272](https://github.com/opencloud-eu/desktop/pull/272)]
- Restart the client if the server url changed [[#254](https://github.com/opencloud-eu/desktop/pull/254)]
- Directly schedule sync once the etag changed [[#253](https://github.com/opencloud-eu/desktop/pull/253)]
- Update quota exeeded message [[#248](https://github.com/opencloud-eu/desktop/pull/248)]
- Fix sync location with manual setup [[#243](https://github.com/opencloud-eu/desktop/pull/243)]
- Properly handle `server_error` response from IDP [[#231](https://github.com/opencloud-eu/desktop/pull/231)]

### 📈 Enhancement

-  Remove settings update from connection validator, update settings only oce per hour [[#301](https://github.com/opencloud-eu/desktop/pull/301)]
- Handle return key for the url wizard page [[#300](https://github.com/opencloud-eu/desktop/pull/300)]
- Show profile images in Desktop Client [[#297](https://github.com/opencloud-eu/desktop/pull/297)]
- Enable native tooltips for the accounts on Qt >= 6.8.3 [[#255](https://github.com/opencloud-eu/desktop/pull/255)]
- Update dependencies to Qt 6.8.3 and OpenSSL 3.4.1 [[#252](https://github.com/opencloud-eu/desktop/pull/252)]
