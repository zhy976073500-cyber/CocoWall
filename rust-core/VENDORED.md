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

Everything else in this tree remains a verbatim copy of upstream.
The other adaptations live outside this directory:

- `ci/build-rust-core.sh` builds this crate for `aarch64-apple-ios`
  and the app links `libairlift_ffi.a` directly (upstream packages an
  xcframework instead; the produced static library is the same).
- `Sources/App/GrappaHelper.h` / `GrappaHelper.m` are the upstream
  app-side helper, copied verbatim from the same commit — the core
  resolves its `ALGetGrappaToken` symbol at runtime via `dlsym`.
- The Swift call layer (`DeviceService.swift`, `TendiesFlash.swift`)
  mirrors upstream `TendiesEngine.swift`'s call sites and arguments.
