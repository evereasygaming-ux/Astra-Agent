# AstraAgent

Agentic AI coding workspace for Android. Built with Flutter, with an embedded
Go bridge for Claude Code stream-json sessions.

## Status

Phase 1: Go bridge packaging and lifecycle (done).

Phase 2: Claude Code runtime. The app extracts a bundled glibc runtime and a
`claude` wrapper from `android/app/src/main/assets`, then starts the bridge with
`--claude-bin`. Claude Code itself is installed and authenticated from the
in-app Claude screen.

## Build

Debug APKs are built by GitHub Actions (`.github/workflows/build-debug-apk.yml`):

- Go bridge cross-compiles for `android/arm64`
- Flutter builds a debug APK for `arm64-v8a`
- CI verifies `targetSdk 28`, `minSdk 24`, 16 KB alignment, and APK signature

Local build:

```bash
flutter pub get
flutter build apk --debug
```

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
