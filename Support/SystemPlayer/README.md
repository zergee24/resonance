# SystemPlayer resources

共鸣 uses these three resources for a read-only macOS Now Playing snapshot on
macOS 15 and later:

- `mediaremote-mini.pl` is the small `/usr/bin/perl` launcher.
- `MediaRemoteMini.dylib` is the arm64 MediaRemote adapter.
- `LICENSE` contains the adapter's BSD 3-Clause license.

The app invokes the launcher with absolute paths and the symbol
`adapter_get_env`, passing only `MEDIAREMOTEADAPTER_OPTION_now=1`.  Artwork is
ignored.  The main app remains compatible with macOS 14.2; on older systems or
when these resources are unavailable, 共鸣 keeps its existing Accessibility and
OCR player reader as the fallback.

These resources are reused from the local dsh player integration in
`eva-nerv-theme/vendor`. The adapter is copyright 2025 Jonas van den Berg;
see `LICENSE` for the complete BSD-3-Clause notice. It calls the private
MediaRemote service, whose behavior can change with macOS updates.

Bundled source binary SHA-256 (before app-local signing):
`71e260db67d521e16efe6ad5b7365f49440594dd02fbb439611c5d1c4f69144b`.
