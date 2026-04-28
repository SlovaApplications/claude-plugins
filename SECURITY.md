# Security policy

## Reporting a vulnerability

Please **do not** open a public GitHub issue for security reports.

Email <support@slova.app> with:

- A description of the issue
- Steps to reproduce (proof-of-concept welcome)
- The plugin version (`/plugin list` in Claude Code) and your operating system
- Whether you'd like to be credited in any subsequent disclosure

We aim to acknowledge reports within **3 business days** and to ship a fix or mitigation for confirmed vulnerabilities within **30 days**, depending on severity.

## Scope

This repository ships client-side code that runs locally in your shell on every Claude Code prompt and connects to the context-memory backend at `https://api.context-memory.slova.app` (or your configured override). In scope:

- The pre-fetch hook (`plugins/context-memory/hooks/prefetch.sh`)
- The plugin manifest and marketplace manifest
- Any future plugins added under `plugins/`

Backend-service vulnerabilities are out of scope for this repository — please email the same address and we'll route the report internally.

## Out of scope

- Reports that require an attacker who already has shell or filesystem access to the user's machine
- Issues caused by user-installed third-party plugins that conflict with this one
- Missing security headers or rate limits on `https://context-memory.slova.app` (frontend not yet deployed)
