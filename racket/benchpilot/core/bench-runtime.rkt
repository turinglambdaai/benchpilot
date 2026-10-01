#lang racket/base

;; Target-oriented runtime facade, port of BenchTarget.cs,
;; BenchTargetDiagnostics.cs, BenchPreflight.cs, BenchResourceRegistry.cs,
;; ResourceDrivers.cs, BenchReadiness.cs and the Core abstractions.
;;
;; This is the single safety/validation choke point: callers request semantic
;; operations on targets and never see drivers directly.

(require json
         racket/contract
         racket/file
         racket/format
         racket/generic
         racket/list
         racket/string)

(require "contracts.rkt"
         "evidence.rkt"
         "profile.rkt"
         "readiness.rkt"
         "runtime-state.rkt")

;; driver generics (Core abstractions)
(provide gen:resource-health-check
         gen:power-supply
         gen:serial-channel
         gen:flash-target
         gen:diag-channel
         check-health
         power-supply?
         ps-power-on
         ps-power-off
         ps-read-current
         ps-check-current
         ps-on?
         serial-channel?
         sc-open
         sc-wait
         sc-window
         sc-send
         sc-open?
         flash-target?
         ft-flash
         ft-reset
         diag-channel?
         diag-transport
         diag-open
         diag-request
         diag-flash
         ;; registries
         (struct-out driver-registry)
         (struct-out driver-factory)
         make-driver-registry
         driver-registry-names
         register-driver-factory!
         driver-create
         driver-create-runtime
         ;; runtime object: state + registry
         (struct-out bench-runtime)
         make-bench-runtime
         runtime-target
         runtime-preflight
         runtime-validate-target-readiness
         ;; target operations
         target-id
         target-name
         target-mcu
         target-capabilities
         target-has-capability?
         target-power-on
         target-power-off
         target-emergency-power-off
         target-read-current
         target-check-current
         target-flash
         target-reset
         target-serial-open
         target-serial-wait
         target-serial-window
         target-serial-send
         target-uds-request
         target-uds-flash
         ;; registry accessors
         registry-instance
         registry-registered?
         ;; state passthrough (host convenience)
         runtime-active-operations
         runtime-active-observations
         runtime-recent-operations
         runtime-recent-observations
         runtime-get-operation-evidence
         runtime-get-observation-evidence
         runtime-cancel-operation!
         runtime-cancel-observation!
         drain-runtime!
         run-mutation
         run-observation
         run-ungated-safety-operation
         ;; flash plan
         build-flash-plan
         (struct-out uds-flash-plan)
         (struct-out uds-flash-segment)
         ;; diag evidence
         diag-uds-request-evidence
         diag-uds-flash-evidence
         instance-type-name)

;; ----------------------------------------------------------------------------
;; Driver interfaces (racket/generic). A value satisfying the methods is the
;; Racket analogue of "implements the C# interface"; the generated predicates
;; power the readiness capability-contract checks.
;; ----------------------------------------------------------------------------

(define-generics resource-health-check (check-health resource-health-check cancel))

(define-generics power-supply
                 (ps-power-on power-supply voltage settle-ms cancel)
                 (ps-power-off power-supply cancel)
                 (ps-read-current power-supply window-ms cancel)
                 (ps-check-current power-supply lt-ma gt-ma cancel)
                 (ps-on? power-supply))

(define-generics serial-channel
                 (sc-open serial-channel port baud cancel)
                 (sc-wait serial-channel pattern timeout-ms cancel)
                 (sc-window serial-channel lines filter cancel)
                 (sc-send serial-channel data cancel)
                 (sc-open? serial-channel))

(define-generics flash-target (ft-flash flash-target firmware cancel) (ft-reset flash-target cancel))

(define-generics diag-channel
                 (diag-transport diag-channel)
                 (diag-open diag-channel cancel)
                 (diag-request diag-channel request-bytes p2-ms p2-star-ms cancel)
                 (diag-flash diag-channel plan cancel))

(define (instance-type-name v)
  (define-values (struct-type _skipped) (struct-info v))
  (if struct-type
      (let-values ([(name _init _auto _acc _mut _parent) (struct-type-info struct-type)])
        (format "~a" name))
      "object"))

;; ----------------------------------------------------------------------------
;; Registries (BenchResourceRegistry / BenchDriverRegistry)
;; ----------------------------------------------------------------------------

