#lang racket/base

;; DoipFrame.cs + DoipClient.cs + SimulatedDoipServer.cs +
;; DoipUdsChannel.cs port: ISO 13400-2 frames, the TCP diagnostic client
;; (routing activation, alive-check answering), UDP vehicle discovery and
;; the simulated DoIP entity serving the shared UdsProcessor.

(require racket/contract
         racket/format
         racket/list
         racket/string
         racket/tcp
         racket/udp)

(require benchpilot/core/contracts
         benchpilot/core/bench-runtime
         benchpilot/core/runtime-state
         benchpilot/core/profile
         benchpilot/diagnostics/channels/sim-uds-channel
         benchpilot/diagnostics/flash/engine
         benchpilot/diagnostics/uds/protocol)

(provide
 (struct-out exn:fail:doip)
 (struct-out doip-frame)
 (struct-out doip-vehicle-identity)
 doip-port
 doip-frame->bytes
 doip-try-decode
 make-doip-frame-diagnostic-message
 make-doip-frame-routing-activation-request
 make-doip-frame-vehicle-identification-request
 doip-diagnostic-target
 doip-diagnostic-user-data
 (struct-out doip-client)
 make-doip-client
 doip-client-connect!
 doip-client-send-request!
 doip-client-receive-response!
 doip-client-discover
 (struct-out simulated-doip-server)
 start-simulated-doip-server
 simulated-doip-server-processor
 simulated-doip-server-listen-port
 simulated-doip-server-dispose!
 doip-uds-channel-request
 doip-uds-channel-flash
 (struct-out doip-uds-channel)
 make-doip-uds-channel
 open-doip-channel!
 doip-uds-driver
 make-doip-uds-resource-factory)

