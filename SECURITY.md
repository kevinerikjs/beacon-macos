# Security Policy

## Reporting a vulnerability

Email **[support@beamscreen.app](mailto:support@beamscreen.app)** with the subject `Security`.

Please do not open a public issue for a security problem. Beacon captures screens and audio, so a
public report gives every user of the current build a problem before there is a fix available.

You should get a first response within 72 hours. If you do not hear back, send a follow-up, since
it more likely means the mail went astray than that it was ignored.

Useful things to include, as far as you have them: what you did, what happened, what you expected,
the Beacon version, and your macOS version. A proof of concept helps but is not required to file.

## What is in scope

Beacon runs on your Mac, holds Screen Recording permission, and accepts network connections from
paired devices. The areas most worth looking at:

- **Pairing and authentication.** `Pairing/PairingManager.swift` and `Pairing/KeyStore.swift`.
  Anything that lets an unpaired device connect, or lets a paired device escalate, is serious.
- **The wire protocol.** `Network/Protocol.swift`, `Network/StreamServer.swift`, and
  `Network/StreamSession.swift`. Malformed packet handling, memory safety, and anything reachable
  before authentication.
- **Keychain handling.** How pairing credentials are stored, scoped, and cleared.
- **Capture permissions.** Anything that causes capture to run, or keep running, without the user
  knowing.

Reports that an attacker already on your Mac with your privileges can read your data are not
vulnerabilities. That is what having your password means.

## Out of scope

- Findings from automated scanners with no demonstrated exploit path
- Denial of service that requires the attacker to already be on your local network and paired
- Social engineering, physical access, and anything targeting Apple's frameworks rather than
  Beacon's use of them
- Missing hardening that has no exploit behind it, reported as a finding on its own

## Disclosure

Report privately, give us a reasonable window to ship a fix, then publish whatever you like. If a
fix is taking too long, say so and we will agree a date rather than let it drift. Fixes ship
through the normal Sparkle update channel, and the release notes will credit you unless you would
rather stay anonymous.

There is no bug bounty. This is a one-person project with no budget for one.

## Scope of this policy

This policy covers Beacon (this repository) and [Beam for
iOS](https://github.com/kevinerikjs/beam-ios). Report issues in either to the same address.
