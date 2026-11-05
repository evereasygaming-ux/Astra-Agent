# AstraAgent

Agentic AI coding workspace for Android. Built with Flutter, with an embedded
Go bridge for Claude Code stream-json sessions.

## Status

Phase 1: Go bridge packaging and lifecycle (done).

Phase 2: Claude Code runtime. The app extracts a bundled glibc runtime and a
`claude` wrapper from `android/app/src/main/assets`, then starts the bridge with
`--claude-bin`. Claude Code itself is installed and authenticated from the
in-app Claude screen.

Phase 3: Debian proot mode (current). AGY and Claude Code run inside the
existing Debian proot container managed by Termux. The Go bridge also runs
inside Debian, and AstraAgent connects to it over `127.0.0.1`.

Debian proot mode is the default. To use the embedded Claude bridge instead,
change the bridge mode in Settings.

## Debian proot mode

Install Termux, Debian proot, and AstraAgent, then tap `Set up & launch` on the
Home screen or in `Settings -> Debian proot automation`. The app enters Debian
through Termux's `RUN_COMMAND` intent and:

- serves the bundled `agy_ide_bridge` binary to Debian over localhost
- reuses the existing `agy` executable in Debian; it does not download AGY
- creates a Claude launcher wrapper; install Claude Code from its Settings
  screen
- writes `~/.astra/start-bridge.sh`, starts the bridge inside Debian and connects
  to it from AstraAgent

Two one-time Android permissions are required, both prompted by the app:

- Termux must be installed from F-Droid (Play Store build is discontinued)
- Termux must allow external apps from the Termux settings tile on the Debian
  proot automation screen.

Manual bridge launch after app setup, if needed:

```bash
proot-distro login debian
~/.astra/start-bridge.sh --restart
```

## Editor and terminal

The Terminal screen uses an interactive PTY with ANSI/xterm rendering, resize,
keyboard input, and Escape/Ctrl shortcuts. From a file in Editor, tap the
terminal icon to open that file in Neovim in the same workspace. Neovim must be
installed inside Debian first:

```bash
apt-get update && apt-get install -y neovim
```

## Build

Debug APKs are built by GitHub Actions (`.github/workflows/build-debug-apk.yml`):

- Go bridge cross-compiles for `android/arm64`
- Flutter builds a debug APK for `arm64-v8a`
- CI verifies `targetSdk 28`, `minSdk 24`, 16 KB alignment, and APK signature

Local build:

```bash
flutter pub get
flutter build apk --debug \
  --dart-define=GITHUB_OAUTH_CLIENT_ID=YOUR_OAUTH_APP_CLIENT_ID
```

For GitHub sign-in, the configured GitHub OAuth App must have Device Flow enabled.
The app uses GitHub's device authorization flow and requests `repo read:user` so
GitHub HTTPS remotes can authenticate. The public Client ID is passed to the APK
build; no OAuth client secret is used. The bridge stores the resulting access
token in Debian outside project folders with owner-only permissions.

The bridge binary is generated into
`android/app/src/main/assets/bin/agy_ide_bridge` by CI or by:

```bash
cd bridge
CGO_ENABLED=0 GOOS=android GOARCH=arm64 \
  go build -buildmode=pie -trimpath -ldflags="-s -w" \
  -o ../android/app/src/main/assets/bin/agy_ide_bridge .
```

## License

This project is licensed under the GNU General Public License v3.0. See
`LICENSE`.

The embedded Go bridge in `bridge/` is derived from the antiGem project
(`agy_ide_bridge`, GPLv3). Its original license is kept in `bridge/LICENSE`.
