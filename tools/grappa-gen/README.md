# grappa-gen

Build-host Grappa token generator for CocoWall (macOS command-line tool).

## Why it exists

The AirTraffic sync handshake needs a Grappa client token. Generating
one at runtime on the phone is impossible: the host-session path
(`ATGrappaSession initWithType: 1` +
`establishHostSessionWithDeviceInfo:clientRequestData:`) depends on
CoreFP, which ships on macOS but not on iOS — build #25's on-device
probe run proved every runtime route dead (ATGrappaDeviceInfo returns
nil, establish fails with ATError 0, no framework exports
ALGetGrappaToken).

The token (100 bytes, hex prefix `0101`) is minted for the
(version=1, deviceType=0, protocolVersion=1) triple. It is not bound
to a device or a session; the device-side daemon verifies the token
body itself. Sage approved (2026-10-28) generating our own token with
this pipeline and bundling it as the in-app helper's **last-resort**
fallback — the helper's runtime paths always run first.

## How it is wired

`project.yml`'s "Generate bundled Grappa token" pre-build script
compiles this tool with clang on the build host, runs it, and copies
the resulting hex into the app bundle as `GrappaToken.txt`.
`Sources/App/GrappaHelper.m` reads that file only after all runtime
routes fail, self-checks it with a device session, logs every step,
and adopts it either way (mirroring the reference behaviour).

Generation failure does **not** fail the build: the script prints a
loud `GRAPPA-GEN FAILURE` banner plus an `error:` line into the build
log and ships the app with no bundled token (pure #25 runtime
behaviour). Rationale: the probe builds are themselves the diagnostic
vehicle, and the app log independently reports the absence of a
bundled token, so the failure stays visible in two places.

## Contract

- stdout: exactly one line, the token as lowercase hex, on success.
- stderr: step-by-step diagnostics (`grappa-gen: ` prefix); the token
  itself is never printed there (only its byte count and 2-byte
  prefix).
- Exit codes: 0 success · 2 no AirTraffic framework loadable ·
  3 ATGrappaSession missing/incomplete · 4 establish returned NSError
  for every candidate · 5 session produced no data · 6 session could
  not be created · 70 NSException.

## Hygiene

A generated token is a build product. It is written only under
`build/grappa-gen/` and into the built app bundle — never into the
source tree — and `GrappaToken.txt` is git-ignored. Do not commit a
generated token value.
