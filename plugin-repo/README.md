# AstraAgent Plugins

The public plugin catalog for AstraAgent. Plugins are installed from this
repository in **Settings → Plugins & MCP → GitHub** by entering:

```text
evereasygaming-ux/AstraAgent-Plugins
```

Each catalog entry points to a folder containing `manifest.json` and either
MCP tools or one or more Markdown skills in `skills/`. AstraAgent reads the
catalog from `astraagent-plugins.json`.

## Add a plugin

1. Create a new plugin folder at the repository root.
2. Add a version 2 or 3 `manifest.json` with a unique `id`, `name`, and
   `version`.
3. Add `skills/<skill-name>.md`, or provide MCP tools and their background
   worker.
4. Add the plugin's path, id, name, version, and description to the catalog.
5. Install from the app using the repository name above.

Plugins in this catalog are public and installable by anyone with the link.
Never include API keys, tokens, passwords, or private user data in plugin
files.

## Current plugins

- `python-assistant`: Python project setup, implementation, debugging, and
  quality guidance.
