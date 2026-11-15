# Security Policy

## Reporting a vulnerability

Please report suspected vulnerabilities privately through GitHub's private
vulnerability reporting (the "Report a vulnerability" button on the
repository's Security tab). Do not open a public issue.

Include what you found, how to reproduce it, and what an attacker could do
with it. You'll get an acknowledgement within a few days.

## Scope

- The iOS and macOS apps and the `InfluxKit` package.
- The sign-in service in `server/oauth-worker` (flux.bespokebits.dev).

## Secrets

No secrets live in this repository. Sign-in credentials are kept in the
keychain. CI uses only the default read-only `GITHUB_TOKEN`. Deploy and
release credentials live in protected GitHub environments that only `main`
can use, and are provisioned outside the repository.
