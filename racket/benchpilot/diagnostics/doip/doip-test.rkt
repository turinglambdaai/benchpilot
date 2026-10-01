#lang racket/base

;; DoIP path test: simulated entity + TCP client — discovery, routing
;; activation, diagnostic round trip and the full flash workflow over DoIP.

(module+ test
  (require benchpilot/core/contracts
           benchpilot/core/bench-runtime
           benchpilot/diagnostics/doip/doip
           benchpilot/diagnostics/channels/sim-uds-channel
           benchpilot/diagnostics/flash/engine
           benchpilot/diagnostics/uds/protocol
           racket/list
           rackunit)

  (define test-image (for/list ([i (in-range 200)]) (modulo (* i 3) 256)))

  (define server
    (start-simulated-doip-server #:tester-address #x0E00 #:ecu-address #x0E10))

  (test-case "simulated DoIP entity serves the flash workflow over TCP"
    (define client (make-doip-client #x0E00 #x0E10))
    (doip-client-connect! client "127.0.0.1" (simulated-doip-server-listen-port server))

    ;; DID read over diagnostic messages.
    (doip-client-send-request! client (uds-read-did #xF195))
    (define response
      (doip-client-receive-response! client))
    (check-true (not (null? response)))
    ;; Raw diagnostic PDU: positive SID (0x62 = 0x22 | 0x40) then the DID.
    (check-equal? (take response 3) (list #x62 #xF1 #x95))

    ;; Full flash workflow over DoIP through the shared engine.
    (define uds
      (make-uds-client
       (lambda (req cancel) (doip-client-send-request! client req))
       (lambda (cancel poll) (doip-client-receive-response! client))))
    (define result
      (flash-execute
       (make-flash-engine uds)
       (uds-flash-plan (list (uds-flash-segment #x08000000 test-image #f))
                       1024 #x02 #x01 "xor0x5a" #xFF00 #xFF01 0 1000 10000)))
    (check-true (uds-flash-result-ok result))
    (check-equal? (uds-flash-result-total-bytes result) (length test-image))
    (check-equal? (uds-processor-received-image (simulated-doip-server-processor server))
                  test-image))

  (test-case "DoIP UDS channel answers UDS requests through the driver contract"
    (define channel (make-doip-uds-channel "127.0.0.1"
                                           (simulated-doip-server-listen-port server)
                                           #x0E00 #x0E10
                                           #:security-level #x01))
    (define result (doip-uds-channel-request channel (uds-read-did #xFD00) 1000 5000))
    (check-true (uds-request-result-ok result))
    (check-true (uds-request-result-positive result))
    (define payload (hex-parse (uds-request-result-response-hex result)))
    ;; FD00 echoes "ready" from the shared ECU options.
    (check-equal? (bytes->string/utf-8 (list->bytes (drop payload 2))) "ready"))

  (simulated-doip-server-dispose! server))
