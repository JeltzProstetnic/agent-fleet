#!/usr/bin/env bash
# Leak SHAPES for the public template (CFG-869). Sourced by .githooks/pre-push and
# by setup/tests/test-template-smoke.sh, so the push guard and the smoke test read
# ONE definition and cannot drift. Keep this file free of any real identifier.
#
# SHAPE_PATTERNS — grep -E alternation of identifier CLASSES that must not appear in
# template files: a home directory, a Windows / VPS hostname, an IPv4 address, an
# e-mail address. Matched with -o, so SHAPE_ALLOW judges the matched TOKEN.
#
# SHAPE_ALLOW — grep -E alternation applied to "<file>:<line>:<token>" lines, i.e.
# anchored on ":<token>$". Tokens that are placeholders, not identifiers:
#   - generic home names: /home/user, /home/username, /home/myuser, /home/you, …
#   - loopback, any, broadcast / netmask, the public resolvers, the Docker bridge,
#     and the RFC 5737 documentation ranges (192.0.2/24, 198.51.100/24, 203.0.113/24),
#     which are reserved and can never be anyone's real address — use THOSE in docs
#   - e-mail accounts that are placeholders or service senders, judged by the LOCAL
#     part (you@, your-…@, name@, user@, persona@, noreply@, notifications@, git@,
#     %s@) — so alice@example.com is still flagged: write you@example.com in examples
# A deployment's own literals (owner, handles, hosts, addresses, an employer) belong
# in the OPTIONAL, gitignored .githooks/personal-patterns.local — see the .example.

SHAPE_PATTERNS='/home/[a-z][a-z0-9_-]*|DESKTOP-[0-9A-Z]{7}|\bsrv[0-9]{6}\b|\b[0-9]{1,3}(\.[0-9]{1,3}){3}\b|[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}'

SHAPE_ALLOW=':/home/(user|username|myuser|you|yourname|example)$|:(127\.[0-9]+\.[0-9]+\.[0-9]+|0\.0\.0\.0|255\.255\.255\.(0|255)|8\.8\.8\.8|8\.8\.4\.4|1\.1\.1\.1|172\.17\.0\.1|192\.0\.2\.[0-9]+|198\.51\.100\.[0-9]+|203\.0\.113\.[0-9]+)$|:(you|your[a-z-]*|name|user|username|persona|noreply|no-reply|notifications|git|%s)@[^:]*$'

# File classes the guard scans (git pathspecs).
SCAN_PATHSPECS=('*.md' '*.sh' '*.json' '*.yml' '*.yaml' '*.conf' '*.js')
