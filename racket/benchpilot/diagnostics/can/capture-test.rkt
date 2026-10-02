#lang racket/base

;; CAN capture + DBC: golden DBC parse/decode, signal encode, bounded
;; capture ring behavior.

(module+ test
  (require benchpilot/core/contracts
           benchpilot/diagnostics/can/capture
           benchpilot/diagnostics/isotp/codec
           racket/list
           rackunit)

  (define dbc-sample
    #<<DBC
BO_ 568 EngineData: 8 ENG
 SG_ EngineSpeed : 0|16@1+ (0.25,0) [0|16383] "rpm"
 SG_ EngineTemp : 16|8@1+ (1,-40) [-40|215] "degC"
BO_ 257 VehicleData: 8 ABS
 SG_ VehicleSpeed : 0|16@1+ (0.01,0) [0|655] "m/s"
DBC
    )

  (define db (parse-dbc dbc-sample))

  (test-case "dbc parses message headers and signals"
    (check-equal? (length db) 2)
    (define eng (first db))
    (check-equal? (dbc-message-id eng) 568)
    (check-equal? (dbc-message-name eng) "EngineData")
    (check-equal? (length (dbc-message-signals eng)) 2)
    (define speed (first (dbc-message-signals eng)))
    (check-equal? (dbc-signal-name speed) "EngineSpeed")
    (check-equal? (dbc-signal-start-bit speed) 0)
    (check-true (dbc-signal-little-endian speed))
    (check-equal? (dbc-signal-factor speed) 0.25))

  (test-case "signal decode applies factor and offset"
    (define data (bytes #x10 #x27 #x50 #x00 #x00 #x00 #x00 #x00))
    (define values (dbc-decode-frame db 568 data))
    ;; raw 0x2710 = 10000 * 0.25 = 2500 rpm
    (check-equal? (hash-ref values 'EngineSpeed) 2500.0)
    ;; raw 0x50 = 80 - 40 = 40 degC
    (check-equal? (hash-ref values 'EngineTemp) 40.0))

  (test-case "signed signals decode negative values"
    (define signed-db
      (parse-dbc "BO_ 100 SignedMsg: 8 ECM\n SG_ Value : 0|16@1- (1,0) [0|0] \"\"\n"))
    (define values (dbc-decode-frame signed-db 100 (bytes #xFF #xFF #x00 #x00 #x00 #x00 #x00 #x00)))
    (check-equal? (hash-ref values 'Value) -1))

  (test-case "unknown frames decode to #f"
    (check-false (dbc-decode-frame db 999 (bytes 0 0 0 0 0 0 0 0))))

  (test-case "signal encoding round trips through decode"
    (define encoded
      (dbc-encode-signals (first db)
                          (hasheq 'EngineSpeed 2500 'EngineTemp 40)))
    (define values (dbc-decode-frame db 568 encoded))
    (check-equal? (hash-ref values 'EngineSpeed) 2500.0)
    (check-equal? (hash-ref values 'EngineTemp) 40.0))

  (test-case "encoding rejects values outside the bit field"
    (check-exn exn:benchpilot:validation?
               (lambda ()
                 (dbc-encode-signals (first db)
                                     (hasheq 'EngineSpeed 999999)))))

  (test-case "capture ring is bounded and newest-first"
    (define session (make-capture-session "cap-1" "demo" "can.ecu" #f 4))
    (for ([i 6])
      (capture-session-record! session (can-frame #x123 #f (list i))))
    (define frames (capture-session-frames session))
    (check-equal? (length frames) 4)
    ;; newest first: last written (5) comes first
    (check-equal? (can-frame-data (cdr (first frames))) (list 5))
    (check-equal? (can-frame-data (cdr (last frames))) (list 2)))

  (test-case "capture emits JSON rows with hex data"
    (define session (make-capture-session "cap-2" "demo" "can.ecu" #f 8))
    (capture-session-record! session (can-frame #x568 #f (list #x10 #x27 80 0 0 0 0 0)))
    (define rows (capture-session-frames-json session))
    (check-equal? (length rows) 1)
    (check-equal? (hash-ref (first rows) 'id) "0x568")
    (check-equal? (hash-ref (first rows) 'data) "1027500000000000")))
