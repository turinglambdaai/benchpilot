#lang racket/base

;; RuntimeHost Program.cs + RuntimeHostLifecycle.cs + RuntimeShutdownService
;; port: the resident benchpilotd — a loopback-only HTTP JSON API over the
;; runtime, with per-user token auth, stopping middleware, graceful drain
;; shutdown and the auto-start quiet mode.
;;
;; Route table: every route evaluates to a plain thunk; admit/stopping
;; wrapping happens once at the dispatch site, keeping the table flat.

(require json
         racket/format
         racket/list
         racket/port
         racket/string
         racket/tcp)

(require benchpilot/core/bench-runtime
         benchpilot/core/contracts
         benchpilot/core/profile
         benchpilot/core/runtime-state
         benchpilot/diagnostics/channels/sim-uds-channel
         benchpilot/diagnostics/doip/doip
         benchpilot/diagnostics/uds/protocol
         benchpilot/protocol/local-auth
         benchpilot/runtime-host/http
         benchpilot/simulator/simulated-bench)

(provide run-daemon
         (struct-out lifecycle)
         make-lifecycle
         lifecycle-begin-stopping!
         lifecycle-stopping?
         lifecycle-try-enter!
         lifecycle-exit!
         make-dispatcher)

;; ----------------------------------------------------------------------------
;; Lifecycle (RuntimeHostLifecycle)
;; ----------------------------------------------------------------------------

(struct lifecycle (stopping-box in-flight-box))

(define (make-lifecycle)
  (lifecycle (box 0) (box 0)))

(define (lifecycle-begin-stopping! lc)
  (set-box! (lifecycle-stopping-box lc) 1))
(define (lifecycle-stopping? lc)
  (not (zero? (unbox (lifecycle-stopping-box lc)))))

