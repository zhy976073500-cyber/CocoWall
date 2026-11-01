# Vendored upstream core — AirliftFFI

The entire contents of this directory (`Cargo.toml`, `Cargo.lock`,
`src/`, `include/`, `vendor/`) are a verbatim copy of the `rust-core/`
directory of the AirCard-iOS project:

- Project: AirCard-iOS — https://github.com/Mak5er/AirCard-iOS
- Author: Johnny Franks (Mak5er)
- Upstream commit: 40640c4d827aeab8d798285b57d24fcf6be070d0 (v1.3.2)
- License: MIT License, Copyright (c) 2026 Johnny Franks (see the
  repository-root NOTICE and the upstream LICENSE)

Vendored on 2026-10-30, replacing CocoWall's own reimplemented write
path (tunnel / staging / AirTraffic sync), which behaved identically
in every audited respect yet failed to inject on device where the
upstream app succeeds on the same phone and package. From this point
the write path is the upstream implementation itself, not a rewrite.

Local modifications to the vendored tree: NONE until 2026-11-01. First
local source change, 2026-11-01 (Sage-approved poster_refresh feature,
registered in SPEC.md):

- ADDED `src/poster_refresh.rs` — new module implementing a
  PosterBoard-only refresh over the RSD tunnel (DVT
  com.apple.instruments.dtservicehub -> processcontrol channel ->
  killPid: on the PosterBoard daemon, then liveness verification via
  deviceinfo). Uses only the already-vendored `idevice` crate's DVT
  clients; no upstream file was altered to build it.
- `src/lib.rs` — pure additions only: `pub mod poster_refresh;` and the
  new FFI export `al_poster_refresh` (with its catch_unwind wrapper).
  No existing line changed.
- `include/airlift.h` — pure addition only: the `al_poster_refresh`
  declaration next to `al_device_respring`. No existing line changed.

Second local source change, 2026-11-01 (Sage-approved device poster
store detect/cleanup feature, registered in SPEC.md):

