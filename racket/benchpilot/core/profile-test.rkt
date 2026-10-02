#lang racket/base

;; Port of the profile-facing parts of tests/Benchpilot.Core.Tests
;; (PreflightTests / BenchReadinessTests fixtures) plus loader contract
;; coverage from ProfileLoader.cs. Assertions follow the frozen contract of
;; ADR 0002: defaults, error messages and resolution semantics are verbatim.

(require racket/path)

;; Find the repository root by walking up with split-path (whose base is #f
;; at a filesystem root, so the walk terminates), the same idea as the C#
;; E2E FindRepoRoot. Works from any invocation directory.
(define (find-repo-root [dir (simple-form-path (current-directory))])
  (let walk ([dir dir])
    (cond
      [(directory-exists? (build-path dir ".git")) dir]
      [else
       (define-values (base _name _dir?) (split-path dir))
       (and base (walk base))])))

;; Repo profiles directory, when the test runs from inside a checkout.
(define real-ecu-profile
  (let ([root (find-repo-root)]) (and root (build-path root "profiles" "real-ecu.example.json"))))

(module+ test
  (require benchpilot/core/profile
           rackunit
           racket/string)

  (define (validation-message thunk)
    (with-handlers ([exn:fail:benchpilot? (lambda (e) (exn-message e))])
      (thunk)
      #f))

  (define (validation-kind thunk)
    (with-handlers ([exn:fail:benchpilot? (lambda (e) (exn:fail:benchpilot-kind e))])
      (thunk)
      #f))

  (define demo-json
    #<<JSON
{
  // BenchPilot test bench
  "schemaVersion": 1,
  "name": "Test bench",
  "defaultTarget": "demo",
  "resources": {
    "sim.demo": {
      "driver": "simulator",
      "capabilities": ["power", "serial", "flash"],
      "settings": {"voltage": 12.0, "settleMs": 2000, "port": "SIM0",},
    },
    "psu.main": { "driver": "scpi", "capabilities": ["power"] },
  },
  "targets": {
    "demo": {
      "name": "Demo ECU",
      "mcu": "simulated-mcu",
      "bindings": {"power": "sim.demo", "serial": "sim.demo", "flash": "sim.demo"},
    },
  },
  "safety": {"maxVoltage": 14.5, "maxCurrentMa": 2000, "requireExplicitTarget": true},
}
JSON
    )

  (define demo (load-profile-json demo-json))

  (test-case "parses resources, targets and safety with comments and trailing commas"
    (check-equal? (bench-profile-schema-version demo) 1)
    (check-equal? (bench-profile-name demo) "Test bench")
    (check-equal? (bench-profile-default-target demo) "demo")
    (check-equal? (hash-count (bench-profile-resources demo)) 2)
    (define sim (ci-ref (bench-profile-resources demo) "SIM.DEMO"))
    (check-equal? (bench-resource-driver sim) "simulator")
    (check-equal? (bench-resource-capabilities sim) '("power" "serial" "flash"))
    (check-equal? (hash-ref (bench-resource-settings sim) "voltage") 12.0)
    (check-equal? (hash-ref (bench-resource-settings sim) "settleMs") 2000)
    (define safety (bench-profile-safety demo))
    (check-equal? (bench-safety-max-voltage safety) 14.5)
    (check-equal? (bench-safety-max-current-ma safety) 2000)
    (check-true (bench-safety-require-explicit-target safety))
    (check-false (bench-safety-require-destructive-confirmation safety)))

  (test-case "resolution is case-insensitive like the C# dictionaries"
    (check-equal? (bench-target-name (resolve-target demo "DEMO")) "Demo ECU")
    (define-values (id resource) (resolve-resource demo "POWER"))
    (check-equal? id "sim.demo")
    (check-equal? (bench-resource-driver resource) "simulator"))

  (test-case "fills the default target when exactly one target exists"
    (define profile
      (load-profile-json #<<JSON
{
  "resources": { "r1": { "driver": "simulator", "capabilities": ["power"] } },
  "targets": { "only": { "name": "Only", "bindings": { "power": "r1" } } }
}
JSON
                         ))
    (check-equal? (bench-profile-default-target profile) "only")
    (check-equal? (bench-target-name (resolve-target profile)) "Only"))

  (test-case "normalizes legacy P0 single-driver profiles"
    (define legacy
      (load-profile-json #<<JSON
{
  "driver": "simulator",
  "board": { "name": "Legacy board", "mcu": "legacy-mcu" },
  "power": { "voltage": 5.5, "settleMs": 100 },
  "serial": { "port": "COM3", "baud": 9600 },
  "flash": {}
}
JSON
                         ))
    (check-equal? (bench-profile-name legacy) "Legacy board")
    (check-equal? (bench-profile-default-target legacy) "default")
    (define resource (ci-ref (bench-profile-resources legacy) "legacy.bench"))
    (check-equal? (bench-resource-driver resource) "simulator")
    (check-equal? (bench-resource-capabilities resource) '("power" "serial" "flash"))
    (check-equal? (hash-ref (bench-resource-settings resource) "voltage") 5.5)
    (check-equal? (hash-ref (bench-resource-settings resource) "settleMs") 100)
    (check-equal? (hash-ref (bench-resource-settings resource) "port") "COM3")
    (check-equal? (hash-ref (bench-resource-settings resource) "baud") 9600)
    (check-equal? (hash-ref (bench-resource-settings resource) "firmware") "build/app.elf")
    (define target (ci-ref (bench-profile-targets legacy) "default"))
    (check-equal? (bench-target-name target) "Legacy board")
    (check-equal? (bench-target-mcu target) "legacy-mcu"))

  (test-case "legacy P0 section defaults apply when a section is empty"
    (define legacy (load-profile-json "{\"driver\": \"sim\", \"serial\": {}}"))
    (define resource (ci-ref (bench-profile-resources legacy) "legacy.bench"))
    (check-equal? (bench-resource-capabilities resource) '("serial"))
    (check-equal? (hash-ref (bench-resource-settings resource) "port") "SIM0")
    (check-equal? (hash-ref (bench-resource-settings resource) "baud") 115200)
    (define target (ci-ref (bench-profile-targets legacy) "default"))
    (check-equal? (bench-target-name target) "Legacy target")
    (check-false (bench-target-mcu target)))

  (test-case "legacy profile without capabilities fails validation like C#"
    ;; A driver-only P0 profile normalizes to a resource with no capabilities;
    ;; resources validate before targets, so this error fires first.
    (check-equal? (validation-message (lambda () (load-profile-json "{\"driver\": \"simulator\"}")))
                  "Resource 'legacy.bench' advertises no capabilities."))

  (test-case "rejects profiles without resources, targets or a legacy driver"
    (check-equal? (validation-message (lambda () (load-profile-json "{}")))
                  "Profile must define 'resources' + 'targets', or use the legacy 'driver' field."))

  (test-case "rejects unsupported schemaVersion"
    ;; The legacy branch forces schemaVersion=1 (C# Normalize), so a wrong
    ;; version only surfaces on the resource/target path.
    (check-equal?
     (validation-message
      (lambda ()
        (load-profile-json
         "{\"schemaVersion\": 2, \"resources\": {\"r\": {\"driver\": \"x\", \"capabilities\": [\"power\"]}}, \"targets\": {\"a\": {\"bindings\": {\"power\": \"r\"}}}}")))
     "Unsupported bench profile schemaVersion '2'. Expected 1."))

  (test-case "rejects profiles without resources or targets"
    (check-equal?
     (validation-message
      (lambda () (load-profile-json "{\"resources\": {}, \"targets\": {\"t\": {\"bindings\": {}}}}")))
     "Bench profile must contain at least one resource.")
    (check-equal?
     (validation-message
      (lambda ()
        (load-profile-json
         "{\"resources\": {\"r\": {\"driver\": \"x\", \"capabilities\": [\"power\"]}}, \"targets\": {}}")))
     "Bench profile must contain at least one target."))

  (test-case "requires defaultTarget for multiple targets"
    (check-equal?
     (validation-message (lambda ()
                           (load-profile-json #<<JSON
{
  "resources": { "r": { "driver": "x", "capabilities": ["power"] } },
  "targets": {
    "a": { "bindings": { "power": "r" } },
    "b": { "bindings": { "power": "r" } }
  }
}
JSON
                                              )))
     "Profiles with multiple targets must define 'defaultTarget' or callers must select a target explicitly."))

  (test-case "rejects a defaultTarget outside targets"
    (check-equal? (validation-message (lambda ()
                                        (load-profile-json #<<JSON
{
  "defaultTarget": "nope",
  "resources": { "r": { "driver": "x", "capabilities": ["power"] } },
  "targets": { "a": { "bindings": { "power": "r" } } }
}
JSON
                                                           )))
                  "Default target 'nope' does not exist in 'targets'."))

  (test-case "rejects non-positive safety limits"
    (for ([json (list "{\"maxVoltage\": 0}" "{\"maxVoltage\": -1}" "{\"maxCurrentMa\": 0}")])
      (check-equal?
       (validation-message
        (lambda ()
          (load-profile-json
           (string-append
            "{\"resources\": {\"r\": {\"driver\": \"x\", \"capabilities\": [\"power\"]}},"
            " \"targets\": {\"a\": {\"bindings\": {\"power\": \"r\"}}},"
            " \"safety\": "
            json
            "}"))))
       (if (string-contains? json "maxVoltage")
           "Safety maxVoltage must be a finite value greater than zero when configured."
           "Safety maxCurrentMa must be a finite value greater than zero when configured."))))

  (test-case "rejects incomplete resources and targets"
    (check-equal?
     (validation-message
      (lambda ()
        (load-profile-json
         "{\"resources\": {\"r\": {\"capabilities\": [\"power\"]}}, \"targets\": {\"a\": {\"bindings\": {\"power\": \"r\"}}}}")))
     "Resource 'r' is missing a driver.")
    (check-equal?
     (validation-message
      (lambda ()
        (load-profile-json
         "{\"resources\": {\"r\": {\"driver\": \"x\", \"capabilities\": []}}, \"targets\": {\"a\": {\"bindings\": {\"power\": \"r\"}}}}")))
     "Resource 'r' advertises no capabilities.")
    (check-equal?
     (validation-message
      (lambda ()
        (load-profile-json
         "{\"resources\": {\"r\": {\"driver\": \"x\", \"capabilities\": [\"power\"]}}, \"targets\": {\"a\": {\"bindings\": {}}}}")))
     "Target 'a' has no resource bindings."))

  (test-case "rejects bindings to missing resources or unadvertised capabilities"
    (check-equal?
     (validation-message
      (lambda ()
        (load-profile-json
         "{\"resources\": {\"r\": {\"driver\": \"x\", \"capabilities\": [\"power\"]}}, \"targets\": {\"a\": {\"bindings\": {\"power\": \"missing\"}}}}")))
     "Target 'a' binding 'power' references missing resource 'missing'.")
    (check-equal?
     (validation-message
      (lambda ()
        (load-profile-json
         "{\"resources\": {\"r\": {\"driver\": \"x\", \"capabilities\": [\"power\"]}}, \"targets\": {\"a\": {\"bindings\": {\"serial\": \"r\"}}}}")))
     "Target 'a' binds 'serial' to resource 'r', but that resource does not advertise the capability."))

  (test-case "resolution errors carry the contract messages and kinds"
    (check-equal? (validation-message (lambda () (resolve-target demo "ghost")))
                  "Target 'ghost' does not exist in this bench profile.")
    (check-equal? (validation-kind (lambda () (resolve-target demo "ghost"))) 'not-found)
    (define no-default
      (bench-profile 1
                     "x"
                     #f
                     (hash "r" (bench-resource "x" '("power") (hash)))
                     (hash "a" (bench-target "A" #f (hash "power" "r")))
                     (bench-safety #f #f #f #f #f)
                     #f
                     #f
                     #f
                     #f
                     #f))
    (check-equal? (validation-message (lambda () (resolve-target no-default)))
                  "No target was specified and the profile has no 'defaultTarget'.")
    (check-equal? (validation-message (lambda () (resolve-resource demo "can")))
                  "Target 'demo' has no 'can' binding.")
    (check-equal?
     (validation-message
      (lambda ()
        (load-profile-json
         "{\"resources\": {\"r\": {\"driver\": \"x\", \"capabilities\": [\"power\"]}}, \"targets\": {\"a\": {\"bindings\": {\"power\": \"ghost\"}}}}")))
     "Target 'a' binding 'power' references missing resource 'ghost'."))

  (test-case "defensive resolution errors bypassed by load validation"
    (define unvalidated
      (bench-profile 1
                     "x"
                     "a"
                     (hash "r" (bench-resource "x" '("power") (hash)))
                     (hash "a" (bench-target "A" #f (hash "power" "ghost" "serial" "r")))
                     (bench-safety #f #f #f #f #f)
                     #f
                     #f
                     #f
                     #f
                     #f))
    (check-equal? (validation-message (lambda () (resolve-resource unvalidated "power")))
                  "Target binding 'power' references missing resource 'ghost'.")
    (check-equal? (validation-message (lambda () (resolve-resource unvalidated "serial")))
                  "Resource 'r' is bound as 'serial' but does not advertise that capability."))

  (test-case "load-profile reports missing files as not-found"
    (check-equal? (validation-message (lambda () (load-profile "/nonexistent/bench.profile.json")))
                  "Bench profile not found: /nonexistent/bench.profile.json")
    (check-equal? (validation-kind (lambda () (load-profile "/nonexistent/bench.profile.json")))
                  'not-found))

  (test-case "reports malformed JSON"
    (check-true (string-prefix? (validation-message (lambda () (load-profile-json "{oops")))
                                "Failed to parse bench profile JSON:")))

  (test-case "default simulator profile matches the C# DefaultSimulator()"
    (define sim (default-simulator-profile))
    (check-equal? (bench-profile-name sim) "BenchPilot simulator")
    (check-equal? (bench-profile-default-target sim) "demo")
    (check-equal? (hash-count (bench-profile-resources sim)) 2)
    (define composite (ci-ref (bench-profile-resources sim) "sim.demo"))
    (check-equal? (bench-resource-capabilities composite) '("power" "serial" "flash"))
    (check-equal? (hash-ref (bench-resource-settings composite) "voltage") 12.0)
    (check-equal? (hash-ref (bench-resource-settings composite) "firmware") "build/app.elf")
    (define uds (ci-ref (bench-profile-resources sim) "sim.uds"))
    (check-equal? (bench-resource-driver uds) "sim-diagnostics")
    (check-equal? (hash-ref (bench-resource-settings uds) "requestId") "0x7E0")
    (define safety (bench-profile-safety sim))
    (check-equal? (bench-safety-max-voltage safety) 14.5)
    (check-equal? (bench-safety-max-current-ma safety) 2000)
    (check-equal? (hash-count (bench-target-bindings (ci-ref (bench-profile-targets sim) "demo"))) 4))

  (test-case "strip-json-comments respects string literals and escapes"
    (check-equal? (strip-json-comments "{\"a\": \"x//y\"}") "{\"a\": \"x//y\"}")
    (check-equal? (strip-json-comments "{\"a\": \"x/*y*/z\"}") "{\"a\": \"x/*y*/z\"}")
    (check-equal? (strip-json-comments "{\"a\": \"\\n\"}") "{\"a\": \"\\n\"}")
    (check-equal? (strip-json-comments "{\"a\": \"line\\\"q\\\"\"}") "{\"a\": \"line\\\"q\\\"\"}")
    (check-equal? (strip-json-comments "{\"a\": 1, // c\n \"b\": [2, 3,] }\n")
                  "{\"a\": 1, \n \"b\": [2, 3] }\n")
    (check-equal? (strip-json-comments "/* head */ {\"a\": 1}") " {\"a\": 1}"))

  (test-case "real-ecu example profile parses (regression: escaped newLine)"
    (when real-ecu-profile ; skipped outside a repository checkout
      (define p (load-profile (path->string real-ecu-profile)))
      (check-true (> (hash-count (bench-profile-resources p)) 0)))))
