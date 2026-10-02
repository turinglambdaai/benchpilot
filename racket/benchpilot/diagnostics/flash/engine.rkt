#lang racket/base

;; Crc32 + UdsFlashEngine.cs port: session -> security access -> erase ->
;; per-segment download (RequestDownload/TransferData/Exit with retries) ->
;; CRC32 verify routine -> ECU reset, every step audited.

(require racket/contract
         racket/format
         racket/list
         racket/string)

(require benchpilot/core/contracts
         benchpilot/core/bench-runtime
         benchpilot/diagnostics/security-provider
         benchpilot/diagnostics/uds/protocol)

(provide (struct-out exn:fail:flash)
         crc32-compute
         make-flash-engine
         flash-execute
         make-key-derivers
         key-derivers-builtin)

;; ----------------------------------------------------------------------------
;; CRC32 (IEEE, reflected, 0xEDB88320)
;; ----------------------------------------------------------------------------

(define crc-table
  (for/vector ([i (in-range 256)])
    (let loop ([value i]
               [bit 0])
      (if (= bit 8)
          value
          (loop (if (odd? value)
                    (bitwise-xor (arithmetic-shift value -1) #xEDB88320)
                    (arithmetic-shift value -1))
                (add1 bit))))))

(define (crc32-compute segments)
  (define crc
    (for/fold ([crc #xFFFFFFFF]) ([seg (in-list segments)])
      (for/fold ([crc crc]) ([b (in-list (uds-flash-segment-data seg))])
        (bitwise-xor (arithmetic-shift crc -8)
                     (vector-ref crc-table (bitwise-and (bitwise-xor crc b) #xFF))))))
  (bitwise-xor crc #xFFFFFFFF))

;; ----------------------------------------------------------------------------
;; Key derivers (KeyDerivers.cs): named seed-to-key algorithms selectable
;; from driver settings; plan JSON never carries keys.
;; ----------------------------------------------------------------------------

;; equal?-based: deriver names arrive as strings from other modules/plans,
;; and eq? misses cross-module literals (CI-proven).
(define (key-derivers-builtin)
  (hash "xor0x5a"
          (lambda (seed) (map (lambda (b) (bitwise-xor b #x5A)) seed))
          "addindex"
          (lambda (seed)
            (for/list ([b (in-list seed)]
                       [i (in-naturals)])
              (bitwise-and (+ b i 1) #xFF)))))

(define (make-key-derivers [extra #f])
  (define base (key-derivers-builtin))
  (if (and extra (> (hash-count extra) 0))
      (for/hash ([(k v) (in-hash base)]) (values k v))
      base))

;; ----------------------------------------------------------------------------
;; Engine
;; ----------------------------------------------------------------------------

(struct flash-engine (client key-derivers))

(define (make-flash-engine client [key-derivers (make-key-derivers)])
  (flash-engine client key-derivers))

(define hex-up (lambda (n width) (string-upcase (~r n #:base 16 #:min-width width #:pad-string "0"))))

(define (engine-timing plan)
  (uds-timing (uds-flash-plan-p2-timeout-ms plan) (uds-flash-plan-p2-star-timeout-ms plan)))

(define (encode-routine-address-and-size address size)
  (define address-size (uds-address-length address))
  (append (for/list ([shift (in-range (* (sub1 address-size) 8) -1 -8)])
            (bitwise-and (arithmetic-shift address (- shift)) #xFF))
          (for/list ([shift (in-range 24 -1 -8)])
            (bitwise-and (arithmetic-shift size (- shift)) #xFF))))

(define (flash-execute engine plan #:cancel [cancel #f])
  (define started (now-millis))
  (define steps '())
  (define total-bytes
    (for/sum ([seg (in-list (uds-flash-plan-segments plan))]) (length (uds-flash-segment-data seg))))
  (define client (flash-engine-client engine))

  (define (add-step! step)
    (set! steps (cons step steps)))
  (define (elapsed-ms)
    (/ (- (now-millis) started) 1.0))

  (define (fail! message [nrc #f])
    (add-step! (flash-step-summary "abort" #f message (elapsed-ms) nrc))
    (raise (exn:fail:flash (format "Flash workflow failed: ~a" message)
                           (current-continuation-marks)
                           (uds-flash-result #f
                                             (length (uds-flash-plan-segments plan))
                                             total-bytes
                                             (elapsed-ms)
                                             (reverse steps)
                                             message))))

  (with-handlers ([exn:fail:flash? (lambda (e) (raise e))]
                  [exn:fail:uds? (lambda (e)
                                   (fail! (exn-message e)
                                          (and (exn:fail:uds-nrc e)
                                               (format "0x~a" (hex-up (exn:fail:uds-nrc e) 2)))))]
                  [exn:benchpilot:cancelled?
                   (lambda (e)
                     (add-step! (flash-step-summary "abort" #f (exn-message e) (elapsed-ms) #f))
                     (raise (exn:fail:flash (format "Flash workflow failed: ~a" (exn-message e))
                                            (current-continuation-marks)
                                            (uds-flash-result #f
                                                              (length (uds-flash-plan-segments plan))
                                                              total-bytes
                                                              (elapsed-ms)
                                                              (reverse steps)
                                                              (exn-message e)))))])

    ;; 1. Diagnostic session control.
    (let ([sw (now-millis)])
      (uds-require-positive client
                            (uds-diagnostic-session (uds-flash-plan-session plan))
                            #:timing (engine-timing plan)
                            #:cancel cancel)
      (add-step! (flash-step-summary "diagnostic-session"
                                     #t
                                     (format "session 0x~a accepted."
                                             (hex-up (uds-flash-plan-session plan) 2))
                                     (/ (- (now-millis) sw) 1.0)
                                     #f)))

    ;; 2. Security access (optional).
    (when (uds-flash-plan-security-level plan)
      (define deriver-name (uds-flash-plan-key-deriver plan))
      (define deriver
        (and deriver-name
             (or (hash-ref (flash-engine-key-derivers engine) deriver-name #f)
                 (resolve-key-deriver deriver-name))))
      (unless deriver
        (fail! (format "Plan references key deriver '~a' but no such deriver is registered."
                       deriver-name)))
      (define level (uds-flash-plan-security-level plan))
      (when (even? level)
        (fail! (format "Security access level 0x~a must be odd (request seed)." (hex-up level 2))))
      (let* ([sw (now-millis)]
             [seed-response (uds-require-positive client
                                                  (uds-security-request-seed level)
                                                  #:timing (engine-timing plan)
                                                  #:cancel cancel)]
             [seed (begin
                     (when (< (length seed-response) 2)
                       (fail! "SecurityAccess seed response malformed."))
                     (cdr seed-response))]
             [key (deriver seed)])
        (uds-require-positive client
                              (uds-security-send-key (add1 level) key)
                              #:timing (engine-timing plan)
                              #:cancel cancel)
        (add-step! (flash-step-summary
                    "security-access"
                    #t
                    (format "level 0x~a unlocked (seed ~a bytes)." (hex-up level 2) (length seed))
                    (/ (- (now-millis) sw) 1.0)
                    #f))))

    ;; 3. Erase per segment.
    (let ([sw (now-millis)])
      (for ([seg (in-list (uds-flash-plan-segments plan))])
        (define response
          (uds-require-positive client
                                (uds-routine-control routine-start
                                                     (uds-flash-plan-erase-routine-id plan)
                                                     (encode-routine-address-and-size
                                                      (uds-flash-segment-address seg)
                                                      (length (uds-flash-segment-data seg))))
                                #:timing (engine-timing plan)
                                #:cancel cancel))
        (define routine-id (bitwise-ior (arithmetic-shift (second response) 8) (third response)))
        (when (or (< (length response) 4)
                  (not (= (first response) routine-start))
                  (not (= routine-id (uds-flash-plan-erase-routine-id plan))))
          (fail! (format "Erase routine response mismatch (got ~a)." (bytes->hex response)))))
      (add-step! (flash-step-summary "erase"
                                     #t
                                     (format "~a segment(s) erased via routine 0x~a."
                                             (length (uds-flash-plan-segments plan))
                                             (hex-up (uds-flash-plan-erase-routine-id plan) 4))
                                     (/ (- (now-millis) sw) 1.0)
                                     #f)))

    ;; 4. Per-segment download.
    (for ([seg (in-list (uds-flash-plan-segments plan))])
      (let ([sw (now-millis)]
            [data (uds-flash-segment-data seg)]
            [retries 0])
        (define payload
          (uds-require-positive client
                                (uds-request-download (uds-flash-segment-address seg) (length data))
                                #:timing (engine-timing plan)
                                #:cancel cancel))
        (when (< (length payload) 2)
          (fail! "RequestDownload response malformed."))
        (define size-bytes (bitwise-and (first payload) #x0F))
        (define max-block-length
          (for/fold ([acc 0])
                    ([i (in-range 1 (add1 size-bytes))]
                     #:break (>= i (length payload)))
            (bitwise-ior (arithmetic-shift acc 8) (list-ref payload i))))
        (define max-block-payload
          (min (uds-flash-plan-max-block-payload plan) (max 2 (- max-block-length 2))))
        (let loop ([offset 0]
                   [block-sequence #x01])
          (when (< offset (length data))
            (define chunk-size (min (- (length data) offset) max-block-payload))
            (define retry-current
              (with-handlers ([exn:fail:uds? (lambda (e)
                                               (if (< retries (uds-flash-plan-block-retries plan))
                                                   (begin
                                                     (set! retries (add1 retries))
                                                     #t)
                                                   (raise e)))])
                (uds-require-positive client
                                      (uds-transfer-data block-sequence
                                                         (take (list-tail data offset) chunk-size))
                                      #:timing (engine-timing plan)
                                      #:cancel cancel)
                #f))
            (if retry-current
                (loop offset block-sequence)
                (let ([next (+ offset chunk-size)]
                      [next-seq (let ([s (add1 block-sequence)]) (if (zero? s) 1 s))])
                  (loop next next-seq)))))
        (uds-require-positive client
                              (uds-request-transfer-exit)
                              #:timing (engine-timing plan)
                              #:cancel cancel)
        (add-step! (flash-step-summary "download"
                                       #t
                                       (format "segment @0x~a: ~a bytes, ~aB blocks~a"
                                               (hex-up (uds-flash-segment-address seg) 8)
                                               (length data)
                                               max-block-payload
                                               (if (> retries 0)
                                                   (format ", ~a retried block(s)" retries)
                                                   ""))
                                       (/ (- (now-millis) sw) 1.0)
                                       #f))))

    ;; 5. Verify via CRC32 routine.
    (let ([sw (now-millis)])
      (define crc (crc32-compute (uds-flash-plan-segments plan)))
      (define response
        (uds-require-positive client
                              (uds-routine-control routine-start
                                                   (uds-flash-plan-verify-routine-id plan)
                                                   (list (bitwise-and (arithmetic-shift crc -24) #xFF)
                                                         (bitwise-and (arithmetic-shift crc -16) #xFF)
                                                         (bitwise-and (arithmetic-shift crc -8) #xFF)
                                                         (bitwise-and crc #xFF)))
                              #:timing (engine-timing plan)
                              #:cancel cancel))
      (define routine-id (bitwise-ior (arithmetic-shift (second response) 8) (third response)))
      (when (or (< (length response) 4)
                (not (= (first response) routine-start))
                (not (= routine-id (uds-flash-plan-verify-routine-id plan))))
        (fail! (format "Verify routine response mismatch (got ~a)." (bytes->hex response))))
      (add-step! (flash-step-summary "verify"
                                     #t
                                     (format "CRC32 0x~a over ~a bytes accepted by routine 0x~a."
                                             (hex-up crc 8)
                                             total-bytes
                                             (hex-up (uds-flash-plan-verify-routine-id plan) 4))
                                     (/ (- (now-millis) sw) 1.0)
                                     #f)))

    ;; 6. ECU reset.
    (let ([sw (now-millis)])
      (uds-require-positive client (uds-ecu-reset 1) #:timing (uds-timing 5000 5000) #:cancel cancel)
      (add-step!
       (flash-step-summary "ecu-reset" #t "hard reset accepted." (/ (- (now-millis) sw) 1.0) #f)))

    (uds-flash-result #t
                      (length (uds-flash-plan-segments plan))
                      total-bytes
                      (elapsed-ms)
                      (reverse steps)
                      #f)))

(struct exn:fail:flash exn:fail (execution) #:transparent)
