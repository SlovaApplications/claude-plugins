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

This repository ships client-side code that runs locally in your shell on every Claude Code prompt and connects to the context-memory backend at `https://cm-api.slova.app` (or your configured override). In scope:

- The plugin hooks under `plugins/context-memory/hooks/` — `prefetch.mjs`, `session-recall.mjs`, `stop-nudge.mjs`, `topic-stop.mjs`, `post-bash-nudge.mjs`, and the shared `lib.mjs` (Node scripts that run locally on your machine and call the backend)
- The `/bootstrap-memory` command script (`plugins/context-memory/commands/scripts/bootstrap-extract.mjs`), which reads local transcripts
- The plugin manifest and marketplace manifest
- Any future plugins added under `plugins/`

Backend-service vulnerabilities are out of scope for this repository — please email the same address and we'll route the report internally.

## Automated scanning

Every pull request and push to `main` runs [Gitleaks](https://github.com/gitleaks/gitleaks)
and [TruffleHog](https://github.com/trufflesecurity/trufflehog) over the full
git history (`.github/workflows/security-scan.yml`). Contributors can also
enable the matching local pre-commit hooks (requires Docker):

```bash
pip install pre-commit
pre-commit install                       # gitleaks on every commit
pre-commit install --hook-type pre-push  # trufflehog before every push
```

## Out of scope

- Reports that require an attacker who already has shell or filesystem access to the user's machine
- Issues caused by user-installed third-party plugins that conflict with this one
- Missing security headers or rate limits on the hosted service (`https://context-memory.slova.app` / `https://cm-api.slova.app`) — those are tracked against the backend, not this client-side plugin repo; email <support@slova.app> to report them
