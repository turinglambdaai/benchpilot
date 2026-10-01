#lang racket/base

;; UdsProcessor.cs + SimulatedUdsEcu.cs + SimUdsChannel.cs + CanUdsChannel.cs
;; + IsotpUdsTransport.cs + DiagResourceFactories (sim part) port: the
;; server-side behavioral ECU, the real ISO-TP plumbing on both sides, and
;; the diagnostics channels exposed through the IDiagChannel contract.

(require racket/contract
         racket/format
         racket/hash
         racket/list
         racket/set
         racket/string)

(require benchpilot/core/contracts
         benchpilot/core/bench-runtime
         benchpilot/core/profile
         benchpilot/diagnostics/flash/engine
         benchpilot/diagnostics/isotp/codec
         benchpilot/diagnostics/isotp/endpoint
         benchpilot/diagnostics/transport/simulated-can-bus
         benchpilot/diagnostics/uds/protocol)

(provide (struct-out uds-ecu-options)
         default-uds-ecu-options
         (struct-out uds-server-response)
         (struct-out uds-processor)
         (struct-out simulated-uds-ecu)
         (struct-out sim-uds-channel)
         (struct-out sim-diagnostics-driver)
         can-uds-channel-request
         make-uds-processor
         uds-processor-process!
         uds-processor-erased?
         uds-processor-erase-count
         uds-processor-verify-count
         uds-processor-received-image
         make-simulated-uds-ecu
         make-can-uds-channel
         make-sim-uds-channel
         make-sim-diagnostics-factory
         sim-channel-request
         sim-channel-flash
         sim-channel-health
         open-sim-channel!
         builtin-routine-erase
         builtin-routine-verify)

