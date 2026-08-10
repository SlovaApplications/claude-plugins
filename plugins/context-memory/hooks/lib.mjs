// Shared helpers for the context-memory Claude Code hooks.
//
// The hooks are Node scripts (not bash) so they run identically on macOS,
// Linux, and Windows with no external dependencies: Claude Code already runs
// on Node, so `node` is always on PATH, and Node's built-in `fetch` + JSON
// replace the old curl + jq. Every hook fails open — any unexpected error
// makes it emit nothing rather than disrupt the session.

import process from 'node:process';
import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

// v0.15 zero-setup pairing: the context-memory app publishes its connection
// details as a credentials.json next to its database. Discovering it by file
// means no shell configuration, and it works identically in GUI and CLI
// sessions (GUI apps never source ~/.zshrc — a whole class of 401s v0.14
// couldn't avoid). Env vars remain as explicit overrides only.
export function discoverCredentials() {
  const home = homedir();
  const candidates = process.env.CONTEXT_MEMORY_CREDENTIALS
    ? [process.env.CONTEXT_MEMORY_CREDENTIALS] // tests / unusual setups
    : [
        // Mac App Store build (sandboxed): inside the app container.
        join(
          home,
          'Library/Containers/app.slova.context-memory/Data/Library/Application Support/context-memory/credentials.json'
        ),
        // Developer ID / direct builds.
        join(home, 'Library/Application Support/context-memory/credentials.json'),
        // Portable engine (`cm-bench serve` with CM_DB_PATH under ~/.config).
        join(home, '.config/context-memory/credentials.json'),
      ];
  for (const path of candidates) {
    try {
      const parsed = JSON.parse(readFileSync(path, 'utf8'));
      if (typeof parsed?.token === 'string' && parsed.token) {
        return {
          token: parsed.token,
          url: typeof parsed.url === 'string' ? parsed.url : '',
        };
      }
    } catch {
      // missing or malformed — keep looking; fail open like everything else
    }
  }
  return { token: '', url: '' };
}

const creds = process.env.CONTEXT_MEMORY_API_KEY ? { token: '', url: '' } : discoverCredentials();
export const API_KEY = process.env.CONTEXT_MEMORY_API_KEY || creds.token;
// Default must stay in lockstep with the app's port (EngineConstants).
export const API_URL =
  process.env.CONTEXT_MEMORY_API_URL || creds.url || 'http://127.0.0.1:41414';

// Numeric env var with a default; non-numeric or unset falls back.
export function envNum(name, fallback) {
  const raw = process.env[name];
  if (raw === undefined || raw === '') return fallback;
  const n = Number(raw);
  return Number.isFinite(n) ? n : fallback;
}

// Refuse to send the API key over a cleartext connection. https is always
// fine; http only for a local backend, where there is no network hop to
// eavesdrop. Mirrors the case-guard in the original bash hooks.
export function apiUrlIsSafe(url = API_URL) {
  return (
    /^https:\/\//.test(url) ||
    /^http:\/\/localhost(:\d+)?(\/|$)/.test(url) ||
    /^http:\/\/127\.0\.0\.1(:\d+)?(\/|$)/.test(url)
  );
}

// Read the hook payload from stdin as a string.
export async function readStdin() {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  return Buffer.concat(chunks).toString('utf8');
}

export function parseJson(text) {
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

// One authenticated request to the backend. Returns { status, json } on a
// completed HTTP exchange (json is null if the body didn't parse), or null on
// any transport error / timeout — callers treat null as "fail open".
export async function apiRequest(path, { method = 'GET', query, body, timeoutSec } = {}) {
  let url;
  try {
    url = new URL(API_URL.replace(/\/+$/, '') + path);
  } catch {
    return null;
  }
  if (query) {
    for (const [key, value] of Object.entries(query)) {
      if (value === undefined || value === null) continue;
      for (const v of Array.isArray(value) ? value : [value]) {
        url.searchParams.append(key, String(v));
      }
    }
  }
  const headers = { Authorization: `Bearer ${API_KEY}` };
  let payload;
  if (body !== undefined) {
    headers['Content-Type'] = 'application/json';
    payload = JSON.stringify(body);
  }
  try {
    const res = await fetch(url, {
      method,
      headers,
      body: payload,
      signal: AbortSignal.timeout(Math.max(1, Math.round(timeoutSec * 1000)))
    });
    const text = await res.text();
    return { status: res.status, json: parseJson(text) };
  } catch {
    return null;
  }
}

export function is2xx(status) {
  return Number.isInteger(status) && status >= 200 && status <= 299;
}

// Truncate to at most maxBytes UTF-8 bytes (mirrors `head -c`), returning a
// valid string (a partial trailing char is dropped rather than left mangled).
export function clipBytes(str, maxBytes) {
  const buf = Buffer.from(str, 'utf8');
  if (buf.length <= maxBytes) return str;
  let end = maxBytes;
  // Back off the cut point so we don't slice through a multi-byte sequence.
  while (end > 0 && (buf[end] & 0xc0) === 0x80) end--;
  return buf.subarray(0, end).toString('utf8');
}

// Truncate to n Unicode codepoints, appending "…" when shortened (mirrors the
// jq `clip` helper used in the original prefetch hook).
export function clipChars(str, n) {
  const cps = Array.from(str);
  return cps.length > n ? cps.slice(0, n).join('') + '…' : str;
}

// Write a JSON object to stdout compactly (the hooks' machine-readable output).
export function emit(obj) {
  process.stdout.write(JSON.stringify(obj));
}
