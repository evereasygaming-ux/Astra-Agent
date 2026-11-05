---
name: flutter-android-development
description: Use when implementing or debugging Flutter and Android application code, platform integration, permissions, or builds.
---

# Flutter and Android development

Follow the existing app architecture and target Android versions. Inspect the
relevant widgets, providers, routes, platform code, and configuration before
changing them.

## Flutter work

- Keep widgets focused and follow the project's state-management and routing
  patterns.
- Handle loading, empty, error, and success states for asynchronous UI.
- Check mounted state before updating widgets after awaited work.
- Respect small screens, keyboard insets, system bars, and text scaling.
- Reuse existing theme tokens and components instead of introducing parallel
  styling systems.

## Android integration

- Check `minSdk`, `targetSdk`, manifest declarations, and runtime permission
  requirements before using platform APIs.
- Request permissions only when needed, explain the purpose in the UI, and
  handle denial or restricted settings gracefully.
- Keep platform channel method names and argument/result shapes consistent on
  both Dart and Android sides.
- Avoid blocking the main thread; manage activity and service lifecycles.
- Do not silently raise SDK targets or remove compatibility code.

## Build and handoff

- Inspect the configured build flavors and target ABI before changing build
  settings.
- Run analysis or a build only when requested or needed for the delivery, and
  report the exact command and result.
- Summarize platform-specific behavior and any required Android settings.
