#lang racket/base

;; Port of the pure readiness helpers from
;; tests/Benchpilot.Core.Tests (BenchReadinessTests): mode determination,
;; placeholder scanning and safety value checks.

(require benchpilot/core/profile
         benchpilot/core/readiness)

(module+ test
  (require rackunit)

  (define placeholder-json
    #<<JSON
{
  "resources": {
    "sim.demo": {
      "driver": "simulator",
      "capabilities": ["power", "serial", "flash"],
      "settings": {"port": "CHANGE_ME", "baud": 115200, "key": "use CHANGE_ME here"}
    },
    "probe.jlink": { "driver": "jlink", "capabilities": ["flash"] }
  },
  "targets": {
    "demo": { "name": "Demo", "mcu": "CHANGE_ME", "bindings": {"power": "sim.demo", "flash": "probe.jlink"} }
  }
}
JSON
    )

  (test-case "required capabilities are the minimum real-ECU vertical slice"
    (check-equal? required-capabilities '("power" "serial" "flash")))

  (test-case "determine-mode classifies like the C# switch"
    (check-equal? (determine-mode '()) "unknown")
    (check-equal? (determine-mode '("simulator")) "simulator")
    (check-equal? (determine-mode '("SIMULATOR" "simulator")) "simulator")
    (check-equal? (determine-mode '("simulator" "scpi")) "mixed")
    (check-equal? (determine-mode '("pcan" "scpi" "jlink")) "hardware")
    (check-equal? (determine-mode '("simulator" "")) "simulator")
    (check-equal? (determine-mode '("  ")) "unknown"))

  (test-case "contains-placeholder? is case-insensitive and whitespace-aware"
    (check-true (contains-placeholder? "CHANGE_ME"))
    (check-true (contains-placeholder? "change_me please"))
    (check-true (contains-placeholder? "port=Change_Me"))
    (check-false (contains-placeholder? "COM3"))
    (check-false (contains-placeholder? "  "))
    (check-false (contains-placeholder? #f)))

  (test-case "find-placeholder-paths reports mcu and settings deterministically"
    (define profile (load-profile-json placeholder-json))
    (check-equal? (find-placeholder-paths profile "demo" '("sim.demo" "probe.jlink" "SIM.DEMO"))
                  '("targets.demo.mcu" "resources.sim.demo.settings.key"
                                       "resources.sim.demo.settings.port")))

  (test-case "find-placeholder-paths is empty for a clean profile"
    (define profile (default-simulator-profile))
    (check-equal? (find-placeholder-paths profile "demo" '("sim.demo")) '()))

  (test-case "safety-value-check renders the contract message for present values"
    (define check
      (safety-value-check "safety.max-voltage" "maxVoltage" 12.5 "V" "Set safety.maxVoltage."))
    (check-true (readiness-check-passed check))
    (check-equal? (readiness-check-severity check) "error")
    (check-equal? (readiness-check-summary check) "Bench safety maxVoltage is configured at 12.5 V.")
    (check-false (readiness-check-remediation check))
    (check-equal? (readiness-check-details check) (hash "value" "12.5" "unit" "V")))

  (test-case "safety-value-check trims to at most three decimals, invariant format"
    (check-equal? (format-safety-number 2000) "2000")
    (check-equal? (format-safety-number 12.0) "12")
    (check-equal? (format-safety-number 14.5) "14.5")
    (check-equal? (format-safety-number 0.125) "0.125"))

  (test-case "safety-value-check carries remediation for missing values"
    (define check
      (safety-value-check "safety.max-current"
                          "maxCurrentMa"
                          #f
                          "mA"
                          "Set safety.maxCurrentMa to a conservative ceiling."))
    (check-false (readiness-check-passed check))
    (check-equal? (readiness-check-summary check)
                  "Real-bench readiness requires safety.maxCurrentMa to be configured.")
    (check-equal? (readiness-check-remediation check)
                  "Set safety.maxCurrentMa to a conservative ceiling.")
    (check-false (readiness-check-details check))))