(struct bench-runtime (profile resources state) #:transparent)

(struct driver-registry (factories) #:transparent) ; hash driver-name(cased) -> factory

;; IBenchResourceFactory port: a named constructor for one live resource.
(struct driver-factory (name create) #:transparent)

(define (make-driver-registry [factories '()])
  (define reg (driver-registry (make-hash)))
  (for ([f (in-list factories)])
    (register-driver-factory! reg f))
  reg)

(define (register-driver-factory! reg factory)
  (define name (driver-factory-name factory))
  (when (string-blank? name)
    (raise-argument-error 'register-driver-factory! "driver factory with a name" factory))
  (when (hash-has-key? (driver-registry-factories reg) (string-foldcase name))
    (raise-validation (format "A resource factory for driver '~a' is already registered." name)))
  (hash-set! (driver-registry-factories reg) (string-foldcase name) factory))

(define (driver-registry-names reg)
  (sort (hash-keys (driver-registry-factories reg)) string<?))

(define (driver-create reg resource-id config)
  (define factory
    (hash-ref (driver-registry-factories reg) (string-foldcase (bench-resource-driver config)) #f))
  (unless factory
    (define available
      (if (zero? (hash-count (driver-registry-factories reg)))
          "none"
          (string-join (driver-registry-names reg) ", ")))
    (raise-validation (format "Resource '~a' uses unsupported driver '~a'. Available drivers: ~a."
                              resource-id
                              (bench-resource-driver config)
                              available)))
  ((driver-factory-create factory) resource-id config))

(define (driver-create-runtime reg profile)
  (validate-profile profile)
  (define resources (make-hash))
  (for ([(resource-id config) (in-hash (bench-profile-resources profile))])
    (hash-set! resources
               (string-foldcase resource-id)
               (cons resource-id (driver-create reg resource-id config))))
  ;; resources maps case-folded id -> (cons original-id instance)
  (define state (make-runtime-state profile resources))
  (bench-runtime profile resources state))

;; resource lookup preserving the registry's contract messages
(define (registry-instance rt resource-id)
  (define entry (hash-ref (bench-runtime-resources rt) (string-foldcase resource-id) #f))
  (unless entry
    (raise-validation (format "Resource '~a' is declared but has no live driver instance."
                              resource-id)))
  (cdr entry))

(define (registry-registered? rt resource-id)
  (hash-has-key? (bench-runtime-resources rt) (string-foldcase resource-id)))

;; ----------------------------------------------------------------------------
;; Target resolution (BenchRuntime.Target)
;; ----------------------------------------------------------------------------

(struct target-ref (id name mcu bindings) #:transparent)

(define (runtime-target rt [target-name* #f])
  (check-disposed (bench-runtime-state rt))
  (define safety (bench-profile-safety (bench-runtime-profile rt)))
  (when (and (bench-safety-require-explicit-target safety) (string-blank? target-name*))
    (raise-validation "This bench requires an explicit target for every operation."))
  (define resolved
    (if (string-blank? target-name*)
        (bench-profile-default-target (bench-runtime-profile rt))
        target-name*))
  (when (string-blank? resolved)
    (raise-validation "No target was specified and the bench profile has no default target."))
  (with-handlers ([exn:fail:benchpilot? (lambda (e)
                                          (if (eq? (exn:fail:benchpilot-kind e) 'not-found)
                                              (raise (make-target-not-found-error (exn-message e)))
                                              (raise e)))])
    (define config (resolve-target (bench-runtime-profile rt) resolved))
    (target-ref (or (for/first ([(k v) (in-hash (bench-profile-targets (bench-runtime-profile rt)))]
                                #:when (eq? v config))
                      k)
                    resolved)
                (if (string-blank? (bench-target-name config))
                    resolved
                    (bench-target-name config))
                (bench-target-mcu config)
                (bench-target-bindings config))))

(define (target-id t)
  (target-ref-id t))
(define (target-name t)
  (target-ref-name t))
(define (target-mcu t)
  (target-ref-mcu t))
(define (target-capabilities t)
  (hash-keys (target-ref-bindings t)))
(define (target-has-capability? t capability)
  (hash-has-key? (target-ref-bindings t) capability))

;; ----------------------------------------------------------------------------
;; Capability binding (BenchTarget.BoundCapability)
;; ----------------------------------------------------------------------------

(struct binding (resource-id capability))

(define (bound-capability rt t capability predicate interface-name)
  (define resource-id (ci-ref (target-ref-bindings t) capability))
  (unless resource-id
    (raise-validation (format "Target '~a' has no '~a' binding." (target-ref-id t) capability)))
  (define instance (registry-instance rt resource-id))
  (unless (predicate instance)
    (raise-validation (format "Resource '~a' does not implement ~a. Actual type: ~a."
                              resource-id
                              interface-name
                              (instance-type-name instance))))
  (binding resource-id instance))

;; ----------------------------------------------------------------------------
;; Power operations
;; ----------------------------------------------------------------------------

(define (target-power-on rt
                         t
                         voltage
                         settle-ms
                         #:deadline-ms [deadline-ms #f]
                         #:caller-cancel [caller #f])
  (when (<= voltage 0)
    (raise-validation "Power voltage must be greater than zero."))
  (when (< settle-ms 0)
    (raise-validation "Power settleMs cannot be negative."))
  (define safety (bench-profile-safety (bench-runtime-profile rt)))
  (define max-voltage (bench-safety-max-voltage safety))
  (when (and max-voltage (> voltage max-voltage))
    (raise-validation (format "Requested voltage ~a V exceeds bench safety limit ~a V."
                              (format-number-0-3 voltage)
                              (format-number-0-3 max-voltage))))
  (define b (bound-capability rt t "power" power-supply? "IPowerSupply"))
  (define result
    (run-mutation
     (bench-runtime-state rt)
     (target-ref-id t)
     "power.on"
     (list (binding-resource-id b))
     (lambda (cancel)
       (define value (ps-power-on (binding-capability b) voltage settle-ms cancel))
       (define max-current (bench-safety-max-current-ma safety))
       (if (and (power-on-result-ok value)
                max-current
                (> (power-on-result-current-ma value) max-current))
           (let ([off (ps-power-off (binding-capability b) #f)])
             (struct-copy power-on-result
                          value
                          [ok #f]
                          [settled #f]
                          [error
                           (format "Measured current ~a mA exceeds bench safety limit ~a mA. ~a"
                                   (format-number-0-3 (power-on-result-current-ma value))
                                   (format-number-0-3 max-current)
                                   (if (power-off-result-ok off)
                                       "Power output was switched off."
                                       "Power-off also reported an error."))]))
           value))
     #:deadline-ms deadline-ms
     #:caller-cancel caller))
  (define item
    (bench-evidence-item "context.power-on"
                         (if (power-on-result-ok result)
                             "Recent power-on result."
                             "Recent power-on attempt returned a device/safety error.")
                         (power-on-result-error result)
                         (hasheq "ok"
                                 (bool-str (power-on-result-ok result))
                                 "voltageV"
                                 (format-number-0-3 (power-on-result-voltage result))
                                 "currentMa"
                                 (format-number-0-3 (power-on-result-current-ma result))
                                 "settled"
                                 (bool-str (power-on-result-settled result)))))
  (context-store-record! (runtime-state-context-store (bench-runtime-state rt))
                         (target-ref-id t)
                         item)
  result)

(define (target-power-off rt t #:deadline-ms [deadline-ms #f] #:caller-cancel [caller #f])
  (define b (bound-capability rt t "power" power-supply? "IPowerSupply"))
  (define result
    (run-mutation (bench-runtime-state rt)
                  (target-ref-id t)
                  "power.off"
                  (list (binding-resource-id b))
                  (lambda (cancel) (ps-power-off (binding-capability b) cancel))
                  #:deadline-ms deadline-ms
                  #:caller-cancel caller))
  (record-power-off-context! rt t result #f)
  result)

(define (target-emergency-power-off rt t #:caller-cancel [caller #f])
  ;; Request cancellation must not abort an accepted safety action.
  (void caller)
  (define b (bound-capability rt t "power" power-supply? "IPowerSupply"))
  (define result
    (run-ungated-safety-operation (bench-runtime-state rt)
                                  (target-ref-id t)
                                  "power.emergency-off"
                                  (list (binding-resource-id b))
                                  (lambda () (ps-power-off (binding-capability b) #f))))
  (record-power-off-context! rt t result #t)
  result)

(define (record-power-off-context! rt t result emergency)
  (context-store-record!
   (runtime-state-context-store (bench-runtime-state rt))
   (target-ref-id t)
   (bench-evidence-item
    (if emergency "context.power-emergency-off" "context.power-off")
    (cond
      [(and (power-off-result-ok result) emergency) "Recent emergency power-off completed."]
      [(power-off-result-ok result) "Recent normal power-off completed."]
      [emergency "Recent emergency power-off returned a device error."]
      [else "Recent normal power-off returned a device error."])
    (power-off-result-error result)
    (hasheq "ok" (bool-str (power-off-result-ok result)) "emergency" (bool-str emergency)))))

(define (target-read-current rt t window-ms #:caller-cancel [caller #f])
  (when (<= window-ms 0)
    (raise-validation "Current sampling window must be greater than zero."))
  (define b (bound-capability rt t "power" power-supply? "IPowerSupply"))
  (define result (ps-read-current (binding-capability b) window-ms caller))
  (context-store-record!
   (runtime-state-context-store (bench-runtime-state rt))
   (target-ref-id t)
   (bench-evidence-item "context.current-reading"
                        (if (current-reading-ok result)
                            "Recent current measurement."
                            "Recent current measurement returned a device error.")
                        (current-reading-error result)
                        (hasheq "ok"
                                (bool-str (current-reading-ok result))
                                "avgMa"
                                (format-number-0-3 (current-reading-avg-ma result))
                                "peakMa"
                                (format-number-0-3 (current-reading-peak-ma result))
                                "sampleCount"
                                (~a (length (current-reading-samples result)))))
   result))

(define (target-check-current rt t lt-ma gt-ma #:caller-cancel [caller #f])
  (when (and (not lt-ma) (not gt-ma))
    (raise-validation "Current check requires at least one lt/gt threshold."))
  (when (or (and lt-ma (< lt-ma 0)) (and gt-ma (< gt-ma 0)))
    (raise-validation "Current thresholds cannot be negative."))
  (define b (bound-capability rt t "power" power-supply? "IPowerSupply"))
  (define result (ps-check-current (binding-capability b) lt-ma gt-ma caller))
  (define metadata
    (let ([base (hasheq "ok"
                        (bool-str (current-check-ok result))
                        "passed"
                        (bool-str (current-check-passed result))
                        "valueMa"
                        (format-number-0-3 (current-check-value-ma result)))])
      (hash-set* (if lt-ma
                     (hash-set base "ltMa" (format-number-0-3 lt-ma))
                     base)
                 "gtMa"
                 (if gt-ma
                     (format-number-0-3 gt-ma)
                     (hash-ref base "gtMa" #f)))))
  (define metadata*
    (if gt-ma
        metadata
        (for/hash ([(k v) (in-hash metadata)]
                   #:when v)
          (values k v))))
  (context-store-record!
   (runtime-state-context-store (bench-runtime-state rt))
   (target-ref-id t)
   (bench-evidence-item
    "context.current-check"
    (cond
      [(not (current-check-ok result)) "Recent current assertion returned a device error."]
      [(current-check-passed result) "Recent current assertion passed."]
      [else "Recent current assertion failed."])
    (current-check-error result)
    metadata*))
  result)

(define (bool-str v)
  (if v "true" "false"))
(define (hash-set* h . kvs)
  (let loop ([h h]
             [kvs kvs])
    (if (null? kvs)
        h
        (loop (hash-set h (car kvs) (cadr kvs)) (cddr kvs)))))

;; ----------------------------------------------------------------------------
;; Flash / reset (destructive; confirm-target gated)
;; ----------------------------------------------------------------------------

(define (validate-destructive-confirmation rt t operation confirm-target)
  (define safety (bench-profile-safety (bench-runtime-profile rt)))
  (when (bench-safety-require-destructive-confirmation safety)
    (unless (and confirm-target (string-ci=? confirm-target (target-ref-id t)))
      (raise-validation
       (format "Destructive operation '~a' requires confirmTarget matching target id '~a'."
               operation
               (target-ref-id t))))))

(define (target-flash rt
                      t
                      firmware
                      confirm-target
                      #:deadline-ms [deadline-ms #f]
                      #:caller-cancel [caller #f])
  (when (string-blank? firmware)
    (raise-validation "Firmware path cannot be empty."))
  (validate-destructive-confirmation rt t "flash" confirm-target)
  (define b (bound-capability rt t "flash" flash-target? "IFlashTarget"))
  (define store (runtime-state-context-store (bench-runtime-state rt)))
  (call-with-failure-scope (make-failure-scope store (target-ref-id t) "flash.write")
                           (lambda ()
                             (run-mutation (bench-runtime-state rt)
                                           (target-ref-id t)
                                           "flash.write"
                                           (list (binding-resource-id b))
                                           (lambda (cancel)
                                             (ft-flash (binding-capability b) firmware cancel))
                                           #:deadline-ms deadline-ms
                                           #:caller-cancel caller))))

(define (target-reset rt t confirm-target #:deadline-ms [deadline-ms #f] #:caller-cancel [caller #f])
  (validate-destructive-confirmation rt t "reset" confirm-target)
  (define b (bound-capability rt t "flash" flash-target? "IFlashTarget"))
  (define store (runtime-state-context-store (bench-runtime-state rt)))
  (call-with-failure-scope (make-failure-scope store (target-ref-id t) "flash.reset")
                           (lambda ()
                             (run-mutation (bench-runtime-state rt)
                                           (target-ref-id t)
                                           "flash.reset"
                                           (list (binding-resource-id b))
                                           (lambda (cancel) (ft-reset (binding-capability b) cancel))
                                           #:deadline-ms deadline-ms
                                           #:caller-cancel caller))))

;; ----------------------------------------------------------------------------
;; Serial observations
;; ----------------------------------------------------------------------------

(define (target-serial-open rt t port baud #:deadline-ms [deadline-ms #f] #:caller-cancel [caller #f])
  (when (and port (string-blank? port))
    (raise-validation "Serial port override cannot be empty."))
  (when (and baud (<= baud 0))
    (raise-validation "Serial baud override must be greater than zero."))
  (define b (bound-capability rt t "serial" serial-channel? "ISerialChannel"))
  (run-observation
   (bench-runtime-state rt)
   (target-ref-id t)
   "serial.open"
   (list (binding-resource-id b))
   (lambda (observation-id cancel)
     (define result (sc-open (binding-capability b) port baud cancel))
     (define identified (struct-copy serial-open-result result [observation-id observation-id]))
     (values identified
             (list (bench-evidence-item "serial.open"
                                        (if (serial-open-result-ok identified)
                                            "Serial channel opened."
                                            "Serial open returned a device error.")
                                        (serial-open-result-error identified)
                                        (hasheq "ok"
                                                (bool-str (serial-open-result-ok identified))
                                                "port"
                                                (serial-open-result-port identified)
                                                "baud"
                                                (~a (serial-open-result-baud identified)))))))
   #:deadline-ms deadline-ms
   #:caller-cancel caller))

(define (target-serial-wait rt
                            t
                            pattern
                            timeout-ms
                            #:deadline-ms [deadline-ms #f]
                            #:caller-cancel [caller #f])
  (when (string-blank? pattern)
    (raise-validation "Serial wait pattern cannot be empty."))
  (when (< timeout-ms 0)
    (raise-validation "Serial timeout cannot be negative."))
  (define b (bound-capability rt t "serial" serial-channel? "ISerialChannel"))
  (run-observation
   (bench-runtime-state rt)
   (target-ref-id t)
   "serial.wait"
   (list (binding-resource-id b))
   (lambda (observation-id cancel)
     (define result (sc-wait (binding-capability b) pattern timeout-ms cancel))
     (define identified (struct-copy serial-wait-result result [observation-id observation-id]))
     (define failure-window
       (if (or (not (serial-wait-result-ok identified)) (not (serial-wait-result-matched identified)))
           ;; The channel owns a bounded local buffer; read only a
           ;; small tail after failure instead of the raw stream.
           (sc-window (binding-capability b) 20 #f #f)
           #f))
     (define evidence
       (extract-serial-observation-evidence 'wait
                                            identified
                                            (list pattern timeout-ms failure-window)))
     (define evidence*
       (if (or (not (serial-wait-result-ok identified)) (not (serial-wait-result-matched identified)))
           (append evidence
                   (context-store-snapshot (runtime-state-context-store (bench-runtime-state rt))
                                           (target-ref-id t)))
           evidence))
     (values identified evidence*))
   #:deadline-ms deadline-ms
   #:caller-cancel caller))

(define (target-serial-window rt
                              t
                              lines
                              filter
                              #:deadline-ms [deadline-ms #f]
                              #:caller-cancel [caller #f])
  (when (<= lines 0)
    (raise-validation "Serial window line count must be greater than zero."))
  (define b (bound-capability rt t "serial" serial-channel? "ISerialChannel"))
  (run-observation (bench-runtime-state rt)
                   (target-ref-id t)
                   "serial.window"
                   (list (binding-resource-id b))
                   (lambda (observation-id cancel)
                     (define result (sc-window (binding-capability b) lines filter cancel))
                     (define identified
                       (struct-copy serial-window-result result [observation-id observation-id]))
                     (values identified (extract-serial-observation-evidence 'window identified)))
                   #:deadline-ms deadline-ms
                   #:caller-cancel caller))

(define (target-serial-send rt t data #:deadline-ms [deadline-ms #f] #:caller-cancel [caller #f])
  (unless (string? data)
    (raise-validation "Serial data cannot be null."))
  (define b (bound-capability rt t "serial" serial-channel? "ISerialChannel"))
  (run-observation
   (bench-runtime-state rt)
   (target-ref-id t)
   "serial.send"
   (list (binding-resource-id b))
   (lambda (observation-id cancel)
     (define result (sc-send (binding-capability b) data cancel))
     (define identified (struct-copy serial-send-result result [observation-id observation-id]))
     (values identified
             (extract-serial-observation-evidence 'send identified (list (string-length data)))))
   #:deadline-ms deadline-ms
   #:caller-cancel caller))

;; ----------------------------------------------------------------------------
;; Diagnostics (BenchTargetDiagnostics)
;; ----------------------------------------------------------------------------

(define (diag-uds-request-evidence result)
  (define (truncate-hex-chars hex)
    (if (<= (string-length hex) 512)
        hex
        (string-append (substring hex 0 512) "…(+512)")))
  (list
   (bench-evidence-item
    "uds.request"
    (cond
      [(not (uds-request-result-ok result)) "UDS request failed at the transport layer."]
      [(uds-request-result-positive result) "UDS request answered with a positive response."]
      [else (format "UDS request rejected by the ECU (NRC ~a)." (uds-request-result-nrc result))])
    (or (uds-request-result-error result) "")
    (hasheq "ok"
            (bool-str (uds-request-result-ok result))
            "positive"
            (bool-str (uds-request-result-positive result))
            "nrc"
            (or (uds-request-result-nrc result) "")
            "request"
            (truncate-hex-chars (uds-request-result-request-hex result))
            "response"
            (truncate-hex-chars (or (uds-request-result-response-hex result) ""))))))

(define (diag-uds-flash-evidence result)
  (define step-items
    (for/list ([step (in-list (uds-flash-result-steps result))])
      (bench-evidence-item "uds.flash.step"
                           (flash-step-summary-detail step)
                           (or (flash-step-summary-nrc step) "")
                           (hasheq "step"
                                   (flash-step-summary-step step)
                                   "ok"
                                   (bool-str (flash-step-summary-ok step))
                                   "nrc"
                                   (or (flash-step-summary-nrc step) "")
                                   "durationMs"
                                   (~r (flash-step-summary-duration-ms step) #:precision '(= 1))))))
  (cons (bench-evidence-item "uds.flash"
                             (if (uds-flash-result-ok result)
                                 (format "UDS flash workflow completed (~a bytes in ~a segment(s))."
                                         (uds-flash-result-total-bytes result)
                                         (uds-flash-result-segment-count result))
                                 (format "UDS flash workflow failed: ~a"
                                         (uds-flash-result-error result)))
                             (or (uds-flash-result-error result) "")
                             (hasheq "ok"
                                     (bool-str (uds-flash-result-ok result))
                                     "totalBytes"
                                     (~a (uds-flash-result-total-bytes result))
                                     "stepCount"
                                     (~a (length (uds-flash-result-steps result)))))
        step-items))

(define (target-uds-request rt
                            t
                            request-bytes
                            #:p2-ms [p2-ms #f]
                            #:p2-star-ms [p2-star-ms #f]
                            #:deadline-ms [deadline-ms #f]
                            #:caller-cancel [caller #f])
  (when (null? request-bytes)
    (raise-validation "UDS request bytes cannot be empty."))
  (define b (bound-capability rt t "diagnostics" diag-channel? "IDiagChannel"))
  (run-observation (bench-runtime-state rt)
                   (target-ref-id t)
                   "uds.request"
                   (list (binding-resource-id b))
                   (lambda (observation-id cancel)
                     (define result
                       (diag-request (binding-capability b)
                                     request-bytes
                                     (or p2-ms 1000)
                                     (or p2-star-ms 5000)
                                     cancel))
                     (values result (diag-uds-request-evidence result)))
                   #:deadline-ms deadline-ms
                   #:caller-cancel caller))

(struct uds-flash-plan
        (segments max-block-payload
                  session
                  security-level
                  key-deriver
                  erase-routine-id
                  verify-routine-id
                  block-retries
                  p2-timeout-ms
                  p2-star-timeout-ms)
  #:transparent)
(struct uds-flash-segment (address data file) #:transparent)

(define (build-flash-plan firmware-path plan-path address max-block-payload)
  (unless (file-exists? firmware-path)
    (raise-validation (format "Firmware file not found: ~a" firmware-path)))
  (define spec
    (if (and plan-path (not (string-blank? plan-path)))
        (let ()
          (unless (file-exists? plan-path)
            (raise-validation (format "Flash plan file not found: ~a" plan-path)))
          (define base-directory
            (let-values ([(dir name dir?) (split-path (simplify-path (path->complete-path
                                                                      plan-path)))])
              (path->string dir)))
          (define parsed (read-flash-plan-json (file->string plan-path)))
          (struct-copy
           uds-flash-plan
           parsed
           [segments
            (for/list ([seg (in-list (uds-flash-plan-segments parsed))])
              (if (and (uds-flash-segment-data seg) (not (null? (uds-flash-segment-data seg))))
                  seg
                  (struct-copy uds-flash-segment
                               seg
                               [data
                                (read-segment-file (uds-flash-segment-file seg) base-directory)])))]))
        (begin
          (unless address
            (raise-validation
             "Provide --address (flash start address, for example 0x08000000) or a flash plan file."))
          (uds-flash-plan (list (uds-flash-segment address (file->bytes firmware-path) #f))
                          1024
                          #x02
                          #f
                          #f
                          #xFF00
                          #xFF01
                          0
                          1000
                          10000))))
  (if max-block-payload
      (struct-copy uds-flash-plan spec [max-block-payload max-block-payload])
      spec))

(define (read-segment-file file base-directory)
  (when (or (not file) (string-blank? file))
    (raise-validation "Flash plan segment has no data and no file reference."))
  (define path
    (if (or (absolute-path? file) (regexp-match? #rx"^[A-Za-z]:" file))
        file
        (path->string (build-path base-directory file))))
  (unless (file-exists? path)
    (raise-validation (format "Flash plan segment file not found: ~a" path)))
  (file->bytes path))

(define (target-uds-flash rt
                          t
                          firmware-path
                          plan-path
                          address
                          max-block-payload
                          confirm-target
                          #:deadline-ms [deadline-ms #f]
                          #:caller-cancel [caller #f])
  (when (string-blank? firmware-path)
    (raise-argument-error 'target-uds-flash "non-blank firmware path" firmware-path))
  (validate-destructive-confirmation rt t "uds flash" confirm-target)
  (define spec (build-flash-plan firmware-path plan-path address max-block-payload))
  (when (null? (uds-flash-plan-segments spec))
    (raise-validation
     "Flash plan has no segments; provide a firmware file with --address or a plan file."))
  (define total-bytes
    (for/sum ([seg (in-list (uds-flash-plan-segments spec))])
             (length (or (uds-flash-segment-data seg) '()))))
  (define b (bound-capability rt t "diagnostics" diag-channel? "IDiagChannel"))
  (run-mutation (bench-runtime-state rt)
                (target-ref-id t)
                "uds.flash"
                (list (binding-resource-id b))
                (lambda (cancel)
                  (define result (diag-flash (binding-capability b) spec))
                  (struct-copy uds-flash-result result [total-bytes total-bytes]))
                #:deadline-ms deadline-ms
                #:caller-cancel caller))

;; ----------------------------------------------------------------------------
;; Preflight (BenchPreflight)
;; ----------------------------------------------------------------------------

(define (runtime-preflight rt [target-name* #f])
  (define t (runtime-target rt target-name*))
  ;; Composite resources are checked only once even when they provide
  ;; multiple capabilities.
  (define seen (make-hash))
  (define ordered '())
  (for ([capability (in-list (target-capabilities t))])
    (define-values (resource-id config)
      (resolve-resource (bench-runtime-profile rt) capability (target-ref-id t)))
    (unless (hash-ref seen (string-foldcase resource-id) #f)
      (hash-set! seen (string-foldcase resource-id) #t)
      (set! ordered (cons (cons resource-id config) ordered))))
  (define sorted (sort ordered (lambda (a b) (string-ci<? (car a) (car b)))))

  (define checks
    (for/list ([pair (in-list sorted)])
      (define resource-id (car pair))
      (define config (cdr pair))
      (cond
        [(not (registry-registered? rt resource-id))
         ;; A profile may declare resources whose driver factory is not
         ;; composed into this host; report a failed check with remediation
         ;; instead of throwing so the rest of the bench stays usable.
         (resource-preflight-result
          #f
          resource-id
          (bench-resource-driver config)
          (bench-resource-capabilities config)
          "Resource has no live driver instance in this host."
          #f
          (format
           "Resource '~a' uses driver '~a', which is not registered in this host. Start benchpilotd with the driver's project referenced, or remove the resource from the profile."
           resource-id
           (bench-resource-driver config)))]
        [else
         (define instance (registry-instance rt resource-id))
         (cond
           [(not (resource-health-check? instance))
            (resource-preflight-result #f
                                       resource-id
                                       (bench-resource-driver config)
                                       (bench-resource-capabilities config)
                                       "Driver does not implement a non-destructive health check."
                                       #f
                                       (format "Resource '~a' cannot be preflighted by driver '~a'."
                                               resource-id
                                               (bench-resource-driver config)))]
           [else
            (with-handlers ([exn:benchpilot:cancelled? (lambda (e) (raise e))]
                            [exn:fail? (lambda (e)
                                         (resource-preflight-result
                                          #f
                                          resource-id
                                          (bench-resource-driver config)
                                          (bench-resource-capabilities config)
                                          "Health check failed with an unexpected driver error."
                                          #f
                                          (exn-message e)))])
              (define health (check-health instance #f))
              (resource-preflight-result (resource-health-result-ok health)
                                         resource-id
                                         (bench-resource-driver config)
                                         (bench-resource-capabilities config)
                                         (resource-health-result-summary health)
                                         (resource-health-result-details health)
                                         (resource-health-result-error health)))])])))

  (define ok (and (not (null? checks)) (andmap resource-preflight-result-ok checks)))
  (target-preflight-result ok
                           (target-ref-id t)
                           (target-ref-name t)
                           checks
                           (if ok #f "One or more target resources are not ready.")))

;; ----------------------------------------------------------------------------
;; Readiness (BenchReadiness.ValidateTargetReadiness)
;; ----------------------------------------------------------------------------

(define required-capabilities-list '("power" "serial" "flash"))

(define (implements-live-capability capability instance)
  (case capability
    [("power") (cons (power-supply? instance) "IPowerSupply")]
    [("serial") (cons (serial-channel? instance) "ISerialChannel")]
    [("flash") (cons (flash-target? instance) "IFlashTarget")]
    [else (cons #f "unknown Runtime capability contract")]))

(define (runtime-validate-target-readiness rt [target-name* #f])
  (define t (runtime-target rt target-name*))
  (define checks '())
  (define bound-resources (make-hash))

  (define (add-check check)
    (set! checks (cons check checks)))

  (for ([capability (in-list required-capabilities-list)])
    (define present (target-has-capability? t capability))
    (define details
      (if present
          (let ()
            (define-values (resource-id config)
              (resolve-resource (bench-runtime-profile rt) capability (target-ref-id t)))
            (hash-set! bound-resources (string-foldcase resource-id) (cons resource-id config))
            (hasheq "capability"
                    capability
                    "resourceId"
                    resource-id
                    "driver"
                    (bench-resource-driver config)))
          #f))
    (add-check (bench-readiness-check
                (string-append "capability." capability)
                present
                "error"
                (if present
                    (format "Target provides required '~a' capability." capability)
                    (format "Target is missing required '~a' capability." capability))
                (if present
                    #f
                    (format "Add a '~a' resource and bind targets.~a.bindings.~a to that resource."
                            capability
                            (target-ref-id t)
                            capability))
                details))
    (when present
      (define-values (resource-id config)
        (resolve-resource (bench-runtime-profile rt) capability (target-ref-id t)))
      (define live (registry-instance rt resource-id))
      (define implemented (implements-live-capability capability live))
      (add-check
       (bench-readiness-check
        (string-append "runtime-capability." capability)
        (car implemented)
        "error"
        (if (car implemented)
            (format "Live resource '~a' implements the Runtime contract for '~a'."
                    resource-id
                    capability)
            (format "Resource '~a' advertises '~a' but its live driver object does not implement ~a."
                    resource-id
                    capability
                    (cdr implemented)))
        (if (car implemented)
            #f
            (format
             "Fix resource '~a' driver/capabilities so '~a' is provided by a driver implementing ~a; do not advertise capabilities the live driver cannot execute."
             resource-id
             capability
             (cdr implemented)))
        (hasheq "capability"
                capability
                "resourceId"
                resource-id
                "driver"
                (bench-resource-driver config)
                "requiredContract"
                (cdr implemented)
                "actualType"
                (instance-type-name live))))))

  (define mode
    (determine-mode (for/list ([pair (in-hash-pairs bound-resources)])
                      (bench-resource-driver (cdr (cdr pair))))))
  (define hardware-only (string=? mode "hardware"))
  (add-check
   (bench-readiness-check
    "target.real-hardware"
    hardware-only
    "error"
    (case mode
      [("hardware") "Required capabilities are bound only to real-hardware drivers."]
      [("simulator")
       "Required capabilities are simulator-backed; this target is not a physical ECU bench."]
      [("mixed")
       "Required capabilities mix simulator and hardware resources; the physical ECU loop is incomplete."]
      [else "Could not determine a complete hardware mode for the required capabilities."])
    (if hardware-only
        #f
        "Replace simulator-backed required capabilities with real resource drivers before running a physical ECU loop.")
    (hasheq "mode" mode)))

  (define safety (bench-profile-safety (bench-runtime-profile rt)))
  (add-check
   (safety-value-check
    "safety.max-voltage"
    "maxVoltage"
    (bench-safety-max-voltage safety)
    "V"
    "Set safety.maxVoltage to the maximum voltage this bench is allowed to apply to the ECU."))
  (add-check
   (safety-value-check
    "safety.max-current"
    "maxCurrentMa"
    (bench-safety-max-current-ma safety)
    "mA"
    "Set safety.maxCurrentMa to a conservative current ceiling for this ECU and bench wiring."))
  (add-check
   (bench-readiness-check
    "safety.explicit-target"
    (bench-safety-require-explicit-target safety)
    "error"
    (if (bench-safety-require-explicit-target safety)
        "Explicit target selection is required by bench policy."
        "Real-bench readiness requires safety.requireExplicitTarget=true.")
    (if (bench-safety-require-explicit-target safety)
        #f
        "Set safety.requireExplicitTarget=true so destructive work cannot silently fall back to a default target.")
    #f))
  (add-check
   (bench-readiness-check
    "safety.destructive-confirmation"
    (bench-safety-require-destructive-confirmation safety)
    "error"
    (if (bench-safety-require-destructive-confirmation safety)
        "Flash/reset require explicit target confirmation."
        "Real-bench readiness requires safety.requireDestructiveConfirmation=true.")
    (if (bench-safety-require-destructive-confirmation safety)
        #f
        "Set safety.requireDestructiveConfirmation=true so flash/reset require an explicit matching target confirmation.")
    #f))

  (define placeholder-paths
    (find-placeholder-paths (bench-runtime-profile rt)
                            (target-ref-id t)
                            (map car (hash-values bound-resources))))
  (add-check
   (bench-readiness-check
    "profile.placeholders"
    (null? placeholder-paths)
    "error"
    (if (null? placeholder-paths)
        "No CHANGE_ME placeholders remain in the target's real-bench configuration."
        (format "Profile still contains ~a CHANGE_ME placeholder(s) for this target."
                (length placeholder-paths)))
    (if (null? placeholder-paths)
        #f
        "Replace every listed CHANGE_ME value with the actual ECU/tool/bench setting before using the physical bench.")
    (if (null? placeholder-paths)
        #f
        (hasheq "paths"
                (string-join (take placeholder-paths (min 20 (length placeholder-paths))) ",")
                "count"
                (~a (length placeholder-paths))))))

  (define mcu-specified
    (and (target-ref-mcu t)
         (not (string-blank? (target-ref-mcu t)))
         (not (contains-placeholder? (target-ref-mcu t)))))
  (add-check
   (bench-readiness-check
    "target.mcu-metadata"
    (and mcu-specified #t)
    "warning"
    (if mcu-specified
        (format "Target MCU metadata is set to '~a'." (target-ref-mcu t))
        "Target MCU metadata is missing or still a placeholder; this does not block Runtime readiness but should be fixed before publishing the profile.")
    (if mcu-specified
        #f
        (format "Set targets.~a.mcu to the concrete MCU/SoC identifier used by this ECU."
                (target-ref-id t)))
    #f))

  (define preflight (runtime-preflight rt (target-ref-id t)))
  (add-check
   (bench-readiness-check
    "resources.preflight"
    (target-preflight-result-ok preflight)
    "error"
    (if (target-preflight-result-ok preflight)
        "All target resources passed non-destructive preflight."
        "One or more target resources failed non-destructive preflight.")
    (if (target-preflight-result-ok preflight)
        #f
        "Inspect preflight.resources entries with ok=false and fix tool installation, device selection, cabling, port visibility or network reachability before continuing.")
    (hasheq "resourceCount"
            (~a (length (target-preflight-result-resources preflight)))
            "failedCount"
            (~a (length (filter (lambda (x) (not (resource-preflight-result-ok x)))
                                (target-preflight-result-resources preflight)))))))

  (define ordered-checks (reverse checks))
  (define ready
    (andmap (lambda (c)
              (or (bench-readiness-check-passed c)
                  (not (string-ci=? (bench-readiness-check-severity c) "error"))))
            ordered-checks))
  (target-readiness-result #t
                           ready
                           mode
                           (target-ref-id t)
                           (target-ref-name t)
                           required-capabilities-list
                           ordered-checks
                           preflight
                           #f))

;; make-bench-runtime: convenience for hosts (drivers.CreateRuntime).
(define (make-bench-runtime registry profile)
  (driver-create-runtime registry profile))

(define (read-flash-plan-json text)
  ;; Port of UdsFlashPlanSpec deserialization (Web defaults, camelCase).
  (define doc
    (with-handlers ([exn:fail? (lambda (e)
                                 (raise-validation (format "Invalid flash plan JSON: ~a"
                                                           (exn-message e))))])
      (read-json (open-input-string text))))
  (unless (hash? doc)
    (raise-validation "Invalid flash plan JSON: expected an object."))
  (define (get-sym key)
    (hash-ref doc key #f))
  (define segments-raw (get-sym 'segments))
  (define segments
    (if (list? segments-raw)
        (for/list ([seg (in-list segments-raw)])
          (unless (hash? seg)
            (raise-validation "Invalid flash plan segment: expected an object."))
          (uds-flash-segment
           (hash-ref seg
                     'address
                     (lambda () (raise-validation "Flash plan segment is missing 'address'.")))
           (let ([data (hash-ref seg 'data #f)])
             (cond
               [(string? data) (hex-parse data)]
               [(list? data) (map (lambda (x) (if (exact-integer? x) x 0)) data)]
               [else #f]))
           (hash-ref seg 'file #f)))
        '()))
  (uds-flash-plan segments
                  (or (hash-ref doc 'maxBlockPayload #f) 1024)
                  (or (hash-ref doc 'session #f) #x02)
                  (hash-ref doc 'securityLevel #f)
                  (hash-ref doc 'keyDeriver #f)
                  (or (hash-ref doc 'eraseRoutineId #f) #xFF00)
                  (or (hash-ref doc 'verifyRoutineId #f) #xFF01)
                  (or (hash-ref doc 'blockRetries #f) 0)
                  (or (hash-ref doc 'p2TimeoutMs #f) 1000)
                  (or (hash-ref doc 'p2StarTimeoutMs #f) 10000)))

;; (flash plan JSON reader above; no forward references remain)
