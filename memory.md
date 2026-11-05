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
  and `git diff --check` passed for this change. GitHub Actions run
  `41958450456` passed Go arm64 compilation, Flutter analysis/tests, APK build,
  Android install-safety checks, and artifact upload. The user then confirmed
  live on-device `hi` prompt/reply through Antigravity.
- Follow-up work now switches command execution to
  `CASCADE_COMMANDS_AUTO_EXECUTION_OFF` and adds AGY permission/question cards
  plus `HandleCascadeUserInteraction` support. The user confirmed the approve
  card appeared and the Python command ran after approval.
- The current follow-up adds on-device private JSON chat history, recent chat
  selection, and restore of agent/model/workspace context. APK/device validation
  for this history work is pending. The user reported seeing the workspace but
  not the transcript; saving now waits for history load, reports storage errors,
  and shows message counts/previews in the history list.
- Latest chat UX fixes in progress: Antigravity is the default agent, the input
  hint follows the selected agent, long AGY turns show stage and elapsed time,
  and Home action cards constrain text to avoid overflow. Flutter analysis passes;
  device validation is pending.
- User tested the new history build but reported no transcript after closing and
  reopening the app. Chat now auto-restores the newest saved conversation on
  entry, flushes history on Android app lifecycle changes and completed turns,
  and surfaces load/save errors. Device validation of this correction is pending.
- Antigravity terminal MVP is implemented and committed in `1e4aa82`, with
  follow-up fixes in `638376d` and `bd51479`. GitHub Actions run `41983414471`
  passed bridge compilation, Flutter analysis/tests, APK build, Android install
  safety checks, and artifact upload. User installed the APK and confirmed the
  terminal works on device.
- Editor MVP is implemented: workspace file browsing, text-file editing, save,
  and unsaved-change confirmation use existing bridge APIs. Flutter analysis
  and `git diff --check` passed; the user confirmed on-device that workspace
  files display, edit, and save successfully.
- Git workspace MVP is implemented using the existing bridge endpoints: branch
  status, staged/unstaged/untracked file lists, per-file diff, stage/unstage,
  stage all, repository initialization, and commit of staged changes. Flutter
  analysis and `git diff --check` pass; device validation is pending.
- GitHub sign-in uses the OAuth device flow. Its Client ID comes from the
  `GITHUB_OAUTH_CLIENT_ID` Dart define and is configured in the GitHub Actions
  workflow. The OAuth App must have Device Flow enabled. The bridge validates the
  access token, stores it outside repositories with owner-only file permissions,
  and supplies it through askpass for HTTPS github.com remotes. The user confirmed
  GitHub connect succeeds on device after the polling request/retry fix.
- Git page now supports setting an HTTPS GitHub origin and authenticated push and
  pull. Pull requires a clean working tree and user confirmation; push is shown
  when there are unpushed commits. Flutter analysis passes; device sync validation
  is pending.
- Git page now shows the latest 12 commits with per-commit file diffs, and lets
  users switch or create local branches. Branch changes require a clean working
  tree and confirmation; Flutter analysis passes and device validation is pending.
- GitHub PR workflow now lists up to 30 open pull requests and creates one from
  the current clean, pushed branch, defaulting the base to the repository's
  default branch. Bridge checks the OAuth token, GitHub origin, clean worktree,
  and published upstream before creation. Flutter analysis and Go build pass;
  device validation is pending.
- Workspace editor now has debounced literal code search, capped at 200 results;
  hidden project files are included while Git internals and common dependency or
  build output directories are excluded. Results include file and line context
  and open the matching file. Flutter analysis and Go build pass; device
  validation is pending.
- Follow-up fixes remove the editor search dependency on ripgrep, add an in-app
  existing-folder picker for workspaces, and save selected workspace ordering so
  it remains the default. Chat now displays AGY command output and changed-file
  paths, blocks back navigation during active work, and exposes history as a
  resume path. Chat selectors use full-width rows on narrow screens. Flutter
  analysis and Go build pass; device validation is pending.
- Attachments remain future work.

## Collaboration preferences

- User prefers direct progress and concrete repository analysis.
- Do not overwrite or discard the existing dirty working tree.
- Give concise updates in Hindi/Hinglish when discussing this project.
