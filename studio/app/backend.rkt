#lang racket/base

(require rivet/backend)

(provide start)

(define-event notification : String)
(define-state counter : Int64 0)

(define-rpc (greet [name String] : String)
  (format "Hello, ~a!" name))

(define-rpc (notify [message String] : Void)
  (notification message)
  (void))

(define (start in-fd out-fd)
  (serve-fds in-fd out-fd))