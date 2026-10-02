#lang racket/base

;; Frozen wire-contract records (ADR 0002): Racket port of
;; src/Benchpilot.Core/Contracts.cs, DiagnosticsContracts.cs,
;; src/Benchpilot.Protocol/ApiModels.cs plus the hex serialization from
;; HexBytes.cs.
;;
;; JSON parity: the C# host serializes with JsonSerializerDefaults.Web —
;; camelCase keys, null fields written explicitly. Internally absent values
;; are #f; the typed api-record serializer converts them to JSON null only
;; for fields declared nullable.

(require (for-syntax racket/base
                     racket/format
                     racket/list
                     racket/string)
         racket/format
         racket/list
         racket/string)

(begin-for-syntax
  (define (kebab->camel sym)
    (define parts (string-split (symbol->string sym) "-"))
    (string->symbol (apply string-append
                           (car parts)
                           (for/list ([part (in-list (cdr parts))])
                             (string-append (string-upcase (substring part 0 1))
                                            (substring part 1))))))

  ;; Conversion table: internal value -> jsexpr per declared field type.
  (define (converter-for type accessor-sym)
    (case type
      [(nullable-string nullable-int nullable-real) `(let ([v (,accessor-sym r)]) (if v v 'null))]
      [else `(any->jsexpr (,accessor-sym r))])))

(provide (all-defined-out))

;; ----------------------------------------------------------------------------
;; api-record: (api-record name (field type) ...) defines the struct, its
;; accessors and `name->jsexpr`. Types: boolean | real | int | string |
;; nullable-string | nullable-int | nullable-real | string-list |
;; record-list | metadata | record | any
;; ----------------------------------------------------------------------------

