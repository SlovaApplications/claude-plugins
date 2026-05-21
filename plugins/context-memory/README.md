# context-memory plugin for Claude Code

Persistent knowledge base for Claude Code sessions. Automatically retrieves relevant prior context before every prompt and exposes MCP tools for saving, searching, and auditing contexts.

## What it gives you

- **MCP tools** for managing contexts:
  - **Save and search**: `save_context`, `search_contexts`, `get_context`, `delete_context`
  - **Audit and cull**: `list_contexts` (paginated, filterable by repo, source type, tag, and age), `bulk_delete_contexts`
- **Pre-fetch hook** that searches your context store on every prompt and injects the top hits as additional context for Claude
- **End-of-turn nudge** (v0.3.0+) that holds the turn open if meaningful work happened (commits, PRs, issue ops, several edits) without a `save_context` call, so learnings actually land in the store instead of getting lost
- **Topic-synthesis enforcement** (v0.4.0+) that blocks turn-end while tags have accumulated enough Contexts to warrant a Topic but none covers them, so clusters of knowledge get compiled into durable Topics instead of staying scattered

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
| `CONTEXT_MEMORY_API_URL` | `https://api.context-memory.slova.app` | Override for self-hosted or staging backends. Must be `https://` (or `http://localhost` / `http://127.0.0.1` for local development) — the hooks refuse to send the API key over any other cleartext URL. |
| `CONTEXT_MEMORY_PREFETCH_TIMEOUT` | `1.5` | Seconds to wait for the search API before giving up. |
| `CONTEXT_MEMORY_PREFETCH_LIMIT` | `5` | Max contexts injected per prompt. |
| `CONTEXT_MEMORY_PREFETCH_MAX_BYTES` | `2000` | Hard cap on injected text size. |
| `CONTEXT_MEMORY_TOPIC_STOP_TIMEOUT` | `2` | Seconds the topic-synthesis `Stop` hook waits for the cluster API before giving up. |

## How the pre-fetch hook works

On every `UserPromptSubmit`, the hook:

1. Reads your prompt from the hook stdin payload.
2. Sends it (capped at 500 chars) to `POST /api/v1/contexts/search` with your bearer token.
3. Formats the top hits — a mixed list of Contexts and Topics — as plain markdown (1.5s timeout, 2KB output cap).
4. Prints the markdown on stdout, so Claude Code prepends it to your prompt as additional context. When several Contexts come back and no Topic covers them, it appends a nudge suggesting Claude synthesize them with `create_topic`.

It **fails open**: if the API key isn't set, the network is unreachable, the request times out, or anything else goes wrong, the hook prints nothing and your prompt passes through unchanged.

## How the end-of-turn nudge works

When Claude tries to end a turn, the `Stop` hook scans this turn's events (everything after the last user prompt). If the turn included meaningful work — a `git commit`, a `gh pr create`/`merge`, a `gh issue close`/`create`/`comment`, or three or more file edits — and Claude did **not** call `save_context`, the hook returns `decision: "block"` with a directive reason. Claude then either saves what was novel, or briefly says nothing is worth saving — and stops on the next attempt (the runtime sets `stop_hook_active=true`, so the hook never fires twice in a row).

A separate `PostToolUse` hook on `Bash` also injects a soft hint right after a commit/PR/issue command, so the model has the prompt fresh in context when it next pauses to think.

Both hooks **fail open**: a missing transcript, missing `jq`, or any unexpected input causes them to exit silently and let Claude stop normally.

## How the topic-synthesis hook works

A second `Stop` hook (`topic-stop.sh`) makes sure accumulated knowledge gets compiled. When Claude tries to end a turn, it calls `GET /api/v1/contexts/cluster-suggestions`: the backend reports any tag carrying enough live Contexts to warrant a Topic but with no Topic covering it. If any such cluster exists, the hook returns `decision: "block"` with the tag, the Context count, and the exact `context_ids` — so Claude can call `create_topic` and attach them in one step. If Claude judges a cluster should not become a Topic, it says so in one line and stops on the next attempt (`stop_hook_active=true` stops the hook firing twice).

Detecting clusters costs no tokens — it is a single database query. Claude spends tokens only on the synthesis itself, where it still has the full session in context.

This hook **fails open too**: a missing API key, missing `jq`/`curl`, a network error, or any non-2xx response lets Claude stop normally. Unlike the pre-fetch hook it never hard-fails on a missing key — a `Stop` hook that errored out would leave Claude unable to ever end a turn.

The first auto-call to `save_context` may trigger a permission prompt. To make it fully silent, allow it once or pre-allowlist it in `~/.claude/settings.json`:

```json
{
  "permissions": {
    "allow": [
      "mcp__context-memory__save_context"
    ]
  }
}
```

## Requirements

- Claude Code (latest)
- `curl` and `jq` on your `PATH` (both are standard on macOS and most Linux distros)

## License

MIT
