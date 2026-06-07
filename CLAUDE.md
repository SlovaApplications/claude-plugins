# CLAUDE.md — claude-plugins

This repo is the **Slova plugin marketplace** for Claude Code. The published
plugin lives in `plugins/context-memory/`; `.claude-plugin/marketplace.json`
serves it straight from that directory on `main`.

## Versioning — read before changing a plugin

- **`plugins/context-memory/.claude-plugin/plugin.json` → `"version"` is the single
  source of truth.** Claude Code reads it; the marketplace serves whatever is on
  `main`; users update against it. There is no separate version anywhere else.
- **Bump it (semver) in the SAME change** as any release-worthy edit to
  `plugins/context-memory/` — hooks, `hooks.json`, `plugin.json`, MCP config.
  Docs-only edits (`README.md`, `CHANGELOG.md`) don't need a bump.
  - **patch** = bug fix, no behavior change · **minor** = new feature/behavior ·
    **major** = breaking change to the MCP tools or config.
- CI (`.github/workflows/version-check.yml`) **fails the PR** if the plugin
  changed without a version bump. Don't work around it — bump the version.

## Releases / tags

- The git tag for a release is `v` + the `plugin.json` version (e.g. `v0.9.0`).
- **After a version-bumped PR merges to `main`,** tag the merge commit and cut a
  GitHub release:
  ```bash
  git tag vX.Y.Z <merge-sha> && git push origin vX.Y.Z
  gh release create vX.Y.Z --verify-tag --title vX.Y.Z --notes "<one-line summary>"
  ```
- **Keep tags and `plugin.json` in lock-step.** They drifted historically (tags
  stopped at v0.3.1 while the plugin reached 0.8.0); every version now has a tag —
  don't let it happen again.

## Hooks

- The hooks are **Node scripts** (`plugins/context-memory/hooks/*.mjs`) with a
  shared `lib.mjs`. They use Node's built-in `fetch` + JSON — **no bash / curl /
  jq** — so they run identically on macOS, Linux, and Windows (Claude Code ships
  Node). Keep them that way, and keep them **fail-open** (any error → emit
  nothing, exit 0; `prefetch` is the one exception — it exits 2 on a
  missing/invalid key so the misconfiguration is visible).
- `hooks.json` invokes each hook as `node "${CLAUDE_PLUGIN_ROOT}/hooks/<name>.mjs"`.
- **After changing any hook, run the suite:** `node plugins/context-memory/tests/run.mjs`.
  If you add or remove a hook/test, update the test harness in the same change —
  CI runs exactly this command, so don't let them drift.

## Checklist for a plugin change

1. Make the change under `plugins/context-memory/`.
2. Bump `plugin.json` `version` (semver).
3. `node plugins/context-memory/tests/run.mjs` → green.
4. Note the feature under its `vX.Y.Z` in `README.md` if it's user-facing.
5. After merge to `main`: tag + release `vX.Y.Z`.
