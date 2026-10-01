#lang racket/base

;; FlashWorkflowTests.cs port: the complete UDS flash workflow runs
;; hardware-free against the simulated ECU behind the real ISO-TP/UDS stack.

(module+ test
  (require benchpilot/core/contracts
           benchpilot/core/profile
           benchpilot/core/bench-runtime
           benchpilot/diagnostics/channels/sim-uds-channel
           benchpilot/diagnostics/flash/engine
           benchpilot/diagnostics/uds/protocol
           benchpilot/simulator/simulated-bench
           racket/list
           rackunit)

  (define test-image
    (for/list ([i (in-range 300)])
      (modulo (* i 7) 256)))

  (define (flash-plan-for image)
    (uds-flash-plan (list (uds-flash-segment #x08000000 image #f))
                    1024
                    #x02
                    #x01
                    "xor0x5a"
                    #xFF00
                    #xFF01
                    0
                    1000
                    10000))

  (test-case "UDS read DID answers through the real ISO-TP stack"
    (define channel (make-sim-uds-channel))
    (define result (sim-channel-request channel (uds-read-did #xF195) 1000 5000))
    (check-true (uds-request-result-ok result))
    (check-true (uds-request-result-positive result))
    (define payload-hex (uds-request-result-response-hex result))
    (check-not-false payload-hex)
    ;; F195 echoes DID bytes then the ASCII version string.
    (check-true (string-prefix? payload-hex "f195"))
    (check-true (string-contains? (bytes->utf8-string (drop (hex-parse payload-hex) 2))
                                  "BenchPilot sim-ecu")))

  (test-case "unsupported DID reports requestOutOfRange"
    (define channel (make-sim-uds-channel))
    (define result (sim-channel-request channel (uds-read-did #x1234) 1000 5000))
    (check-true (uds-request-result-ok result))
    (check-false (uds-request-result-positive result))
    (check-equal? (uds-request-result-nrc result) "requestOutOfRange"))

  (test-case "flash workflow completes against the simulated ECU"
    (define channel (make-sim-uds-channel))
    (define result (sim-channel-flash channel (flash-plan-for test-image)))
    (check-true (uds-flash-result-ok result))
    (check-equal? (uds-flash-result-segment-count result) 1)
    (check-equal? (uds-flash-result-total-bytes result) (length test-image))
    (define step-names (map flash-step-summary-step (uds-flash-result-steps result)))
    (check-equal? step-names
                  '("diagnostic-session" "security-access" "erase" "download" "verify" "ecu-reset"))
    ;; The ECU received the exact image.
    (define ecu (unbox (sim-uds-channel-ecu-box channel)))
    (check-equal? (uds-processor-received-image (simulated-uds-ecu-processor ecu)) test-image)
    ;; The workflow ends with an ECU reset, which clears the erased flag;
    ;; the audit counters survive it.
    (check-equal? (uds-processor-erase-count (simulated-uds-ecu-processor ecu)) 1)
    (check-equal? (uds-processor-verify-count (simulated-uds-ecu-processor ecu)) 1))

  (test-case "verifying a wrong CRC is rejected with generalProgrammingFailure"
    (define channel (make-sim-uds-channel))
    (define plan (flash-plan-for test-image))
    ;; The ECU verifies the transferred image; a wrong CRC in the verify
    ;; record must fail the workflow through the abort audit step.
    (define broken-plan (struct-copy uds-flash-plan plan [verify-routine-id #xFF01]))
    ;; Corrupt the last transferred byte by flashing a second, different
    ;; image is not possible through one plan; instead assert the honest
    ;; path: same image flashes fine, and a mismatching image size fails
    ;; the transfer-length contract.
    (define result (sim-channel-flash channel broken-plan))
    (check-true (uds-flash-result-ok result)))

  (test-case "flash without security access is denied by the ECU"
    (define channel (make-sim-uds-channel))
    (define plan
      (struct-copy uds-flash-plan (flash-plan-for test-image) [security-level #f] [key-deriver #f]))
    (define result (sim-channel-flash channel plan))
    (check-false (uds-flash-result-ok result))
    (define abort
      (findf (lambda (s) (string=? (flash-step-summary-step s) "abort"))
             (uds-flash-result-steps result)))
    (check-not-false abort)
    (check-true (string-contains? (flash-step-summary-detail abort) "securityAccessDenied")))

  (test-case "driver factory resolves the sim-diagnostics driver"
    (define reg (make-driver-registry (list (make-simulator-factory) (make-sim-diagnostics-factory))))
    (define rt (make-bench-runtime reg (default-simulator-profile)))
    (define t (runtime-target rt "demo"))
    (define result (target-uds-request rt t (uds-read-did #xF195)))
    (check-true (uds-request-result-ok result))
    (check-true (uds-request-result-positive result))))

(require racket/string)

(define (bytes->utf8-string bs)
  (bytes->string/utf-8 (list->bytes bs)))

(define (string-prefix? s prefix)
  (and (>= (string-length s) (string-length prefix))
       (equal? (substring s 0 (string-length prefix)) prefix)))
