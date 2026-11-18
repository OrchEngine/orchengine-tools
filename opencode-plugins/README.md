# OpenCode plugins

Plugins and CLIs that run alongside OpenCode, kept in this repo so they share
the same tooling and release process.

- `opencode-usage-review/` — daily AI usage review: quota, active time, rework,
  and outcome labels. See its README for the CLI, the OpenCode plugin path, and
  the systemd timer setup.

Each entry is a regular directory in this repo. None of them are git submodules.
