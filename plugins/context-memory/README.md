# context-memory plugin for Claude Code

Persistent knowledge base for Claude Code sessions. Automatically retrieves relevant prior context before every prompt and exposes MCP tools for saving, searching, and auditing contexts.

## What it gives you

- **MCP tools** for managing contexts:
  - **Save and search**: `save_context`, `search_contexts`, `get_context`, `delete_context`
  - **Audit and cull**: `list_contexts` (paginated, filterable by repo, source type, tag, and age), `bulk_delete_contexts`
- **Session recall** (v0.5.0+) that, on `SessionStart`, injects this repo's *"where you left off"* (the session summary + its open items) plus durable project facts, and stands up a lightweight instruction so the agent keeps that memory current — scoped **per session × git repo** (v0.8.0+), so concurrent or successive sessions don't clobber each other's state
- **Pre-fetch hook** that searches your context store on every prompt and injects the top hits as additional context for Claude — scoped to your current project and repo (v0.12.0+), so knowledge from where you're working ranks above cross-project hits (a soft preference, not a filter: cross-cutting context still surfaces)
- **End-of-turn nudge** (v0.3.0+) that holds the turn open if meaningful work happened (commits, PRs, issue ops, several edits) without a `save_context` call, so learnings actually land in the store instead of getting lost
- **Topic-synthesis enforcement** (v0.4.0+) that blocks turn-end while tags have accumulated enough Contexts to warrant a Topic but none covers them, so clusters of knowledge get compiled into durable Topics instead of staying scattered — or explicitly dismissed (v0.4.1+) when a cluster genuinely shouldn't become a Topic
- **`/bootstrap-memory` command** (v0.10.0+) that seeds an empty knowledge base from your *existing* Claude Code session history: it distills durable knowledge out of past transcripts into Contexts and Topics, so a new install starts populated instead of blank — the current repo by default, or every project with `/bootstrap-memory all` (v0.11.0+)

Backend service: <https://context-memory.slova.app>

## Install

1. **Get an API key.** Sign up free at <https://context-memory.slova.app/signup/> — with email and a password (confirm via the link we email you), or one click with **Sign up with GitHub**. Either way you land on your account with your `cm_…` key shown exactly once; the full walkthrough lives at [Get started](https://context-memory.slova.app/get-started/). Lost a key later? Log in at your [account page](https://context-memory.slova.app/account/) and rotate it. (Questions: <hello@slova.app>.)

2. **Export the key** in your shell profile (`~/.zshrc`, `~/.bashrc`, etc.):

   ```bash
   export CONTEXT_MEMORY_API_KEY="cm_..."
   ```

   Reload your shell, or open a new terminal, before launching Claude Code.

3. **Add the marketplace** in Claude Code:

   ```
   /plugin marketplace add SlovaApplications/claude-plugins
   ```

4. **Install the plugin**:

   ```
   /plugin install context-memory@slova
   ```

   When the install prompt asks who to install for, choose **Install for you (user scope)**.

5. **Activate it.** `/reload-plugins` loads the plugin's MCP server and hooks into your current session, no restart needed:

   ```
   /reload-plugins
   ```

   The MCP tools should appear and the pre-fetch hook will fire on every prompt.

## Configuration

All configuration is via environment variables (read at MCP-server-start time and on every hook invocation):

| Variable | Default | Purpose |
| --- | --- | --- |
| `CONTEXT_MEMORY_API_KEY` | _(required)_ | Bearer token from your dashboard. If unset, the prefetch hook exits with setup guidance; the other hooks stay silent and the MCP server fails to load. |
| `CONTEXT_MEMORY_API_URL` | `https://cm-api.slova.app` | Override to point at a staging or local development backend. Must be `https://` (or `http://localhost` / `http://127.0.0.1` for local development) — the hooks refuse to send the API key over any other cleartext URL. |
| `CONTEXT_MEMORY_PREFETCH_TIMEOUT` | `1.5` | Seconds to wait for the search API before giving up. |
| `CONTEXT_MEMORY_PREFETCH_LIMIT` | `5` | Max contexts injected per prompt. |
| `CONTEXT_MEMORY_PREFETCH_MAX_BYTES` | `2000` | Hard cap on injected text size. |
| `CONTEXT_MEMORY_TOPIC_STOP_TIMEOUT` | `2` | Seconds the topic-synthesis `Stop` hook waits for the cluster API before giving up. |
| `CONTEXT_MEMORY_RECALL_TIMEOUT` | `2` | Seconds the `SessionStart` recall hook waits per `GET /contexts` call. |
| `CONTEXT_MEMORY_ORIENTATION_LIMIT` | `25` | Max `orientation` facts injected at session start. |
| `CONTEXT_MEMORY_RECALL_MAX_BYTES` | `4000` | Hard cap on the surfaced recall text. The capture instruction is always appended outside this cap. |

## How the pre-fetch hook works

On every `UserPromptSubmit`, the hook:

1. Reads your prompt from the hook stdin payload.
2. Sends it (capped at 500 chars) to `POST /api/v1/contexts/search` with your bearer token.
3. Formats the top hits — a mixed list of Contexts and Topics — as plain markdown (1.5s timeout, 2KB output cap).
4. Prints the markdown on stdout, so Claude Code prepends it to your prompt as additional context. When several Contexts come back and no Topic covers them, it appends a nudge suggesting Claude synthesize them with `create_topic`.

It **fails open**: if the API key isn't set, the network is unreachable, the request times out, or anything else goes wrong, the hook prints nothing and your prompt passes through unchanged.

## How the session-recall hook works

On `SessionStart` (startup, resume, or after `/clear`), `session-recall.mjs` grounds the session in this repo's memory:

