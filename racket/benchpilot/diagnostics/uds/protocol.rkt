#lang racket/base

;; UdsProtocol.cs port: ISO 14229 services, NRCs, message builders and the
;; UdsClient transaction state machine (P2/P2* timing, NRC 0x78 pending).

(require racket/format
         racket/list
         racket/string)

(require benchpilot/core/contracts)

(provide (struct-out uds-timing)
         (struct-out uds-response)
         (struct-out exn:fail:uds)
         uds-service-name
         nrc-name
         uds-session-default
         uds-session-extended
         uds-session-programming
         routine-start
         routine-stop
         routine-request-results
         uds-diagnostic-session
         uds-tester-present
         uds-read-did
         uds-write-did
         uds-security-request-seed
         uds-security-send-key
         uds-routine-control
         uds-request-download
         uds-transfer-data
         uds-request-transfer-exit
         uds-ecu-reset
         uds-read-dtcs
         uds-clear-dtcs
         parse-dtc-response
         uds-address-length
         make-uds-client
         uds-send
         uds-require-positive)

;; ----------------------------------------------------------------------------
;; Constants
;; ----------------------------------------------------------------------------

(define sid-diagnostic-session-control #x10)
(define sid-ecu-reset #x11)
(define sid-read-data-by-identifier #x22)
(define sid-read-memory-by-address #x23)
(define sid-write-data-by-identifier #x2E)
(define sid-security-access #x27)
(define sid-routine-control #x31)
(define sid-request-download #x34)
(define sid-request-upload #x35)
(define sid-transfer-data #x36)
(define sid-request-transfer-exit #x37)
(define sid-tester-present #x3E)

(define (hex2 n)
  (string-upcase (~r n #:base 16 #:min-width 2 #:pad-string "0")))

(define (uds-service-name sid)
  (case sid
    [(#x10) "DiagnosticSessionControl"]
    [(#x11) "EcuReset"]
    [(#x22) "ReadDataByIdentifier"]
    [(#x23) "ReadMemoryByAddress"]
    [(#x2E) "WriteDataByIdentifier"]
    [(#x27) "SecurityAccess"]
    [(#x31) "RoutineControl"]
    [(#x34) "RequestDownload"]
    [(#x35) "RequestUpload"]
    [(#x36) "TransferData"]
    [(#x37) "RequestTransferExit"]
    [(#x3E) "TesterPresent"]
    [else (format "0x~a" (hex2 sid))]))

(define uds-session-default #x01)
(define uds-session-programming #x02)
(define uds-session-extended #x03)
(define routine-start #x01)
(define routine-stop #x02)
(define routine-request-results #x03)

(define nrc-names
  (hash #x10
        "generalReject"
        #x11
        "serviceNotSupported"
        #x12
        "subFunctionNotSupported"
        #x13
        "incorrectMessageLength"
        #x14
        "responseTooLong"
        #x21
        "busyRepeatRequest"
        #x22
        "conditionsNotCorrect"
        #x24
        "requestSequenceError"
        #x25
        "noResponseFromSubnetComponent"
        #x31
        "requestOutOfRange"
        #x33
        "securityAccessDenied"
        #x35
        "invalidKey"
        #x36
        "exceedNumberOfAttempts"
        #x37
        "requiredTimeDelayNotExpired"
        #x70
        "uploadDownloadNotAccepted"
        #x71
        "transferDataSuspended"
        #x72
        "generalProgrammingFailure"
        #x73
        "wrongBlockSequenceCounter"
        #x78
        "responsePending"
        #x7E
        "subFunctionNotSupportedInActiveSession"
        #x7F
        "serviceNotSupportedInActiveSession"))

(define (nrc-name nrc)
  (hash-ref nrc-names nrc (lambda () (format "0x~a" (hex2 nrc)))))

(define nrc-response-pending #x78)

;; ----------------------------------------------------------------------------
;; Types
;; ----------------------------------------------------------------------------

(struct uds-timing (p2-timeout-ms p2-star-timeout-ms) #:transparent)
(struct uds-response (positive request-sid payload nrc) #:transparent)
(struct exn:fail:uds exn:fail (nrc) #:transparent)

(define (uds-protocol-error message [nrc #f])
  (raise (exn:fail:uds message (current-continuation-marks) nrc)))

;; ----------------------------------------------------------------------------
;; Message builders (UdsMessages)
;; ----------------------------------------------------------------------------

(define (uds-diagnostic-session session)
  (list sid-diagnostic-session-control session))

(define (uds-tester-present [response-required #t])
  (list sid-tester-present (if response-required #x00 #x80)))

(define sid-read-dtc-information #x19)
(define sid-clear-diagnostic-information #x14)

(define (uds-read-dtcs [status-mask #xFF])
  (list sid-read-dtc-information #x02 status-mask))

(define (uds-clear-dtcs [group #xFFFFFF])
  (list sid-clear-diagnostic-information
        (bitwise-and (arithmetic-shift group -16) #xFF)
        (bitwise-and (arithmetic-shift group -8) #xFF)
        (bitwise-and group #xFF)))

;; 59 02 <availability> (<dtc-hi> <dtc-mid> <dtc-lo> <status>)*
(define (parse-dtc-response payload)
  ;; payload = positive response bytes after the SID: [02, avail, records...]
  (if (or (< (length payload) 2) (not (= (first payload) #x02)))
      'unsupported
      (let ([available (second payload)]
            [rest (list-tail payload (min 2 (length payload)))])
        (hasheq 'availableMask available
                'dtcs
                (let build ([rest rest])
                  (if (< (length rest) 4)
                      '()
                      (cons (hasheq 'dtc
                                    (format "0x~a"
                                            (string-upcase
                                             (~r (+ (* (first rest) 65536)
                                                    (* (second rest) 256)
                                                    (third rest))
                                                 #:base 16
                                                 #:min-width 6
                                                 #:pad-string "0")))
                                    'status (format "0x~a"
                                                    (~r (fourth rest)
                                                        #:base 16
                                                        #:min-width 2
                                                        #:pad-string "0")))
                            (build (list-tail rest 4)))))))))

(define (uds-read-did did)
  (list sid-read-data-by-identifier
        (bitwise-and (arithmetic-shift did -8) #xFF)
        (bitwise-and did #xFF)))

(define (uds-write-did did value)
  (append (list sid-write-data-by-identifier
                (bitwise-and (arithmetic-shift did -8) #xFF)
                (bitwise-and did #xFF))
          value))

(define (uds-security-request-seed level)
  (list sid-security-access level))

(define (uds-security-send-key level key)
  (append (list sid-security-access level) key))

(define (uds-routine-control kind routine-id record)
  (append (list sid-routine-control
                kind
                (bitwise-and (arithmetic-shift routine-id -8) #xFF)
                (bitwise-and routine-id #xFF))
          record))

(define (uds-address-length address)
  (cond
    [(> address #xFFFFFFFF) 8]
    [(> address #xFFFFFF) 4]
    [(> address #xFFFF) 3]
    [(> address #xFF) 2]
    [else 1]))

(define (uds-request-download address
                              length*
                              #:compression [compression #x00]
                              #:encryption [encryption #x00])
  (define address-size (uds-address-length address))
  (append (list sid-request-download
                (bitwise-ior (arithmetic-shift compression 4) encryption)
                (bitwise-ior (arithmetic-shift address-size 4) #x04))
          (for/list ([shift (in-range (* (sub1 address-size) 8) -1 -8)])
            (bitwise-and (arithmetic-shift address (- shift)) #xFF))
          (for/list ([shift (in-range 24 -1 -8)])
            (bitwise-and (arithmetic-shift length* (- shift)) #xFF))))

(define (uds-transfer-data block-sequence-counter data)
  (append (list sid-transfer-data block-sequence-counter) data))

(define (uds-request-transfer-exit)
  (list sid-request-transfer-exit))

(define (uds-ecu-reset [reset-type #x01])
  (list sid-ecu-reset reset-type))

;; ----------------------------------------------------------------------------
;; UdsClient: runs ISO 14229 transactions over a transport pair of thunks —
;; send posts one request PDU; receive returns the next response PDU (a byte
;; list), polling the cancel event so cancellation stays cooperative.
;; ----------------------------------------------------------------------------

(define (make-uds-client send-request receive-response)
  (cons send-request receive-response))

(define (uds-send client
                  request
                  #:timing [timing #f]
                  #:cancel [cancel #f]
                  #:receive-poll-seconds [poll 0.02])
  (when (null? request)
    (raise-argument-error 'uds-send "non-empty UDS request" request))
  (define t (or timing (uds-timing 1000 5000)))
  (define sid (car request))
  ((car client) request cancel)

  (define started (now-millis))
  (define pending-deadline (+ started (uds-timing-p2-timeout-ms t) (uds-timing-p2-star-timeout-ms t)))

  (let loop ()
    (define response ((cdr client) cancel poll))
    (define positive-sid (bitwise-ior sid #x40))
    (when (and (< (length response) 3)
               (not (and (> (length response) 0) (= (car response) positive-sid))))
      (uds-protocol-error "UDS response too short to be valid."))
    (cond
      [(= (car response) positive-sid) (uds-response #t sid (cdr response) #f)]
      [(or (not (= (car response) #x7F)) (< (length response) 3))
       (uds-protocol-error (format "UDS response does not match request SID 0x~a (got 0x~a)."
                                   (hex2 sid)
                                   (hex2 (car response))))]
      [(not (= (second response) sid))
       (uds-protocol-error (format "UDS negative response references SID 0x~a, expected 0x~a."
                                   (hex2 (second response))
                                   (hex2 sid)))]
      [else
       (define nrc (third response))
       (if (= nrc nrc-response-pending)
           (begin
             (when (> (now-millis) pending-deadline)
               (uds-protocol-error (format "Server kept responding NRC 0x78 beyond P2* (~a ms)."
                                           (uds-timing-p2-star-timeout-ms t))
                                   nrc))
             (loop))
           (uds-response #f sid '() nrc))])))

;; Positive responses only; negative responses throw with their NRC.
(define (uds-require-positive client request #:timing [timing #f] #:cancel [cancel #f])
  (define response (uds-send client request #:timing timing #:cancel cancel))
  (if (uds-response-positive response)
      (uds-response-payload response)
      (uds-protocol-error (format "~a rejected: ~a (0x~a)."
                                  (uds-service-name (uds-response-request-sid response))
                                  (nrc-name (uds-response-nrc response))
                                  (hex2 (uds-response-nrc response)))
                          (uds-response-nrc response))))
