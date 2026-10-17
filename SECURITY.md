# Security Policy

## Reporting a vulnerability

Please report security issues privately through GitHub's
[private vulnerability reporting](../../security/advisories/new) (the
**Security** tab → **Report a vulnerability**), not in a public issue.

Only the latest release is supported; fixes ship in a new release.

## Scope

This daemon executes on macOS with private entitlements and Full Disk Access to
bridge iMessage and SMS traffic. Of particular interest are vulnerabilities that
could allow unauthorized command execution, bypass bearer token authentication,
leak credentials, or expose message content outside the configured endpoints.
