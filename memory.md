# AstraAgent project memory

## User direction

- Analyze the existing AstraAgent state before starting feature work.
- Use AntiGem v1.0.19 as a reference for reverse-engineering features and
  workflows.
- Keep AstraAgent's app implementation in Flutter and use GitHub Actions for
  Android APK builds.
- Plan and memory documentation were created before coding. User has now
  authorized implementation; first milestone is bridge/Termux stabilization.

## Project identity

- Repository: AstraAgent, Android package `com.astra.agent`.
- Flutter/Dart UI with Riverpod and GoRouter.
- Kotlin Android MethodChannel integration.
- Go bridge under `bridge/`, derived from AntiGem's `agy_ide_bridge` (GPL-3.0).
- Android min SDK 24, target SDK 28; current CI target is arm64-v8a debug APK.

## Current baseline (2026-11-04)

- Committed HEAD is `9df16df` (`phase 2: add AGY runtime and screen`).
- Working tree has substantial existing uncommitted Phase 3 changes for external
  bridge configuration and Termux-driven Debian proot setup. Preserve them.
- Screens/routes exist for Home, Settings, Claude Code, and AGY.
- Home shows Chat, Terminal, Editor, and Browser cards, but those actions are
  placeholders. No complete chat/editor/terminal/browser/Git workspace exists.
- Claude and AGY clients use the Go bridge APIs. Bridge modes include embedded
  and external/Debian proot.
- User clarified the runtime layout: Termux manages Debian 13 proot; AGY and
  Claude Code must run inside Debian, and AstraAgent connects to the bridge via
  localhost. AGY is already installed in Debian at `/root/.local/bin/agy`.
- Read-only inspection found no active bridge listener on ports 1234/1235 and no
  Claude or bridge command in Debian's current PATH. The Android bridge asset is
  an arm64 Android ELF using `/system/bin/linker64`, which is visible in Debian
  proot; invoking it with `--help` inside Debian succeeded. No service was
  started, and the localhost API remains unverified because no bridge was
  listening.
- The Termux launcher now invokes `proot-distro login debian`; setup reuses the
  existing AGY executable and installs the bridge and Claude wrapper under
  Debian's `/root` home rather than installing AGY into outer Termux.
- GitHub Actions workflow: `.github/workflows/build-debug-apk.yml`. It builds
  the Android Go bridge, runs `flutter analyze` and `flutter test`, builds an
  arm64 debug APK, checks SDK metadata/alignment/signature, and uploads it.
- Release signing/publishing is not set up; Gradle currently signs release
  builds with the debug key.
- Current analysis was static; no tests or builds were run.

## Known decisions and questions

- Keep Flutter for AstraAgent UI; do not port AntiGem's Jetpack Compose UI.
- Study AntiGem's flows and protocols; reuse bridge code only with GPL-3.0
  license/attribution requirements preserved.
- External/Debian proot mode is the default; Settings retains the embedded
  option.
- Token/port changes in external localhost mode now update Debian bridge config,
  request restart, and verify authenticated connection. Older setup scripts
  prompt the user to rerun setup first.
- Setup reuses AGY already installed in Debian and creates a Claude launcher
  wrapper for the bridge's native Claude installer.
- README and native MethodChannel fallback now agree that Debian proot/external mode
  is the default. Settings can still switch to embedded mode.
- No build, analyzer, or test suite was run after these edits. The bridge
  `--help` command runs inside Debian; on-device setup, restart behavior, and
  authenticated localhost API access still need validation.
- Debian proot workspace selection and setup recovery remain open.
- Reconcile documentation with the implementation as the Debian integration
  evolves.

## Current implementation (2026-11-05)

- Claude chat MVP is implemented in Flutter: workspace picker, session WebSocket,
  streamed response, and new-chat reset.
- Antigravity chat is now wired through the Go bridge using the AGY
  `LanguageServerService` gRPC protocol: model discovery, cascade creation,
  prompt submission, and trajectory update streaming.
- The protocol schema is derived from AntiGem v1.0.19 (`babb5ded`) and remains
  covered by the retained GPL-3.0 bridge license/attribution.
- Local `go build ./...`, dynamic protocol-schema compilation, `flutter analyze`,
  and `git diff --check` passed for this change. A GitHub Actions APK build and
  live RPC validation against the Debian Hub are still pending.
- AGY chat sends command execution policy `CASCADE_COMMANDS_AUTO_EXECUTION_EAGER`,
  matching the AntiGem v1.0.19 chat flow. Interactive approval/question UI,
  attachments, and saved chat history are not part of this first AGY pass.

## Collaboration preferences

- User prefers direct progress and concrete repository analysis.
- Do not overwrite or discard the existing dirty working tree.
- Give concise updates in Hindi/Hinglish when discussing this project.
