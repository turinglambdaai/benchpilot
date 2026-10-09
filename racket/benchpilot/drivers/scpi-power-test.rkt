#lang racket/base

;; ScpiPowerTests.cs port: profile-driven TCP SCPI flow against a fake
;; server, and the response-timeout safety-shutoff path.

(module+ test
  (require benchpilot/core/bench-runtime
           benchpilot/core/contracts
           benchpilot/drivers/scpi-power
           racket/list
           racket/string
           racket/tcp
           rackunit)

  ;; FakeScpiServer: answers each command from a table; unanswered commands
  ;; never respond (timeout path). Records every command received.
  (define (make-fake-scpi-server responses)
    (define-values (listener port)
      (let probe ()
        (define candidate (+ 43800 (random 1000)))
        (with-handlers ([exn:fail? (lambda (_) (probe))])
          (define l (tcp-listen candidate 8 #t))
          (values l candidate))))
    (define commands-box (box '()))
    (define done-box (box #f))
    (define server-thread
      (thread
       (lambda ()
         (with-handlers ([exn:fail? void])
           (define-values (in out) (tcp-accept listener))
           (let loop ()
             (define line (read-line in 'return-linefeed))
             (unless (eof-object? line)
               (define command (string-trim line))
               (set-box! commands-box (append (unbox commands-box) (list command)))
               (define reply (hash-ref responses command 'no-reply))
               (when (not (eq? reply 'no-reply))
                 (display reply out)
                 (display "\r\n" out)
                 (flush-output out))
               (loop)))))))
    (define (wait-for-command command timeout-s)
      (define deadline (+ (now-millis) (inexact->exact (* 1000 timeout-s))))
      (let loop ()
        (or (for/first ([c (in-list (unbox commands-box))] #:when (string=? c command)) c)
            (if (< (now-millis) deadline)
                (begin (sleep 0.05) (loop))
                #f))))
    (lambda (msg)
      (case msg
        [(port) port]
        [(commands) (unbox commands-box)]
        [(wait-for) wait-for-command]
        [(close)
         (set-box! done-box #t)
         (tcp-close listener)
         (kill-thread server-thread)])))

  (define (new-supply port #:io-timeout-ms [io-timeout-ms 2000])
    (make-scpi-power-driver
     (scpi-power-settings "127.0.0.1" port 3000 io-timeout-ms 1.5 #f default-scpi-commands)))

  (test-case "power supply executes the profile-driven TCP SCPI flow"
    (define server (make-fake-scpi-server (hash "MEAS:VOLT?" "12.04" "MEAS:CURR?" "0.123")))
    (define supply (new-supply (server 'port)))
    (define on (ps-power-on supply 12 0 #f))
    (check-true (power-on-result-ok on) (power-on-result-error on))
    (check-= (power-on-result-voltage on) 12.04 0.001)
    (check-= (power-on-result-current-ma on) 123 0.001)
    (check-true (ps-on? supply))
    (define off (ps-power-off supply #f))
    (check-true (power-off-result-ok off) (power-off-result-error off))
    (check-false (ps-on? supply))
    (check-not-false ((server 'wait-for) "OUTP OFF" 2))
    (define commands (server 'commands))
    (check-not-false (member "VOLT 12" commands) (format "commands: ~a" commands))
    (check-not-false (member "CURR 1.5" commands) (format "commands: ~a" commands))
    (check-not-false (member "OUTP ON" commands))
    (check-not-false (member "MEAS:VOLT?" commands))
    (check-not-false (member "MEAS:CURR?" commands))
    (check-not-false (member "OUTP OFF" commands))
    (server 'close))

  (test-case "device response timeout is a device error and triggers safety off"
    (define server (make-fake-scpi-server (hash "MEAS:VOLT?" 'no-reply)))
    (define supply (new-supply (server 'port) #:io-timeout-ms 150))
    (define result (ps-power-on supply 12 0 #f))
    (check-false (power-on-result-ok result))
    (check-true (string-contains? (string-foldcase (power-on-result-error result)) "timed out"))
    (check-false (string-contains? (string-foldcase (power-on-result-error result)) "cancel"))
    (check-false (ps-on? supply))
    (check-not-false ((server 'wait-for) "OUTP OFF" 2))
    (server 'close)))