- ADDED `src/poster_store.rs` — new module implementing enumeration
  and deletion of the descriptors actually present in the device's
  PRBPosterExtensionDataStore, over the RSD tunnel. Enumeration and
  auditing go through AFC (com.apple.afc.shim.remote): a temporary
  symlink is planted in the AFC media jail pointing at the store's
  Extensions directory, and descriptors are listed/read through it.
  Planting mechanism (revised 2026-11-01, run #107 hardware log):
  the AFC MakeLink operation is refused by the RSD AFC service
  (OpNotSupported), so the link is planted the flash way — a
  StreamingZip archive (same builder shape as the delete staging)
  whose symlink entry streaming_zip_conduit extracts into a scratch
  Media subdir, then an AFC rename moves the extracted symlink to
  the Media root, the geometry its ../../../ target is calibrated
  for. (Revised again later the same day, run #108 hardware log:
  the rename step is refused too (InvalidArg) and the flash flow
  never renames — its root-level link is landed by the ATC sync —
  so the link now stays at its staged depth inside the scratch
  subdir and the archive's symlink target is computed for that
  depth: six ../ to /var plus the container tail (variant
  `relative-depth`); if that does not traverse, an archive with
  the plain absolute target is staged and tried in the same
  session (variant `absolute`). The archive builder's link target
  is a parameter; the delete flow passes the original
  root-calibrated target unchanged.) (Diagnostic revision, run
  #110: both #109 target variants failed the staged-presence
  check on device while the #108 archive passed it; the only
  staging delta is the symlink target string, and AFC
  get_file_info is lstat-like, so the conduit extractor
  dropping escape-target symlinks is the leading but unproven
  mechanism. plant_store_link's verification-failure branch
  now logs a level-by-level enumeration of the extracted
  staging tree (stage.diag lines) before cleanup; behavior
  otherwise unchanged.) Deletion does NOT erase through AFC: each
  descriptor is moved out of the store by an AirTraffic/Books sync
  whose two books (staging link + the descriptor, identified by its
  Airlock-escaping relative path) make the on-device ATAirlock daemon
  download it into Media as an `airlift-quarantine-<token>` copy —
  the Walllive-verified airlift.delete mechanism; the ATC wire flow
  mirrors `exploit::run`'s, reusing the crate-public
  `crate::grappa::generate_grappa_token`. A fresh-connection audit
  must re-confirm each deleted path absent. Uses only the
  already-vendored `idevice` crate; no upstream file was altered.
- `src/poster_refresh.rs` — one branch added (same change series):
  in the identity stage, a successfully read process list with no
  PosterBoard entry now returns confirmed with an
  `already_stopped` log line (Walllive parity) instead of a
  pidNotFound failure. No other line changed.
- `src/lib.rs` — pure additions only: `pub mod poster_store;` and the
  new FFI exports `al_poster_store_list` / `al_poster_store_delete`
  (with catch_unwind wrappers). No existing line changed.
- `include/airlift.h` — pure additions only: the two declarations
  next to `al_poster_refresh`. No existing line changed.

Third local source change, 2026-11-01 (poster_refresh signal fix,
registered in SPEC.md). This is the first change that touches a
vendored upstream file itself — additively only:

- `vendor/idevice/src/services/dvt/process_control.rs` — ADDED one
  method, `ProcessControlClient::send_signal(pid, signal)`, sending
  the DTX ProcessControl selector `sendSignal:toPid:` (aux args:
  signal first, then pid, mirroring the selector; wire shape mirrors
  the adjacent upstream `kill_app`). No existing line changed;
  `kill_app` (`killPid:`) is untouched. Reason: on hardware (run
  #106) `killPid:` was acknowledged by the service but did not
  terminate the PosterBoard daemon — it only takes effect on
  processes the instruments server itself spawned. Walllive's
  binary carries the `sendSignal:toPid:` selector string in its
  processcontrol cluster; it is the call that actually delivers
  the signal. (The DVT Channel inside ProcessControlClient is
  crate-private, so the vendored client is the only clean place
  to add the call.)
- `src/poster_refresh.rs` — the signal stage now calls
  `send_signal(pid, 9)` instead of `kill_app(pid)`; a send failure
  maps to status killFailed with the original error. Header docs
  corrected. Identity / already_stopped / fresh-connection verify /
  status honesty all unchanged.

Revision of the same addition, later the same day (run #107
hardware log; registered in SPEC.md in the signal-reply section):

- Upstream check: jkcoxson/idevice master @ 8970209 was cloned and
  its `idevice/src/services/dvt/process_control.rs` read line by
  line — upstream has NO sendSignal method at all (only `killPid:`
  at line 289); apart from this local addition the vendored file
  is byte-identical to upstream master. There is therefore no
  upstream form to port; the method stays a local addition.
- `send_signal` changed from the fire-and-forget form above
  (`call_method(..., expect_reply=false)`, returning `()`) to a
  request–reply form: `call_method_with_reply`, returning the
  reply payload as `Result<Option<Value>, IdeviceError>`. Selector
  and aux encoding unchanged (selector `sendSignal:toPid:`, aux
  [U32 signal, U32 pid]). Shape aligned with pymobiledevice3's
  ProcessControlService, which declares `sendSignal:toPid:`
  without `expects_reply=False` and documents its `kill()` as
  relying on the round-trip — a one-way call can be silently
  dropped over the userspace tunnel, leaving the target alive
  (observed verbatim in runs #106/#107).
- `src/poster_refresh.rs` — the signal stage awaits the reply
  under a 10s timeout, logs it verbatim as
  `airlift.poster_refresh.signal.reply data=…`, and only then logs
  signal.acknowledged; a reply timeout is logged and the flow
  proceeds to fresh-connection verification (the ground truth)
  instead of failing the kill outright; a transport-level error
  still maps to killFailed with the original error.

Second revision of the same addition, later the same day (run
#108 hardware log; registered in SPEC.md in the
receipt-classification section):

- The vendored `send_signal` body is unchanged. What the #108
  hardware log showed is a classification problem one layer up:
  the service DID reply (the message was dispatched and handled),
  but the DTX reply parser classified the payload as
  `IdeviceError::UnexpectedResponse`, and `poster_refresh.rs`
  mapped ANY send error to killFailed and skipped verification —
  the pid's fate was never checked.
- `src/poster_refresh.rs` now splits the awaited-reply result
  three ways: a parsed reply payload proceeds as before; an
  `UnexpectedResponse` error logs `signal.reply
  unexpected_response=true (dispatch confirmed by response;
  deferring to verification)` and proceeds to fresh-connection
  verification as if delivered; only channel/connection-level
  errors (the message never left) still map to killFailed with
  the original error. Verification alone decides the outcome.

Apart from the additions registered above, everything else in this
tree remains a verbatim copy of upstream.
The other adaptations live outside this directory:

- `ci/build-rust-core.sh` builds this crate for `aarch64-apple-ios`
  and the app links `libairlift_ffi.a` directly (upstream packages an
  xcframework instead; the produced static library is the same).
- `Sources/App/GrappaHelper.h` / `GrappaHelper.m` are the upstream
  app-side helper, copied verbatim from the same commit — the core
  resolves its `ALGetGrappaToken` symbol at runtime via `dlsym`.
- The Swift call layer (`DeviceService.swift`, `TendiesFlash.swift`)
  mirrors upstream `TendiesEngine.swift`'s call sites and arguments.
