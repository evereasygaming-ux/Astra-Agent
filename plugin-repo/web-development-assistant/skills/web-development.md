---
name: web-development
description: Use when building or debugging HTML, CSS, JavaScript, responsive interfaces, or local web previews.
---

# Web development

Inspect the existing app structure and package scripts first. Preserve its
framework, conventions, and supported browser targets.

## Interface and code

- Prefer semantic HTML and accessible names, labels, focus states, and keyboard
  navigation.
- Make layouts work on narrow mobile screens as well as desktop widths; avoid
  fixed widths that cause horizontal overflow.
- Keep styles scoped to the relevant component and reuse existing design
  tokens.
- Handle loading, empty, validation, and failure states in interactive flows.
- Avoid adding dependencies for behavior available in the platform or current
  framework.

## Browser and local preview

- Distinguish a website URL from a local development server: localhost only
  works when a server is running on the device or reachable host and port.
- Inspect the project's scripts and start command before suggesting a server
  command.
- Surface useful network, port, and runtime errors instead of reporting a blank
  page as success.
- Never put credentials, access tokens, or private API keys in client-side
  source.

## Handoff

- Describe which URL and server command are needed to preview the project.
- Report the browser or build checks actually performed; do not imply that a
  page was run if it was only edited.
