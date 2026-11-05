---
name: go-bridge-development
description: Use when implementing or debugging Go HTTP APIs, process bridges, background services, and command-line integrations.
---

# Go bridge development

Read the package boundaries, route wiring, configuration, and existing error
handling before editing. Keep the change compatible with the deployed Go
version and target platforms.

## Implementation

- Pass `context.Context` through network and process work; honor cancellation
  and deadlines.
- Close response bodies and files, check every important I/O error, and bound
  request and response sizes.
- Validate paths and user input before filesystem or process operations.
- Return consistent HTTP status codes and structured errors without leaking
  secrets or internal filesystem details.
- Protect shared mutable state with the existing synchronization pattern.
- Keep handlers small; put reusable behavior in the appropriate package.

## Reliability and security

- Use explicit timeouts for outbound HTTP and child processes.
- Avoid shell interpolation of user-controlled values; pass arguments directly
  when starting a process.
- Keep credentials out of logs and files with broad permissions.
- Consider Android, Termux, and Linux path and process differences when the
  bridge runs across those environments.

## Handoff

- Explain API or configuration changes and any compatibility impact.
- Report which packages were built or analyzed and the exact result.
