# TopNotch

A geeky Dynamic Island for the MacBook notch. Hover the notch and it springs open into a black HUD panel.

- **Agents:** live Claude Code sessions (running / thinking / your turn), the current tool, tokens, and a 5-hour usage meter, all read from `~/.claude/projects`. Plays a chime when an agent finishes.
- **Music:** Apple Music and Spotify controls, album art and seeking, plus time-synced lyrics from [LRCLIB](https://lrclib.net). The line being sung right now can show big under the notch.
- **Clipboard:** history of what you copy. Password-manager copies are skipped, and nothing is stored on disk.
- **Notes:** a scratchpad that saves automatically.
- **Messages:** WhatsApp and Telegram notifications show up instantly as a card on the notch.

Native SwiftUI. No dependencies, no Xcode project.

## Build

Requires macOS 14+ on Apple Silicon and the Xcode Command Line Tools.

```bash
./build.sh
```

This builds a release binary, wraps it in `/Applications/TopNotch.app`, signs it and launches it.

## Permissions

| Feature | Permission |
|---|---|
| Music control | Automation → Music / Spotify (asked on first use) |
| Messages (history) | Full Disk Access (reads Notification Center's database) |
| Messages (instant) | Accessibility (reads the banner while it's on screen) |

Builds with ad-hoc signatures lose these permissions on every rebuild. To keep them, create a self-signed code-signing certificate named **TopNotch Dev** in your login keychain; `build.sh` uses it automatically when it's present.

## Self-test

```bash
/Applications/TopNotch.app/Contents/MacOS/TopNotch --selftest
```