(struct exn:fail:doip exn:fail () #:transparent)
(define (doip-error message) (raise (exn:fail:doip message (current-continuation-marks))))

;; ----------------------------------------------------------------------------
;; Frames (DoipFrame.cs). ISO 13400-2:2019: version 0x02, inverse 0xFD,
;; 8-byte header (version, inverse, type:u16, length:u32 big endian).
;; ----------------------------------------------------------------------------

(struct doip-frame (type payload) #:transparent)
(struct doip-vehicle-identity (vin logical-address ip-address) #:transparent)

(define doip-port 13400)
(define protocol-version #x02)
(define inverse-version #xFD)
(define header-length 8)

;; payload types
(define pt-generic-header-nack #x0000)
(define pt-vehicle-identification-request #x0001)
(define pt-vehicle-identification-response #x0004)
(define pt-routing-activation-request #x0005)
(define pt-routing-activation-response #x0006)
(define pt-alive-check-request #x0007)
(define pt-alive-check-response #x0008)
(define pt-diagnostic-message #x8001)
(define pt-diagnostic-positive-acknowledgement #x8002)
(define pt-diagnostic-negative-acknowledgement #x8003)

(define routing-accepted #x10)
(define routing-confirmed #x11)
(define routing-already-active #x12)

(define (u16-be v) (list (bitwise-and (arithmetic-shift v -8) #xFF) (bitwise-and v #xFF)))
(define (u32-be v)
  (list (bitwise-and (arithmetic-shift v -24) #xFF)
        (bitwise-and (arithmetic-shift v -16) #xFF)
        (bitwise-and (arithmetic-shift v -8) #xFF)
        (bitwise-and v #xFF)))
(define (bytes-u16-be data offset)
  (+ (* 256 (list-ref data offset)) (list-ref data (add1 offset))))
(define (bytes-u32-be data offset)
  (+ (* 16777216 (list-ref data offset))
     (* 65536 (list-ref data (add1 offset)))
     (* 256 (list-ref data (+ offset 2)))
     (list-ref data (+ offset 3))))

(define (doip-frame->bytes frame)
  (append (list protocol-version inverse-version)
          (u16-be (doip-frame-type frame))
          (u32-be (length (doip-frame-payload frame)))
          (doip-frame-payload frame)))

;; Attempts to decode one frame; returns (cons frame consumed) or #f when
;; more bytes are needed; raises on a malformed header.
(define (doip-try-decode available)
  (if (< (length available) header-length)
      #f
      (let ([version (list-ref available 0)]
            [inverse (list-ref available 1)])
        (unless (and (= version protocol-version) (= inverse inverse-version))
          (doip-error
           (format "Invalid DoIP header version ~a/~a."
                   (~r version #:base 16 #:min-width 2 #:pad-string "0")
                   (~r inverse #:base 16 #:min-width 2 #:pad-string "0"))))
        (let* ([type (bytes-u16-be available 2)]
               [length* (bytes-u32-be available 4)])
          (if (< (length available) (+ header-length length*))
              #f
              (cons (doip-frame type
                                (list-tail (take available (+ header-length length*)) header-length))
                    (+ header-length length*)))))))

(define (make-doip-frame-diagnostic-message source target user-data)
  (doip-frame pt-diagnostic-message (append (u16-be source) (u16-be target) user-data)))

(define (make-doip-frame-routing-activation-request source-address [activation-type #x00])
  (doip-frame pt-routing-activation-request
              (append (u16-be source-address) (list activation-type 0 0 0 0))))

(define (make-doip-frame-vehicle-identification-request)
  (doip-frame pt-vehicle-identification-request '()))

(define (doip-diagnostic-target frame)
  (if (and (= (doip-frame-type frame) pt-diagnostic-message)
           (>= (length (doip-frame-payload frame)) 4))
      (bytes-u16-be (doip-frame-payload frame) 2)
      #f))

(define (doip-diagnostic-user-data frame)
  (if (and (= (doip-frame-type frame) pt-diagnostic-message)
           (>= (length (doip-frame-payload frame)) 4))
      (list-tail (doip-frame-payload frame) 4)
      '()))

;; ----------------------------------------------------------------------------
;; TCP frame reader/writer with buffering (FrameReader)
;; ----------------------------------------------------------------------------

;; Reads whatever bytes are available (at least one; blocking — dispose
;; paths kill the owning thread). The frame reader reassembles frames.
(define (read-chunk! in)
  (define buffer (make-bytes 1024))
  (define n (read-bytes-avail! buffer in))
  (if (and n (not (eof-object? n)) (> n 0))
      (bytes->list (subbytes buffer 0 n))
      (doip-error "DoIP connection closed by peer.")))

(define (make-frame-reader in)
  (define buffer-box (box #f)) ; pending bytes or #f
  (lambda (cancel)
    (let loop ()
      (define pending (unbox buffer-box))
      (define decode-input (or pending '()))
      (cond
        [(doip-try-decode decode-input)
         => (lambda (decoded)
              (define rest (list-tail decode-input (cdr decoded)))
              (set-box! buffer-box (and (not (null? rest)) rest))
              (car decoded))]
        [(> (length decode-input) (* 16 1024))
         (doip-error "DoIP receive buffer exhausted.")]
        [else
         (define chunk (read-chunk! in))
         (set-box! buffer-box (append decode-input chunk))
         (loop)]))))

(define (write-frame! out frame cancel)
  (display (list->bytes (doip-frame->bytes frame)) out)
  (flush-output out))

;; ----------------------------------------------------------------------------
;; DoipClient
;; ----------------------------------------------------------------------------

(struct doip-client (tester-address ecu-address
                     in-box out-box reader-box connected-box mutex))

(define (make-doip-client tester-address ecu-address)
  (doip-client tester-address ecu-address (box #f) (box #f) (box #f) (box #f) (make-semaphore 1)))

(define (with-client-mutex c proc)
  (semaphore-wait/enable-break (doip-client-mutex c))
  (begin0 (proc) (semaphore-post (doip-client-mutex c))))

;; Connects TCP, then performs the routing activation handshake.
(define (doip-client-connect! c host [port doip-port] #:cancel [cancel #f])
  (with-client-mutex
   c
   (lambda ()
     (unless (unbox (doip-client-connected-box c))
       (define-values (in out)
         (tcp-connect host port))
       (set-box! (doip-client-in-box c) in)
       (set-box! (doip-client-out-box c) out)
       (set-box! (doip-client-reader-box c) (make-frame-reader in))
       (write-frame! out (make-doip-frame-routing-activation-request
                          (doip-client-tester-address c)) cancel)
       (define response ((unbox (doip-client-reader-box c)) cancel))
       (unless (= (doip-frame-type response) pt-routing-activation-response)
         (doip-error
          (format "Unexpected routing activation response type ~a." (doip-frame-type response))))
       (define code (list-ref (doip-frame-payload response) 4))
       (unless (memq code (list routing-accepted routing-confirmed routing-already-active))
         (doip-error
          (format "Routing activation denied (code 0x~a)."
                  (~r code #:base 16 #:min-width 2 #:pad-string "0"))))
       (set-box! (doip-client-connected-box c) #t)))))

(define (doip-client-send-request! c request #:cancel [cancel #f])
  (unless (unbox (doip-client-connected-box c))
    (doip-error "DoIP client is not connected."))
  (write-frame! (unbox (doip-client-out-box c))
                (make-doip-frame-diagnostic-message
                 (doip-client-tester-address c) (doip-client-ecu-address c) request)
                cancel))

(define (doip-client-receive-response! c #:cancel [cancel #f])
  (unless (unbox (doip-client-connected-box c))
    (doip-error "DoIP client is not connected."))
  (define out (unbox (doip-client-out-box c)))
  (let loop ()
    (define frame ((unbox (doip-client-reader-box c)) cancel))
    (cond
      [(= (doip-frame-type frame) pt-diagnostic-message)
       (if (and (doip-diagnostic-target frame)
                (= (doip-diagnostic-target frame) (doip-client-tester-address c)))
           (doip-diagnostic-user-data frame)
           (loop))]
      [(= (doip-frame-type frame) pt-diagnostic-negative-acknowledgement)
       (doip-error
        (format "DoIP negative acknowledgement (code 0x~a)."
                (~r (if (> (length (doip-frame-payload frame)) 4)
                        (list-ref (doip-frame-payload frame) 4)
                        0)
                    #:base 16 #:min-width 2 #:pad-string "0")))]
      [(= (doip-frame-type frame) pt-alive-check-request)
       (write-frame! out (doip-frame pt-alive-check-response '(#x00 #x00)) cancel)
       (loop)]
      [(= (doip-frame-type frame) pt-generic-header-nack)
       (doip-error "DoIP generic header negative acknowledgement.")]
      [else (loop)])))


;; Bounded UDP receive: Racket's udp-receive! blocks indefinitely, so the
;; discovery window polls in a worker thread and reaps it on timeout.
(define (udp-receive-with-timeout sock buffer seconds)
  (define result-box (box #f))
  (define done (make-semaphore))
  (define worker
    (thread
     (lambda ()
       (with-handlers ([exn:fail? (lambda (_) (void))])
         (define-values (len hostname port*) (udp-receive! sock buffer))
         (set-box! result-box (list len hostname port*))
         (semaphore-post done)))))
  (sync/timeout seconds done)
  (kill-thread worker)
  (unbox result-box))

;; UDP vehicle discovery: loopback unicast first (simulators bind loopback
;; only), then LAN broadcast; every valid answer inside the window returns.
(define (doip-client-discover [window-ms 500] #:cancel [cancel #f])
  (define sock (udp-open-socket))
  (udp-bind! sock #f 0)
  (define request (list->bytes (doip-frame->bytes (make-doip-frame-vehicle-identification-request))))
  (with-handlers ([exn:fail:network? (lambda (_) (void))])
    (udp-send-to sock "127.0.0.1" doip-port request))
  (udp-send-to sock "255.255.255.255" doip-port request)

  (define identities '())
  (define deadline (+ (now-millis) window-ms))
  (define receive-buffer (make-bytes 2048))
  (let loop ()
    (when (< (now-millis) deadline)
      (define-values (len hostname port* response)
        (udp-receive!* sock receive-buffer))
      (cond
        [(and len (> len 0))
         (define decoded
           (with-handlers ([exn:fail:doip? (lambda (_) #f)])
             (doip-try-decode (bytes->list (subbytes response 0 len)))))
         (when (and decoded
                    (= (doip-frame-type (car decoded)) pt-vehicle-identification-response)
                    (>= (length (doip-frame-payload (car decoded))) 21))
           (define payload (doip-frame-payload (car decoded)))
           (define vin
             (string-trim (bytes->string/latin-1 (list->bytes (take payload 17))) #px"[\0 ]+"))
           (define logical (bytes-u16-be payload 17))
           (set! identities
                 (cons (doip-vehicle-identity vin logical hostname) identities)))
         (loop)]
        [else (loop)])))
  (udp-close sock)
  (reverse identities))

;; ----------------------------------------------------------------------------
;; SimulatedDoipServer: answers UDP discovery, accepts one routing
;; activation per connection, serves diagnostics through UdsProcessor.
;; ----------------------------------------------------------------------------

(struct simulated-doip-server (processor listener tcp-thread udp-thread udp-sock port-box))

(define (start-simulated-doip-server
         #:tester-address [tester-address #x0E00]
         #:ecu-address [ecu-address #x0E10]
         #:vin [vin "BPILSIMECU0000001"]
         #:enable-discovery [enable-discovery #t]
         #:ecu-options [ecu-options #f])
  ;; racket/tcp has no ephemeral-port query; probe a small range.
  (define-values (listener port*)
    (let probe ([attempt 0])
      (define candidate (+ 43400 (random 2000)))
      (with-handlers ([exn:fail:network? (lambda (_) (probe (add1 attempt)))])
        (values (tcp-listen candidate 16 #t) candidate))))
  (define udp-sock
    (and enable-discovery
         (let ([s (udp-open-socket)])
           (with-handlers ([exn:fail:network? (lambda (_) (udp-close s) #f)])
             (udp-bind! s "127.0.0.1" doip-port)
             s))))
  (define processor (make-uds-processor (or ecu-options (default-uds-ecu-options))))

  (define (serve-client in out)
    (define reader (make-frame-reader in))
    ;; Routing activation: exactly one per connection (single tester sim).
    (define activation (reader #f))
    (unless (= (doip-frame-type activation) pt-routing-activation-request)
      (write-frame! out (doip-frame pt-generic-header-nack '(#x02)) #f)
      (error 'sim-doip "bad activation"))
    (define source (bytes-u16-be (doip-frame-payload activation) 0))
    (write-frame!
     out
     (doip-frame pt-routing-activation-response
                 (append (u16-be ecu-address) (u16-be source)
                         (list routing-accepted 0 0 0 0)))
     #f)
    (let loop ()
      (with-handlers ([exn:fail:doip? (lambda (_) (void))]
                      [exn:fail? (lambda (_) (void))])
        (define frame (reader #f))
        (cond
          [(and (= (doip-frame-type frame) pt-diagnostic-message)
                (>= (length (doip-frame-payload frame)) 4))
           (define target (bytes-u16-be (doip-frame-payload frame) 2))
           (if (not (= target ecu-address))
               (begin
                 (write-frame!
                  out
                  (doip-frame pt-diagnostic-negative-acknowledgement
                              (append (u16-be target) (u16-be source) '(#x02)))
                  #f)
                 (loop))
               (let* ([request (doip-diagnostic-user-data frame)]
                      [result (uds-processor-process! processor request)])
                 (when (and (>= (uds-server-response-delay-ms result) 0)
                            (not (null? (uds-server-response-response result))))
                   (when (> (uds-server-response-delay-ms result) 0)
                     (sleep (/ (uds-server-response-delay-ms result) 1000.0)))
                   (write-frame!
                    out
                    (make-doip-frame-diagnostic-message ecu-address source
                                                        (uds-server-response-response result))
                    #f))
                 (loop)))]
          [(= (doip-frame-type frame) pt-alive-check-request)
           (write-frame! out (doip-frame pt-alive-check-response '(#x00 #x00)) #f)
           (loop)]
          [else (loop)]))))

  (define tcp-thread*
    (thread
     (lambda ()
       (let loop ()
         (with-handlers ([exn:fail? (lambda (_) (void))])
           (define-values (in out) (tcp-accept listener))
           (thread (lambda ()
                     (with-handlers ([exn:fail? (lambda (_) (void))])
                       (serve-client in out)
                       (close-input-port in)
                       (close-output-port out))))
           (loop))))))
  (define udp-thread*
    (and udp-sock
         (thread
          (lambda ()
            (define buffer (make-bytes 2048))
            (let loop ()
              (define received (udp-receive-with-timeout udp-sock buffer 3600))
              (when received
                (let* ([len (first received)]
                       [hostname (second received)]
                       [port*2 (third received)])
                  (when (and len (> len 0))
                    (define decoded
                      (with-handlers ([exn:fail:doip? (lambda (_) #f)])
                        (doip-try-decode (bytes->list (subbytes buffer 0 len)))))
                    (when (and decoded (= (doip-frame-type (car decoded)) pt-vehicle-identification-request))
                      (define payload
                        (append
                         (take (append (bytes->list (string->bytes/latin-1 vin)) (make-list 17 0)) 17)
                         (u16-be ecu-address)
                         (make-list 13 0))) ; EID/GID/reserved/sync stay zero
                      (with-handlers ([exn:fail:network? (lambda (_) (void))])
                        (udp-send-to udp-sock hostname port*2
                                     (list->bytes (doip-frame->bytes (doip-frame pt-vehicle-identification-response payload))))))))
                (loop)))))))
  (simulated-doip-server processor listener tcp-thread* udp-thread* udp-sock (box port*)))

(define (simulated-doip-server-listen-port server)
  (unbox (simulated-doip-server-port-box server)))

(define (simulated-doip-server-dispose! server)
  (tcp-close (simulated-doip-server-listener server))
  (when (simulated-doip-server-udp-sock server)
    (udp-close (simulated-doip-server-udp-sock server)))
  (kill-thread (simulated-doip-server-tcp-thread server))
  (when (simulated-doip-server-udp-thread server)
    (kill-thread (simulated-doip-server-udp-thread server))))

;; ----------------------------------------------------------------------------
;; DoIP UDS channel: connect + activate once, then UDS over diagnostic
;; messages. The same flash engine drives this channel unchanged.
;; ----------------------------------------------------------------------------

(struct doip-uds-channel
  (host port tester-address ecu-address security-level key-deriver-name max-block-payload
        client-box mutex))

(define (make-doip-uds-channel host port tester-address ecu-address
                               #:security-level [security-level #f]
                               #:key-deriver-name [key-deriver-name "xor0x5a"]
                               #:max-block-payload [max-block-payload 1024])
  (doip-uds-channel host port tester-address ecu-address security-level key-deriver-name
                    max-block-payload (box #f) (make-semaphore 1)))

(define (hex-up* n width)
  (string-upcase (~r n #:base 16 #:min-width width #:pad-string "0")))

(define (with-channel-mutex sema proc)
  (semaphore-wait/enable-break sema)
  (begin0 (proc) (semaphore-post sema)))

(define (open-doip-channel! c)
  (with-channel-mutex
   (doip-uds-channel-mutex c)
   (lambda ()
     (unless (unbox (doip-uds-channel-client-box c))
       (define client (make-doip-client (doip-uds-channel-tester-address c)
                                        (doip-uds-channel-ecu-address c)))
       (doip-client-connect! client (doip-uds-channel-host c) (doip-uds-channel-port c))
       (set-box! (doip-uds-channel-client-box c) client)))))

(define (doip-uds-channel-request c request p2-ms p2-star-ms)
  (define hex (bytes->hex request))
  (open-doip-channel! c)
  (define client (unbox (doip-uds-channel-client-box c)))
  (with-handlers ([exn:fail:uds?
                   (lambda (e)
                     (uds-request-result #f #f hex #f
                                         (and (exn:fail:uds-nrc e) (nrc-name (exn:fail:uds-nrc e)))
                                         (exn-message e)))]
                  [exn:fail:doip?
                   (lambda (e)
                     (uds-request-result #f #f hex #f #f (exn-message e)))])
    (define response
      (uds-send (make-uds-client
                 (lambda (req cancel) (doip-client-send-request! client req #:cancel cancel))
                 (lambda (cancel poll) (doip-client-receive-response! client #:cancel cancel)))
                request
                #:timing (uds-timing p2-ms p2-star-ms)))
    (if (uds-response-positive response)
        (uds-request-result #t #t hex (bytes->hex (uds-response-payload response)) #f #f)
        (uds-request-result #t #f hex #f (nrc-name (uds-response-nrc response)) #f))))

(define (doip-uds-channel-flash c spec)
  (open-doip-channel! c)
  (define client (unbox (doip-uds-channel-client-box c)))
  (define uds
    (make-uds-client
     (lambda (req cancel) (doip-client-send-request! client req))
     (lambda (cancel poll) (doip-client-receive-response! client))))
  (with-handlers ([exn:fail:flash? (lambda (e) (exn:fail:flash-execution e))]
                  [exn:fail:doip?
                   (lambda (e)
                     (uds-flash-result #f 0 0 0 '() (exn-message e)))])
    (flash-execute (make-flash-engine uds (make-key-derivers)) spec)))

(struct doip-uds-driver (channel)
  #:methods gen:diag-channel
  [(define (diag-transport d) "doip")
   (define (diag-open d cancel)
     (open-doip-channel! (doip-uds-driver-channel d))
     (diag-open-result #t "doip" #f))
   (define (diag-request d request-bytes p2-ms p2-star-ms cancel)
     (doip-uds-channel-request (doip-uds-driver-channel d) request-bytes p2-ms p2-star-ms))
   (define (diag-flash d plan cancel)
     (doip-uds-channel-flash (doip-uds-driver-channel d) plan))]
  #:methods gen:resource-health-check
  [(define (check-health d cancel)
     (define c (doip-uds-driver-channel d))
     (resource-health-result
      #t "DoIP UDS channel is configured."
      (hasheq "kind" "doip-uds"
              "transport" "doip"
              "host" (doip-uds-channel-host c)
              "port" (~a (doip-uds-channel-port c))
              "txId" (format "0x~a" (hex-up* (doip-uds-channel-tester-address c) 1))
              "rxId" (format "0x~a" (hex-up* (doip-uds-channel-ecu-address c) 1)))
      #f))])

;; DiagResourceFactories (doip part): settings host/port/requestId/responseId.
(define (make-doip-uds-resource-factory)
  (driver-factory "doip-uds"
                  (lambda (resource-id config)
                    (define settings (bench-resource-settings config))
                    (doip-uds-driver
                     (make-doip-uds-channel
                      (or (hash-ref settings 'host #f) "127.0.0.1")
                      (or (parse-int-setting (hash-ref settings 'port #f)) doip-port)
                      (or (parse-hex-setting* (hash-ref settings 'requestId #f)) #x0E00)
                      (or (parse-hex-setting* (hash-ref settings 'responseId #f)) #x0E10))))))

(define (parse-int-setting v)
  (and (exact-integer? v) v))
(define (parse-hex-setting* v)
  (and (string? v)
       (let ([m (regexp-match #rx"^0x([0-9a-fA-F]+)$" v)])
         (and m (string->number (second m) 16)))))