(define-syntax (api-record stx)
  (syntax-case stx ()
    [(_ name (field type) ...)
     (let ()
       (define name-sym (syntax->datum #'name))
       (define fields (syntax->datum #'(field ...)))
       (define types (syntax->datum #'(type ...)))
       (define accessors
         (for/list ([f (in-list fields)])
           (string->symbol (format "~a-~a" name-sym f))))
       (define keys (map kebab->camel fields))
       (define serializer (string->symbol (format "~a->jsexpr" name-sym)))
       (define conv-exprs (map converter-for types accessors))
       (datum->syntax stx
                      `(begin
                         (struct ,name-sym ,fields #:transparent)
                         (define (,serializer r)
                           (hasheq ,@(append-map (lambda (key conv) (list (list 'quote key) conv))
                                                 keys
                                                 conv-exprs))))))]))

;; Nested records / lists / string-keyed dictionaries.
(define (any->jsexpr v)
  (cond
    [(struct? v) (api->jsexpr v)]
    [(list? v) (map any->jsexpr v)]
    [(hash? v)
     (for/hash ([(k val) (in-hash v)])
       (values (if (symbol? k)
                   k
                   (string->symbol (format "~a" k)))
               (any->jsexpr val)))]
    [else v]))

;; ----------------------------------------------------------------------------
;; ISO 8601 round-trip ("O") UTC timestamps: seven fractional digits like
;; C# DateTimeOffset "O", so consumers matching that shape keep working.
;; ----------------------------------------------------------------------------

(define (now-millis)
  (inexact->exact (floor (current-inexact-milliseconds))))

(define (utc-now)
  (utc-iso (now-millis)))

(define (utc-iso unix-millis)
  (define sec (quotient unix-millis 1000))
  (define frac (modulo unix-millis 1000))
  (define d (seconds->date sec #f))
  (format "~a-~a-~aT~a:~a:~a.~a+00:00"
          (~a (date-year d) #:width 4 #:pad-string "0")
          (~r (date-month d) #:min-width 2 #:pad-string "0")
          (~r (date-day d) #:min-width 2 #:pad-string "0")
          (~r (date-hour d) #:min-width 2 #:pad-string "0")
          (~r (date-minute d) #:min-width 2 #:pad-string "0")
          (~r (date-second d) #:min-width 2 #:pad-string "0")
          (string-append (~r frac #:min-width 3 #:pad-string "0") "0000")))

;; ----------------------------------------------------------------------------
;; Generic serializer dispatch for nested records.
;; ----------------------------------------------------------------------------

(define (api->jsexpr v)
  (cond
    [(api-error? v) (api-error->jsexpr v)]
    [(power-on-result? v) (power-on-result->jsexpr v)]
    [(power-off-result? v) (power-off-result->jsexpr v)]
    [(current-reading? v) (current-reading->jsexpr v)]
    [(current-check? v) (current-check->jsexpr v)]
    [(flash-result? v) (flash-result->jsexpr v)]
    [(reset-result? v) (reset-result->jsexpr v)]
    [(serial-open-result? v) (serial-open-result->jsexpr v)]
    [(serial-wait-result? v) (serial-wait-result->jsexpr v)]
    [(serial-window-result? v) (serial-window-result->jsexpr v)]
    [(serial-send-result? v) (serial-send-result->jsexpr v)]
    [(resource-health-result? v) (resource-health-result->jsexpr v)]
    [(resource-preflight-result? v) (resource-preflight-result->jsexpr v)]
    [(target-preflight-result? v) (target-preflight-result->jsexpr v)]
    [(bench-readiness-check? v) (bench-readiness-check->jsexpr v)]
    [(target-readiness-result? v) (target-readiness-result->jsexpr v)]
    [(diag-open-result? v) (diag-open-result->jsexpr v)]
    [(uds-request-result? v) (uds-request-result->jsexpr v)]
    [(flash-step-summary? v) (flash-step-summary->jsexpr v)]
    [(uds-flash-result? v) (uds-flash-result->jsexpr v)]
    [(target-summary? v) (target-summary->jsexpr v)]
    [(resource-summary? v) (resource-summary->jsexpr v)]
    [(runtime-status-result? v) (runtime-status-result->jsexpr v)]
    [(operation-summary? v) (operation-summary->jsexpr v)]
    [(operation-list-result? v) (operation-list-result->jsexpr v)]
    [(operation-cancel-result? v) (operation-cancel-result->jsexpr v)]
    [(operation-history-summary? v) (operation-history-summary->jsexpr v)]
    [(operation-history-result? v) (operation-history-result->jsexpr v)]
    [(observation-summary? v) (observation-summary->jsexpr v)]
    [(observation-list-result? v) (observation-list-result->jsexpr v)]
    [(observation-cancel-result? v) (observation-cancel-result->jsexpr v)]
    [(observation-history-summary? v) (observation-history-summary->jsexpr v)]
    [(observation-history-result? v) (observation-history-result->jsexpr v)]
    [(evidence-item-summary? v) (evidence-item-summary->jsexpr v)]
    [(operation-evidence-result? v) (operation-evidence-result->jsexpr v)]
    [(observation-evidence-result? v) (observation-evidence-result->jsexpr v)]
    [(doip-vehicle-summary? v) (doip-vehicle-summary->jsexpr v)]
    [(doip-discovery-result? v) (doip-discovery-result->jsexpr v)]
    [(shutdown-result? v) (shutdown-result->jsexpr v)]
    [(update-check-result? v) (update-check-result->jsexpr v)]
    [(update-result? v) (update-result->jsexpr v)]
    [else (error 'api->jsexpr "no serializer for ~a" v)]))

;; ----------------------------------------------------------------------------
;; Core results (Contracts.cs)
;; ----------------------------------------------------------------------------

(api-record power-on-result
            (ok boolean)
            (voltage real)
            (current-ma real)
            (settled boolean)
            (error nullable-string))
(api-record power-off-result (ok boolean) (error nullable-string))
(api-record current-reading
            (ok boolean)
            (avg-ma real)
            (peak-ma real)
            (samples string-list)
            (error nullable-string))
(api-record current-check (ok boolean) (value-ma real) (passed boolean) (error nullable-string))
(api-record flash-result (ok boolean) (bytes int) (duration-ms int) (error nullable-string))
(api-record reset-result (ok boolean) (error nullable-string))
(api-record serial-open-result
            (ok boolean)
            (port string)
            (baud int)
            (error nullable-string)
            (observation-id nullable-string))
(api-record serial-wait-result
            (ok boolean)
            (matched boolean)
            (matched-line nullable-string)
            (elapsed-ms int)
            (error nullable-string)
            (observation-id nullable-string))
(api-record serial-window-result
            (ok boolean)
            (lines string-list)
            (error nullable-string)
            (observation-id nullable-string))
(api-record serial-send-result (ok boolean) (error nullable-string) (observation-id nullable-string))
(api-record resource-health-result
            (ok boolean)
            (summary string)
            (details metadata)
            (error nullable-string))
(api-record resource-preflight-result
            (ok boolean)
            (resource-id string)
            (driver string)
            (capabilities string-list)
            (summary string)
            (details metadata)
            (error nullable-string))

(api-record target-preflight-result
            (ok boolean)
            (target-id string)
            (target-name string)
            (resources record-list)
            (error nullable-string))
(api-record bench-readiness-check
            (code string)
            (passed boolean)
            (severity string)
            (summary string)
            (remediation nullable-string)
            (details metadata))
(api-record target-readiness-result
            (ok boolean)
            (ready-for-real-ecu-loop boolean)
            (mode string)
            (target-id string)
            (target-name string)
            (required-capabilities string-list)
            (checks record-list)
            (preflight record)
            (error nullable-string))

;; ----------------------------------------------------------------------------
;; Diagnostics contracts (DiagnosticsContracts.cs)
;; ----------------------------------------------------------------------------

(api-record diag-open-result (ok boolean) (transport string) (error nullable-string))
(api-record uds-request-result
            (ok boolean)
            (positive boolean)
            (request-hex string)
            (response-hex nullable-string)
            (nrc nullable-string)
            (error nullable-string))
(api-record flash-step-summary
            (step string)
            (ok boolean)
            (detail string)
            (duration-ms real)
            (nrc nullable-string))
(api-record uds-flash-result
            (ok boolean)
            (segment-count int)
            (total-bytes int)
            (duration-ms real)
            (steps record-list)
            (error nullable-string))

;; ----------------------------------------------------------------------------
;; Protocol API models (ApiModels.cs)
;; ----------------------------------------------------------------------------

(api-record api-error
            (ok boolean)
            (code string)
            (error string)
            (operation-id nullable-string)
            (busy-scope nullable-string)
            (busy-id nullable-string)
            (deadline-ms nullable-int)
            (deadline-at-utc nullable-string))
(api-record target-summary (id string) (name string) (mcu nullable-string) (capabilities string-list))
(api-record resource-summary
            (id string)
            (driver string)
            (capabilities string-list)
            (registered boolean))
(api-record runtime-status-result
            (ok boolean)
            (name string)
            (schema-version int)
            (default-target nullable-string)
            (targets record-list)
            (resources record-list)
            (error nullable-string)
            (runtime-version nullable-string))
(api-record operation-summary
            (id string)
            (target-id string)
            (kind string)
            (resource-ids string-list)
            (started-at-utc string)
            (deadline-at-utc nullable-string)
            (cancellation-requested boolean)
            (deadline-exceeded boolean))
(api-record operation-list-result (ok boolean) (operations record-list) (error nullable-string))
(api-record operation-cancel-result
            (ok boolean)
            (operation-id string)
            (cancel-requested boolean)
            (error nullable-string))
(api-record operation-history-summary
            (id string)
            (target-id string)
            (kind string)
            (resource-ids string-list)
            (started-at-utc string)
            (completed-at-utc string)
            (duration-ms int)
            (deadline-at-utc nullable-string)
            (state string)
            (error nullable-string))
(api-record operation-history-result (ok boolean) (operations record-list) (error nullable-string))
(api-record observation-summary
            (id string)
            (target-id string)
            (kind string)
            (resource-ids string-list)
            (started-at-utc string)
            (deadline-at-utc nullable-string)
            (cancellation-requested boolean)
            (deadline-exceeded boolean))
(api-record observation-list-result (ok boolean) (observations record-list) (error nullable-string))
(api-record observation-cancel-result
            (ok boolean)
            (observation-id string)
            (cancel-requested boolean)
            (error nullable-string))
(api-record observation-history-summary
            (id string)
            (target-id string)
            (kind string)
            (resource-ids string-list)
            (started-at-utc string)
            (completed-at-utc string)
            (duration-ms int)
            (deadline-at-utc nullable-string)
            (state string)
            (error nullable-string))
(api-record observation-history-result
            (ok boolean)
            (observations record-list)
            (error nullable-string))
(api-record evidence-item-summary
            (kind string)
            (summary string)
            (text nullable-string)
            (metadata metadata))
(api-record operation-evidence-result
            (ok boolean)
            (operation-id string)
            (target-id string)
            (operation-kind string)
            (resource-ids string-list)
            (created-at-utc string)
            (items record-list))
(api-record observation-evidence-result
            (ok boolean)
            (observation-id string)
            (target-id string)
            (observation-kind string)
            (resource-ids string-list)
            (created-at-utc string)
            (items record-list))
(api-record doip-vehicle-summary (vin string) (logical-address string) (ip-address nullable-string))
(api-record doip-discovery-result (ok boolean) (vehicles record-list) (error nullable-string))
(api-record shutdown-result (ok boolean) (state string) (error nullable-string))
(api-record update-check-result
            (update-available boolean)
            (current-version string)
            (latest-version nullable-string)
            (release-url nullable-string)
            (error nullable-string))
(api-record update-result
            (ok boolean)
            (message string)
            (new-version nullable-string)
            (daemon-was-running boolean)
            (error nullable-string))

;; ----------------------------------------------------------------------------
;; Runtime internal record types (RuntimeTypes.cs / OperationEvidence.cs /
;; ObservationTypes.cs) — surfaced through the API summaries above; millis
;; integers internally, ISO strings at the API boundary.
;; ----------------------------------------------------------------------------

(struct bench-operation-info
        (id target-id
            kind
            resource-ids
            started-at-millis
            deadline-at-millis
            cancellation-requested
            deadline-exceeded)
  #:transparent)
(struct bench-operation-record
        (id target-id
            kind
            resource-ids
            started-at-millis
            completed-at-millis
            duration-ms
            deadline-at-millis
            state
            error)
  #:transparent)
(struct bench-observation-info
        (id target-id
            kind
            resource-ids
            started-at-millis
            deadline-at-millis
            cancellation-requested
            deadline-exceeded)
  #:transparent)
(struct bench-observation-record
        (id target-id
            kind
            resource-ids
            started-at-millis
            completed-at-millis
            duration-ms
            deadline-at-millis
            state
            error)
  #:transparent)
(struct bench-evidence-item (kind summary text metadata) #:transparent)
(struct bench-operation-evidence
        (operation-id target-id operation-kind resource-ids created-at-millis items)
  #:transparent)
(struct bench-observation-evidence
        (observation-id target-id observation-kind resource-ids created-at-millis items)
  #:transparent)

;; ----------------------------------------------------------------------------
;; Exception taxonomy (RuntimeTypes.cs). The subtype drives CLI exit codes
;; and the HTTP status mapping exactly like the C# host catch chain.
;; ----------------------------------------------------------------------------

(struct exn:benchpilot exn:fail () #:transparent)
(struct exn:benchpilot:validation exn:benchpilot () #:transparent)
(struct exn:benchpilot:target-not-found exn:benchpilot () #:transparent)
(struct exn:benchpilot:busy
        exn:benchpilot
        (target-id operation busy-scope busy-id owner-operation-id owner-operation)
  #:transparent)
(struct exn:benchpilot:deadline-exceeded
        exn:benchpilot
        (target-id operation deadline-ms deadline-at-millis)
  #:transparent)
(struct exn:benchpilot:cancelled exn:benchpilot () #:transparent)

(define (make-cancelled-error)
  (exn:benchpilot:cancelled "Request cancelled." (current-continuation-marks)))

(define (string-blank? s)
  (or (not (string? s)) (zero? (string-length (string-trim s)))))

(define (make-validation-error message)
  (exn:benchpilot:validation message (current-continuation-marks)))

(define (make-target-not-found-error message)
  (exn:benchpilot:target-not-found message (current-continuation-marks)))

(define (raise-validation message)
  (raise (make-validation-error message)))

(define (busy-message target-id operation busy-scope busy-id owner-operation-id owner-operation)
  (define owner
    (if (string-blank? owner-operation-id)
        ""
        (format " Active operation: ~a (~a)." (or owner-operation "mutation") owner-operation-id)))
  (if (string-ci=? busy-scope "resource")
      (format
       "Resource '~a' is busy with another mutating operation; target '~a' operation '~a' was not started.~a"
       (or busy-id "unknown")
       target-id
       operation
       owner)
      (format "Target '~a' is busy with another mutating operation; '~a' was not started.~a"
              target-id
              operation
              owner)))

(define (make-busy-error target-id operation busy-scope busy-id owner-operation-id owner-operation)
  (exn:benchpilot:busy
   (busy-message target-id operation busy-scope busy-id owner-operation-id owner-operation)
   (current-continuation-marks)
   target-id
   operation
   busy-scope
   busy-id
   owner-operation-id
   owner-operation))

(define (make-deadline-error target-id operation deadline-ms deadline-at-millis)
  (exn:benchpilot:deadline-exceeded
   (format "Target '~a' operation '~a' exceeded its Runtime deadline of ~a ms."
           target-id
           operation
           deadline-ms)
   (current-continuation-marks)
   target-id
   operation
   deadline-ms
   deadline-at-millis))

;; ----------------------------------------------------------------------------
;; Hex serialization (HexBytes.cs) — CLI input is hex, JSON responses are
;; lowercase hex, logs are truncated hex.
;; ----------------------------------------------------------------------------

(define (hex-digit? c)
  (or (char-numeric? c) (and (char>=? c #\a) (char<=? c #\f)) (and (char>=? c #\A) (char<=? c #\F))))

(define (hex-value c)
  (cond
    [(char-numeric? c) (- (char->integer c) 48)]
    [(char<=? c #\F) (- (char->integer c) 55)]
    [else (- (char->integer c) 87)]))

;; Parses hex with or without a 0x prefix and with optional interior spaces;
;; odd-length input is rejected.
(define (hex-parse input)
  (unless (and (string? input) (not (string-blank? input)))
    (raise-argument-error 'hex-parse "non-blank string" input))
  (define trimmed (string-trim input))
  (define no-prefix
    (if (>= (string-length trimmed) 2)
        (let ([two (substring trimmed 0 2)])
          (if (or (string=? two "0x") (string=? two "0X"))
              (substring trimmed 2)
              trimmed))
        trimmed))
  (define cleaned (string-replace (string-replace no-prefix " " "") "-" ""))
  (cond
    [(zero? (string-length cleaned)) (raise-validation "Hex payload is empty.")]
    [(odd? (string-length cleaned))
     (raise-validation (format "Hex payload has an odd number of digits: '~a'." input))]
    [else
     (for/list ([i (in-range 0 (string-length cleaned) 2)])
       (define a (string-ref cleaned i))
       (define b (string-ref cleaned (+ i 1)))
       (unless (and (hex-digit? a) (hex-digit? b))
         (raise-validation (format "Hex payload contains non-hex characters: '~a'." input)))
       (+ (* 16 (hex-value a)) (hex-value b)))]))

(define (bytes->hex bs)
  (string-append* (for/list ([b (in-list bs)])
                    (~r b #:base 16 #:min-width 2 #:pad-string "0"))))

(define (truncate-hex bs [max-bytes 64])
  (if (<= (length bs) max-bytes)
      (bytes->hex bs)
      (string-append (bytes->hex (take bs max-bytes))
                     (format "…(+~a bytes)" (- (length bs) max-bytes)))))
