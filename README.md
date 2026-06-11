# Slova Applications — Claude Code plugins

Plugin marketplace for [Slova Applications](https://slova.app).

## Install

```
/plugin marketplace add SlovaApplications/claude-plugins
```

Then install any of the plugins below with `/plugin install <name>@slova`.

## Plugins

### `context-memory`

Persistent knowledge base for Claude Code sessions. Pre-fetches relevant contexts before every prompt and exposes MCP tools for saving, searching, and synthesizing Topics.

```
/plugin install context-memory@slova
```

Then activate it in your current session (no restart needed):

```
/reload-plugins
```

**Requires an API key.** The plugin talks to the context-memory backend, which is in invite-only beta — request access at <https://context-memory.slova.app> and you'll receive a personal invite link by email. The link registers your account and shows your API key (once); export it as `CONTEXT_MEMORY_API_KEY` before launching Claude Code. Keys can be rotated any time from your [account page](https://context-memory.slova.app/account/).

See [`plugins/context-memory/README.md`](plugins/context-memory/README.md) for setup, configuration, and how the prefetch hook works.

Backend service: <https://context-memory.slova.app>

## Development

CI runs on every PR: file hygiene (`.github/workflows/ci.yml`, the
`pre-commit` job), the Node hook test suite (`Hook tests` job), and full-history
secret scanning (`.github/workflows/security-scan.yml`). The static checks are
mirrored locally via [pre-commit](https://pre-commit.com/):

```bash
pip install pre-commit
pre-commit install                       # hygiene + gitleaks on commit
pre-commit install --hook-type pre-push  # trufflehog before every push
```

Run the hook tests directly with `node plugins/context-memory/tests/run.mjs`
and `node plugins/context-memory/tests/run-bootstrap.mjs` (Node only — no extra deps).

## License

MIT — see [LICENSE](LICENSE).
