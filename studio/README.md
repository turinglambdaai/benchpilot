# studio

A first-party native desktop app powered by Racket and Rivet.

## Start here

```bash
raco rivet inspect --json
raco rivet schema --json
raco rivet doctor
raco rivet dev
```

`doctor` checks the local Racket/native toolchain and prints actionable fixes when something required is missing. `dev` rebuilds the Racket backend, regenerates the typed native client, builds the current platform host, and launches the app.

## Edit the app

- Shared Racket logic: `app/backend.rkt`
- Windows UI: `windows/MainWindow.xaml` and `windows/MainWindow.xaml.cpp`
- macOS UI: `macos-host/Sources/RivetHost/ContentView.swift` and `RivetHostApp.swift`
- Linux UI: `linux/src/main.cpp` (GTK4)
- Packaged application resources and icons: configure `resources`, `windows-icon`, and `macos-icon` in `rivet.rktd`
- App identity/deployment targets: `rivet.rktd`
- Versioned public API baseline: `rivet-schema.json`

## When Racket does not already have the capability

Run `raco rivet inspect --json` and read `capability-sourcing`. Prefer a built-in or maintained Racket package; keep platform-owned features in the native host; use a small safe FFI wrapper for a stable C ABI; use an argv-based subprocess for coarse-grained tools; reserve a sidecar for persistent or crash-isolated runtimes. The generated `AGENTS.md` contains the safety and packaging checks.

## Ship a build

```bash
raco rivet build
raco rivet package
raco rivet verify
```

Full tutorial: https://github.com/turinglambdaai/rivet/blob/main/docs/getting-started.md
中文教程: https://github.com/turinglambdaai/rivet/blob/main/docs/getting-started.zh-CN.md
Rivet website: https://rivet.jrtx.site
