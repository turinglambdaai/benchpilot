#lang racket/base

;; Pure readiness-decision helpers, ported from
;; src/Benchpilot.Runtime/BenchReadiness.cs — the parts that do not need the
;; live runtime (mode determination, placeholder scan, safety value checks).
;; The runtime-facing readiness report lands with Phase 3 of ADR 0002.

(require racket/format
         racket/list
         racket/math
         racket/string)

(provide (struct-out readiness-check)
         required-capabilities
         determine-mode
         contains-placeholder?
         find-placeholder-paths
         safety-value-check
         format-safety-number)

(require benchpilot/core/contracts
         "profile.rkt")

;; ----------------------------------------------------------------------------
;; One deterministic readiness assertion. Severity is "error" or "warning";
;; only failed error checks block ReadyForRealEcuLoop. Codes are stable
;; machine-facing identifiers; remediation is intentionally actionable.
;; ----------------------------------------------------------------------------

(struct readiness-check (code passed severity summary remediation details) #:transparent)

;; The minimum real-ECU vertical slice (power + serial + flash).
(define required-capabilities '("power" "serial" "flash"))

;; ----------------------------------------------------------------------------
;; Mode determination
;; ----------------------------------------------------------------------------

;; "simulator" when every bound driver is the simulator, "mixed" when some
;; are, "hardware" when none are, "unknown" when nothing is bound.
(define (determine-mode drivers)
  (define present (filter (lambda (d) (and (string? d) (not (blank? d)))) drivers))
  (cond
    [(null? present) "unknown"]
    [(andmap (lambda (d) (string-ci=? d "simulator")) present) "simulator"]
    [(ormap (lambda (d) (string-ci=? d "simulator")) present) "mixed"]
    [else "hardware"]))

;; ----------------------------------------------------------------------------
;; Placeholder scan
;; ----------------------------------------------------------------------------

(define (contains-placeholder? value)
  (and (string? value)
       (not (zero? (string-length (string-trim value))))
       (string-contains? (string-foldcase value) "change_me")))

;; Paths of CHANGE_ME placeholders in the target's real-bench configuration.
;; Settings iterate in sorted-key order: Racket hashes do not preserve JSON
;; document order, and a deterministic report beats an unstable approximation
;; of the C# insertion order.
(define (find-placeholder-paths profile target-id resource-ids)
  (define result '())
  (define target (ci-ref (bench-profile-targets profile) target-id))
  (when (and target (contains-placeholder? (bench-target-mcu target)))
    (set! result (cons (format "targets.~a.mcu" target-id) result)))
  (for* ([resource-id (in-list (remove-duplicates resource-ids string-ci=?))])
    (define resource (ci-ref (bench-profile-resources profile) resource-id))
    (when resource
      (define settings (bench-resource-settings resource))
      (for ([key (in-list (sort (hash-keys settings) string<?))])
        (define value (hash-ref settings key))
        (when (contains-placeholder? value)
          (set! result (cons (format "resources.~a.settings.~a" resource-id key) result))))))
  (reverse result))

;; ----------------------------------------------------------------------------
;; Safety value checks
;; ----------------------------------------------------------------------------

;; C# renders the value with double.ToString("0.###", InvariantCulture).
(define (format-safety-number v)
  (define s (~r v #:precision '(= 3)))
  (if (string-contains? s ".")
      (regexp-replace #rx"\\.?0+$" s "")
      s))

(define (safety-value-check code setting value unit remediation)
  (define present (and (real? value) (not (nan? value))))
  (bench-readiness-check
   code
   present
   "error"
   (if present
       (format "Bench safety ~a is configured at ~a ~a." setting (format-safety-number value) unit)
       (format "Real-bench readiness requires safety.~a to be configured." setting))
   (if present #f remediation)
   (if present
       (hash "value" (format-safety-number value) "unit" unit)
       #f)))
