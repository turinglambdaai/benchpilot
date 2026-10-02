#lang racket/base

;; Bench profile model, loader, normalizer and validator.
;;
;; Port of src/Benchpilot.Core/Profile (BenchProfile.cs + ProfileLoader.cs)
;; as specified by ADR 0002: JSON shapes, defaults and error messages are
;; observable product contract and are ported verbatim.

(require json
         racket/file
         racket/format
         racket/list
         racket/math
         racket/string)

(provide (struct-out bench-profile)
         (struct-out bench-resource)
         (struct-out bench-target)
         (struct-out bench-safety)
         (struct-out exn:fail:benchpilot)
         load-profile
         load-profile-json
         normalize-profile
         resolve-target
         resolve-resource
         validate-profile
         default-simulator-profile
         ci-ref
         blank?
         strip-json-comments)

;; ----------------------------------------------------------------------------
;; Data model
;;
;; The C# records are immutable; these structs are the same shapes. `resources`
;; and `targets` map ids to configs; `bindings` maps capability ids to resource
;; ids; `settings` holds driver-specific JSON values as jsexpr.
;; ----------------------------------------------------------------------------

(struct bench-profile
        (schema-version name
                        default-target
                        resources
                        targets
                        safety
                        ;; Legacy P0 fields, retained for profile compatibility.
                        driver
                        board
                        power
                        serial
                        flash)
  #:transparent)

(struct bench-resource (driver capabilities settings) #:transparent)
(struct bench-target (name mcu bindings) #:transparent)
(struct bench-safety
        (max-voltage max-current-ma require-explicit-target require-destructive-confirmation
                     leases-required)
  #:transparent)

;; Legacy P0 records with their C# defaults (Board, PowerConfig, ...).
(struct bench-board (name mcu) #:transparent)
(struct bench-power (voltage settle-ms) #:transparent)
(struct bench-serial (port baud) #:transparent)
(struct bench-flash (firmware) #:transparent)

;; ----------------------------------------------------------------------------
;; Errors
;;
;; The C# loader distinguishes FileNotFoundException / KeyNotFoundException /
;; InvalidOperationException, which the CLI maps to exit codes 3 and 2. The
;; `kind` field carries that mapping forward: 'not-found or 'validation.
;; ----------------------------------------------------------------------------

(struct exn:fail:benchpilot exn:fail (kind) #:transparent)

(define (raise-validation message)
  (raise (exn:fail:benchpilot message (current-continuation-marks) 'validation)))
(define (raise-not-found message)
  (raise (exn:fail:benchpilot message (current-continuation-marks) 'not-found)))

(define (blank? s)
  (or (not (string? s)) (zero? (string-length (string-trim s)))))

;; ----------------------------------------------------------------------------
;; Case-insensitive ids
;;
;; C# stores resource/target ids and capability names in
;; StringComparer.OrdinalIgnoreCase dictionaries: the insertion casing is
;; preserved for display and iteration, lookups ignore case. Hashes here keep
;; original-cased keys; ci-ref is the lookup convention.
;; ----------------------------------------------------------------------------

(define (ci-ref h key [default #f])
  (define key*
    (if (symbol? key)
        (symbol->string key)
        key))
  (or (hash-ref h key #f)
      (hash-ref h key* #f)
      (for/first ([(k v) (in-hash h)]
                  #:when (string-ci=? (if (symbol? k)
                                          (symbol->string k)
                                          k)
                                      key*))
        v)
      (if (procedure? default)
          (default)
          default)))

;; ----------------------------------------------------------------------------
;; Tolerant JSON reading
;;
;; The C# loader reads JSON with JsonCommentHandling.Skip and
;; AllowTrailingCommas. Base Racket read-json is strict, so the text is
;; preprocessed with the same tolerance before parsing. String literals are
;; respected (a "//" inside a value is never treated as a comment).
;; ----------------------------------------------------------------------------

(define (strip-json-comments text)
  (define n (string-length text))
  (define (at i)
    (string-ref text i))
  (let loop ([i 0]
             [acc '()]
             [state 'code])
    (cond
      [(>= i n) (list->string (reverse acc))]
      [else
       (define c (at i))
       (define next
         (if (< (add1 i) n)
             (at (add1 i))
             #\nul))
       (case state
         [(string)
          (cond
            ;; Escaped pair: acc is reversed at the end, so append in reverse.
            [(char=? c #\\) (loop (+ i 2) (list* next c acc) 'string)]
            [(char=? c #\") (loop (add1 i) (cons c acc) 'code)]
            [else (loop (add1 i) (cons c acc) 'string)])]
         [(line-comment)
          (if (or (char=? c #\newline) (char=? c #\return))
              (loop i acc 'code)
              (loop (add1 i) acc 'line-comment))]
         [(block-comment)
          (if (and (char=? c #\*) (char=? next #\/))
              (loop (+ i 2) acc 'code)
              (loop (add1 i) acc 'block-comment))]
         [else
          (cond
            [(and (char=? c #\/) (char=? next #\/)) (loop (+ i 2) acc 'line-comment)]
            [(and (char=? c #\/) (char=? next #\*)) (loop (+ i 2) acc 'block-comment)]
            [(char=? c #\") (loop (add1 i) (cons c acc) 'string)]
            [(char=? c #\,)
             ;; Trailing comma: drop it when only whitespace precedes the
             ;; closing brace/bracket, otherwise keep it.
             (let scan ([j (add1 i)])
               (cond
                 [(>= j n) (loop (add1 i) (cons c acc) 'code)]
                 [(char-whitespace? (at j)) (scan (add1 j))]
                 [(or (char=? (at j) #\}) (char=? (at j) #\])) (loop (add1 i) acc 'code)]
                 [else (loop (add1 i) (cons c acc) 'code)]))]
            [else (loop (add1 i) (cons c acc) 'code)])])])))

;; read-json produces hasheq objects with symbol keys; profiles want
;; string keys with original casing.
(define (string-keyed v)
  (cond
    [(hash? v)
     (for/hash ([(k val) (in-hash v)])
       (values (if (symbol? k)
                   (symbol->string k)
                   (~a k))
               (string-keyed val)))]
    [(list? v) (map string-keyed v)]
    [else v]))

;; ----------------------------------------------------------------------------
;; Field readers
;;
;; System.Text.Json is strict about types; these readers are too, with
;; concise messages. `get-real` accepts exact integers and floats the way
;; C# double deserialization does.
;; ----------------------------------------------------------------------------

(define (expected-object key)
  (raise-validation (format "Invalid type for profile field '~a': expected an object." key)))
(define (expected-string key)
  (raise-validation (format "Invalid type for profile field '~a': expected a string." key)))

(define (get-object h key)
  (define v (hash-ref h key #f))
  (cond
    [(not v) (hash)]
    [(hash? v) v]
    [else (expected-object key)]))

(define (get-opt-object h key)
  (define v (hash-ref h key #f))
  (cond
    [(not v) #f]
    [(hash? v) v]
    [else (expected-object key)]))

(define (get-string h key [default #f])
  (define v (hash-ref h key #f))
  (cond
    [(not v) default]
    [(string? v) v]
    [else (expected-string key)]))

(define (get-bool h key [default #f])
  (define v (hash-ref h key #f))
  (cond
    [(not v) default]
    [(boolean? v) v]
    [else
     (raise-validation (format "Invalid type for profile field '~a': expected a boolean." key))]))

(define (get-int h key [default #f])
  (define v (hash-ref h key #f))
  (cond
    [(not v) default]
    [(exact-integer? v) v]
    [else
     (raise-validation (format "Invalid type for profile field '~a': expected an integer." key))]))

(define (get-real h key [default #f])
  (define v (hash-ref h key #f))
  (cond
    [(not v) default]
    [(real? v) v]
    [else (raise-validation (format "Invalid type for profile field '~a': expected a number." key))]))

(define (get-string-list h key)
  (define v (hash-ref h key #f))
  (cond
    [(not v) '()]
    [(and (list? v) (andmap string? v)) v]
    [else
     (raise-validation (format "Invalid type for profile field '~a': expected an array of strings."
                               key))]))

;; ----------------------------------------------------------------------------
;; Parsing
;; ----------------------------------------------------------------------------

(define (parse-resource doc)
  (bench-resource (get-string doc "driver" "")
                  (get-string-list doc "capabilities")
                  (for/hash ([(k v) (in-hash (get-object doc "settings"))])
                    (values k v))))

(define (parse-target id doc)
  (bench-target
   (get-string doc "name" "")
   (get-string doc "mcu")
   (for/hash ([(k v) (in-hash (get-object doc "bindings"))])
     (values k
             (if (string? v)
                 v
                 (raise-validation
                  (format "Invalid type for target '~a' binding '~a': expected a string." id k)))))))

(define (parse-safety doc)
  (bench-safety (get-real doc "maxVoltage")
                (get-real doc "maxCurrentMa")
                (get-bool doc "requireExplicitTarget")
                (get-bool doc "requireDestructiveConfirmation")
                (get-bool doc "leasesRequired")))

(define (parse-board doc)
  (and doc (bench-board (get-string doc "name" "Demo Board") (get-string doc "mcu" "simulated-mcu"))))
(define (parse-power doc)
  (and doc (bench-power (get-real doc "voltage" 12) (get-int doc "settleMs" 2000))))
(define (parse-serial doc)
  (and doc (bench-serial (get-string doc "port" "SIM0") (get-int doc "baud" 115200))))
(define (parse-flash doc)
  (and doc (bench-flash (get-string doc "firmware" "build/app.elf"))))

(define (parse-profile doc)
  (bench-profile (get-int doc "schemaVersion" 1)
                 (get-string doc "name" "BenchPilot bench")
                 (get-string doc "defaultTarget")
                 (for/hash ([(k v) (in-hash (get-object doc "resources"))])
                   (values k (parse-resource v)))
                 (for/hash ([(k v) (in-hash (get-object doc "targets"))])
                   (values k (parse-target k v)))
                 (parse-safety (get-object doc "safety"))
                 (get-string doc "driver")
                 (parse-board (get-opt-object doc "board"))
                 (parse-power (get-opt-object doc "power"))
                 (parse-serial (get-opt-object doc "serial"))
                 (parse-flash (get-opt-object doc "flash"))))

;; ----------------------------------------------------------------------------
;; Loading
;; ----------------------------------------------------------------------------

(define (load-profile path)
  (unless (file-exists? path)
    (raise-not-found (format "Bench profile not found: ~a" path)))
  (load-profile-json (file->string path)))

(define (load-profile-json json-text)
  (define doc
    (with-handlers ([exn:fail? (lambda (e)
                                 (raise-validation (format "Failed to parse bench profile JSON: ~a"
                                                           (exn-message e))))])
      (string-keyed (read-json (open-input-string (strip-json-comments json-text))))))
  (unless (hash? doc)
    (raise-validation "Failed to parse bench profile JSON: expected a JSON object."))
  (define profile (normalize-profile (parse-profile doc)))
  (validate-profile profile)
  profile)

;; ----------------------------------------------------------------------------
;; Normalization
;; ----------------------------------------------------------------------------

;; Convert a P0 single-driver profile to the resource/target schema; new
;; profiles pass through with the default target filled in when exactly one
;; target exists. (The C# side also re-copies ids into case-insensitive
;; dictionaries; here case-insensitivity lives in ci-ref at lookup time.)
(define (normalize-profile profile)
  (if (or (> (hash-count (bench-profile-resources profile)) 0)
          (> (hash-count (bench-profile-targets profile)) 0))
      (struct-copy bench-profile profile [default-target (fill-default-target profile)])
      (normalize-legacy profile)))

(define (fill-default-target profile)
  (define current (bench-profile-default-target profile))
  (define targets (bench-profile-targets profile))
  (if (and (or (not current) (blank? current)) (= (hash-count targets) 1))
      (first (hash-keys targets))
      current))

(define (normalize-legacy profile)
  (define driver (bench-profile-driver profile))
  (when (blank? driver)
    (raise-validation
     "Profile must define 'resources' + 'targets', or use the legacy 'driver' field."))
  (define resource-id "legacy.bench")
  (define target-id "default")
  (define board (bench-profile-board profile))
  (define capabilities '())
  (define bindings (make-hash))
  (define settings (make-hash))
  (define (add-setting key value)
    (hash-set! settings key value))
  (define (add-capability cap)
    (set! capabilities (cons cap capabilities))
    (hash-set! bindings cap resource-id))
  (define power (bench-profile-power profile))
  (define serial (bench-profile-serial profile))
  (define flash (bench-profile-flash profile))
  (when power
    (add-capability "power")
    (add-setting "voltage" (bench-power-voltage power))
    (add-setting "settleMs" (bench-power-settle-ms power)))
  (when serial
    (add-capability "serial")
    (add-setting "port" (bench-serial-port serial))
    (add-setting "baud" (bench-serial-baud serial)))
  (when flash
    (add-capability "flash")
    (add-setting "firmware" (bench-flash-firmware flash)))
  (struct-copy bench-profile
               profile
               [schema-version 1]
               [name
                (if board
                    (bench-board-name board)
                    (bench-profile-name profile))]
               [default-target target-id]
               [resources (hash resource-id (bench-resource driver (reverse capabilities) settings))]
               [targets
                (hash target-id
                      (bench-target (if board
                                        (bench-board-name board)
                                        "Legacy target")
                                    (and board (bench-board-mcu board))
                                    bindings))]))

;; ----------------------------------------------------------------------------
;; Resolution
;; ----------------------------------------------------------------------------

(define (resolve-target profile [target-name #f])
  (define id
    (if (and target-name (not (blank? target-name)))
        target-name
        (bench-profile-default-target profile)))
  (unless (and id (not (blank? id)))
    (raise-validation "No target was specified and the profile has no 'defaultTarget'."))
  (define target (ci-ref (bench-profile-targets profile) id))
  (unless target
    (raise-not-found (format "Target '~a' does not exist in this bench profile." id)))
  target)

(define (resolve-resource profile capability [target-name #f])
  (define target (resolve-target profile target-name))
  (define resource-id (ci-ref (bench-target-bindings target) capability))
  (unless resource-id
    (raise-validation (format "Target '~a' has no '~a' binding."
                              (or target-name (bench-profile-default-target profile))
                              capability)))
  (define resource (ci-ref (bench-profile-resources profile) resource-id))
  (unless resource
    (raise-validation
     (format "Target binding '~a' references missing resource '~a'." capability resource-id)))
  (unless (member capability (bench-resource-capabilities resource) string-ci=?)
    (raise-validation (format "Resource '~a' is bound as '~a' but does not advertise that capability."
                              resource-id
                              capability)))
  (values resource-id resource))

;; ----------------------------------------------------------------------------
;; Validation
;; ----------------------------------------------------------------------------

(define (validate-finite-positive key value)
  (when value
    (unless (and (real? value) (not (nan? value)) (not (infinite? value)) (> value 0))
      (raise-validation (format "Safety ~a must be a finite value greater than zero when configured."
                                key)))))

(define (validate-profile profile)
  (unless (= 1 (bench-profile-schema-version profile))
    (raise-validation (format "Unsupported bench profile schemaVersion '~a'. Expected 1."
                              (bench-profile-schema-version profile))))

  (define resources (bench-profile-resources profile))
  (define targets (bench-profile-targets profile))

  (when (zero? (hash-count resources))
    (raise-validation "Bench profile must contain at least one resource."))
  (when (zero? (hash-count targets))
    (raise-validation "Bench profile must contain at least one target."))

  (define default-target (bench-profile-default-target profile))
  (when (and (or (not default-target) (blank? default-target)) (> (hash-count targets) 1))
    (raise-validation
     "Profiles with multiple targets must define 'defaultTarget' or callers must select a target explicitly."))

  (when (and default-target (not (blank? default-target)) (not (ci-ref targets default-target)))
    (raise-validation (format "Default target '~a' does not exist in 'targets'." default-target)))

  (define safety (bench-profile-safety profile))
  (validate-finite-positive "maxVoltage" (bench-safety-max-voltage safety))
  (validate-finite-positive "maxCurrentMa" (bench-safety-max-current-ma safety))

  (for ([(id resource) (in-hash resources)])
    (when (blank? id)
      (raise-validation "Resource ids cannot be empty."))
    (when (blank? (bench-resource-driver resource))
      (raise-validation (format "Resource '~a' is missing a driver." id)))
    (when (null? (bench-resource-capabilities resource))
      (raise-validation (format "Resource '~a' advertises no capabilities." id))))

  (for ([(id target) (in-hash targets)])
    (when (zero? (hash-count (bench-target-bindings target)))
      (raise-validation (format "Target '~a' has no resource bindings." id)))
    (for ([(capability resource-id) (in-hash (bench-target-bindings target))])
      (define resource (ci-ref resources resource-id))
      (unless resource
        (raise-validation (format "Target '~a' binding '~a' references missing resource '~a'."
                                  id
                                  capability
                                  resource-id)))
      (unless (member capability (bench-resource-capabilities resource) string-ci=?)
        (raise-validation
         (format
          "Target '~a' binds '~a' to resource '~a', but that resource does not advertise the capability."
          id
          capability
          resource-id))))))

;; ----------------------------------------------------------------------------
;; Zero-config simulator profile. One composite simulator resource exposes
;; power + serial + flash so all channels share the same virtual ECU state,
;; and a separate diagnostics resource carries the simulated UDS ECU.
;; ----------------------------------------------------------------------------

(define (default-simulator-profile)
  (bench-profile
   1
   "BenchPilot simulator"
   "demo"
   (hash
    "sim.demo"
    (bench-resource
     "simulator"
     '("power" "serial" "flash")
     (hash "voltage" 12.0 "settleMs" 2000 "port" "SIM0" "baud" 115200 "firmware" "build/app.elf"))
    "sim.uds"
    (bench-resource "sim-diagnostics"
                    '("diagnostics")
                    (hash "requestId" "0x7E0" "responseId" "0x7E8")))
   (hash "demo"
         (bench-target
          "Demo ECU"
          "simulated-mcu"
          (hash "power" "sim.demo" "serial" "sim.demo" "flash" "sim.demo" "diagnostics" "sim.uds")))
   (bench-safety 14.5 2000 #f #f #f)
   #f
   #f
   #f
   #f
   #f))
