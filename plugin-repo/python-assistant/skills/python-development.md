---
name: python-development
description: Use when creating, modifying, debugging, or reviewing Python code and Python project setup.
---

# Python development

Help build Python software that fits the current project and runs in its
existing environment.

## Before changing code

- Inspect the workspace for `pyproject.toml`, `requirements*.txt`, `Pipfile`,
  `setup.cfg`, `tox.ini`, and existing tests.
- Follow the project's existing Python version, package manager, formatter,
  and test conventions.
- If no environment is configured, prefer a project-local virtual environment
  and the package manager already available. Do not install global packages
  without the user's request.
- Read the relevant modules and tests before editing; preserve established
  APIs unless the task requires a change.

## Implementing and debugging

- Make the smallest complete change that solves the requested behavior.
- Use clear names, type hints where consistent with the project, and standard
  library features before adding dependencies.
- For bugs, reproduce the behavior or identify a concrete failing path before
  editing, then explain the cause and fix.
- Handle expected invalid input and I/O failures explicitly. Do not silently
  swallow exceptions.
- Keep secrets out of source files, logs, example configs, and commits. Read
  credentials from environment variables or the project's secret store.

## Verification and handoff

- Run the formatter, linter, type checker, or tests already configured by the
  project when the user asks for verification or when they are part of the
  requested delivery.
- Report the exact checks that ran and their results. Never say code was tested
  if only inspected.
- Summarize the changed files and any setup or migration steps the user needs.
