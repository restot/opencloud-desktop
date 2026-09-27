## Implementation
- [x] Select on-demand files by default when the extension is compatible.
- [x] Add the traditional folder sync preference and restart action.
- [x] Keep traditional sync inactive in on-demand mode and preserve saved folders.
- [x] Disconnect existing on-demand domains before traditional sync starts.
- [x] Update account setup and account settings for the active provider.
- [x] Build and run provider-selection and folder-manager regression tests.
- [x] Validate the specification and formatting.

## Manual validation
- [ ] Verify both switch directions with a signed app and a connected account, including Finder access, pending local changes and app relaunch. Tracked in bd-22q.

## Validation performed
- Built `opencloud`, `testsyncproviderselection` and `testfolderman` using the existing macOS Craft build.
- Both CTest suites passed with `DYLD_LIBRARY_PATH` pointing to the build's `bin` directory, so tests load the newly built libraries instead of the installed Craft copies.
- OpenSpec strict validation and diff formatting checks passed.
