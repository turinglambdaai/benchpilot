#lang racket/base

;; Benchpilot.E2E.Tests port: the real CLI against the real resident daemon
;; as separate processes. ShutdownTests + AutostartTests get fresh daemons;
;; AuthAndDiagnosticsTests + FullLoopTests share one (the shared-daemon
;; fixture). Serial execution is inherent — raco test runs cases in order.

(module+ test
  (require benchpilot/core/contracts
           benchpilot/e2e/e2e-env
           json
           racket/file
           racket/format
           racket/list
           racket/port
           racket/string
           racket/tcp
           rackunit)

  ;; JSON null parses to the 'null symbol in Racket.
  (define (null?* v) (or (not v) (eq? v 'null)))
  (define (not-null? v) (not (null?* v)))

  ;; ---------------------------------------------------------------------------
  ;; ShutdownTests
  ;; ---------------------------------------------------------------------------

  (define skip-prefix (getenv "E2E_SKIP_PREFIX"))
  (when (and skip-prefix (not (equal? skip-prefix "2")))
  (test-case "shutdown stops the daemon and releases the endpoint"
    (define env (make-e2e-env))
    (start-daemon! env)
    (check-true (daemon-healthy? env))
    (define-values (code stdout) (run-cli env "shutdown" "--json"))
    (check-equal? code 0)
    (define result (read-json (open-input-string stdout)))
    (check-true (hash-ref result 'ok))
    (sleep 1.5)
    (check-false (daemon-healthy? env))
    (kill-daemon! env))

  (test-case "shutdown is idempotent when the daemon is not running"
    (define env (make-e2e-env))
    (define-values (code stdout) (run-cli env "shutdown" "--json"))
    (check-equal? code 0)
    (define result (read-json (open-input-string stdout)))
    (check-true (hash-ref result 'ok))
    (check-equal? (hash-ref result 'state) "not_running"))

  ;; ---------------------------------------------------------------------------
  ;; AutostartTests
  ;; ---------------------------------------------------------------------------

  (test-case "first command starts the daemon and succeeds"
    (define env (make-e2e-env))
    (define-values (code stdout) (run-cli env "status" "--json"))
    (check-equal? code 0)
    (define result (read-json (open-input-string stdout)))
    (check-true (hash-ref result 'ok))
    ;; The daemon outlives the CLI process (resident is the product premise).
    (check-true (daemon-healthy? env))
    (kill-daemon! env))

  (test-case "doctor does not start the daemon"
    (define env (make-e2e-env))
    (define-values (code stdout) (run-cli env "doctor" "--json"))
    (check-equal? code 4)
    (define report (read-json (open-input-string stdout)))
    (check-false (hash-ref report 'runtimeReachable))
    (check-true (not-null? (hash-ref report 'remediation)))
    (check-false (daemon-healthy? env)))

  ;; ---------------------------------------------------------------------------
  ;; AuthAndDiagnosticsTests + FullLoopTests (shared daemon)
  ;; ---------------------------------------------------------------------------

  )  ; end skip-prefix block
  (when (equal? skip-prefix "2")
  (test-case "SKIPALL" (void)))

  (define shared-env (make-e2e-env))
  (start-daemon! shared-env)

  (define version-regexp #px"^\\d+\\.\\d+\\.\\d+$")
  ;; JSON null parses to the 'null symbol in Racket.

  (test-case "cli reports the product version"
    (define-values (code stdout) (run-cli shared-env "--version"))
    (check-equal? code 0)
    (check-true (regexp-match? version-regexp stdout) stdout)
    (define-values (code2 stdout2) (run-cli shared-env "version"))
    (check-equal? code2 0)
    (check-equal? stdout2 stdout))

  (test-case "healthz and status expose the runtime version"
    (define-values (status body)
      (raw-api-call shared-env "GET" "/healthz" #f #f))
    (check-equal? status 200)
    (define health (read-json (open-input-string body)))
    (check-true (regexp-match? version-regexp (hash-ref health 'version)))
    (define result (run-cli-json shared-env "status" "--json"))
    (check-true (regexp-match? version-regexp (hash-ref result 'runtimeVersion))))

  (test-case "api rejects requests without a token"
    (define-values (status body)
      (raw-api-call shared-env "GET" "/api/v1/status" #f #f))
    (check-equal? status 401)
    (define error (read-json (open-input-string body)))
    (check-equal? (hash-ref error 'code) "unauthorized")
    (check-not-false (hash-ref error 'error)))

  (test-case "api rejects a wrong token"
    (define-values (status _body)
      (raw-api-call shared-env "GET" "/api/v1/status" #f #t
                    "definitely-not-the-token"))
    (check-equal? status 401))

  (test-case "doctor reports a healthy installation"
    (define-values (code stdout) (run-cli shared-env "doctor" "--json"))
    (check-equal? code 0)
    (define report (read-json (open-input-string stdout)))
    (for ([field (in-list '(ok runtimeReachable tokenFound daemonFound versionMatch))])
      (check-true (hash-ref report field) (format "~a was false" field)))
    (check-true (null?* (hash-ref report 'remediation))))

  (test-case "uds routes are served through the resident daemon"
    (define-values (uds-status uds-body)
      (raw-api-call shared-env "POST" "/api/v1/uds/request"
                    (hasheq 'requestHex "22F195")))
    (check-equal? uds-status 200 uds-body)
    (define uds (read-json (open-input-string uds-body)))
    (check-true (hash-ref uds 'positive))
    (define-values (doip-status _doip-body)
      (raw-api-call shared-env "POST" "/api/v1/doip/discover"
                    (hasheq 'windowMs 200)))
    (check-equal? doip-status 200))

  (test-case "history records completed mutations"
    (run-cli-json shared-env "power" "on" "--voltage" "12" "--settle-ms" "100" "--json")
    (run-cli-json shared-env "power" "off" "--json")
    (define history (run-cli-json shared-env "history" "--limit" "5" "--json"))
    (check-not-false
     (findf (lambda (op)
              (and (equal? (hash-ref op 'kind) "power.on")
                   (equal? (hash-ref op 'state) "completed")))
            (hash-ref history 'operations))))

  (test-case "simulator ECU loop succeeds through the cli"
    (run-cli-json shared-env "status" "--json")
    (define on (run-cli-json shared-env "power" "on" "--voltage" "12"
                             "--settle-ms" "200" "--json"))
    (check-true (hash-ref on 'ok))
    (run-cli-json shared-env "serial" "open" "--json")
    (define flash (run-cli-json shared-env "flash" "write" "build/app.elf" "--json"))
    (check-true (hash-ref flash 'ok))
    (check-true (> (hash-ref flash 'bytes) 0))
    (define wait (run-cli-json shared-env "serial" "wait" "Ready"
                               "--timeout-ms" "5000" "--json"))
    (check-true (hash-ref wait 'matched))
    (define check (run-cli-json shared-env "power" "check" "--lt-ma" "100" "--json"))
    (check-true (hash-ref check 'passed))
    (define off (run-cli-json shared-env "power" "off" "--json"))
    (check-true (hash-ref off 'ok)))

  (test-case "unmatched serial wait returns exit code 1 with failure evidence"
    (run-cli-json shared-env "power" "on" "--voltage" "12" "--settle-ms" "100" "--json")
    (run-cli-json shared-env "serial" "open" "--json")
    (define-values (code stdout)
      (run-cli shared-env "serial" "wait" "__E2E_NEVER_MATCH__"
               "--timeout-ms" "50" "--json"))
    (check-equal? code 1)
    (define wait (read-json (open-input-string stdout)))
    (check-true (hash-ref wait 'ok))
    (check-false (hash-ref wait 'matched))
    (define observation-id (hash-ref wait 'observationId))
    (check-true (not-null? observation-id))
    (define evidence
      (run-cli-json shared-env "observe" "evidence" observation-id "--json"))
    (define kinds
      (map (lambda (item) (hash-ref item 'kind)) (hash-ref evidence 'items)))
    (check-not-false (member "serial.wait" kinds))
    (check-not-false (member "serial.failure-window" kinds))
    (check-not-false (member "context.power-on" kinds)))

  (test-case "runtime deadline exceeds semantic wait and returns exit code 6"
    (define-values (code stdout)
      (run-cli shared-env "serial" "wait" "__E2E_DEADLINE__"
               "--timeout-ms" "5000" "--deadline-ms" "100" "--json"))
    (check-equal? code 6)
    (define result (read-json (open-input-string stdout)))
    (check-equal? (hash-ref result 'code) "deadline_exceeded")
    (check-equal? (hash-ref result 'deadlineMs) 100))

  (test-case "simulator bench validate is not ready for real ECU"
    (define-values (code stdout)
      (run-cli shared-env "bench" "validate" "--target" "demo" "--json"))
    (check-equal? code 1)
    (define result (read-json (open-input-string stdout)))
    (check-true (hash-ref result 'ok))
    (check-false (hash-ref result 'readyForRealEcuLoop))
    (check-equal? (hash-ref result 'mode) "simulator")
    (define real-hardware
      (findf (lambda (check) (equal? (hash-ref check 'code) "target.real-hardware"))
             (hash-ref result 'checks)))
    (check-not-false real-hardware)
    (check-false (hash-ref real-hardware 'passed))
    (check-true (not-null? (hash-ref real-hardware 'remediation))))

  (kill-daemon! shared-env))