1. Derives a canonical repo id (`owner/repo`) from the working directory's `git` origin remote — the **same key used for capture**, so recall and capture stay aligned.
2. Reads the Claude Code `session_id` from the hook input. The rolling summary is scoped **per session × repo**, not per repo: each session keeps its own summary, so concurrent or successive sessions never overwrite each other's end-state.
3. Fetches `session-summary` + all `orientation` Contexts for that repo via `GET /api/v1/contexts` (filtered by `git_repo` + tag, recency-ordered). It makes two summary fetches: one filtered by the current `session_id` (this session's own doc, present only when resuming) and one for the most recent summary across all sessions.
4. Injects them as `additionalContext`, branching on session state:
   - **Resuming** (this session already has a summary): a *"Resuming this session"* block, and the instruction hands back that summary's id so the agent keeps **superseding its own doc**.
   - **Fresh session**: the most recent prior session's summary as a read-only *"Where you left off (previous session)"* block, and the instruction tells the agent to **create its own** `session-summary` stamped with the current `session_id` (then supersede that — `session_id` carries over automatically). It does **not** touch the previous session's summary.
   - Plus a *"Project facts"* block from `orientation`, and the standing capture instruction, all under this repo's `git_repo`.

This is how *"where did I leave off?"* and per-project orientation work without you re-typing them each session. Capture is **instruction-driven** — the agent follows the injected reminder — so a missed turn just means a slightly staler summary; nothing breaks. (If the client doesn't supply a `session_id`, the hook falls back to a single repo-wide rolling summary.)

It **fails open** on everything (no git repo, missing key, unreachable backend, non-2xx): it injects nothing rather than ever erroring at session start. Outside a git repo it does nothing at all.

## How the end-of-turn nudge works

When Claude tries to end a turn, the `Stop` hook scans this turn's events (everything after the last user prompt). If the turn included meaningful work — a `git commit`, a `gh pr create`/`merge`, a `gh issue close`/`create`/`comment`, or three or more file edits — and Claude did **not** call `save_context`, the hook returns `decision: "block"` with a directive reason. Claude then either saves what was novel, or briefly says nothing is worth saving — and stops on the next attempt (the runtime sets `stop_hook_active=true`, so the hook never fires twice in a row).

A separate `PostToolUse` hook on `Bash` also injects a soft hint right after a commit/PR/issue command, so the model has the prompt fresh in context when it next pauses to think.

Both hooks **fail open**: a missing transcript or any unexpected input causes them to exit silently and let Claude stop normally.

## How the topic-synthesis hook works

A second `Stop` hook (`topic-stop.mjs`) makes sure accumulated knowledge gets compiled. When Claude tries to end a turn, it calls `GET /api/v1/contexts/cluster-suggestions`: the backend reports any tag carrying enough live Contexts to warrant a Topic but with no Topic covering it. If any such cluster exists, the hook returns `decision: "block"` with the tag, the Context count, and the exact `context_ids` — so Claude can call `create_topic` and attach them in one step. If Claude judges a cluster should not become a Topic — a generic label, or Contexts too scattered to cohere under one scope — it calls `dismiss_cluster` instead, and that cluster stops being flagged on future turns.

Detecting clusters costs no tokens — it is a single database query. Claude spends tokens only on the synthesis itself, where it still has the full session in context.

This hook **fails open too**: a missing API key, a network error, or any non-2xx response lets Claude stop normally. Unlike the pre-fetch hook it never hard-fails on a missing key — a `Stop` hook that errored out would leave Claude unable to ever end a turn.

The first auto-call to `save_context` may trigger a permission prompt. To make it fully silent, allow it once or pre-allowlist it in `~/.claude/settings.json`:

```json
{
  "permissions": {
    "allow": [
      "mcp__plugin_context-memory_context-memory__save_context"
    ]
  }
}
```

## How the `/bootstrap-memory` command works

A fresh knowledge base is empty, but your Claude Code history is not. Run
`/bootstrap-memory` in a repo and it seeds the store from that repo's past
sessions:

1. A small Node script (`commands/scripts/bootstrap-extract.mjs`, built-ins only —
   no extra dependencies) reads this repo's local transcripts from
   `~/.claude/projects/…` and renders each substantive session into a compact,
   signal-only digest. **Transcripts never leave your machine** — only the
   distilled, approved knowledge is written.
2. Claude reads each digest and distills the genuinely durable, non-obvious
   knowledge (gotchas, decisions, orientation) into candidate Contexts and
   Topics — the same selectivity as the live `save_context` flow.
3. Before anything is saved, it **dedups against what's already there** (skip
   true duplicates; merge related-but-distinct findings into a Topic) and shows
   you a preview to approve or edit.
4. Approved atoms are written with `source_type=session-history`, via the same
   MCP tools the rest of the plugin uses.

It is **idempotent**: each write records the originating session, so a second
run skips sessions it has already processed and makes no changes.

By default it scopes to the **current repo**. Run `/bootstrap-memory all`
(v0.11.0+) to seed from **every** project under `~/.claude/projects` — each
atom is tagged with its own repo (`git_repo`) so it stays filterable. The
dedup + preview gate matter even more in `all` mode, since it also surfaces
non-dev and local-only directories.

## Requirements

- Claude Code (latest), on **macOS, Linux, or Windows**.
- **Node.js 18 or newer**, available as `node` on your `PATH`. The plugin's hooks are Node scripts. Claude Code's installer may bundle its own Node without exposing a `node` command, so if `node --version` doesn't print a version, install Node yourself (for example `brew install node`, your distro's package manager, or [nodejs.org](https://nodejs.org)). If `node` can't be found, the hooks can't run and Claude Code reports a hook error each turn.
- `git` is used only for the per-repo session recall; outside a git repo that hook simply no-ops.

## License

MIT
