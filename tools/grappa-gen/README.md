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

This tool's primary route is the macOS home one: `dlsym`
`ALGetGrappaToken` in every loaded AirTraffic framework (and
RTLD_DEFAULT) and call it with the (1,0,1) triple — the entry the
Vellum/airlift dissection records name as how a Mac sync host mints
its token. The session-class route is kept as second in line; run
#29 proved `ATGrappaSession` does not exist in macOS's
AirTrafficHost (it lives in iOS's AirTrafficDevice), so on the build
host that route is expected to stay unreachable. Each run also logs,
as evidence only, the Grappa-containing class names of the
AirTrafficHost image and the per-framework `ATGrappaDeviceInfo`
probe results.

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
- argv[1] (optional): diagnostics file path. Every diagnostic line is
  also written there via raw `write()`+`fsync`, and numbered
  `MARK n` lines bracket every framework call — MARK 0 is main()'s
  first statement. If the process is killed externally (run #26 died
  with SIGKILL/137 and zero captured output), the file still shows
  exactly how far it got. The build script runs the tool under a 20s
  watchdog (stack `sample` on timeout) and ad-hoc re-signs + retries
  once when the diag file lacks MARK 0 (dyld/code-signature death).
- Exit codes: 0 success · 2 no AirTraffic framework loadable ·
  3 no framework token entry produced a token and ATGrappaSession
  missing/incomplete · 4 establish returned NSError for every
  candidate · 5 session produced no data · 6 session could not be
  created · 70 NSException.

## Debugging: pre-main SIGKILL bisect (builds #26–#28)

Runs #26/#27: the generator died with SIGKILL (exit 137) **before
main()'s first statement** — no diag file, watchdog_timeout=0, ad-hoc
re-signing changed nothing, no crash report (AMFI/policy-class kill).
The build script now bisects "our binary" vs "the CI execution
environment" through one identical compile+run path:

- level 0 `bisect/hello.c` — trivial C tool;
- level 1 `bisect/hello_foundation.m` — ObjC + Foundation with
  grappa-gen's exact compile flags;
- level 2 `bisect/hello_dlopen.m` — level 1 + one
  `dlopen(AirTrafficHost)`;
- level 3 — grappa-gen itself.

Each level leaves MARK lines in its own write()+fsync diag file and
runs under the same 20s watchdog; the script also probes
`ENABLE_USER_SCRIPT_SANDBOXING` in the generated pbxproj, each
binary's `LC_BUILD_VERSION`, and collects DiagnosticReports + a
bounded `log show` query (amfid / tool names). See the `BISECT
SUMMARY` block at the end of the build log.

## Hygiene

A generated token is a build product. It is written only under
`build/grappa-gen/` and into the built app bundle — never into the
source tree — and `GrappaToken.txt` is git-ignored. Do not commit a
generated token value.
