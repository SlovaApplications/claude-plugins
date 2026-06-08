---
description: Seed context-memory from your past Claude Code session history — distills durable knowledge from old transcripts into Contexts and Topics.
---

# Bootstrap context-memory from session history

Seed this user's knowledge base by mining their existing Claude Code transcripts,
distilling each substantive session into durable Contexts (and Topics where they
cohere), and saving them via the context-memory MCP tools.

**Scope** — depends on the argument (`$ARGUMENTS`):
- _no argument_ → just the **current repo**.
- `all` → **every project** under `~/.claude/projects` (across all repos). Each
  session carries its own `gitRepo`, so atoms stay attributed/filterable per
  repo. Note `all` will also surface non-dev or local-only directories; lean
  even harder on the dedup + preview gate there.

Transcripts never leave the machine: you read them locally and only the
distilled, user-approved knowledge is written. Be conservative — a sparse,
high-signal KB is the goal; a polluted one is worse than an empty one.

## Step 1 — Enumerate substantive sessions (deterministic)

Current repo (default):

```
!node "${CLAUDE_PLUGIN_ROOT}/commands/scripts/bootstrap-extract.mjs" list "$(pwd)"
```

All repos (when the argument is `all`):

```
!node "${CLAUDE_PLUGIN_ROOT}/commands/scripts/bootstrap-extract.mjs" list-all
```

Each entry has `{file, sessionId, title, substantive, cwd, gitRepo}`. Ignore
non-substantive sessions (trivial/command-only). In `all` mode, consider
grouping by `gitRepo` and confirming scope with the user before distilling.

## Step 2 — Idempotency gate (skip already-bootstrapped sessions)

Bootstrap must be idempotent: a second run makes no changes. For each
substantive session, do an existence check with `list_contexts` filtered by
**both** `source_type="session-history"` and `session_id="<that sessionId>"`
(`limit` 1). If it returns any context, that session was already bootstrapped —
**skip it**. (Filter by `session_id`; don't try to read it back from the
result text — `list_contexts` renders only id/body-head/tags, not `session_id`.)
If every substantive session is already processed, say so and stop.

## Step 3 — Distill each remaining session

For each session to process, render its digest:

```
!node "${CLAUDE_PLUGIN_ROOT}/commands/scripts/bootstrap-extract.mjs" digest "<file>"
```

Read the digest and extract ONLY non-obvious, reusable knowledge, exactly as the
live `save_context` flow would: `orientation` (how things are wired), `gotcha`
(a trap/constraint that bit someone), `decision` (a choice + why), `dead-end`
(an approach that failed), and at most one `session-summary` if there are
standing open items. Most sessions yield 0–3 atoms; a pure chore yields none —
do not invent value. Never save what git/the code already records.

Produce candidates in this shape (member-index mapping makes Topic membership
explicit — only the listed atoms join a Topic; the rest are saved standalone):

```jsonc
{
  "contexts": [ { "body": "...", "tags": [...], "kind": "gotcha" }, ... ],
  "topics": [
    {
      "title": "...", "scope": "X for Y", "overview": "...",
      "member_indices": [0, 1],          // indices into contexts[] that belong here
      "merge_existing_ids": ["<kb-id>"]  // pre-existing KB contexts to cross-link
    }
  ]
}
```

## Step 4 — Dedup by retrieve-then-judge (NOT a similarity threshold)

For each candidate, `search_contexts` for near-neighbors and classify:
- **duplicate** — the knowledge is already captured → **skip it** (say which id).
- **overlap** — related but distinct (e.g. same root cause, different fix site)
  → keep the atom AND add the neighbor's id to the relevant Topic's
  `merge_existing_ids`, so both compile under one Topic.
- **novel** — no neighbor covers it → keep.

(Search score is unnormalized/query-relative, so judge from the retrieved
bodies; don't threshold on a number.)

## Step 5 — Preview gate (REQUIRED before any write)

Show the user the full candidate set — every Context (kind, tags, body) and every
Topic (with its members and merges) — and the count of skipped duplicates. Ask
for explicit approval, and let them drop/edit any item. **Write nothing until
they approve.**

## Step 6 — Apply via MCP

On approval, for each session:
1. `save_context` each kept atom with `source_type="session-history"`,
   `session_id="<the historical sessionId>"`, and its tags. Set `git_repo` to
   that session's repo: the current repo in default mode, or the session's own
   `gitRepo` from `list-all` in `all` mode (omit `git_repo` when `gitRepo` is
   null — a local-only dir with no remote).
   (`source_type` + `session_id` are what make Step 2 idempotent next run.)
2. For each Topic, `create_topic`, then attach the newly-saved member atoms and
   every `merge_existing_ids` id via `attach_context_to_topic`.

Report what was saved (ids), what was skipped as duplicate, and what was merged
into Topics with pre-existing knowledge.
