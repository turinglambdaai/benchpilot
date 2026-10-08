#lang racket/base

;; Wire-level test for the Studio backend over a REAL RVT1 server, backed by
;; a fake loopback daemon speaking the benchpilotd HTTP contract. Proves the
;; JSON -> RVT1 adapters end to end: field mapping, integer unit scaling
;; (volts -> millivolts, mA -> microamps), active/history operation shapes,
;; token forwarding, and non-2xx error surfacing across the RPC boundary.

(require rackunit
         racket/async-channel
         racket/list
         racket/string
         racket/tcp
         rivet/backend
         rivet/protocol
         json
         "../app/backend.rkt")

(define (blank? s)
  (regexp-match? #px"^\\s*$" s))

;; --- fake daemon ------------------------------------------------------------

(define last-token (box #f))

(define (fake-status)
  (hasheq 'ok #t
          'name "bench-sim"
          'schemaVersion 2
          'defaultTarget "ecu-main"
          'targets (list (hasheq 'id "ecu-main"
                                 'name "Main ECU"
                                 'mcu 'null
                                 'capabilities (list "flash" "uds")))
          'resources (list (hasheq 'id "psu-1"
                                   'driver "scpi"
                                   'capabilities (list "power")
                                   'registered #t))
          'error 'null
          'runtimeVersion "1.0.0"))

(define (read-http-request in)
  (define request-line (read-line in 'return-linefeed))
  (define parts (string-split request-line " "))
  (define method (if (null? parts) "GET" (first parts)))
  (define target (if (>= (length parts) 2) (second parts) "/"))
  ;; strip the query string: routes match on the path only
  (define path (car (string-split target "?")))
  (let headers-loop ([token #f] [content-length 0])
    (define line (read-line in 'return-linefeed))
    (cond
      [(or (eof-object? line) (blank? line))
       (define body
         (if (> content-length 0)
             (read-json (open-input-bytes (read-bytes content-length in)))
             (hasheq)))
       (values method target token (or body (hasheq)))]
      [(regexp-match #px"(?i:^x-benchpilot-token:[ \t]*(.+)$)" line)
       => (lambda (m) (headers-loop (string-trim (second m)) content-length))]
      [(regexp-match #px"(?i:^content-length:[ \t]*([0-9]+)$)" line)
       => (lambda (m) (headers-loop token (string->number (second m))))]
      [else (headers-loop token content-length)])))

(define (fake-respond out status payload)
  (define body (jsexpr->bytes payload))
  (fprintf out "HTTP/1.1 ~a ~a\r\n" status (if (< status 400) "OK" "Error"))
  (fprintf out "Content-Type: application/json\r\n")
  (fprintf out "Content-Length: ~a\r\nConnection: close\r\n\r\n" (bytes-length body))
  (write-bytes body out)
  (flush-output out)
  (close-output-port out))

(define (fake-route method target query token body)
  (set-box! last-token token)
  (cond
    [(not (string=? (or token "") "test-token"))
     (values 401 (hasheq 'code "unauthorized" 'error "bad token"))]
    [(and (string=? method "GET") (string-suffix? target "/status"))
     (values 200 (fake-status))]
    [(and (string=? method "GET") (string-suffix? target "/operations/history"))
     (values 200
             (hasheq 'ok #t
                     'operations (list (hasheq 'id "op-h1" 'targetId "ecu-main" 'kind "power.on"
                                               'resourceIds (list "psu-1")
                                               'startedAtUtc "2026-10-08T09:00:00.0000000+00:00"
                                               'completedAtUtc "2026-10-08T09:00:03.0000000+00:00"
                                               'durationMs 3000
                                               'deadlineAtUtc 'null
                                               'state "succeeded"
                                               'error 'null)
                                       (hasheq 'id "op-h2" 'targetId "ecu-main" 'kind "flash.write"
                                               'resourceIds (list "jlink-1")
                                               'startedAtUtc "2026-10-08T09:01:00.0000000+00:00"
                                               'completedAtUtc "2026-10-08T09:01:05.0000000+00:00"
                                               'durationMs 5000
                                               'deadlineAtUtc 'null
                                               'state "failed"
                                               'error "verification failed"))))]
    [(and (string=? method "GET") (string-suffix? target "/operations"))
     (values 200
             (hasheq 'ok #t
                     'operations (list (hasheq 'id "op-1" 'targetId "ecu-main" 'kind "power.on"
                                               'resourceIds (list "psu-1")
                                               'startedAtUtc "2026-10-08T09:02:00.0000000+00:00"
                                               'deadlineAtUtc 'null
                                               'cancellationRequested #f
                                               'deadlineExceeded #f))))]
    [(and (string=? method "POST") (string-suffix? target "/power/on"))
     (if (regexp-match? #rx"target=boom" query)
         (values 409 (hasheq 'code "busy" 'error "resource busy"))
         (values 200 (hasheq 'ok #t 'voltage 12.0 'currentMa 45.6 'settled #t 'error 'null)))]
    [(and (string=? method "POST") (string-suffix? target "/flash/write"))
     (values 200 (hasheq 'ok #t 'bytes 1024 'durationMs 3000 'error 'null))]
    [(and (string=? method "POST") (string-suffix? target "/operations/cancel"))
     (values 200 (hasheq 'ok #t 'operationId "op-1" 'cancelRequested #t 'error 'null))]
    [(and (string=? method "POST")
          (or (string-suffix? target "/power/off")
              (string-suffix? target "/power/emergency-off")
              (string-suffix? target "/flash/reset")))
     (values 200 (hasheq 'ok #t 'error 'null))]
    [else (values 404 (hasheq 'code "not_found" 'error "no route"))]))

(define fake-port
  (let loop ([port 49190])
    (with-handlers ([exn:fail? (lambda (_) (loop (add1 port)))])
      (define listener (tcp-listen port 16 #t "127.0.0.1"))
      (thread
       (lambda ()
         (let accept ()
           (define-values (in out) (tcp-accept listener))
           (with-handlers ([exn:fail? void])
             (define-values (method target token body) (read-http-request in))
             (define-values (path query)
               (let ([qm (regexp-match #rx"^([^?]*)\\?(.*)$" target)])
                 (if qm (values (second qm) (third qm)) (values target ""))))
             (define-values (status payload) (fake-route method path query token body))
             (fake-respond out status payload))
           (with-handlers ([exn:fail? void]) (close-input-port in))
           (accept))))
      port)))

;; --- point the backend at the fake daemon ------------------------------------

(putenv "BENCHPILOT_ENDPOINT" (format "http://127.0.0.1:~a/" fake-port))
(putenv "BENCHPILOT_TOKEN" "test-token")

;; --- start the RVT1 server on pipes -------------------------------------------

(define-values (server-in client-out) (make-pipe))
(define-values (client-in server-out) (make-pipe))

(define server-thread (thread (lambda () (serve server-in server-out))))

(define hello (read-frame client-in))
(check-equal? (frame-type hello) message:hello)

(define frames (make-async-channel 1024))
(thread
 (lambda ()
   (let loop ()
     (define f (read-frame client-in))
     (unless (eof-object? f)
       (async-channel-put frames f)
       (loop)))))

(define (next-frame [timeout 10.0])
  (define f (sync/timeout timeout frames))
  (unless f (error 'backend-server-test "timed out waiting for a frame"))
  f)

(define next-id 1)

(define (call name . args)
  (define id next-id)
  (set! next-id (add1 next-id))
  (write-frame (frame message:request id (encode-value (cons name args)))
               client-out)
  (let loop ()
    (define f (next-frame))
    (cond
      [(= (frame-type f) message:event) (loop)]
      [(= (frame-id f) id)
       (define payload (decode-value (frame-payload f)))
       (values (if (= (frame-type f) message:response) 'response 'error)
               payload)]
      [else (loop)])))

;; --- 1. status: field mapping across the wire ---------------------------------

(define-values (status-kind status-wire) (call "status"))
(check-equal? status-kind 'response)
(check-equal? (list-ref status-wire 0) "bench-sim")          ; name
(check-equal? (list-ref status-wire 1) 2)                    ; schema-version
(check-equal? (list-ref status-wire 2) "ecu-main")           ; default-target
(check-equal? (length (list-ref status-wire 3)) 1)           ; targets
(define target-wire (list-ref (list-ref status-wire 3) 0))
(check-equal? (list-ref target-wire 0) "ecu-main")
(check-equal? (list-ref target-wire 1) "Main ECU")
(check-equal? (list-ref target-wire 3) (list "flash" "uds"))
(define resource-wire (list-ref (list-ref status-wire 4) 0))
(check-equal? (list-ref resource-wire 0) "psu-1")
(check-equal? (list-ref resource-wire 1) "scpi")
(check-true (list-ref resource-wire 3))                      ; registered
(check-equal? (list-ref status-wire 5) "1.0.0")              ; runtime-version
(check-equal? (unbox last-token) "test-token")

;; --- 2. operations: active + history shapes ------------------------------------

(define-values (ops-kind ops-wire) (call "list-operations"))
(check-equal? ops-kind 'response)
(check-equal? (length ops-wire) 1)
(define op-wire (list-ref ops-wire 0))
(check-equal? (list-ref op-wire 0) "op-1")
(check-equal? (list-ref op-wire 2) "power.on")
(check-false (list-ref op-wire 6))                           ; cancellation-requested

(define-values (hist-kind hist-wire) (call "operation-history" 25))
(check-equal? hist-kind 'response)
(check-equal? (length hist-wire) 2)
(check-equal? (list-ref (list-ref hist-wire 0) 6) 3000)      ; duration-ms
(check-equal? (list-ref (list-ref hist-wire 0) 8) "succeeded")
(check-equal? (list-ref (list-ref hist-wire 1) 9) "verification failed")

;; --- 3. power-on: unit scaling volts -> millivolts, mA -> microamps -------------

(define-values (pon-kind pon-wire) (call "power-on" "ecu-main" 12000 2000))
(check-equal? pon-kind 'response)
(check-true (list-ref pon-wire 0))                           ; ok
(check-equal? (list-ref pon-wire 1) 12000)                   ; voltage-millivolts
(check-equal? (list-ref pon-wire 2) 45600)                   ; current-microamps
(check-true (list-ref pon-wire 3))                           ; settled

;; --- 4. flash-write / actions / cancel -------------------------------------------

(define-values (fw-kind fw-wire) (call "flash-write" "ecu-main" "/tmp/fw.hex" (void)))
(check-equal? fw-kind 'response)
(check-true (list-ref fw-wire 0))
(check-equal? (list-ref fw-wire 1) 1024)
(check-equal? (list-ref fw-wire 2) 3000)

(define-values (poff-kind poff-wire) (call "power-off" "ecu-main"))
(check-equal? poff-kind 'response)
(check-true (list-ref poff-wire 0))

(define-values (eoff-kind eoff-wire) (call "emergency-off" "ecu-main"))
(check-equal? eoff-kind 'response)
(check-true (list-ref eoff-wire 0))

(define-values (reset-kind reset-wire) (call "flash-reset" "ecu-main" (void)))
(check-equal? reset-kind 'response)
(check-true (list-ref reset-wire 0))

(define-values (cancel-kind cancel-wire) (call "cancel-operation" "op-1"))
(check-equal? cancel-kind 'response)
(check-true (list-ref cancel-wire 0))
(check-equal? (list-ref cancel-wire 1) "op-1")
(check-true (list-ref cancel-wire 2))

;; --- 5. daemon non-2xx surfaces as an RPC error frame -----------------------------

(define-values (boom-kind boom-wire) (call "power-on" "boom" 12000 2000))
(check-equal? boom-kind 'error)
(check-true (string-contains? (format "~a" boom-wire) "resource busy"))

;; --- shutdown ----------------------------------------------------------------

(write-frame (frame message:shutdown 0 #"") client-out)
(thread-wait server-thread)
