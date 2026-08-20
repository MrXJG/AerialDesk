# AerialDesk

A native macOS menu-bar app that keeps aerial dynamic wallpapers playing on the desktop.

## Features

- Continue playing aerial videos while the Mac is on AC power.
- Pause playback on battery power.
- Resume after the screen wakes and automatically continue with the next video when one ends.
- Read Apple aerial metadata and show Chinese/English names instead of UUIDs.
- Preview an aerial image in the download manager.
- Download one selected aerial, the current category, or all available aerial videos.
- Recognize Apple system videos and user-managed videos without moving or deleting them.
- Provide a menu-bar switch for “Launch at Login”.
- Reveal the installed app in `/Applications` from the menu.

## Requirements

- macOS 14.0 or later
- Apple Silicon Mac (the current build target is `arm64-apple-macos14.0`)
- Swift toolchain provided by Xcode or the Command Line Tools

The app reads the Apple aerial manifest and media already present on the Mac. It does not ship Apple aerial videos, system thumbnails, or cached media in this repository.

## Build and run

```bash
./build.sh
open build/AerialDesk.app
```

The development build is ad-hoc signed. macOS may show the usual local-development security prompt. A distributable release should be signed and notarized with the developer’s own Apple Developer identity.

## Runtime data

Runtime files are stored under:

```text
~/Library/Application Support/AerialDesk/
```

The app keeps downloaded videos in its own `Videos` directory and generated previews in `Thumbnails`. Existing Apple system aerial media remains in Apple’s own directories. The environment variables `AERIALDESK_VIDEO_DIR` and `AERIALDESK_THUMBNAIL_DIR` can be used for local testing.

## Important boundaries

- Apple’s manifest format and system paths are private implementation details and may change between macOS releases.
- Apple aerial videos and thumbnails are Apple-provided media; they are intentionally not included here.
- The generated app icon is included as a project asset, but it does not contain Apple trademarks or Apple media.

## License

The source code is released under the MIT License. See [LICENSE](LICENSE).