(define builtin-routine-erase #xFF00)
(define builtin-routine-verify #xFF01)

;; ----------------------------------------------------------------------------
;; Options (UdsEcuOptions)
;; ----------------------------------------------------------------------------

(struct uds-ecu-options
        (response-delay-ms erase-delay-ms
                           verify-delay-ms
                           s3-timeout-ms
                           max-security-attempts
                           seed-base
                           key-deriver
                           data-identifiers
                           writable-identifiers)
  #:transparent)

(define (default-uds-ecu-options)
  (uds-ecu-options
   2
   10
   10
   5000
   3
   #x1234
   (lambda (seed) (map (lambda (b) (bitwise-xor b #x5A)) seed))
   (make-hash (list (cons #xF195 (bytes->list (string->bytes/utf-8 "BenchPilot sim-ecu v1.0.4")))
                    (cons #xF186 (list uds-session-default))
                    (cons #xFD00 (bytes->list (string->bytes/utf-8 "ready")))))
   (mutable-set #xFD00)))

;; ----------------------------------------------------------------------------
;; UdsProcessor: models the behavioral surface a real ECU presents to a flash
;; tool. Semantics follow ISO 14229; the implementation is original.
;; ----------------------------------------------------------------------------

(struct uds-processor
        (options mutex
                 session-box
                 activity-box
                 security-box
                 pending-seed-box
                 transfer-box ; hash: active address length transferred expected buffer
                 last-image-box
                 erased-box
                 erase-count-box
                 verify-count-box)
  #:transparent)

(struct uds-server-response (response delay-ms) #:transparent)

(define no-reply (uds-server-response '() -1))

(define (now-ms*)
  (inexact->exact (floor (current-inexact-milliseconds))))

(define (with-mutex* sema proc)
  (semaphore-wait/enable-break sema)
  (begin0 (proc)
    (semaphore-post sema)))

(define hex-up (lambda (n width) (string-upcase (~r n #:base 16 #:min-width width #:pad-string "0"))))

(define (make-uds-processor [options (default-uds-ecu-options)])
  (uds-processor options
                 (make-semaphore 1)
                 (box uds-session-default)
                 (box (now-ms*))
                 (box 0)
                 (box #f)
                 (make-hash)
                 (box '())
                 (box #f)
                 (box 0)
                 (box 0)))

(define (negative sid nrc)
  (uds-server-response (list #x7F sid nrc) 0))

(define (uds-processor-erased? p)
  (unbox (uds-processor-erased-box p)))
(define (uds-processor-erase-count p)
  (unbox (uds-processor-erase-count-box p)))
(define (uds-processor-verify-count p)
  (unbox (uds-processor-verify-count-box p)))
(define (uds-processor-received-image p)
  (unbox (uds-processor-last-image-box p)))

(define (reset-transfer! p)
  (define t (uds-processor-transfer-box p))
  (hash-set! t 'active #f)
  (hash-set! t 'transferred 0)
  (hash-set! t 'buffer '())
  (hash-set! t 'expected #x01))

(define (check-s3-timeout! p)
  (with-mutex* (uds-processor-mutex p)
               (lambda ()
                 (unless (= (unbox (uds-processor-session-box p)) uds-session-default)
                   (define elapsed (- (now-ms*) (unbox (uds-processor-activity-box p))))
                   (when (>= elapsed (uds-ecu-options-s3-timeout-ms (uds-processor-options p)))
                     (set-box! (uds-processor-session-box p) uds-session-default)
                     (set-box! (uds-processor-security-box p) 0)
                     (reset-transfer! p))))))

(define (uds-processor-process! p request)
  (check-s3-timeout! p)
  (with-mutex* (uds-processor-mutex p)
               (lambda () (set-box! (uds-processor-activity-box p) (now-ms*))))
  (define options (uds-processor-options p))
  (define delay (uds-ecu-options-response-delay-ms options))
  (cond
    [(null? request) (negative 0 #x13)]
    [(= (car request) #x7F) (negative (car request) #x12)]
    [else
     (case (car request)
       [(#x10) (handle-session! p request)]
       [(#x3E) (handle-tester-present! p request)]
       [(#x22) (handle-read-did! p request)]
       [(#x2E) (handle-write-did! p request)]
       [(#x27) (handle-security-access! p request)]
       [(#x31) (handle-routine! p request)]
       [(#x34) (handle-request-download! p request)]
       [(#x36) (handle-transfer-data! p request)]
       [(#x37) (handle-transfer-exit! p request)]
       [(#x11) (handle-ecu-reset! p request)]
       [else (negative (car request) #x11)])]))

(define (handle-session! p request)
  (define options (uds-processor-options p))
  (if (not (= (length request) 2))
      (negative (car request) #x13)
      (let ([requested (second request)])
        (if (not (memq requested
                       (list uds-session-default uds-session-extended uds-session-programming)))
            (negative (car request) #x12)
            (let ([previous (with-mutex* (uds-processor-mutex p)
                                         (lambda ()
                                           (define previous (unbox (uds-processor-session-box p)))
                                           (set-box! (uds-processor-session-box p) requested)
                                           (unless (= requested uds-session-programming)
                                             (set-box! (uds-processor-security-box p) 0)
                                             (set-box! (uds-processor-pending-seed-box p) #f))
                                           previous))])
              (when (and (= previous uds-session-programming)
                         (not (= requested uds-session-programming)))
                (with-mutex* (uds-processor-mutex p) (lambda () (reset-transfer! p))))
              (uds-server-response
               (list (bitwise-ior (car request) #x40) requested #x00 #x32 #x01 #xF4)
               (uds-ecu-options-response-delay-ms options)))))))

(define (handle-tester-present! p request)
  (if (or (not (= (length request) 2)) (not (zero? (bitwise-and (second request) #x7F))))
      (negative (car request) #x13)
      (if (not (zero? (bitwise-and (second request) #x80)))
          no-reply
          (uds-server-response (list (bitwise-ior (car request) #x40) #x00)
                               (uds-ecu-options-response-delay-ms (uds-processor-options p))))))

(define (handle-read-did! p request)
  (define options (uds-processor-options p))
  (if (not (= (length request) 3))
      (negative (car request) #x13)
      (let* ([did (bitwise-ior (arithmetic-shift (second request) 8) (third request))]
             [value (hash-ref (uds-ecu-options-data-identifiers options) did #f)])
        (if (not value)
            (negative (car request) #x31)
            (uds-server-response
             (append (list (bitwise-ior (car request) #x40) (second request) (third request)) value)
             (uds-ecu-options-response-delay-ms options))))))

(define (handle-write-did! p request)
  (define options (uds-processor-options p))
  (if (< (length request) 4)
      (negative (car request) #x13)
      (let* ([did (bitwise-ior (arithmetic-shift (second request) 8) (third request))])
        (cond
          [(not (set-member? (uds-ecu-options-writable-identifiers options) did))
           (negative (car request) #x31)]
          [(= (unbox (uds-processor-session-box p)) uds-session-default)
           (negative (car request) #x7F)]
          [else
           (hash-set! (uds-ecu-options-data-identifiers options) did (drop request 3))
           (uds-server-response
            (list (bitwise-ior (car request) #x40) (second request) (third request))
            (uds-ecu-options-response-delay-ms options))]))))

(define (handle-security-access! p request)
  (define options (uds-processor-options p))
  (if (< (length request) 2)
      (negative (car request) #x13)
      (let ([level (second request)])
        (cond
          [(zero? level) (negative (car request) #x12)]
          [(= 1 (bitwise-and level #x01))
           ;; Request seed.
           (if (not (= (length request) 2))
               (negative (car request) #x13)
               (let ([seed (with-mutex*
                            (uds-processor-mutex p)
                            (lambda ()
                              (cond
                                [(>= (unbox (uds-processor-security-box p)) level) 'already-unlocked]
                                [else
                                 (define seed
                                   (for/list ([_ (in-range 4)])
                                     (random 256)))
                                 (set-box! (uds-processor-pending-seed-box p) seed)
                                 seed])))])
                 (if (eq? seed 'already-unlocked)
                     (uds-server-response (list (bitwise-ior (car request) #x40) level 0)
                                          (uds-ecu-options-response-delay-ms options))
                     (uds-server-response (append (list (bitwise-ior (car request) #x40) level) seed)
                                          (uds-ecu-options-response-delay-ms options)))))]
          [else
           ;; Send key.
           (with-mutex*
            (uds-processor-mutex p)
            (lambda ()
              (cond
                [(or (not (unbox (uds-processor-pending-seed-box p)))
                     (null? (unbox (uds-processor-pending-seed-box p))))
                 (negative (car request) #x24)]
                [(not (= (length request) (+ 2 (length (unbox (uds-processor-pending-seed-box p))))))
                 (negative (car request) #x13)]
                [else
                 (define expected
                   ((uds-ecu-options-key-deriver options) (unbox (uds-processor-pending-seed-box p))))
                 (define provided (drop request 2))
                 (if (not (equal? expected provided))
                     (let ([attempts (add1 (get-security-attempts p))])
                       (set-security-attempts! p attempts)
                       (set-box! (uds-processor-pending-seed-box p) #f)
                       (negative
                        (car request)
                        (if (>= attempts (uds-ecu-options-max-security-attempts options)) #x36 #x35)))
                     (begin
                       (set-box! (uds-processor-security-box p) (sub1 level))
                       (set-box! (uds-processor-pending-seed-box p) #f)
                       (uds-server-response (list (bitwise-ior (car request) #x40) level)
                                            (uds-ecu-options-response-delay-ms options))))])))]))))

;; Security attempt counting (the C# keeps a dedicated field; here it lives
;; beside the transfer state under the same mutex).
(define (set-security-attempts! p attempts)
  (hash-set! (uds-processor-transfer-box p) 'security-attempts attempts))
(define (get-security-attempts p)
  (hash-ref (uds-processor-transfer-box p) 'security-attempts 0))

(define (handle-routine! p request)
  (define options (uds-processor-options p))
  (if (< (length request) 4)
      (negative (car request) #x13)
      (let* ([kind (second request)]
             [routine-id (bitwise-ior (arithmetic-shift (third request) 8) (fourth request))]
             [record (drop request 4)])
        (cond
          [(not (memq kind (list routine-start routine-stop routine-request-results)))
           (negative (car request) #x12)]
          [(and (not (= (unbox (uds-processor-session-box p)) uds-session-programming))
                (or (= routine-id builtin-routine-erase) (= routine-id builtin-routine-verify)))
           (negative (car request) #x7F)]
          [(and (= routine-id builtin-routine-erase) (= kind routine-start))
           (cond
             [(zero? (unbox (uds-processor-security-box p))) (negative (car request) #x33)]
             [(not (= (length record) 8)) (negative (car request) #x13)]
             [else
              (with-mutex* (uds-processor-mutex p)
                           (lambda ()
                             (set-box! (uds-processor-erased-box p) #t)
                             (set-box! (uds-processor-erase-count-box p)
                                       (add1 (unbox (uds-processor-erase-count-box p))))
                             (hash-set! (uds-processor-transfer-box p) 'buffer '())))
              (uds-server-response
               (append
                (list (bitwise-ior (car request) #x40) kind (third request) (fourth request) #x00))
               (uds-ecu-options-erase-delay-ms options))])]
          [(and (= routine-id builtin-routine-verify) (= kind routine-start))
           (if (not (= (length record) 4))
               (negative (car request) #x13)
               (let* ([expected (for/fold ([acc 0]) ([b (in-list record)])
                                  (bitwise-ior (arithmetic-shift acc 8) b))]
                      [image (with-mutex*
                              (uds-processor-mutex p)
                              (lambda ()
                                (if (not (unbox (uds-processor-erased-box p)))
                                    'not-erased
                                    (hash-ref (uds-processor-transfer-box p) 'buffer '()))))])
                 (cond
                   [(eq? image 'not-erased) (negative (car request) #x24)]
                   [(not (= (crc32-compute (list (uds-flash-segment 0 image #f))) expected))
                    (negative (car request) #x72)]
                   [else
                    (with-mutex* (uds-processor-mutex p)
                                 (lambda ()
                                   (set-box! (uds-processor-verify-count-box p)
                                             (add1 (unbox (uds-processor-verify-count-box p))))))
                    (uds-server-response (list (bitwise-ior (car request) #x40)
                                               kind
                                               (third request)
                                               (fourth request)
                                               #x00)
                                         (uds-ecu-options-verify-delay-ms options))])))]
          [(and (or (= routine-id builtin-routine-erase) (= routine-id builtin-routine-verify))
                (= kind routine-request-results))
           (uds-server-response
            (list (bitwise-ior (car request) #x40) kind (third request) (fourth request) #x00)
            (uds-ecu-options-response-delay-ms options))]
          [else (negative (car request) #x31)]))))

(define (handle-request-download! p request)
  (define options (uds-processor-options p))
  (cond
    [(not (= (unbox (uds-processor-session-box p)) uds-session-programming))
     (negative (car request) #x7F)]
    [(zero? (unbox (uds-processor-security-box p))) (negative (car request) #x33)]
    [(hash-ref (uds-processor-transfer-box p) 'active #f) (negative (car request) #x24)]
    [(< (length request) 4) (negative (car request) #x13)]
    [else
     (define address-size (arithmetic-shift (third request) -4))
     (define length-size (bitwise-and (third request) #x0F))
     (cond
       [(or (not (<= 1 address-size 8)) (not (<= 1 length-size 8))) (negative (car request) #x13)]
       [(not (= (length request) (+ 3 address-size length-size))) (negative (car request) #x13)]
       [else
        (define address
          (for/fold ([acc 0]) ([i (in-range address-size)])
            (bitwise-ior (arithmetic-shift acc 8) (list-ref request (+ 3 i)))))
        (define length*
          (for/fold ([acc 0]) ([i (in-range length-size)])
            (bitwise-ior (arithmetic-shift acc 8) (list-ref request (+ 3 address-size i)))))
        (define outcome
          (with-mutex* (uds-processor-mutex p)
                       (lambda ()
                         (if (not (unbox (uds-processor-erased-box p)))
                             'not-erased
                             (let ([t (uds-processor-transfer-box p)])
                               (hash-set! t 'active #t)
                               (hash-set! t 'address address)
                               (hash-set! t 'length length*)
                               (hash-set! t 'transferred 0)
                               (hash-set! t 'expected #x01)
                               (hash-set! t 'buffer '())
                               'ok)))))
        (if (eq? outcome 'not-erased)
            (negative (car request) #x70)
            ;; maxNumberOfBlockLength: format byte + 4-byte value 1026
            ;; (2 header bytes + 1024 payload).
            (uds-server-response (list (bitwise-ior (car request) #x40) #x04 #x00 #x00 #x04 #x02)
                                 (uds-ecu-options-response-delay-ms options)))])]))

(define (handle-transfer-data! p request)
  (define options (uds-processor-options p))
  (cond
    [(not (hash-ref (uds-processor-transfer-box p) 'active #f)) (negative (car request) #x24)]
    [(< (length request) 2) (negative (car request) #x13)]
    [else
     (with-mutex*
      (uds-processor-mutex p)
      (lambda ()
        (define t (uds-processor-transfer-box p))
        (cond
          [(not (= (second request) (hash-ref t 'expected))) (negative (car request) #x73)]
          [(> (+ (hash-ref t 'transferred) (length (drop request 2))) (hash-ref t 'length))
           (negative (car request) #x13)]
          [else
           (let ([next (bitwise-and (add1 (hash-ref t 'expected)) #xFF)]
                 [chunk (drop request 2)])
             (hash-set! t 'buffer (append (hash-ref t 'buffer) chunk))
             (hash-set! t 'transferred (+ (hash-ref t 'transferred) (length chunk)))
             (hash-set! t 'expected (if (zero? next) 1 next))
             (uds-server-response (list (bitwise-ior (car request) #x40) (second request))
                                  (uds-ecu-options-response-delay-ms options)))])))]))

(define (handle-transfer-exit! p request)
  (define options (uds-processor-options p))
  (cond
    [(not (hash-ref (uds-processor-transfer-box p) 'active #f)) (negative (car request) #x24)]
    [else
     (with-mutex* (uds-processor-mutex p)
                  (lambda ()
                    (define t (uds-processor-transfer-box p))
                    (if (not (= (hash-ref t 'transferred) (hash-ref t 'length)))
                        (begin
                          (reset-transfer! p)
                          (negative (car request) #x24))
                        (begin
                          (set-box! (uds-processor-last-image-box p) (hash-ref t 'buffer))
                          (hash-set! t 'active #f)
                          (uds-server-response (list (bitwise-ior (car request) #x40))
                                               (uds-ecu-options-response-delay-ms options))))))]))

(define (handle-ecu-reset! p request)
  (define options (uds-processor-options p))
  (if (not (= (length request) 2))
      (negative (car request) #x13)
      (if (not (memq (second request) (list #x01 #x03)))
          (negative (car request) #x12)
          (begin
            (with-mutex* (uds-processor-mutex p)
                         (lambda ()
                           (set-box! (uds-processor-session-box p) uds-session-default)
                           (set-box! (uds-processor-security-box p) 0)
                           (reset-transfer! p)
                           (set-box! (uds-processor-erased-box p) #f)))
            (uds-server-response (list (bitwise-ior (car request) #x40) (second request))
                                 (uds-ecu-options-response-delay-ms options))))))

;; ----------------------------------------------------------------------------
;; SimulatedUdsEcu: real ISO-TP endpoints on both sides of the UdsProcessor,
;; with a background dispatch loop.
;; ----------------------------------------------------------------------------

(struct simulated-uds-ecu (processor endpoint bus-port-bus dispatch-thread))

(define (make-simulated-uds-ecu bus
                                #:tester-to-ecu-id [tester-to-ecu-id #x7E0]
                                #:ecu-to-tester-id [ecu-to-tester-id #x7E8]
                                #:options [options #f])
  (define processor (make-uds-processor (or options (default-uds-ecu-options))))
  (define ecu-port-bus (make-sim-can-port-bus (simulated-can-bus-attach bus) "sim-ecu"))
  (sim-can-port-bus-open! ecu-port-bus)
  (define endpoint (make-isotp-endpoint ecu-port-bus ecu-to-tester-id tester-to-ecu-id))
  (define dispatch
    (thread (lambda ()
              (let loop ()
                (with-handlers ([exn:benchpilot:cancelled? (lambda (_) (void))])
                  (define request (isotp-endpoint-receive! endpoint))
                  (define response (uds-processor-process! processor request))
                  (when (and (>= (uds-server-response-delay-ms response) 0)
                             (not (null? (uds-server-response-response response))))
                    (when (> (uds-server-response-delay-ms response) 0)
                      (sleep (/ (uds-server-response-delay-ms response) 1000.0)))
                    (isotp-endpoint-send! endpoint (uds-server-response-response response)))
                  (loop))))))
  (simulated-uds-ecu processor endpoint ecu-port-bus dispatch))

;; ----------------------------------------------------------------------------
;; CanUdsChannel: UDS over ISO-TP on any ICanBus; the channel keeps session
;; and security state resident like a real tool session.
;; ----------------------------------------------------------------------------

(struct can-uds-channel
        (bus-bus tx-id
                 rx-id
                 security-level
                 key-deriver-name
                 max-block-payload
                 ecu-options
                 mutex
                 endpoint-box
                 client-box
                 engine-box))

(define (make-can-uds-channel bus
                              tx-id
                              rx-id
                              #:security-level [security-level #f]
                              #:key-deriver-name [key-deriver-name "xor0x5a"]
                              #:max-block-payload [max-block-payload 1024]
                              #:ecu-options [ecu-options #f])
  (can-uds-channel bus
                   tx-id
                   rx-id
                   security-level
                   key-deriver-name
                   max-block-payload
                   (or ecu-options (default-uds-ecu-options))
                   (make-semaphore 1)
                   (box #f)
                   (box #f)
                   (box #f)))

(define (channel-transport c)
  "iso-tp/can (simulated)")

(define (open-can-uds-channel! c)
  (with-mutex*
   (can-uds-channel-mutex c)
   (lambda ()
     (unless (unbox (can-uds-channel-client-box c))
       (sim-can-port-bus-open! (can-uds-channel-bus-bus c))
       (define endpoint
         (make-isotp-endpoint (can-uds-channel-bus-bus c)
                              (can-uds-channel-tx-id c)
                              (can-uds-channel-rx-id c)))
       (define client
         ;; Send request thunk.
         (make-uds-client (lambda (request cancel)
                            (isotp-endpoint-send! endpoint request #:cancel cancel))
                          ;; Receive response thunk: polls the endpoint.
                          (lambda (cancel poll) (isotp-endpoint-receive! endpoint #:cancel cancel))))
       (set-box! (can-uds-channel-endpoint-box c) endpoint)
       (set-box! (can-uds-channel-client-box c) client)
       (set-box! (can-uds-channel-engine-box c) (make-flash-engine client (make-key-derivers)))))))

(define (can-uds-channel-request c request p2-ms p2-star-ms #:cancel [cancel #f])
  (define hex (bytes->hex request))
  (open-can-uds-channel! c)
  (with-handlers ([exn:fail:uds? (lambda (e)
                                   (uds-request-result #f
                                                       #f
                                                       hex
                                                       #f
                                                       (and (exn:fail:uds-nrc e)
                                                            (nrc-name (exn:fail:uds-nrc e)))
                                                       (exn-message e)))])
    (define response
      (uds-send (unbox (can-uds-channel-client-box c))
                request
                #:timing (uds-timing p2-ms p2-star-ms)
                #:cancel cancel))
    (if (uds-response-positive response)
        (uds-request-result #t #t hex (bytes->hex (uds-response-payload response)) #f #f)
        (uds-request-result #t #f hex #f (nrc-name (uds-response-nrc response)) #f))))

(define (can-uds-channel-flash c spec)
  (open-can-uds-channel! c)
  (define plan
    (uds-flash-plan (for/list ([seg (in-list (uds-flash-plan-segments spec))])
                      seg)
                    (uds-flash-plan-max-block-payload spec)
                    (uds-flash-plan-session spec)
                    (uds-flash-plan-security-level spec)
                    (and (uds-flash-plan-security-level spec) (uds-flash-plan-key-deriver spec))
                    (uds-flash-plan-erase-routine-id spec)
                    (uds-flash-plan-verify-routine-id spec)
                    (uds-flash-plan-block-retries spec)
                    (uds-flash-plan-p2-timeout-ms spec)
                    (uds-flash-plan-p2-star-timeout-ms spec)))
  (with-handlers ([exn:fail:flash? (lambda (e) (exn:fail:flash-execution e))])
    (flash-execute (unbox (can-uds-channel-engine-box c)) plan)))

(define (can-uds-channel-health c)
  (resource-health-result #t
                          "CAN UDS channel is configured."
                          (hasheq "kind"
                                  "can-uds"
                                  "transport"
                                  (channel-transport c)
                                  "txId"
                                  (format "0x~a" (hex-up (can-uds-channel-tx-id c) 1))
                                  "rxId"
                                  (format "0x~a" (hex-up (can-uds-channel-rx-id c) 1)))
                          #f))

;; ----------------------------------------------------------------------------
;; SimUdsChannel: the simulator's diagnostics channel — a virtual ECU behind
;; a real ISO-TP stack on a virtual CAN segment.
;; ----------------------------------------------------------------------------

(struct sim-uds-channel
        (tester-to-ecu-id ecu-to-tester-id
                          security-level
                          key-deriver-name
                          max-block-payload
                          ecu-options
                          mutex
                          bus
                          ecu-box
                          channel-box))

(define (make-sim-uds-channel #:tester-to-ecu-id [tester-to-ecu-id #x7E0]
                              #:ecu-to-tester-id [ecu-to-tester-id #x7E8]
                              #:security-level [security-level #x01]
                              #:key-deriver-name [key-deriver-name "xor0x5a"]
                              #:max-block-payload [max-block-payload 1024]
                              #:ecu-options [ecu-options #f])
  (sim-uds-channel tester-to-ecu-id
                   ecu-to-tester-id
                   security-level
                   key-deriver-name
                   max-block-payload
                   (or ecu-options (default-uds-ecu-options))
                   (make-semaphore 1)
                   (make-simulated-can-bus)
                   (box #f)
                   (box #f)))

(define (sim-channel-transport c)
  "iso-tp/can (simulated)")

(define (open-sim-channel! c)
  (with-mutex*
   (sim-uds-channel-mutex c)
   (lambda ()
     (unless (unbox (sim-uds-channel-channel-box c))
       (set-box! (sim-uds-channel-ecu-box c)
                 (make-simulated-uds-ecu (sim-uds-channel-bus c)
                                         #:tester-to-ecu-id (sim-uds-channel-tester-to-ecu-id c)
                                         #:ecu-to-tester-id (sim-uds-channel-ecu-to-tester-id c)
                                         #:options (sim-uds-channel-ecu-options c)))
       (set-box! (sim-uds-channel-channel-box c)
                 (make-can-uds-channel
                  (make-sim-can-port-bus (simulated-can-bus-attach (sim-uds-channel-bus c))
                                         "sim-tester")
                  (sim-uds-channel-tester-to-ecu-id c)
                  (sim-uds-channel-ecu-to-tester-id c)
                  #:security-level (sim-uds-channel-security-level c)
                  #:key-deriver-name (sim-uds-channel-key-deriver-name c)
                  #:max-block-payload (sim-uds-channel-max-block-payload c)
                  #:ecu-options (sim-uds-channel-ecu-options c)))))))

(define (sim-channel-request c request p2-ms p2-star-ms)
  (open-sim-channel! c)
  (can-uds-channel-request (unbox (sim-uds-channel-channel-box c)) request p2-ms p2-star-ms))

(define (sim-channel-flash c plan)
  (open-sim-channel! c)
  (can-uds-channel-flash (unbox (sim-uds-channel-channel-box c)) plan))

(define (sim-channel-health c)
  (resource-health-result #t
                          "Simulated diagnostics resource is ready."
                          (hasheq "kind"
                                  "sim-diagnostics"
                                  "transport"
                                  (sim-channel-transport c)
                                  "requestId"
                                  (format "0x~a" (hex-up (sim-uds-channel-tester-to-ecu-id c) 1))
                                  "responseId"
                                  (format "0x~a" (hex-up (sim-uds-channel-ecu-to-tester-id c) 1)))
                          #f))

;; ----------------------------------------------------------------------------
;; IDiagChannel adapter for the sim channel: struct implementing the generic.
;; ----------------------------------------------------------------------------

(struct sim-diagnostics-driver (channel)
  #:methods gen:diag-channel
  [(define (diag-transport d)
     (sim-channel-transport (sim-diagnostics-driver-channel d)))
   (define (diag-open d cancel)
     (open-sim-channel! (sim-diagnostics-driver-channel d))
     (diag-open-result #t (sim-channel-transport (sim-diagnostics-driver-channel d)) #f))
   (define (diag-request d request-bytes p2-ms p2-star-ms cancel)
     (sim-channel-request (sim-diagnostics-driver-channel d) request-bytes p2-ms p2-star-ms))
   (define (diag-flash d plan cancel)
     (sim-channel-flash (sim-diagnostics-driver-channel d) plan))]
  #:methods gen:resource-health-check
  [(define (check-health d cancel)
     (sim-channel-health (sim-diagnostics-driver-channel d)))])

;; DiagResourceFactories (sim part): driver "sim-diagnostics".
(define (make-sim-diagnostics-factory #:tester-to-ecu-id [tester-to-ecu-id #x7E0]
                                      #:ecu-to-tester-id [ecu-to-tester-id #x7E8]
                                      #:ecu-options [ecu-options #f])
  (driver-factory
   "sim-diagnostics"
   (lambda (resource-id config)
     (define settings (bench-resource-settings config))
     (sim-diagnostics-driver
      (make-sim-uds-channel
       #:tester-to-ecu-id (or (parse-hex-setting (hash-ref settings 'requestId #f)) tester-to-ecu-id)
       #:ecu-to-tester-id (or (parse-hex-setting (hash-ref settings 'responseId #f)) ecu-to-tester-id)
       #:ecu-options ecu-options)))))

(define (parse-hex-setting v)
  (and (string? v)
       (let ([m (regexp-match #rx"^0x([0-9a-fA-F]+)$" v)]) (and m (string->number (second m) 16)))))
