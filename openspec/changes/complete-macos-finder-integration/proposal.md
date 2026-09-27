# Complete macOS Finder integration

The user requested sync status comparable to iCloud and confirmed the scope includes all Finder on-demand features available to third-party providers. This extends the reviewed macOS FileProvider implementation.

Use public FileProvider APIs for native progress, pending items, content policies, metadata, and recovery. Add accurate status to the desktop client. Document which behaviors Finder owns and which require backend support; do not claim control over iCloud-specific sidebar presentation.

Keep default on-demand sync mutually exclusive with traditional folder sync. Preserve domain identity, credential isolation, conflict safety, and existing local files. Use a stable signed app location for manual testing so a development/distribution signing-identity change does not recur between builds.

The scope is Finder features inside OpenCloud. Desktop and Documents backup, relocation, and a backup setup flow are excluded by the user.
