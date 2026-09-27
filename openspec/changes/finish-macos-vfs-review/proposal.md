# Finish macOS VFS review fixes

The user approved fixing all remaining findings in the full PR review. This change completes provider space coverage, durable item identity, bounded enumeration, conflict recovery, credential revocation, native error reporting, and portable packaging.

The implementation keeps the existing account UUID for the personal-space domain. Additional spaces receive deterministic account-scoped domain identifiers. Credentials remain in Keychain, with generation checks that reject delayed configuration and cleanup messages.

Unrelated Windows hydration, shared download, and Unix formatting changes are removed from this PR. Existing stable upstream behavior needs no new Windows rollout.

Affected capability: `macos-vfs`. Verification combines local regression suites, unsigned universal extension builds, bundle dependency checks, and a signed disposable host using a loopback DAV fixture. The host uses separate bundle IDs, app groups, domains, and test credentials.
