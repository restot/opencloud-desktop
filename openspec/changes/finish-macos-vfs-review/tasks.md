## Implementation

- [x] Add per-space domains and guarded native lifecycle transitions.
- [x] Persist stable identities separately from metadata cache.
- [x] Bound change history, paginate results, and cancel invalidated enumeration.
- [x] Preserve local conflicts without overwriting remote contents.
- [x] Reject stale credential configuration and cleanup generations.
- [x] Support signed Developer ID Keychain storage and report persistence errors.
- [x] Report native errors and enforce conservative provider fallback.
- [x] Remove unrelated Windows/shared-download and formatting changes.
- [x] Make packaging configurable and verify dependency closure and architectures.

## Verification

- [x] Run integrated CTest and Swift suites after the final edits.
- [x] Build both universal extensions and the desktop app.
- [x] Run signed XPC, Keychain, revocation, and Finder I/O tests with isolated data.
- [ ] Update the review report and issue states, commit, and push.
