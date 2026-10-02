#lang racket/base

;; DTC primitives: the simulated ECU answers ReadDTCInformation (0x19 0x02)
;; with its canned fault and clears it via ClearDiagnosticInformation (0x14).

(module+ test
  (require benchpilot/core/contracts
           benchpilot/diagnostics/channels/sim-uds-channel
           benchpilot/diagnostics/uds/protocol
           racket/list
           racket/string
           rackunit)

  (define ch (make-sim-uds-channel))

  (define (dtc-request request)
    (define result (sim-channel-request ch request 1000 5000))
    (check-true (uds-request-result-ok result))
    (check-true (uds-request-result-positive result))
    (parse-dtc-response
     (hex-parse (uds-request-result-response-hex result))))

  (test-case "fresh ECU reports the canned DTC"
    (define parsed (dtc-request (uds-read-dtcs #xFF)))
    (check-equal? (hash-ref parsed 'availableMask) #x2F)
    (define dtcs (hash-ref parsed 'dtcs))
    (check-equal? (length dtcs) 1)
    (check-equal? (hash-ref (first dtcs) 'dtc) "0x010870")
    (check-equal? (hash-ref (first dtcs) 'status) "0x2f"))

  (test-case "clearing removes the DTC"
    ;; 0x14 answers with the bare positive SID, which the channel reports
    ;; as an empty payload.
    (define cleared (sim-channel-request ch (uds-clear-dtcs #xFFFFFF) 1000 5000))
    (check-true (uds-request-result-ok cleared))
    (check-true (uds-request-result-positive cleared))
    (check-equal? (uds-request-result-response-hex cleared) "")
    (check-equal? (hash-ref (dtc-request (uds-read-dtcs #xFF)) 'dtcs) '()))

  (test-case "malformed requests are rejected with ISO NRCs"
    (define result (sim-channel-request ch (list #x19 #x02) 1000 5000))
    (check-false (uds-request-result-positive result))
    (check-equal? (uds-request-result-nrc result) "incorrectMessageLength")))
