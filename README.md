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

## License

MIT — see [LICENSE](LICENSE).
