#lang racket/base

;; ScpiPowerSupply.cs + ScpiPowerResourceFactory.cs port: generic raw-TCP
;; SCPI power supply; vendor differences are profile command templates and
;; the Runtime sees only the power-supply generic. Safety shutoff on
;; transport/protocol errors, bounded query timeouts.

(require racket/format
         racket/list
         racket/string
         racket/tcp)

(require benchpilot/core/bench-runtime
         benchpilot/core/contracts
         benchpilot/core/profile)

(provide
 (struct-out scpi-power-settings)
 (struct-out scpi-power-commands)
 (struct-out scpi-power-driver-impl)
 make-scpi-power-driver
 make-scpi-power-resource-factory
 format-scpi-template
 default-scpi-commands
 ps-power-on ps-power-off ps-read-current ps-check-current ps-on?)

;; ----------------------------------------------------------------------------
;; Settings (ScpiPowerSettings / ScpiPowerCommands)
;; ----------------------------------------------------------------------------

(struct scpi-power-commands
  (set-voltage set-current-limit output-on output-off measure-voltage measure-current identify)
  #:transparent)

(struct scpi-power-settings
  (host port connect-timeout-ms io-timeout-ms current-limit-a channel commands)
  #:transparent)

;; ----------------------------------------------------------------------------
;; Template formatting (Format): {voltage} / {current} / {channel}, all
;; case-insensitive; empty replacement when the value is absent.
;; ----------------------------------------------------------------------------

(define default-scpi-commands
  (scpi-power-commands "VOLT {voltage}" "CURR {current}" "OUTP ON" "OUTP OFF"
                       "MEAS:VOLT?" "MEAS:CURR?" "*IDN?"))

(define (format-number-8 v)
  ;; C# "0.########": up to 8 decimals, trailing zeros trimmed.
  (define s (~r v #:precision '(= 8)))
  (if (string-contains? s ".")
      (regexp-replace #rx"[.]$" (regexp-replace #rx"0+$" s "") "")
      s))

(define (string-replace-ci s from to)
  (define from-ci (string-foldcase from))
  (define n (string-length from))
  (let loop ([remaining s] [acc (list)])
    (if (zero? (string-length remaining))
        (apply string-append (reverse acc))
        (let ([idx (index-of-ci remaining from-ci n)])
          (if idx
              (loop (substring remaining (+ idx n))
                    (cons to (cons (substring remaining 0 idx) acc)))
              (apply string-append (reverse (cons remaining acc))))))))

(define (index-of-ci haystack needle-ci n)
  (let loop ([i 0])
    (cond
      [(> (+ i n) (string-length haystack)) #f]
      [(string=? (string-foldcase (substring haystack i (+ i n))) needle-ci) i]
      [else (loop (add1 i))])))

(define (format-scpi-template template voltage current channel)
  (define command
    (string-replace-ci
     (string-replace-ci
      (string-replace-ci template "{voltage}" (and voltage (format-number-8 voltage)))
      "{current}" (and current (format-number-8 current)))
     "{channel}" (or channel "")))
  (when (string-contains? command "\r")
    (scpi-error "Formatted SCPI command must remain single-line."))
  command)

;; ----------------------------------------------------------------------------
;; Errors: transport/protocol failures are scpi errors; a response that
;; never arrives within the IO window is a timeout.
;; ----------------------------------------------------------------------------

(struct exn:fail:scpi exn:fail () #:transparent)
(struct exn:fail:scpi:timeout exn:fail:scpi () #:transparent)

(define (scpi-error message) (raise (exn:fail:scpi message (current-continuation-marks))))
(define (scpi-timeout message) (raise (exn:fail:scpi:timeout message (current-continuation-marks))))

;; ----------------------------------------------------------------------------
;; Driver: one connection, one IO gate; _isOn lives in a box.
;; ----------------------------------------------------------------------------

(struct scpi-power-driver (settings mutex in-box out-box on-box) #:transparent)

(struct scpi-power-driver-impl (driver)
  #:methods gen:power-supply
  [(define (ps-power-on d voltage settle-ms cancel)
     (define driver (scpi-power-driver-impl-driver d))
     (define settings (scpi-power-driver-settings driver))
     (define commands (scpi-power-settings-commands settings))
     (with-io-gate
      driver
      (lambda ()
        (with-handlers
            ([exn:benchpilot:cancelled?
              (lambda (e)
                (when (unbox (scpi-power-driver-on-box driver))
                  (try-safety-off! driver))
                (raise e))]
             [exn:fail:scpi?
              (lambda (e)
                (define shutoff-error
                  (and (unbox (scpi-power-driver-on-box driver))
                       (try-safety-off! driver)))
                (close-connection! driver)
                (set-box! (scpi-power-driver-on-box driver) #f)
                (power-on-result
                 #f voltage 0 #f
                 (if shutoff-error
                     (format "~a Safety shutoff could not be confirmed: ~a"
                             (exn-message e) shutoff-error)
                     (exn-message e))))])
          (ensure-connected! driver)
          (send! driver (format-scpi-template
                         (scpi-power-commands-set-voltage commands)
                         voltage
                         (scpi-power-settings-current-limit-a settings)
                         (scpi-power-settings-channel settings)))
          (when (scpi-power-settings-current-limit-a settings)
            (send! driver (format-scpi-template
                           (scpi-power-commands-set-current-limit commands)
                           voltage
                           (scpi-power-settings-current-limit-a settings)
                           (scpi-power-settings-channel settings))))
          (send! driver (format-scpi-template
                         (scpi-power-commands-output-on commands)
                         voltage
                         (scpi-power-settings-current-limit-a settings)
                         (scpi-power-settings-channel settings)))
          (set-box! (scpi-power-driver-on-box driver) #t)
          (when (> settle-ms 0)
            (sleep (/ settle-ms 1000.0)))
          (define measured-voltage
            (query-double! driver (format-scpi-template
                                   (scpi-power-commands-measure-voltage commands)
                                   voltage
                                   (scpi-power-settings-current-limit-a settings)
                                   (scpi-power-settings-channel settings))))
          (define current-a
            (query-double! driver (format-scpi-template
                                   (scpi-power-commands-measure-current commands)
                                   voltage
                                   (scpi-power-settings-current-limit-a settings)
                                   (scpi-power-settings-channel settings))))
          (power-on-result #t measured-voltage (* current-a 1000.0) #t #f)))))
   (define (ps-power-off d cancel)
     (define driver (scpi-power-driver-impl-driver d))
     (with-io-gate
      driver
      (lambda ()
        (with-handlers
            ([exn:fail:scpi?
              (lambda (e)
                (close-connection! driver)
                (set-box! (scpi-power-driver-on-box driver) #f)
                (power-off-result #f (exn-message e)))])
          (ensure-connected! driver)
          (send! driver (format-scpi-template
                         (scpi-power-commands-output-off
                          (scpi-power-settings-commands (scpi-power-driver-settings driver)))
                         #f
                         (scpi-power-settings-current-limit-a (scpi-power-driver-settings driver))
                         (scpi-power-settings-channel (scpi-power-driver-settings driver))))
          (set-box! (scpi-power-driver-on-box driver) #f)
          (power-off-result #t #f)))))
   (define (ps-read-current d window-ms cancel)
     (define driver (scpi-power-driver-impl-driver d))
     (if (not (unbox (scpi-power-driver-on-box driver)))
         (current-reading #f 0 0 '() "Power output is off.")
         (with-io-gate
          driver
          (lambda ()
            (with-handlers
                ([exn:benchpilot:cancelled? (lambda (e) (raise e))]
                 [exn:fail:scpi?
                  (lambda (e)
                    (close-connection! driver)
                    (set-box! (scpi-power-driver-on-box driver) #f)
                    (current-reading #f 0 0 '() (exn-message e)))])
              (let loop ([samples (list)] [start (now-millis)])
                (define sample (ps-measure-current-ma d))
                (define next (cons sample samples))
                (if (>= (- (now-millis) start) window-ms)
                    (current-reading
                     #t (/ (apply + next) (length next)) (apply max next) (reverse next) #f)
                    (begin
                      (sleep (/ (min 100 (max 20 (quotient window-ms 10))) 1000.0))
                      (loop next start)))))))))
   (define (ps-check-current d lt-ma gt-ma cancel)
     (define driver (scpi-power-driver-impl-driver d))
     (cond
       [(not (unbox (scpi-power-driver-on-box driver)))
        (current-check #f 0 #f "Power output is off.")]
       [(and (not lt-ma) (not gt-ma))
        (current-check #f 0 #f "Provide lt or gt threshold (mA).")]
       [else
        (let ([reading (ps-read-current d 300 cancel)])
          (if (not (current-reading-ok reading))
              (current-check #f (current-reading-avg-ma reading) #f
                             (current-reading-error reading))
            (let ([v (current-reading-avg-ma reading)])
              (current-check
               #t v
               (and (or (not lt-ma) (< v lt-ma)) (or (not gt-ma) (> v gt-ma)))
               #f))))]))
   (define (ps-on? d)
     (unbox (scpi-power-driver-on-box (scpi-power-driver-impl-driver d))))]
  #:methods gen:resource-health-check
  [(define (check-health d cancel)
     ;; Identifies the instrument without touching the output state.
     (define driver (scpi-power-driver-impl-driver d))
     (define settings (scpi-power-driver-settings driver))
     (define commands (scpi-power-settings-commands settings))
     (with-io-gate
      driver
      (lambda ()
        (with-handlers
            ([exn:benchpilot:cancelled? (lambda (e) (raise e))]
             [exn:fail:scpi?
              (lambda (e)
                (close-connection! driver)
                (set-box! (scpi-power-driver-on-box driver) #f)
                (resource-health-result
                 #f
                 "SCPI instrument is not ready."
                 (hasheq "host" (scpi-power-settings-host settings)
                         "port" (~a (scpi-power-settings-port settings)))
                 (exn-message e)))])
          (ensure-connected! driver)
          (define idn
            (string-trim
             (query! driver (scpi-power-commands-identify commands))))
          (resource-health-result
           #t
           "SCPI instrument is reachable and responded to its identify query."
           (hasheq "host" (scpi-power-settings-host settings)
                   "port" (~a (scpi-power-settings-port settings))
                   "idn" idn
                   "outputState" (if (unbox (scpi-power-driver-on-box driver)) "on" "off"))
           #f)))))])

;; ----------------------------------------------------------------------------
;; IO primitives
;; ----------------------------------------------------------------------------

(define (with-io-gate driver proc)
  (semaphore-wait/enable-break (scpi-power-driver-mutex driver))
  (begin0 (proc) (semaphore-post (scpi-power-driver-mutex driver))))

(define (ensure-connected! driver)
  (unless (unbox (scpi-power-driver-in-box driver))
    (define settings (scpi-power-driver-settings driver))
    (define-values (in out)
      (tcp-connect (scpi-power-settings-host settings)
                   (scpi-power-settings-port settings)))
    (set-box! (scpi-power-driver-in-box driver) in)
    (set-box! (scpi-power-driver-out-box driver) out)
    (eprintf "DRIVER connected to ~a:~a
" (scpi-power-settings-host settings) (scpi-power-settings-port settings))))

(define (close-connection! driver)
  (define in (unbox (scpi-power-driver-in-box driver)))
  (define out (unbox (scpi-power-driver-out-box driver)))
  (when in (with-handlers ([exn:fail? void]) (close-input-port in)))
  (when out (with-handlers ([exn:fail? void]) (close-output-port out)))
  (set-box! (scpi-power-driver-in-box driver) #f)
  (set-box! (scpi-power-driver-out-box driver) #f))

(define (send! driver command)
  (define out (unbox (scpi-power-driver-out-box driver)))
  (with-handlers ([exn:fail? (lambda (e) (raise (exn:fail:scpi (exn-message e) (current-continuation-marks))))])
    (display command out)
    (display "\r\n" out)
    (flush-output out)))

;; Reads one response line with a wall-clock timeout (worker thread + reap,
;; matching the C# ioTimeout behavior).
;; Reads one response line with a wall-clock timeout: TCP input ports are
;; sync events (readable when data is available), so wait on the port and
;; only then read — no worker thread, no kill-race.
(define (read-line-with-timeout! driver timeout-ms)
  (define in (unbox (scpi-power-driver-in-box driver)))
  (unless (sync/timeout (/ timeout-ms 1000.0) in)
    (scpi-timeout (format "SCPI response timed out after ~a ms." timeout-ms)))
  (read-line in 'return-linefeed))

(define (query! driver command)
  (eprintf "QUERY sending: ~a
" command)
  (send! driver command)
  (string-trim
   (read-line-with-timeout! driver (scpi-power-settings-io-timeout-ms (scpi-power-driver-settings driver)))))

(define (query-double! driver command)
  (define response (query! driver command))
  (or (string->number response)
      (scpi-error (format "SCPI response is not numeric: '~a'." response))))

(define (try-safety-off! driver)
  (with-handlers ([exn:fail? (lambda (e) (exn-message e))])
    (send! driver (format-scpi-template
                   (scpi-power-commands-output-off
                    (scpi-power-settings-commands (scpi-power-driver-settings driver)))
                   #f
                   (scpi-power-settings-current-limit-a (scpi-power-driver-settings driver))
                   (scpi-power-settings-channel (scpi-power-driver-settings driver))))
    (set-box! (scpi-power-driver-on-box driver) #f)
    #f))

;; Internal: one current sample in mA.
(define (ps-measure-current-ma d)
  (define driver (scpi-power-driver-impl-driver d))
  (define settings (scpi-power-driver-settings driver))
  (* 1000.0
     (query-double! driver (format-scpi-template
                            (scpi-power-commands-measure-current
                             (scpi-power-settings-commands settings))
                            #f
                            (scpi-power-settings-current-limit-a settings)
                            (scpi-power-settings-channel settings)))))

;; ----------------------------------------------------------------------------
;; Construction (ScpiPowerResourceFactory)
;; ----------------------------------------------------------------------------

(define (make-scpi-power-driver settings)
  (scpi-power-driver-impl
   (scpi-power-driver settings (make-semaphore 1) (box #f) (box #f) (box #f))))

(define (make-scpi-power-resource-factory)
  (driver-factory "scpi-power"
                  (lambda (resource-id config)
                    (unless (member "power" (bench-resource-capabilities config) string-ci=?)
                      (raise-validation
                       (format "Resource '~a' uses scpi-power but does not declare the 'power' capability." resource-id)))
                    (define settings (bench-resource-settings config))
                    (define (get-string key)
                      (define v (hash-ref settings key #f))
                      (and (string? v) v))
                    (define (get-int key)
                      (define v (hash-ref settings key #f))
                      (and v (exact-integer? v) v))
                    (define (get-real key)
                      (define v (hash-ref settings key #f))
                      (and v (real? v) v))
                    (define host (get-string 'host))
                    (unless (and host (not (string-blank? host)))
                      (raise-validation
                       (format "Resource '~a' requires scpi-power setting 'host'." resource-id)))
                    (define port (get-int 'port))
                    (define connect-timeout (get-int 'connectTimeoutMs))
                    (define io-timeout (get-int 'ioTimeoutMs))
                    (define current-limit-a (get-real 'currentLimitA))
                    (define channel (get-string 'channel))
                    (define commands
                      (scpi-power-commands
                       (or (get-string 'setVoltage) "VOLT {voltage}")
                       (or (get-string 'setCurrentLimit) "CURR {current}")
                       (or (get-string 'outputOn) "OUTP ON")
                       (or (get-string 'outputOff) "OUTP OFF")
                       (or (get-string 'measureVoltage) "MEAS:VOLT?")
                       (or (get-string 'measureCurrent) "MEAS:CURR?")
                       (or (get-string 'identify) "*IDN?")))
                    (for ([template (in-list (list (scpi-power-commands-set-voltage commands)
                                                   (scpi-power-commands-set-current-limit commands)
                                                   (scpi-power-commands-output-on commands)
                                                   (scpi-power-commands-output-off commands)
                                                   (scpi-power-commands-measure-voltage commands)
                                                   (scpi-power-commands-measure-current commands)
                                                   (scpi-power-commands-identify commands)))])
                      (when (or (string-contains? template "\n")
                                (string-contains? template "\r"))
                        (raise-validation
                         (format "Resource '~a' SCPI command templates must be single-line."
                                 resource-id))))
                    (when (and port (or (<= port 0) (> port 65535)))
                      (raise-validation (format "Resource '~a' has invalid TCP port ~a." resource-id port)))
                    (when (and connect-timeout (or (< connect-timeout 100) (> connect-timeout 120000)))
                      (raise-validation
                       (format "Resource '~a' connectTimeoutMs must be between 100 and 120000." resource-id)))
                    (when (and io-timeout (or (< io-timeout 100) (> io-timeout 120000)))
                      (raise-validation
                       (format "Resource '~a' ioTimeoutMs must be between 100 and 120000." resource-id)))
                    (when (and current-limit-a (<= current-limit-a 0))
                      (raise-validation
                       (format "Resource '~a' currentLimitA must be greater than zero when configured." resource-id)))
                    (make-scpi-power-driver
                     (scpi-power-settings host
                                          (or port 5025)
                                          (or connect-timeout 3000)
                                          (or io-timeout 3000)
                                          current-limit-a
                                          channel
                                          commands)))))
