#!/usr/bin/env node
// context-memory MCP stdio bridge (v0.15 zero-setup pairing).
//
// plugin.json's HTTP MCP transport can only send static env-expanded headers,
// which forced the auth token into the user's shell config — the single
// setup step users got wrong, and one GUI sessions couldn't satisfy at all.
// This bridge is a stdio MCP server that proxies each JSON-RPC message to
// the local engine's /mcp/ endpoint, discovering the URL + token from the
// credentials file the app publishes (see hooks/lib.mjs). Zero configuration.
//
// MCP stdio framing is newline-delimited JSON-RPC. Requests (with an id) get
// exactly one response line; notifications are forwarded but produce no
// output. Responses may interleave out of order — JSON-RPC matches by id.

import process from 'node:process';
import { createInterface } from 'node:readline';
import { API_KEY, API_URL, apiUrlIsSafe, parseJson } from '../hooks/lib.mjs';

const ENDPOINT = API_URL.replace(/\/+$/, '') + '/mcp/';

function reply(obj) {
  process.stdout.write(JSON.stringify(obj) + '\n');
}

function rpcError(id, message) {
  return { jsonrpc: '2.0', id, error: { code: -32603, message } };
}

const rl = createInterface({ input: process.stdin, crlfDelay: Infinity });
rl.on('line', async (line) => {
  if (!line.trim()) return;
  const msg = parseJson(line);
  if (!msg) return;
  const isRequest = msg.id !== undefined && msg.id !== null;

  if (!API_KEY) {
    if (isRequest)
      reply(
        rpcError(
          msg.id,
          'context-memory credentials not found — launch the context-memory app once to pair (or set CONTEXT_MEMORY_API_KEY).'
        )
      );
    return;
  }
  if (!apiUrlIsSafe(API_URL)) {
    if (isRequest) reply(rpcError(msg.id, `refusing to send token over cleartext non-local URL: ${API_URL}`));
    return;
  }

  try {
    const res = await fetch(ENDPOINT, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${API_KEY}`,
        'Content-Type': 'application/json',
      },
      body: line,
      signal: AbortSignal.timeout(30_000),
    });
    if (!isRequest) return; // notification: engine's ack (if any) is dropped
    const json = parseJson(await res.text());
    if (json && typeof json === 'object') reply(json);
    else reply(rpcError(msg.id, `context-memory engine returned HTTP ${res.status}`));
  } catch {
    if (isRequest)
      reply(
        rpcError(
          msg.id,
          'context-memory engine unreachable at ' + API_URL + ' — is the context-memory app running?'
        )
      );
  }
});
