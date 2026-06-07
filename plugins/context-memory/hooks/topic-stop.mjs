#!/usr/bin/env node
// Stop hook: block the agent from ending its turn while context-memory has
// tag clusters that crossed the synthesis threshold with no Topic covering
// them. Detection is one read-only API call (no tokens spent); the agent
// resolves each cluster itself — create_topic to synthesize, or
// dismiss_cluster when a cluster should not become a Topic — while it still
// has the full session context, more than it ever saved to context-memory.
//
// stop_hook_active guard: once the agent has already been asked to continue,
// exit 0 so the hook never loops forever.
// Fails open on every error (missing key/deps, network, bad response): a Stop
// hook that hard-failed would wedge the agent, unable to ever finish. Key
// misconfiguration is surfaced loudly by the UserPromptSubmit prefetch hook
// instead — this hook stays silent and lets the agent stop.

import { API_KEY, apiUrlIsSafe, apiRequest, is2xx, readStdin, parseJson, emit, envNum } from './lib.mjs';

const TIMEOUT = envNum('CONTEXT_MEMORY_TOPIC_STOP_TIMEOUT', 2);
const MAX_IDS = 25;

try {
  if (!API_KEY) process.exit(0);
  if (!apiUrlIsSafe()) process.exit(0);

  const input = parseJson(await readStdin());
  if (input && (input.stop_hook_active === true || input.stop_hook_active === 'true')) process.exit(0);

  const res = await apiRequest('/api/v1/contexts/cluster-suggestions', { timeoutSec: TIMEOUT });
  if (!res || !is2xx(res.status) || !res.json) process.exit(0);

  const clusters = Array.isArray(res.json.clusters) ? res.json.clusters : [];
  const count = clusters.length;
  if (count <= 0) process.exit(0);

  // One imperative line per cluster: the tag, the live-Context count, and the
  // context_ids to attach. IDs are capped so a very large cluster cannot blow
  // up the block message; the agent can list_contexts by tag for the rest.
  const detail = clusters
    .map((c) => {
      const ids = Array.isArray(c.context_ids) ? c.context_ids : [];
      const total = Number.isInteger(c.context_count) ? c.context_count : ids.length;
      const shown = Math.min(MAX_IDS, ids.length);
      let line = `  - tag "${c.tag}": ${total} Contexts, no Topic. context_ids: ${ids.slice(0, MAX_IDS).join(', ')}`;
      if (total > shown) {
        line += ` (+${total - shown} more — list_contexts tag="${c.tag}" for the rest)`;
      }
      return line;
    })
    .join('\n');
  if (!detail) process.exit(0);

  const reason =
    `context-memory: ${count} tag cluster(s) have reached the synthesis threshold with no Topic covering them. Before you stop, call create_topic for each cluster below — give each a title, scope, overview, and a body that compiles the understanding, and pass the listed context_ids so the Contexts become a durable synthesis:\n` +
    `${detail}\n` +
    `You have more context right now than a future session will. If a cluster genuinely should not become a Topic — a generic/process label, or Contexts too scattered to cohere under one scope — call dismiss_cluster(tag, reason) instead of create_topic. A dismissed cluster stops being flagged; this is how you clear a cluster you are deliberately not synthesizing.`;

  emit({ decision: 'block', reason });
} catch {
  // fail open
}
process.exit(0);
