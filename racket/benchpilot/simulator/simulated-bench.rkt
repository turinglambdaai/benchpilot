#lang racket/base

;; SimulatedBench.cs port: one object implements power + serial + flash +
;; health so all channels share virtual board state. Flashing while powered
;; reboots the simulated firmware, which then streams its boot log over the
;; serial console. Boot lines become visible according to their timestamps,
;; so no background thread is required.

(require racket/contract
         racket/format
         racket/list
         racket/string)

(require benchpilot/core/bench-runtime
         benchpilot/core/contracts
         benchpilot/core/runtime-state)

(provide (struct-out simulated-bench)
         (struct-out simulated-bench-driver)
         make-simulated-bench
         make-simulated-bench-driver
         make-simulator-factory)

(struct simulated-bench (mutex powered-box power-on-at-box boot-at-box firmware-box console-box)
  #:transparent)

;; C# Random(0xC0FFEE) seeds deterministic jitter; sample values are only
;; asserted as ranges, so the base generator is contract-equivalent.
(define (jitter lo hi)
  (+ lo (* (random) (- hi lo))))

;; (list ms template) — the ms=0 template takes the firmware name.
(define boot-lines
  (list (list 0 (lambda (fw) (format "[reset] ~a starting..." fw)))
        (list 180 (lambda (_) "Clock: 160MHz, Flash: OK"))
        (list 440 (lambda (_) "Initializing peripherals..."))
        (list 640 (lambda (_) "CAN1: up @ 500kbps"))
        (list 800 (lambda (_) "GPIO: configured (8 pins)"))
        (list 981 (lambda (_) "Watchdog: enabled"))
        (list 1200 (lambda (_) "System Ready"))))

(define (now-ms*)
  (inexact->exact (floor (current-inexact-milliseconds))))

(define (with-mutex* sema proc)
  (semaphore-wait/enable-break sema)
  (begin0 (proc)
    (semaphore-post sema)))

(define (make-simulated-bench)
  (simulated-bench (make-semaphore 1) (box #f) (box 0) (box 0) (box "factory-bootloader") (box '())))

(define (powered? bench)
  (unbox (simulated-bench-powered-box bench)))

(define (firmware-name bench)
  (unbox (simulated-bench-firmware-box bench)))

(define (current-ma-now bench)
  (with-mutex*
   (simulated-bench-mutex bench)
   (lambda ()
     (or (and (powered? bench)
              (let* ([elapsed (/ (- (now-ms*) (unbox (simulated-bench-power-on-at-box bench)))
                                 1000.0)]
                     [steady (if (string=? (firmware-name bench) "factory-bootloader") 22.0 45.0)])
                (cond
                  [(< elapsed 0.4) (jitter 600 900)]
                  [(< elapsed 1.5) (+ (- 200 (* (- elapsed 0.4) 90)) (jitter 0 20))]
                  [else (jitter steady (+ steady 5))])))
         0))))

(define (boot-firmware! bench)
  ;; caller holds the mutex; resets the console and restarts the timeline
  (set-box! (simulated-bench-console-box bench)
            (for/list ([entry (in-list boot-lines)])
              (cons (car entry)
                    (format "[~ams] ~a"
                            (~a (car entry) #:width 4 #:pad-string " ")
                            ((cadr entry) (unbox (simulated-bench-firmware-box bench)))))))
  (set-box! (simulated-bench-boot-at-box bench) (now-ms*)))

(define (try-boot-firmware bench)
  (with-mutex* (simulated-bench-mutex bench)
               (lambda ()
                 (and (powered? bench)
                      (begin
                        (boot-firmware! bench)
                        #t)))))

(define (try-install-firmware-and-boot bench firmware)
  (with-mutex* (simulated-bench-mutex bench)
               (lambda ()
                 (and (powered? bench)
                      (begin
                        (set-box! (simulated-bench-firmware-box bench) firmware)
                        (boot-firmware! bench)
                        #t)))))

(define (clear-console! bench)
  (set-box! (simulated-bench-console-box bench) '())
  (set-box! (simulated-bench-boot-at-box bench) 0))

(define (visible-console-lines bench)
  (with-mutex* (simulated-bench-mutex bench)
               (lambda ()
                 (if (or (not (powered? bench)) (zero? (unbox (simulated-bench-boot-at-box bench))))
                     '()
                     (let ([visible-through (- (now-ms*)
                                               (unbox (simulated-bench-boot-at-box bench)))])
                       (for/list ([entry (in-list (unbox (simulated-bench-console-box)))]
                                  #:when (<= (car entry) visible-through))
                         (cdr entry)))))))

;; Cancel handle: the runtime's exec-cancel struct; drivers poll its event.
(define (cancelled? cancel)
  (and cancel (sync/timeout 0 (cancel-evt cancel))))
(define (cancel-wait cancel seconds)
  (sync/timeout seconds
                (if cancel
                    (cancel-evt cancel)
                    never-evt)))

(struct simulated-bench-driver (bench)
  #:methods gen:power-supply
  [(define (ps-power-on d voltage settle-ms cancel)
     (define bench (simulated-bench-driver-bench d))
     (define already-on
       (with-mutex* (simulated-bench-mutex bench)
                    (lambda ()
                      (define was (powered? bench))
                      (unless was
                        (set-box! (simulated-bench-powered-box bench) #t)
                        (set-box! (simulated-bench-power-on-at-box bench) (now-ms*))
                        (set-box! (simulated-bench-boot-at-box bench) 0))
                      was)))
     (if already-on
         (power-on-result #t voltage (current-ma-now bench) #t #f)
         (let ([wait (min (max settle-ms 0) 5000)])
           ;; Rollback on cancellation: the powered flag is already set, so
           ;; every cancellation after the mutation must undo it.
           (if (cancel-wait cancel (/ wait 1000.0))
               (begin
                 (with-mutex* (simulated-bench-mutex bench)
                              (lambda ()
                                (set-box! (simulated-bench-powered-box bench) #f)
                                (clear-console! bench)))
                 (raise (make-cancelled-error)))
               (if (try-boot-firmware bench)
                   (power-on-result #t voltage (current-ma-now bench) #t #f)
                   (power-on-result #f
                                    voltage
                                    0
                                    #f
                                    "Power was removed while the simulated board was settling."))))))
   (define (ps-power-off d cancel)
     (define bench (simulated-bench-driver-bench d))
     (when (cancelled? cancel)
       (raise (make-cancelled-error)))
     (with-mutex* (simulated-bench-mutex bench)
                  (lambda ()
                    (set-box! (simulated-bench-powered-box bench) #f)
                    (clear-console! bench)))
     (power-off-result #t #f))
   (define (ps-read-current d window-ms cancel)
     (define bench (simulated-bench-driver-bench d))
     (if (not (powered? bench))
         (current-reading #f 0 0 '() "Power is off.")
         (let ([samples
                (let loop ([samples '()]
                           [start (now-ms*)])
                  (define step-ms (min (max (quotient window-ms 20) 20) 200))
                  (cond
                    [(or (>= (- (now-ms*) start) window-ms) (not (powered? bench))) (reverse samples)]
                    [else
                     (define next (cons (current-ma-now bench) samples))
                     (cancel-wait cancel (/ step-ms 1000.0))
                     (loop next start)]))])
           (if (null? samples)
               (current-reading #f 0 0 '() "Power is off.")
               (current-reading #t
                                (/ (apply + samples) (length samples))
                                (apply max samples)
                                samples
                                #f)))))
   (define (ps-check-current d lt-ma gt-ma cancel)
     (define bench (simulated-bench-driver-bench d))
     (cond
       [(not (powered? bench)) (current-check #f 0 #f "Power is off.")]
       [(and (not lt-ma) (not gt-ma)) (current-check #f 0 #f "Provide lt or gt threshold (mA).")]
       [else
        (define reading (ps-read-current d 300 cancel))
        (if (not (current-reading-ok reading))
            (current-check #f (current-reading-avg-ma reading) #f (current-reading-error reading))
            (let ([v (current-reading-avg-ma reading)])
              (current-check #t
                             v
                             (and (or (not lt-ma) (< v lt-ma)) (or (not gt-ma) (> v gt-ma)))
                             #f)))]))
   (define (ps-on? d)
     (powered? (simulated-bench-driver-bench d)))]
  #:methods gen:serial-channel
  [(define (sc-open d port baud cancel)
     (when (cancelled? cancel)
       (raise (make-cancelled-error)))
     (serial-open-result #t (if (string-blank? port) "SIM0" port) (or baud 115200) #f #f))
   (define (sc-wait d pattern timeout-ms cancel)
     (define bench (simulated-bench-driver-bench d))
     (let loop ([start (now-ms*)])
       (cond
         [(not (powered? bench)) (serial-wait-result #f #f #f (- (now-ms*) start) "Power is off." #f)]
         [else
          (define matched
            (for/first ([line (in-list (visible-console-lines bench))]
                        #:when (string-contains? (string-foldcase line) (string-foldcase pattern)))
              line))
          (cond
            [matched (serial-wait-result #t #t matched (- (now-ms*) start) #f #f)]
            [(>= (- (now-ms*) start) timeout-ms)
             (serial-wait-result #t #f #f (- (now-ms*) start) #f #f)]
            [else
             (cancel-wait cancel 0.05)
             (loop start)])])))
   (define (sc-window d lines filter cancel)
     (define bench (simulated-bench-driver-bench d))
     (when (cancelled? cancel)
       (raise (make-cancelled-error)))
     (define all
       (if (and filter (not (string=? filter "")))
           (for/list ([line (in-list (visible-console-lines bench))]
                      #:when (string-contains? (string-foldcase line) (string-foldcase filter)))
             line)
           (visible-console-lines bench)))
     (define clamped (min (max lines 1) 1024))
     (serial-window-result #t (take-right all (min clamped (length all))) #f #f))
   (define (sc-send d data cancel)
     (when (cancelled? cancel)
       (raise (make-cancelled-error)))
     (serial-send-result #t #f #f))
   (define (sc-open? d)
     (not (null? (visible-console-lines (simulated-bench-driver-bench d)))))]
  #:methods gen:flash-target
  [(define (ft-flash d firmware cancel)
     (define bench (simulated-bench-driver-bench d))
     (define-values (bytes duration-ms)
       (with-mutex* (simulated-bench-mutex bench)
                    (lambda ()
                      (if (not (powered? bench))
                          (values #f #f)
                          (values (+ (* 256 1024) (random 4096)) (+ 400 (random 250)))))))
     (if (not bytes)
         (flash-result #f 0 0 "Power is off; cannot flash.")
         (begin
           (when (cancelled? cancel)
             (raise (make-cancelled-error)))
           (cancel-wait cancel (/ duration-ms 1000.0))
           (when (cancelled? cancel)
             (raise (make-cancelled-error)))
           (let ([firmware-name* (if (string-blank? firmware)
                                     "app.elf"
                                     (let-values ([(_dir name _dir?) (split-path firmware)])
                                       (path->string name)))])
             (if (try-install-firmware-and-boot bench firmware-name*)
                 (flash-result #t bytes duration-ms #f)
                 (flash-result #f 0 duration-ms "Power was removed during flash."))))))
   (define (ft-reset d cancel)
     (define bench (simulated-bench-driver-bench d))
     (when (cancelled? cancel)
       (raise (make-cancelled-error)))
     (if (try-boot-firmware bench)
         (reset-result #t #f)
         (reset-result #f "Power is off; cannot reset.")))]
  #:methods gen:resource-health-check
  [(define (check-health d cancel)
     (define bench (simulated-bench-driver-bench d))
     (when (cancelled? cancel)
       (raise (make-cancelled-error)))
     (resource-health-result #t
                             "Simulator resource is ready."
                             (hasheq "kind"
                                     "simulator"
                                     "powered"
                                     (if (powered? bench) "True" "False")
                                     "firmware"
                                     (firmware-name bench))
                             #f))])

(define (make-simulated-bench-driver [bench (make-simulated-bench)])
  (simulated-bench-driver bench))

;; SimulatorResourceFactory port.
(define (make-simulator-factory)
  (driver-factory "simulator" (lambda (resource-id config) (make-simulated-bench-driver))))
