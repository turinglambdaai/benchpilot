#lang racket/base

;; SimulatedCanBus.cs / SimulatedCanPortBus.cs port: an in-process CAN
;; segment; every sent frame fans out to all ports (including the sender,
;; like a real bus), and each port raises its own receive event on its pump
;; thread. Frame accurate, so ISO-TP state machines run the real code path.

(require racket/contract
         racket/list)

(require benchpilot/core/contracts
         benchpilot/core/runtime-state
         benchpilot/diagnostics/isotp/codec
         benchpilot/diagnostics/transport/can-bus)

(provide (struct-out simulated-can-bus)
         (struct-out sim-can-port)
         make-simulated-can-bus
         simulated-can-bus-frames-exchanged
         simulated-can-bus-attach
         simulated-can-bus-send!
         simulated-can-bus-snapshot-log
         make-sim-can-port-bus
         sim-can-port-bus-open!
         sim-can-port-bus-send!
         sim-can-port-bus-on-frame!)

;; ----------------------------------------------------------------------------
;; SimulatedCanBus
;; ----------------------------------------------------------------------------

(struct simulated-can-bus (name ports-box log-box mutex) #:transparent)

(struct sim-can-port (bus inbox-sema inbox-box)) ; inbox-box: #f or list

(define (make-simulated-can-bus [name "sim-can0"])
  (simulated-can-bus name (box '()) (box '()) (make-semaphore 1)))

(define (call-with-bus-mutex bus proc)
  (semaphore-wait/enable-break (simulated-can-bus-mutex bus))
  (begin0 (proc)
    (semaphore-post (simulated-can-bus-mutex bus))))

(define (simulated-can-bus-frames-exchanged bus)
  (call-with-bus-mutex bus (lambda () (length (unbox (simulated-can-bus-log-box bus))))))

(define (simulated-can-bus-attach bus)
  (define port (sim-can-port bus (make-semaphore 0) (box '())))
  (call-with-bus-mutex bus
                       (lambda ()
                         (set-box! (simulated-can-bus-ports-box bus)
                                   (append (unbox (simulated-can-bus-ports-box bus)) (list port)))))
  port)

(define (simulated-can-bus-send! bus frame)
  (call-with-bus-mutex bus
                       (lambda ()
                         (set-box! (simulated-can-bus-log-box bus)
                                   (append (unbox (simulated-can-bus-log-box bus)) (list frame)))
                         (for ([port (in-list (unbox (simulated-can-bus-ports-box bus)))])
                           (sim-can-port-deliver! port frame)))))

(define (sim-can-port-deliver! port frame)
  (define b (sim-can-port-inbox-box port))
  (set-box! b (append (or (unbox b) '()) (list frame)))
  (semaphore-post (sim-can-port-inbox-sema port)))

;; Next frame on the wire for this port (includes loopback). Waits on the
;; inbox signal or the cancel event.
(define (sim-can-port-receive! port cancel [poll 0.05])
  (let loop ()
    (cond
      [(unbox (sim-can-port-inbox-box port))
       =>
       (lambda (inbox)
         (define frame (car inbox))
         (set-box! (sim-can-port-inbox-box port) (let ([rest (cdr inbox)]) (if (null? rest) #f rest)))
         frame)]
      [else
       (define fired
         (sync/timeout poll
                       (sim-can-port-inbox-sema port)
                       (if cancel
                           (cancel-evt cancel)
                           never-evt)))
       (when (and cancel (eq? fired (cancel-evt cancel)))
         (raise (make-cancelled-error)))
       ;; A post may have raced the timeout; retry the dequeue either way.
       (loop)])))

(define (sim-can-port-send! port frame)
  (simulated-can-bus-send! (sim-can-port-bus port) frame))

(define (simulated-can-bus-snapshot-log bus [limit 256])
  (call-with-bus-mutex bus
                       (lambda ()
                         (define log (unbox (simulated-can-bus-log-box bus)))
                         (take-right log (min limit (length log))))))

;; ----------------------------------------------------------------------------
;; SimulatedCanPortBus: one port exposed as an ICanBus with its own pump
;; thread, so the ISO-TP endpoint attaches exactly like to SocketCAN/PCAN.
;; ----------------------------------------------------------------------------

(struct sim-tester-port (port name listener-box pump-thread-box open-box)
  #:methods gen:can-bus
  [(define (can-bus-name b) (sim-tester-port-name b))
   (define (can-bus-open! b) (sim-can-port-bus-open! b))
   (define (can-bus-send! b frame) (sim-can-port-bus-send! b frame))
   (define (can-bus-on-frame! b listener) (sim-can-port-bus-on-frame! b listener))
   (define (can-bus-dispose! b) (void))])

(define (make-sim-can-port-bus port [name "sim-can-port"])
  (sim-tester-port port name (box #f) (box #f) (box #f)))

(define (sim-can-port-bus-on-frame! bus listener)
  (set-box! (sim-tester-port-listener-box bus) listener))

(define (sim-can-port-bus-open! bus)
  (unless (unbox (sim-tester-port-open-box bus))
    (set-box! (sim-tester-port-open-box bus) #t)
    (set-box! (sim-tester-port-pump-thread-box bus)
              (thread (lambda ()
                        (let loop ()
                          (with-handlers ([exn:benchpilot:cancelled? (lambda (_) (void))])
                            (define frame (sim-can-port-receive! (sim-tester-port-port bus) #f))
                            (define listener (unbox (sim-tester-port-listener-box bus)))
                            (when listener
                              (listener frame)))
                          (loop)))))))

(define (sim-can-port-bus-send! bus frame)
  (sim-can-port-send! (sim-tester-port-port bus) frame))
