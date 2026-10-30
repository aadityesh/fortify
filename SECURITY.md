# Security policy

## Reporting a vulnerability

If you find a way to see or use a locked app without Touch ID or the PIN,
please don't open a public issue. Report it privately through
[GitHub's security advisories](https://github.com/aadityesh/fortify/security/advisories/new)
(Security tab → Report a vulnerability).

Please include the macOS version, the Fortify version, the app involved, and
the steps. You'll get a reply within a week, and credit in the release notes
if you'd like it.

## Scope

In scope: anything that shows a locked app's content, or lets someone use it,
without unlocking; ways to learn or skip the PIN; and the lock card leaving the
Mac stuck.

Out of scope: someone signed in to your macOS account force-quitting Fortify,
or reading app data straight from disk. Fortify is a privacy lock, not
encryption; see "What it does and doesn't protect against" in the
[README](README.md).

## Supported versions

Fixes go into the latest release.
