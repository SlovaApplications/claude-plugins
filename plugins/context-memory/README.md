# context-memory plugin for Claude Code

Persistent knowledge base for Claude Code sessions. Automatically retrieves relevant prior context before every prompt and exposes MCP tools for saving, searching, voting on, and auditing contexts.

## What it gives you

- **MCP tools** for managing contexts:
  - **Save and search**: `save_context`, `search_contexts`, `get_context`, `delete_context`, `vote_context`
  - **Audit and cull**: `list_contexts` (paginated, filterable by type, repo, score, age, staleness), `bulk_delete_contexts`, `mark_context_verified`
- **Pre-fetch hook** that searches your context store on every prompt and injects the top hits as additional context for Claude

Backend service: <https://context-memory.slova.app>

## Install

1. **Request an API key.** Public signup at <https://context-memory.slova.app> is coming soon. In the meantime, email <support@slova.app> for early access.

2. **Export the key** in your shell profile (`~/.zshrc`, `~/.bashrc`, etc.):

   ```bash
   export CONTEXT_MEMORY_API_KEY="cm_..."
   ```

   Reload your shell, or open a new terminal, before launching Claude Code.

3. **Add the marketplace and install the plugin** in Claude Code:

   ```
   /plugin marketplace add SlovaApplications/claude-plugins
   /plugin install context-memory@slova
   ```

4. **Restart Claude Code**. The MCP tools should appear and the pre-fetch hook will fire on every prompt.

## Configuration

All configuration is via environment variables (read at MCP-server-start time and on every hook invocation):

| Variable | Default | Purpose |
| --- | --- | --- |
| `CONTEXT_MEMORY_API_KEY` | _(required)_ | Bearer token from your dashboard. If unset, the hook stays silent and the MCP server fails to load. |
| `CONTEXT_MEMORY_API_URL` | `https://api.context-memory.slova.app` | Override for self-hosted or staging backends. |
| `CONTEXT_MEMORY_PREFETCH_TIMEOUT` | `1.5` | Seconds to wait for the search API before giving up. |
| `CONTEXT_MEMORY_PREFETCH_LIMIT` | `5` | Max contexts injected per prompt. |
| `CONTEXT_MEMORY_PREFETCH_MAX_BYTES` | `2000` | Hard cap on injected text size. |

## How the pre-fetch hook works

On every `UserPromptSubmit`, the hook:

1. Reads your prompt from the hook stdin payload.
2. Sends it (capped at 500 chars) to `POST /api/v1/contexts/search` with your bearer token.
3. Formats the top hits (1.5s timeout, 2KB output cap) as plain markdown.
4. Prints the markdown on stdout — Claude Code prepends it to your prompt as additional context.

It **fails open**: if the API key isn't set, the network is unreachable, the request times out, or anything else goes wrong, the hook prints nothing and your prompt passes through unchanged.

## Requirements

- Claude Code (latest)
- `curl` and `jq` on your `PATH` (both are standard on macOS and most Linux distros)

## License

MIT
