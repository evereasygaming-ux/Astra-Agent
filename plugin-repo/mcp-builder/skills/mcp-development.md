---
name: mcp-development
description: Use when creating or debugging Model Context Protocol servers, clients, tools, resources, prompts, and server configuration.
---

# MCP development

Identify whether the task concerns an MCP host, client, or server, then follow
the protocol SDK and transport already used by the project.

## Design

- Give each tool a narrow purpose, clear description, and validated input
  schema.
- Return structured, bounded results and useful errors; do not report a failed
  operation as a successful tool result.
- Use resources for application-provided context and prompts for reusable
  user-facing tasks when those fit better than an action tool.
- Keep tool names stable and document side effects.

## Security and reliability

- Validate arguments and paths; constrain file access to the intended
  workspace.
- Keep credentials in environment variables or a secret store, never in
  manifests, prompts, logs, or example configs.
- Set timeouts and handle cancellation, unavailable servers, and malformed
  responses.
- Require user confirmation for destructive or externally visible actions
  unless the user has already authorized them.
- Avoid logging full prompts or secret-bearing tool arguments.

## Configuration and handoff

- Keep configuration valid JSON and document required environment variables.
- Verify the selected transport and endpoint match the host's capabilities.
- Explain how to start the server and how to verify its advertised tools,
  resources, or prompts.
