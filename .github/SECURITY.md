# Security Policy

## Reporting a vulnerability

Please **do not** open a public issue for a security problem.

Use GitHub's private vulnerability reporting instead:
<https://github.com/Pondsi/infinitycontext/security/advisories/new>

If that is not available to you, open a minimal issue asking for a private channel
**without any technical detail**, and the maintainer will reach out.

Please include, when you can:

- the version (`version` in `SKILL.md` frontmatter) and host (dsh / OpenClaw / Claude Code / …);
- the exact command and the JSON result, redacted of secrets;
- a description of the impact and, if possible, a minimal reproduction.

## Scope

In scope: the published package — `SKILL.md`, `README.md`, `说明.md`, `CHANGELOG.md`,
`SPONSORS.md`, `LICENSE`, `checksums.txt`, `scripts/*.py`, `references/*.md`, `sponsors/*`.

Out of scope for this policy: the optional OpenClaw/Windows integration in the repository's
`openclaw/` folder. It is not part of the published artifact and carries its own
`openclaw/checksums.txt`; report issues there with the same private channel.

## Design boundaries worth knowing

- The core has **no network access, no shell and no subprocesses**.
- The archive is owner-only and fail-closed: if permissions cannot be enforced, archiving
  aborts and the half-written database is destroyed.
- Redaction is **best-effort**, not encryption. Treat the archive as sensitive data.
- Retention is bounded by default (30 days) and can be disabled entirely with
  `INFINITY_CONTEXT_NO_ARCHIVE=1`.

## Response

Reports are acknowledged as soon as possible. A fix is released with a new patch version,
the ClawHub audit for that version is re-run, and the changelog entry names the issue
without exposing the reporter.