;; Atomically admits one non-health API request while running; the second
;; stopping check closes the shutdown race.
(define (lifecycle-try-enter! lc)
  (and (not (lifecycle-stopping? lc))
       (let ()
         (set-box! (lifecycle-in-flight-box lc) (add1 (unbox (lifecycle-in-flight-box lc))))
         (cond
           [(lifecycle-stopping? lc)
            (set-box! (lifecycle-in-flight-box lc) (sub1 (unbox (lifecycle-in-flight-box lc))))
            #f]
           [else #t]))))

(define (lifecycle-exit! lc)
  (set-box! (lifecycle-in-flight-box lc) (max 0 (sub1 (unbox (lifecycle-in-flight-box lc))))))

;; ----------------------------------------------------------------------------
;; Driver composition
;; ----------------------------------------------------------------------------

(define (parse-hex-setting v)
  (and (string? v)
       (let ([m (regexp-match #rx"^0x([0-9a-fA-F]+)$" v)]) (and m (string->number (second m) 16)))))

(define (can-uds-settings-factory)
  (driver-factory
   "can-uds"
   (lambda (resource-id config)
     (define settings (bench-resource-settings config))
     (sim-diagnostics-driver
      (make-sim-uds-channel
       #:tester-to-ecu-id (or (parse-hex-setting (hash-ref settings 'requestId #f)) #x7E0)
       #:ecu-to-tester-id (or (parse-hex-setting (hash-ref settings 'responseId #f)) #x7E8))))))

;; ----------------------------------------------------------------------------
;; JSON protocol mapping
;; ----------------------------------------------------------------------------

(define (iso millis)
  (and millis (utc-iso millis)))

(define (active-op->summary a)
  (operation-summary (active-exec-id a)
                     (active-exec-target-id a)
                     (active-exec-kind a)
                     (active-exec-resource-ids a)
                     (iso (active-exec-started-at-millis a))
                     (iso (active-exec-deadline-at-millis a))
                     (exec-cancel-cancellation-requested? (active-exec-cancel a))
                     (exec-cancel-deadline-exceeded? (active-exec-cancel a))))

(define (active-obs->summary a)
  (observation-summary (active-exec-id a)
                       (active-exec-target-id a)
                       (active-exec-kind a)
                       (active-exec-resource-ids a)
                       (iso (active-exec-started-at-millis a))
                       (iso (active-exec-deadline-at-millis a))
                       (exec-cancel-cancellation-requested? (active-exec-cancel a))
                       (exec-cancel-deadline-exceeded? (active-exec-cancel a))))

(define (record->history-summary rec)
  (operation-history-summary (bench-operation-record-id rec)
                             (bench-operation-record-target-id rec)
                             (bench-operation-record-kind rec)
                             (bench-operation-record-resource-ids rec)
                             (iso (bench-operation-record-started-at-millis rec))
                             (iso (bench-operation-record-completed-at-millis rec))
                             (bench-operation-record-duration-ms rec)
                             (iso (bench-operation-record-deadline-at-millis rec))
                             (bench-operation-record-state rec)
                             (bench-operation-record-error rec)))

(define (obs-record->history-summary rec)
  (observation-history-summary (bench-observation-record-id rec)
                               (bench-observation-record-target-id rec)
                               (bench-observation-record-kind rec)
                               (bench-observation-record-resource-ids rec)
                               (iso (bench-observation-record-started-at-millis rec))
                               (iso (bench-observation-record-completed-at-millis rec))
                               (bench-observation-record-duration-ms rec)
                               (iso (bench-observation-record-deadline-at-millis rec))
                               (bench-observation-record-state rec)
                               (bench-observation-record-error rec)))

(define (evidence-items->summaries items)
  (for/list ([item (in-list items)])
    (evidence-item-summary (bench-evidence-item-kind item)
                           (bench-evidence-item-summary item)
                           (bench-evidence-item-text item)
                           (bench-evidence-item-metadata item))))

;; ----------------------------------------------------------------------------
;; Status/result helpers (Execute wrapper)
;; ----------------------------------------------------------------------------

(define (ok-result v)
  (cons 200 (api->jsexpr v)))

(define (execute proc)
  (with-handlers
      ([exn:benchpilot:validation?
        (lambda (e)
          (cons 400 (api->jsexpr (api-error #f "validation" (exn-message e) #f #f #f #f #f))))]
       [exn:benchpilot:target-not-found?
        (lambda (e)
          (cons 404 (api->jsexpr (api-error #f "not_found" (exn-message e) #f #f #f #f #f))))]
       [exn:benchpilot:busy?
        (lambda (e)
          (cons 409
                (api->jsexpr (api-error #f
                                        "busy"
                                        (exn-message e)
                                        (exn:benchpilot:busy-owner-operation-id e)
                                        (exn:benchpilot:busy-busy-scope e)
                                        (exn:benchpilot:busy-busy-id e)
                                        #f
                                        #f))))]
       [exn:benchpilot:deadline-exceeded?
        (lambda (e)
          (cons 408
                (api->jsexpr (api-error #f
                                        "deadline_exceeded"
                                        (exn-message e)
                                        #f
                                        #f
                                        #f
                                        (exn:benchpilot:deadline-exceeded-deadline-ms e)
                                        (iso (exn:benchpilot:deadline-exceeded-deadline-at-millis
                                              e))))))]
       [exn:benchpilot:cancelled?
        (lambda (_)
          (cons 409 (api->jsexpr (api-error #f "cancelled" "Request cancelled." #f #f #f #f #f))))]
       [exn:benchpilot?
        (lambda (e)
          (cons 409 (api->jsexpr (api-error #f "runtime_state" (exn-message e) #f #f #f #f #f))))]
       [exn:fail? (lambda (e)
                    (cons 500
                          (api->jsexpr (api-error #f "internal" (exn-message e) #f #f #f #f #f))))])
    (ok-result (proc))))

(define (hex-up*4 n)
  (string-upcase (~r n #:base 16 #:min-width 4 #:pad-string "0")))

;; ----------------------------------------------------------------------------
;; Daemon entry point
;; ----------------------------------------------------------------------------

(define (daemon-log log-file-box message)
  (when (unbox log-file-box)
    (with-handlers ([exn:fail? (lambda (_) (void))])
      (call-with-output-file* (unbox log-file-box)
                              (lambda (out) (fprintf out "~a ~a~n" (utc-now) message))
                              #:mode 'text
                              #:exists 'append))))

(define (run-daemon [args '()])
  (define endpoint-text (or (getenv "BENCHPILOT_ENDPOINT") ""))
  (define endpoint-text* (if (string-blank? endpoint-text) "http://127.0.0.1:5640" endpoint-text))
  (define m (regexp-match #px"^http://([^/:]+):(\\d+)/?$" endpoint-text*))
  (unless m
    (eprintf "Invalid BENCHPILOT_ENDPOINT: ~a~n" endpoint-text*)
    (exit 2))
  (define host (second m))
  (define port (string->number (third m)))
  (unless (or (string=? host "127.0.0.1") (string=? host "localhost"))
    (eprintf "BenchPilot Runtime refuses non-loopback binding at this milestone.~n")
    (exit 2))

  (define quiet (not (string-blank? (or (getenv "BENCHPILOT_QUIET") ""))))
  (when quiet
    ;; Detach from the spawning shell's pipes: close the inherited write
    ;; ends so the parent's readers see EOF, and land console writes on the
    ;; NUL device.
    (with-handlers ([exn:fail? (lambda (_) (void))])
      (close-output-port (current-output-port))
      (close-output-port (current-error-port)))
    (current-output-port (open-output-nowhere))
    (current-error-port (open-output-nowhere)))

  (define log-path (getenv "BENCHPILOT_LOG_FILE"))
  (define log-file-box (box (and log-path (not (string-blank? log-path)) log-path)))

  (define profile
    (let ([profile-path (getenv "BENCHPILOT_PROFILE")])
      (if (or (not profile-path) (string-blank? profile-path))
          (default-simulator-profile)
          (load-profile profile-path))))

  (define registry
    (make-driver-registry (list (make-simulator-factory)
                                (make-sim-diagnostics-factory)
                                (can-uds-settings-factory)
                                (make-doip-uds-resource-factory))))
  (define rt (make-bench-runtime registry profile))
  (define state (bench-runtime-state rt))
  (define lc (make-lifecycle))
  (define api-token (resolve-or-create-token))

  (daemon-log log-file-box
              (format "BenchPilot Runtime ~a listening on http://~a:~a. Profile: ~a."
                      benchpilot-version
                      host
                      port
                      (bench-profile-name profile)))

  (define shutdown-requested (make-semaphore))

  (define (begin-shutdown!)
    (lifecycle-begin-stopping! lc)
    (for ([op (in-list (runtime-active-operations state))])
      (runtime-cancel-operation! state (active-exec-id op)))
    (for ([obs (in-list (runtime-active-observations state))])
      (runtime-cancel-observation! state (active-exec-id obs))))

  (thread (lambda ()
            (semaphore-wait shutdown-requested)
            (begin-shutdown!)
            ;; Bounded drain: cancel everything active and wait, then exit.
            (define deadline (+ (now-millis) 5000))
            (let loop ()
              (define drained (drain-runtime! state (max 0 (- deadline (now-millis)))))
              (when (and (not (drain-result-drained drained)) (< (now-millis) deadline))
                (sleep 0.025)
                (loop)))
            (exit 0)))

  (define dispatch (make-dispatcher rt state lc begin-shutdown!))

  (http-serve
   #:host host
   #:port port
   #:token api-token
   #:admit (lambda () (lifecycle-try-enter! lc))
   #:exit-request (lambda () (lifecycle-exit! lc))
   #:health-handler (lambda ()
                      (if (lifecycle-stopping? lc)
                          (cons 503 (hasheq 'ok #f 'state "stopping" 'version benchpilot-version))
                          (cons 200 (hasheq 'ok #t 'state "running" 'version benchpilot-version))))
   #:handler
   (lambda (method path query body)
     (define api-path
       (if (string-prefix? path "/api/v1")
           (substring path 7)
           path))
     (define route-thunk (dispatch method api-path query body))
     ;; Admit once at the dispatch site: while stopping, no new non-health
     ;; work is accepted; requests admitted just before shutdown stay
     ;; counted until they leave.
     (if route-thunk
         (if (lifecycle-try-enter! lc)
             (begin0 (execute route-thunk)
               (lifecycle-exit! lc))
             (cons 503
                   (api->jsexpr
                    (api-error #f
                               "runtime_stopping"
                               "BenchPilot Runtime is stopping and is not accepting new work."
                               #f
                               #f
                               #f
                               #f
                               #f))))
         (cons
          404
          (api->jsexpr
           (api-error #f "not_found" (format "No API route: ~a ~a" method path) #f #f #f #f #f))))))

  (sync/timeout +inf.0 shutdown-requested)
  (exit 0))

;; ----------------------------------------------------------------------------
;; Route table: (method path thunk?) triples via match. Each thunk closes
;; over the request's query/body. Returns #f for unknown routes.
;; ----------------------------------------------------------------------------

(define (make-dispatcher rt state lc begin-shutdown!)
  (define (target* query)
    (runtime-target rt (query-ref query "target")))
  (lambda (method api-path query body-json)
    (define match? (lambda (m p) (and (string=? method m) (string=? api-path p))))
    (cond
      [(match? "GET" "/status")
       (lambda ()
         (define profile (bench-runtime-profile rt))
         (define targets
           (for/list ([pair (in-list (sort (hash->list (bench-profile-targets profile))
                                           string-ci<?
                                           #:key car))])
             (target-summary (car pair)
                             (let ([cfg (cdr pair)])
                               (if (string-blank? (bench-target-name cfg))
                                   (car pair)
                                   (bench-target-name cfg)))
                             (bench-target-mcu (cdr pair))
                             (sort (hash-keys (bench-target-bindings (cdr pair))) string-ci<?))))
         (define resources
           (for/list ([pair (in-list (sort (hash->list (bench-profile-resources profile))
                                           string-ci<?
                                           #:key car))])
             (resource-summary (car pair)
                               (bench-resource-driver (cdr pair))
                               (sort (bench-resource-capabilities (cdr pair)) string-ci<?)
                               (registry-registered? rt (car pair)))))
         (runtime-status-result #t
                                (bench-profile-name profile)
                                (bench-profile-schema-version profile)
                                (bench-profile-default-target profile)
                                targets
                                resources
                                #f
                                benchpilot-version))]
      [(match? "GET" "/operations")
       (lambda ()
         (operation-list-result #t (map active-op->summary (runtime-active-operations state)) #f))]
      [(match? "GET" "/operations/history")
       (lambda ()
         (operation-history-result
          #t
          (map record->history-summary (runtime-recent-operations state (query-int query "limit" 50)))
          #f))]
      [(match? "GET" "/operations/evidence")
       (lambda ()
         (define operation-id (query-ref query "operationId"))
         (when (string-blank? operation-id)
           (raise-validation "Operation id cannot be empty."))
         (define evidence (runtime-get-operation-evidence state operation-id))
         (unless evidence
           (raise (make-target-not-found-error (format "Evidence for operation '~a' was not found."
                                                       operation-id))))
         (operation-evidence-result #t
                                    (bench-operation-evidence-operation-id evidence)
                                    (bench-operation-evidence-target-id evidence)
                                    (bench-operation-evidence-operation-kind evidence)
                                    (bench-operation-evidence-resource-ids evidence)
                                    (iso (bench-operation-evidence-created-at-millis evidence))
                                    (evidence-items->summaries (bench-operation-evidence-items
                                                                evidence))))]
      [(match? "POST" "/operations/cancel")
       (lambda ()
         (define operation-id (query-ref query "operationId"))
         (when (string-blank? operation-id)
           (raise-validation "Operation id cannot be empty."))
         (unless (runtime-cancel-operation! state operation-id)
           (raise (make-target-not-found-error (format "Active operation '~a' was not found."
                                                       operation-id))))
         (operation-cancel-result #t operation-id #t #f))]
      [(match? "GET" "/observations")
       (lambda ()
         (observation-list-result #t
                                  (map active-obs->summary (runtime-active-observations state))
                                  #f))]
      [(match? "GET" "/observations/history")
       (lambda ()
         (observation-history-result #t
                                     (map obs-record->history-summary
                                          (runtime-recent-observations state
                                                                       (query-int query "limit" 50)))
                                     #f))]
      [(match? "GET" "/observations/evidence")
       (lambda ()
         (define observation-id (query-ref query "observationId"))
         (when (string-blank? observation-id)
           (raise-validation "Observation id cannot be empty."))
         (define evidence (runtime-get-observation-evidence state observation-id))
         (unless evidence
           (raise (make-target-not-found-error (format "Evidence for observation '~a' was not found."
                                                       observation-id))))
         (observation-evidence-result #t
                                      (bench-observation-evidence-observation-id evidence)
                                      (bench-observation-evidence-target-id evidence)
                                      (bench-observation-evidence-observation-kind evidence)
                                      (bench-observation-evidence-resource-ids evidence)
                                      (iso (bench-observation-evidence-created-at-millis evidence))
                                      (evidence-items->summaries (bench-observation-evidence-items
                                                                  evidence))))]
      [(match? "POST" "/observations/cancel")
       (lambda ()
         (define observation-id (query-ref query "observationId"))
         (when (string-blank? observation-id)
           (raise-validation "Observation id cannot be empty."))
         (unless (runtime-cancel-observation! state observation-id)
           (raise (make-target-not-found-error (format "Active observation '~a' was not found."
                                                       observation-id))))
         (observation-cancel-result #t observation-id #t #f))]
      [(match? "POST" "/preflight") (lambda () (runtime-preflight rt (query-ref query "target")))]
      [(match? "POST" "/validate")
       (lambda () (runtime-validate-target-readiness rt (query-ref query "target")))]
      [(match? "POST" "/power/on")
       (lambda ()
         (target-power-on rt
                          (target* query)
                          (body-real body-json 'voltage 12)
                          (body-int body-json 'settleMs 2000)
                          #:deadline-ms (query-int-opt query "deadlineMs")))]
      [(match? "POST" "/power/off")
       (lambda ()
         (target-power-off rt (target* query) #:deadline-ms (query-int-opt query "deadlineMs")))]
      [(match? "POST" "/power/emergency-off")
       (lambda () (target-emergency-power-off rt (target* query)))]
      [(match? "POST" "/power/current/read")
       (lambda () (target-read-current rt (target* query) (body-int body-json 'windowMs 500)))]
      [(match? "POST" "/power/current/check")
       (lambda ()
         (target-check-current rt
                               (target* query)
                               (body-real-opt body-json 'ltMa)
                               (body-real-opt body-json 'gtMa)))]
      [(match? "POST" "/flash/write")
       (lambda ()
         (target-flash rt
                       (target* query)
                       (body-string body-json 'firmware)
                       (body-string-opt body-json 'confirmTarget)
                       #:deadline-ms (query-int-opt query "deadlineMs")))]
      [(match? "POST" "/flash/reset")
       (lambda ()
         (target-reset rt
                       (target* query)
                       (body-string-opt body-json 'confirmTarget)
                       #:deadline-ms (query-int-opt query "deadlineMs")))]
      [(match? "POST" "/serial/open")
       (lambda ()
         (target-serial-open rt
                             (target* query)
                             (body-string-opt body-json 'port)
                             (body-int-opt body-json 'baud)
                             #:deadline-ms (query-int-opt query "deadlineMs")))]
      [(match? "POST" "/serial/wait")
       (lambda ()
         (target-serial-wait rt
                             (target* query)
                             (body-string body-json 'pattern)
                             (body-int body-json 'timeoutMs 10000)
                             #:deadline-ms (query-int-opt query "deadlineMs")))]
      [(match? "POST" "/serial/window")
       (lambda ()
         (target-serial-window rt
                               (target* query)
                               (body-int body-json 'lines 50)
                               (body-string-opt body-json 'filter)
                               #:deadline-ms (query-int-opt query "deadlineMs")))]
      [(match? "POST" "/serial/send")
       (lambda ()
         (target-serial-send rt
                             (target* query)
                             (body-string body-json 'data)
                             #:deadline-ms (query-int-opt query "deadlineMs")))]
      [(match? "POST" "/uds/request")
       (lambda ()
         (define hex (body-string-opt body-json 'requestHex))
         (when (or (not hex) (string-blank? hex))
           (raise-validation "requestHex cannot be empty."))
         (define bytes (hex-parse hex))
         (target-uds-request rt
                             (target* query)
                             bytes
                             #:p2-ms (body-int-opt body-json 'p2TimeoutMs)
                             #:p2-star-ms (body-int-opt body-json 'p2StarTimeoutMs)))]
      [(match? "POST" "/uds/flash")
       (lambda ()
         (define firmware (body-string-opt body-json 'firmware))
         (define plan-path (body-string-opt body-json 'planPath))
         (when (or (not firmware) (string-blank? firmware))
           (raise-validation "firmware is required."))
         (when (and (not (body-int-opt body-json 'address))
                    (or (not plan-path) (string-blank? plan-path)))
           (raise-validation
            "address is required when no planPath is given (for example 0x08000000)."))
         (target-uds-flash rt
                           (target* query)
                           firmware
                           plan-path
                           (body-int-opt body-json 'address)
                           (body-int-opt body-json 'maxBlockPayload)
                           (body-string-opt body-json 'confirmTarget)
                           #:deadline-ms (query-int-opt query "deadlineMs")))]
      [(match? "POST" "/doip/discover")
       (lambda ()
         (define identities (doip-client-discover (body-int body-json 'windowMs 800)))
         (doip-discovery-result
          #t
          (for/list ([identity (in-list identities)])
            (doip-vehicle-summary (doip-vehicle-identity-vin identity)
                                  (format "0x~a"
                                          (hex-up*4 (doip-vehicle-identity-logical-address identity)))
                                  (doip-vehicle-identity-ip-address identity)))
          #f))]
      [(match? "POST" "/shutdown")
       (lambda ()
         ;; Token-authenticated like every other endpoint: the graceful
         ;; "drain active work, release hardware, exit" path.
         (begin-shutdown!)
         (shutdown-result #t "stopping" #f))]
      [else #f])))
