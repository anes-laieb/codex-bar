# Security Policy

## Supported versions

Security fixes are made against the latest code on the default branch and are included
in the next available release. Older releases are not maintained with separate security
patches.

## Reporting a vulnerability

Please do **not** disclose a suspected vulnerability in a public issue, pull request,
discussion, or social-media post.

Use GitHub's private vulnerability reporting flow:

<https://github.com/anes-laieb/codex-bar/security/advisories/new>

Include the affected version, impact, reproduction steps or proof of concept, and any
suggested mitigation. Remove unrelated prompts, credentials, session text, and personal
paths from diagnostic material.

The maintainers will acknowledge the report when possible, investigate it, and coordinate
a fix and disclosure. Please allow a reasonable remediation period before publishing
details.

## Security model

Codex Bar is a locally built, ad-hoc-signed macOS application. It reads the current
user's Codex thread database and rollout logs, launches Codex deep links, displays local
notifications, and stores preferences in macOS user defaults. Its optional update check
retrieves public release metadata from GitHub; it does not download or install an update
automatically.

Review the source and installation scripts before running them, especially when using a
fork. Install only from a repository and revision you trust.
