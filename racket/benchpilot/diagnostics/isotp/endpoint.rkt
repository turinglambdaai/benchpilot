#lang racket/base

;; IsotpEndpoint.cs port: ISO 15765-2 network-layer endpoint over a CAN bus.
;; One endpoint owns one (txId, rxId) pair; diagnostic traffic is half-duplex,
;; so one pending transmission at a time; receiving stays concurrent.

(require racket/contract
         racket/format
         racket/list
         racket/string)

(require benchpilot/core/contracts
         benchpilot/core/runtime-state
         benchpilot/diagnostics/isotp/codec
         benchpilot/diagnostics/transport/can-bus)

(provide (struct-out isotp-options)
         (struct-out exn:fail:isotp)
         (struct-out isotp-endpoint)
         make-isotp-endpoint
         isotp-endpoint-send!
         isotp-endpoint-receive!
         isotp-endpoint-dispose!)

(struct isotp-options (block-size st-min-ms flow-control-timeout-ms poll-seconds) #:transparent)

(struct exn:fail:isotp exn:fail () #:transparent)

(define (isotp-error message)
  (raise (exn:fail:isotp message (current-continuation-marks))))

;; Receive-side state lives in one mutable record per endpoint.
(struct isotp-endpoint
        (bus tx-id
             rx-id
             options
             received-sema
             received-box
             flow-controls-box
             rx-box ; #(vector buffer length offset expected-seq fc-sent)
             send-gate
             sending-box
             listener)
  #:transparent)

(define (make-rx-state)
  (box (vector #f 0 0 1 #f)))
(define (rx-buffer rs)
  (vector-ref (unbox rs) 0))
(define (rx-length rs)
  (vector-ref (unbox rs) 1))
(define (rx-offset rs)
  (vector-ref (unbox rs) 2))
(define (rx-expected rs)
  (vector-ref (unbox rs) 3))
(define (rx-fc-sent rs)
  (vector-ref (unbox rs) 4))
(define (set-rx! rs buffer length* offset expected fc-sent)
  (set-box! rs (vector buffer length* offset expected fc-sent)))

(define (make-isotp-endpoint bus tx-id rx-id [options (isotp-options 0 0 1000 0.002)])
  (define ep-box (box #f))
  (define ep
    (isotp-endpoint bus
                    tx-id
                    rx-id
                    options
                    (make-semaphore 0)
                    (box #f)
                    (box #f)
                    (make-rx-state)
                    (make-semaphore 1)
                    (box #f)
                    (lambda (frame) (on-frame-received! (unbox ep-box) frame))))
  (set-box! ep-box ep)
  (can-bus-on-frame! bus (isotp-endpoint-listener ep))
  ep)

(define (isotp-endpoint-dispose! ep)
  (can-bus-on-frame! (isotp-endpoint-bus ep) #f))

(define (send-can! ep data)
  (can-bus-send!
   (isotp-endpoint-bus ep)
   (can-frame (isotp-endpoint-tx-id ep) (> (isotp-endpoint-tx-id ep) #x7FF) data)))

(define (isotp-endpoint-send! ep payload #:cancel [cancel #f])
  (when (null? payload)
    (raise-argument-error 'isotp-endpoint-send! "non-empty ISO-TP payload" payload))
  (semaphore-wait/enable-break (isotp-endpoint-send-gate ep))
  (define acquired
    (let loop ()
      (cond
        [(not (unbox (isotp-endpoint-sending-box ep)))
         (set-box! (isotp-endpoint-sending-box ep) #t)
         #t]
        [else
         ;; Another ISO-TP transmission is in progress; half-duplex contract.
         (semaphore-post (isotp-endpoint-send-gate ep))
         (raise-validation
          "Another ISO-TP transmission is in progress; diagnostic traffic is half-duplex.")])))
  (dynamic-wind void
                (lambda () (send-locked! ep payload cancel))
                (lambda ()
                  (set-box! (isotp-endpoint-sending-box ep) #f)
                  (semaphore-post (isotp-endpoint-send-gate ep)))))

(define (send-locked! ep payload cancel)
  (cond
    [(<= (length payload) 7) (send-can! ep (encode-single payload))]
    [else
     ;; First frame, then wait for a flow control (N_Bs timeout).
     (send-can! ep (encode-first-prefix payload))
     (define fc (receive-flow-control! ep cancel))
     (define fc*
       (case (isotp-frame-flow-status fc)
         [(continue-to-send) fc]
         [(wait)
          (define fc2 (receive-flow-control! ep cancel))
          (unless (eq? (isotp-frame-flow-status fc2) 'continue-to-send)
            (isotp-error (format "Flow control did not clear (status ~a)."
                                 (isotp-frame-flow-status fc2))))
          fc2]
         [(overflow) (isotp-error "Receiver signaled buffer overflow (FC.OVFLW).")]
         [else (isotp-error (format "Unexpected flow status ~a." (isotp-frame-flow-status fc)))]))
     (define st-min-seconds (/ (max 0 (isotp-frame-st-min-ms fc*)) 1000.0))
     (define block-size (isotp-frame-block-size fc*))
     (define total (length payload))
     (define first-chunk (if (<= total 4095) 6 2))
     (let loop ([offset first-chunk]
                [sequence 1]
                [block-count 0])
       (when (< offset total)
         (define chunk-size (min (- total offset) (sub1 classic-data-length)))
         (send-can! ep (encode-consecutive sequence (list-tail payload offset)))
         (define next-offset (+ offset chunk-size))
         (define next-sequence (bitwise-and (+ sequence 1) #x0F))
         (define next-block (add1 block-count))
         (cond
           [(and (> block-size 0) (>= next-block block-size) (< next-offset total))
            (define fc-next (receive-flow-control! ep cancel))
            (unless (eq? (isotp-frame-flow-status fc-next) 'continue-to-send)
              (isotp-error (format "Flow control interrupted a block (status ~a)."
                                   (isotp-frame-flow-status fc-next))))
            (when (> st-min-seconds 0)
              (cancel-wait* cancel st-min-seconds))
            (loop next-offset next-sequence 0)]
           [else
            (when (and (> st-min-seconds 0) (< next-offset total))
              (cancel-wait* cancel st-min-seconds))
            (loop next-offset next-sequence next-block)])))]))

(define (cancel-wait* cancel seconds)
  (when cancel
    (when (sync/timeout seconds (cancel-evt cancel))
      (raise (make-cancelled-error)))))

(define (receive-flow-control! ep cancel)
  (define options (isotp-endpoint-options ep))
  (define deadline (+ (now-millis) (isotp-options-flow-control-timeout-ms options)))
  (let loop ()
    (cond
      [(unbox (isotp-endpoint-flow-controls-box ep))
       =>
       (lambda (fcs)
         (define fc (car fcs))
         (set-box! (isotp-endpoint-flow-controls-box ep)
                   (let ([rest (cdr fcs)]) (if (null? rest) #f rest)))
         fc)]
      [(>= (now-millis) deadline)
       (isotp-error (format "No flow control received within ~a ms (N_Bs timeout)."
                            (isotp-options-flow-control-timeout-ms options)))]
      [else
       (when cancel
         (when (sync/timeout (isotp-options-poll-seconds options) (cancel-evt cancel))
           (raise (make-cancelled-error))))
       (unless cancel
         (sleep (isotp-options-poll-seconds options)))
       (loop)])))

;; Receives the next complete payload addressed to this endpoint.
(define (isotp-endpoint-receive! ep #:cancel [cancel #f])
  (let loop ()
    (cond
      [(unbox (isotp-endpoint-received-box ep))
       =>
       (lambda (received)
         (define payload (car received))
         (set-box! (isotp-endpoint-received-box ep)
                   (let ([rest (cdr received)]) (if (null? rest) #f rest)))
         payload)]
      [else
       (define poll (isotp-options-poll-seconds (isotp-endpoint-options ep)))
       (when cancel
         (when (sync/timeout poll (cancel-evt cancel))
           (raise (make-cancelled-error))))
       (unless cancel
         (sleep poll))
       (loop)])))

(define (enqueue-received! ep payload)
  (define b (isotp-endpoint-received-box ep))
  (set-box! b (append (or (unbox b) '()) (list payload))))

(define (reset-receive! ep)
  (set-rx! (isotp-endpoint-rx-box ep) #f 0 0 1 #f))

;; Emitted autonomously from the receive callback: the peer's sender is
;; blocked waiting for this flow control right now.
(define (emit-flow-control! ep)
  (thread (lambda ()
            (with-handlers ([exn:fail? (lambda (_) (void))])
              (send-can! ep
                         (encode-flow-control 'continue-to-send
                                              (isotp-options-block-size (isotp-endpoint-options ep))
                                              (isotp-options-st-min-ms
                                               (isotp-endpoint-options ep))))))))

(define (on-frame-received! ep frame)
  (unless (= (can-frame-id frame) (isotp-endpoint-rx-id ep))
    (void))
  (when (= (can-frame-id frame) (isotp-endpoint-rx-id ep))
    (define decoded (try-decode-frame (can-frame-data frame)))
    (when decoded
      (case (isotp-frame-type decoded)
        [(single)
         (set-rx! (isotp-endpoint-rx-box ep) #f 0 0 1 #f)
         (enqueue-received! ep (isotp-frame-payload decoded))]
        [(first)
         (reset-receive! ep)
         (define data (can-frame-data frame))
         (define total-length
           (if (or (not (zero? (bitwise-and (car data) #x0F)))
                   (and (> (length data) 1) (not (zero? (second data)))))
               (bitwise-ior (arithmetic-shift (bitwise-and (car data) #x0F) 8) (second data))
               (bitwise-ior (arithmetic-shift (third data) 24)
                            (arithmetic-shift (fourth data) 16)
                            (arithmetic-shift (fifth data) 8)
                            (sixth data))))
         (define prefix (length (isotp-frame-payload decoded)))
         (when (> total-length prefix)
           (set-rx! (isotp-endpoint-rx-box ep)
                    (list->bytes (append (isotp-frame-payload decoded)
                                         (make-list (max 0 (- total-length prefix)) 0)))
                    total-length
                    prefix
                    1
                    #t)
           (emit-flow-control! ep))]
        [(consecutive)
         (define rs (isotp-endpoint-rx-box ep))
         (when (rx-buffer rs)
           (when (or (rx-fc-sent rs) (zero? (rx-offset rs)))
             (if (not (= (isotp-frame-sequence decoded) (rx-expected rs)))
                 ;; Desynchronized: drop; the next single/first frame re-arms.
                 (reset-receive! ep)
                 (let* ([buffer (rx-buffer rs)]
                        [remaining (- (rx-length rs) (rx-offset rs))]
                        [take (min remaining (length (isotp-frame-payload decoded)))])
                   (for ([i (in-range take)])
                     (bytes-set! buffer
                                 (+ (rx-offset rs) i)
                                 (list-ref (isotp-frame-payload decoded) i)))
                   (define next-offset (+ (rx-offset rs) take))
                   (set-rx! rs
                            buffer
                            (rx-length rs)
                            next-offset
                            (bitwise-and (add1 (rx-expected rs)) #x0F)
                            #t)
                   (when (>= next-offset (rx-length rs))
                     (define done buffer)
                     (reset-receive! ep)
                     (enqueue-received! ep (bytes->list done)))))))]
        [(flow-control)
         (define b (isotp-endpoint-flow-controls-box ep))
         (set-box! b (append (or (unbox b) '()) (list decoded)))]))))
