# AstraAgent plan

## Goal

Build AstraAgent as an Android coding workspace with a Flutter UI. Study
AntiGem v1.0.19 as a feature and behavior reference, selectively reuse its
bridge where appropriate, and build/debug the Android app through GitHub
Actions.

AntiGem source reference: `antigem-1.0.19.zip`, release commit `babb5de`,
GitHub repository `Santoshkurmi/antigem`. Its bridge is GPL-3.0; preserve the
license and attribution for derived/reused bridge code.

## Current repository state (2026-11-04)

- Flutter Android application, package ID `com.astra.agent`, Riverpod state,
  GoRouter navigation, minimum SDK 24 and target SDK 28.
- Existing screens/routes: Home, Settings, Claude Code, and AGY.
- Existing bridge layer: native Go bridge lifecycle, token/health checks,
  embedded/external bridge configuration, Claude and AGY HTTP API clients.
- Current working tree contains an in-progress Debian proot setup flow driven by
  Termux `RUN_COMMAND`; many app files are modified and several files are new.
- Read-only device inspection found Debian 13 proot and executable
  `/root/.local/bin/agy`. No service responded on localhost ports 1234/1235;
  `claude` and `agy_ide_bridge` were not found in Debian PATH at inspection time.
- External/Debian proot bridge mode is the default in Dart configuration and native
  preferences; Settings can switch to the embedded bridge.
- Home Chat, Terminal, Editor, and Browser cards are placeholders. No full chat
  UI, editor, in-app terminal, browser, or Git workspace is present yet.
- `bridge/` contains the AntiGem-derived Go service. Its Claude manager and
  HTTP handlers match the corresponding v1.0.19 bridge source inspected so far.
- `.github/workflows/build-debug-apk.yml` builds an arm64 debug APK, generates
  the Android Go bridge asset, runs Flutter analyze/tests, checks APK alignment,
  SDK metadata and signature, and uploads an artifact. Release signing/release
  publishing is not configured; release currently uses the debug signing key.

This status is a static source review. No build or tests were run for this plan.

## Architecture

- **Frontend:** Flutter/Dart; keep app features in `lib/features/`.
- **Android integration:** Kotlin `MainActivity` MethodChannel for bridge,
  runtime and Termux operations.
- **Agent service:** AntiGem-derived Go bridge in `bridge/`, exposing local HTTP
  APIs and WebSocket/gRPC communication to AGY/Claude.
- **External runtime:** The Go bridge, AGY, and Claude Code run inside the
  existing Debian 13 proot managed by Termux. AstraAgent connects to the bridge
  at `127.0.0.1:1234`; AGY is already installed at `/root/.local/bin/agy` on the
  inspected device. The bridge binary is delivered through the app's temporary
  localhost asset server.
- **Embedded runtime:** The app can still run its bundled bridge for Claude.
- **Build:** GitHub Actions is the canonical Android arm64 debug build path.

## Remaining foundation work

1. Finish the Debian proot integration lifecycle: workspace selection and
   recovery after failed setup. Token/port changes update the generated bridge
   config and request a restart; authenticated health is checked afterward.
2. The Android Go bridge binary's `--help` runs inside Debian proot; start it
   with the installed AGY and confirm its authenticated localhost API is
   reachable from AstraAgent.
3. Clarify whether direct in-app AGY installation (`AgyRuntime`) remains
   supported or should be retired/gated.
4. Review handling of configurable external bridge URLs and auth tokens; the
   current app enables cleartext traffic for the localhost Termux connection.
5. Reconcile version metadata and actual runtime behavior.

## Work sequence

### Phase 0 - Baseline and AntiGem study

- Record AstraAgent repository state and protect the existing uncommitted work.
- Map AntiGem v1.0.19 user workflows, architecture, bridge APIs, and runtime
  assumptions to AstraAgent equivalents.
- Keep Flutter as the AstraAgent UI/build target; do not port AntiGem Compose UI.
- Identify which AntiGem-derived bridge components can be reused under GPL-3.0
  and which app features need independent Flutter implementations.

### Phase 1 - Stabilize current foundation

- [x] Resolve the default-mode decision as external/Debian proot and align native
  defaults and README.
- [x] Store Debian bridge token/ports outside the launcher script so Settings
  changes can update the config and request a restart.
- [x] Run Termux `RUN_COMMAND` through `proot-distro login debian`.
- [x] Reuse Debian's existing AGY executable and put the bridge/Claude wrapper
  inside Debian rather than installing AGY in outer Termux.
- [ ] Confirm setup/restart behavior on-device and verify the Android Go bridge
  can serve AGY/Claude from Debian proot.
- Complete and document Debian proot setup, restart, workspace, and failure
  handling.
- Retain GitHub Actions as the repeatable arm64 debug APK build and artifact
  delivery path.

### Phase 2 - Agent chat

- [x] Implement workspace selection and Claude Code stream-json chat.
- [x] Add Antigravity model discovery and prompt streaming through AGY Hub gRPC.
- [x] Map the AntiGem interaction schema and validate AGY's basic prompt/reply
  path against the user's live Debian Hub (user-confirmed).
- [x] Add AGY permission/question cards and bridge-side interaction responses;
  the user confirmed approving a command card and seeing command output.
- Add private on-device chat history with recent-conversation restore; local
  validation passes, with APK and device validation pending.

### Phase 3 - Coding workspace

- Add workspace/project selection and file access.
- Implement editor, terminal, and Git in incremental Flutter modules.
- Evaluate browser preview and MCP/plugin support after core workflows work.

### Phase 4 - Distribution

- Define release versioning and signing separately from debug CI.
- Publish release artifacts only after release signing and install/update flow
  are explicitly designed.

## Working constraints and decisions

- User requested analysis and planning before coding, then explicitly authorized
  implementation. Initial coding milestone is bridge/Termux stabilization.
- Keep the existing uncommitted work intact; inspect diffs before modifying
  implementation files.
- Use AntiGem primarily as an architecture/behavior reference. Respect GPL-3.0
  for code derived from its Go bridge.
- Prefer GitHub Actions for Flutter Android builds and APK artifact delivery.
