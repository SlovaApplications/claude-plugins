# Slova Applications — Claude Code plugins

Plugin marketplace for [Slova Applications](https://slova.app).

## Install

```
/plugin marketplace add SlovaApplications/claude-plugins
```

Then install any of the plugins below with `/plugin install <name>@slova`.

## Plugins

### `context-memory`

Persistent knowledge base for Claude Code sessions. Pre-fetches relevant contexts before every prompt and exposes MCP tools for saving, searching, and voting.

```
/plugin install context-memory@slova
```

See [`plugins/context-memory/README.md`](plugins/context-memory/README.md) for setup, configuration, and how the prefetch hook works.

Backend service: <https://context-memory.slova.app>

## Development

CI runs on every PR: shellcheck + file hygiene (`.github/workflows/ci.yml`, the
`pre-commit` job), the hook test suite (`shell-tests` job), and full-history
secret scanning (`.github/workflows/security-scan.yml`). The static checks are
mirrored locally via [pre-commit](https://pre-commit.com/):

```bash
pip install pre-commit
pre-commit install                       # shellcheck + hygiene + gitleaks on commit
pre-commit install --hook-type pre-push  # trufflehog before every push
```

Run the hook tests directly with `bash plugins/context-memory/tests/test_*.sh` (needs `jq`).

## License

MIT — see [LICENSE](LICENSE).
