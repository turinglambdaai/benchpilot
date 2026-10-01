#lang racket/base

;; PcanBus.cs port: PEAK PCAN-Basic transport (Windows). Requires the vendor
;; driver and PCANBasic.dll next to the runtime (BenchPilot never
;; redistributes vendor binaries). One channel, pumped receive, classic CAN
;; frames.
;;
;; The DLL bindings load lazily at first bus use so this module is
;; importable everywhere. The C# side waits on the driver's receive event;
;; here an empty queue costs a 50 ms sleep, which keeps the pump well under
;; any CPU budget a bench tool cares about.

(require ffi/unsafe
         racket/format
         racket/generic)

(require benchpilot/core/contracts
         benchpilot/diagnostics/isotp/codec
         benchpilot/diagnostics/transport/can-bus)

(provide (struct-out pcan-bus)
         make-pcan-bus)

(define pcan-none-value #x00)
(define pcan-parameter-message-filter #x2004)
(define pcan-acceptance-filter-all #x0000)
(define pcan-message-extended #x0004)
(define pcan-message-rtr #x0002)
(define qrc-pcan-receive-queue-empty #x0100)
(define pcan-max-frame-length 8)

;; PcanMessage packed layout (17 bytes): id u32, type u32, len u8, data[8].
(define pcan-message-size 17)

(define (new-pcan-message)
  (make-bytes pcan-message-size 0))

(define (pm-id! m v) (integer->integer-bytes v 4 #f m 0))
(define (pm-type! m v) (integer->integer-bytes v 4 #f m 4))
(define (pm-len! m v) (bytes-set! m 8 v))
(define (pm-data! m data)
  (for ([b (in-list data)]
        [i (in-naturals)])
    (bytes-set! m (+ 9 i) b)))
(define (pm-type m) (integer-bytes->integer m #f 4 8))

;; ----------------------------------------------------------------------------
;; Bus
;; ----------------------------------------------------------------------------

(struct pcan-bus (channel bitrate extended-ids mutex open-box listener-box pump-thread-box stop-box)
  #:methods gen:can-bus
  [(define (can-bus-name b) (format "PCAN ~a" (pcan-bus-channel b)))
   (define (can-bus-open! b) (pcan-open! b))
   (define (can-bus-send! b frame) (pcan-send! b frame))
   (define (can-bus-on-frame! b listener) (set-box! (pcan-bus-listener-box b) listener))
   (define (can-bus-dispose! b) (pcan-dispose! b))])

(define (make-pcan-bus channel bitrate [extended-ids #f])
  (unless (eq? (system-path-convention-type) 'windows)
    (raise-argument-error 'make-pcan-bus "PCAN-Basic requires Windows" channel))
  (pcan-bus channel bitrate extended-ids
            (make-semaphore 1) (box #f) (box #f) (box #f) (box #f)))

(define (with-bus-mutex bus proc)
  (semaphore-wait/enable-break (pcan-bus-mutex bus))
  (begin0 (proc)
    (semaphore-post (pcan-bus-mutex bus))))

;; ----------------------------------------------------------------------------
;; PCANBasic.dll bindings (lazy, cached)
;; ----------------------------------------------------------------------------

(struct pcan-ffi (initialize uninitialize write read set-value))

(define ffi-box (box #f))

(define (pcan-ffi*)
  (or (unbox ffi-box)
      (let ([f (load-pcan-ffi!)])
        (set-box! ffi-box f)
        f)))

(define (load-pcan-ffi!)
  (define lib (ffi-lib "PCANBasic"))
  (pcan-ffi
   (get-ffi-obj "CAN_Initialize" lib (_fun _ushort _uint -> _int))
   (get-ffi-obj "CAN_Uninitialize" lib (_fun _ushort -> _int))
   (get-ffi-obj "CAN_Write" lib (_fun _ushort _pointer -> _int))
   ;; TPCANStatus CAN_Read(TPCANHandle, TPCANMsg*, TPCANTimestamp*) — the
   ;; timestamp is a 64-bit tick count.
   (get-ffi-obj "CAN_Read" lib (_fun _ushort _pointer (_ptr o _uint64) -> _int))
   (get-ffi-obj "CAN_SetValue" lib (_fun _ushort _int (_ptr io _uint32) _uint -> _int))))

;; ----------------------------------------------------------------------------
;; Lifecycle
;; ----------------------------------------------------------------------------

(define (status-hex status)
  (~r status #:base 16 #:min-width 2 #:pad-string "0"))

(define (pcan-open! bus)
  (with-bus-mutex
   bus
   (lambda ()
     (unless (unbox (pcan-bus-open-box bus))
       (define ffi (pcan-ffi*))
       (define status
         ((pcan-ffi-initialize ffi)
          (pcan-bus-channel bus)
          (bitwise-and (pcan-bus-bitrate bus) #xFFFFFFFF)))
       (unless (= status pcan-none-value)
         (raise (exn:fail
                 (format
                  "PCAN: initialize failed for channel ~a with status 0x~a. Check that the PCAN driver is installed and the channel is not in use."
                  (pcan-bus-channel bus)
                  (status-hex status))
                 (current-continuation-marks))))
       (define filter pcan-acceptance-filter-all)
       ((pcan-ffi-set-value ffi)
        (pcan-bus-channel bus) pcan-parameter-message-filter filter 4)
       (set-box! (pcan-bus-open-box bus) #t)
       (set-box! (pcan-bus-stop-box bus) #f)
       (set-box! (pcan-bus-pump-thread-box bus)
                 (thread (lambda () (pump bus))))))))

(define (pump bus)
  (define ffi (pcan-ffi*))
  (define channel (pcan-bus-channel bus))
  (define message (new-pcan-message))
  (let loop ()
    (cond
      [(unbox (pcan-bus-stop-box bus)) (void)]
      [else
       (define status ((pcan-ffi-read ffi) channel message))
       (cond
         [(= status pcan-none-value)
          (define type (pm-type message))
          (when (zero? (bitwise-and type pcan-message-rtr))
            (define id (integer-bytes->integer message #f 0 4))
            (define length (bytes-ref message 8))
            (define listener (unbox (pcan-bus-listener-box bus)))
            (when listener
              (listener
               (can-frame id
                          (not (zero? (bitwise-and type pcan-message-extended)))
                          (for/list ([i (in-range (min length pcan-max-frame-length))])
                            (bytes-ref message (+ 9 i)))))))
          (loop)]
         [(= status qrc-pcan-receive-queue-empty)
          (sleep 0.05)
          (loop)]
         [else
          (sleep 0.01)
          (loop)])])))

(define (pcan-send! bus frame)
  (unless (unbox (pcan-bus-open-box bus))
    (raise (exn:fail "PCAN: bus is not open." (current-continuation-marks))))
  (define data (can-frame-data frame))
  (when (> (length data) pcan-max-frame-length)
    (raise-validation "Classic CAN frames carry at most 8 data bytes."))
  (define id (can-frame-id frame))
  (when (and (> id #x7FF) (not (can-frame-extended? frame)))
    (raise-validation (format "CAN id 0x~a requires extended frames (--extended)."
                              (~r id #:base 16))))
  (define message (new-pcan-message))
  (pm-id! message id)
  (pm-type! message (if (can-frame-extended? frame) pcan-message-extended 0))
  (pm-len! message (length data))
  (pm-data! message data)
  (define status ((pcan-ffi-write (pcan-ffi*)) (pcan-bus-channel bus) message))
  (unless (= status pcan-none-value)
    (raise (exn:fail (format "PCAN: write failed with status 0x~a." (status-hex status))
                     (current-continuation-marks)))))

(define (pcan-dispose! bus)
  (set-box! (pcan-bus-stop-box bus) #t)
  (define pump-thread (unbox (pcan-bus-pump-thread-box bus)))
  (when pump-thread
    (sync/timeout 1.5 (thread-dead-evt pump-thread)))
  (when (unbox (pcan-bus-open-box bus))
    (with-handlers ([exn:fail? (lambda (_) (void))])
      ((pcan-ffi-uninitialize (pcan-ffi*)) (pcan-bus-channel bus)))
    (set-box! (pcan-bus-open-box bus) #f)))
