# Rivet agent contract

Human-first. Agent-native. Local by design.

## Start every task here

```bash
raco rivet inspect --json
raco rivet doctor --json
```

`inspect` is the machine-readable project map. It identifies the shared Racket
backend, each native UI edit point, platform maturity, generated directories,
and safe lifecycle commands. `doctor` reports the exact local toolchain and
returns a failing exit status when the current host is not usable.

## Architecture boundary

- Keep shared application and domain logic in `app/backend.rkt`.
- Keep Windows UI native in WinUI 3 / C++/WinRT under `windows/`.
- Keep macOS UI native in SwiftUI/AppKit under `macos-host/`.
- Keep Linux UI native in GTK4 under `linux/`.
- Do not introduce a cross-platform UI DSL or bypass RVT1 with an ad-hoc IPC.
- iOS/iPadOS/watchOS and Android are foundation targets until their
  generated app, embedding, packaging, signing, and device workflows exist.

## Capability sourcing

When a feature is not already present, do not reject Racket or add another
runtime by reflex. Read `capability-sourcing` from `inspect --json`, then choose
the narrowest boundary that fits:

1. Prefer a Racket built-in or maintained package. Discover candidates with
   `raco docs <term>`, `raco pkg show`, and
   `raco pkg catalog-show --all --only-names`; inspect a candidate with
   `raco pkg catalog-show --modules <package>`.
2. Put UI, lifecycle, accessibility, notification, device, and other
   platform-owned behavior in the first-party native host.
3. Use FFI for a stable C ABI that needs frequent, low-latency in-process
   calls. Hide `ffi/unsafe` behind a small safe module with explicit ownership,
   callback, thread, ABI, and native-library packaging rules.
4. Use `subprocess` or `system*` for a mature executable doing coarse-grained
   work. Pass an executable and argv directly; never construct a shell command.
   Add a version probe, timeout, bounded/concurrently drained output, exit-code
   handling, cancellation, packaging, and license checks.
5. Use a sidecar only for a persistent runtime, streaming workload, unstable
   ABI, or required crash isolation. Own authentication, protocol versioning,
   resource limits, restart/shutdown, packaging, and offline behavior.
6. Implement the capability only when it is small or security-critical and
   owning it is cheaper than owning the dependency boundary.

For every choice, verify Racket 9.0 CS support, license/redistribution terms,
all target OS/architectures, upstream maintenance, reproducible installation,
failure behavior, packaged dependency closure, and a clean-machine smoke test.

## Ownership

Source you may edit:

- `app/`
- `windows/`
- `macos-host/`
- `linux/`
- `rivet.rktd`
- `rivet-schema.json` when an API compatibility break is intentional
- declared application resources

Generated output you should not hand-edit:

- `windows/GeneratedBackend.hpp`
- `macos-host/Sources/RivetHost/GeneratedBackend.swift`
- `linux/GeneratedBackend.hpp`
- `.rivet/`
- `build/`
- `dist/`
- `windows/Generated Files/`
- `windows/obj/`
- `windows/RivetHost/`
- `macos-host/.build/`

`raco rivet build` regenerates the typed clients. Use `raco rivet clean` to
remove transient build output while keeping the generated client sources that
make the native API reviewable.

## Verification loop

This project includes a source-controlled `rivet-schema.json` API baseline.
Refresh it only after deliberately changing the public backend schema:

```bash
raco rivet schema --output rivet-schema.json
```

Before accepting later API changes, run the compatibility gate. Adding a new
RPC, Event, State, Record, or Enum type is compatible; removing one or changing
a type, argument order, result, Record field/order, or an existing Enum's
cases/order is breaking:

```bash
raco rivet schema check rivet-schema.json --json
```

```bash
raco rivet build
raco rivet dev
raco rivet package
raco rivet verify
```

After changing RPC, Event, State, Record, or Enum declarations, run the
compatibility gate and rebuild before editing code that consumes generated native APIs.
Update the baseline only when a breaking change is intentional and governed by
the application's release policy. Preserve the first `rivet: error:` line and
nearby compiler output when diagnosing a failure.