#lang racket/base

;; Phase 4 driver tests, ported from DriverFactoryTests.cs,
;; ScpiPowerTests.cs (remaining cases), JLinkProbeDiscoveryTests.cs and
;; SocketCanBus frame-layout behavior. Everything here runs hardware-free:
;; OS handles are never opened, and bus transports are constructed lazily.

(module+ test
  (require benchpilot/core/bench-runtime
           benchpilot/core/contracts
           benchpilot/core/profile
           benchpilot/diagnostics/channels/sim-uds-channel
           benchpilot/diagnostics/isotp/codec
           benchpilot/diagnostics/transport/socketcan
           benchpilot/drivers/jlink
           benchpilot/drivers/scpi-power
           benchpilot/drivers/system-serial
           benchpilot/simulator/simulated-bench
           racket/file
           racket/list
           racket/port
           racket/string
           racket/tcp
           rackunit)

  (define darwin?
    (regexp-match? #rx"macosx" (format "~a" (system-library-subpath))))
  (define linux?
    (and (eq? (system-path-convention-type) 'unix) (not darwin?)))

  ;; Runs thunk; returns the validation exn message or #f when nothing raised.
  (define (validation-message thunk)
    (with-handlers ([exn:benchpilot:validation? exn-message]
                    [exn:fail? (lambda (e) (exn-message e))])
      (thunk)
      #f))

  (define (resource driver capabilities settings)
    (bench-resource driver capabilities settings))

  ;; ---------------------------------------------------------------------------
  ;; DriverFactoryTests: system-serial
  ;; ---------------------------------------------------------------------------

  (test-case "system serial factory builds a profile driven resource without opening the port"
    (define factory (make-system-serial-resource-factory))
    (define instance
      ((driver-factory-create factory)
       "uart.ecu"
       (resource "system-serial" (list "serial")
                 (hasheq 'port "COM7" 'baud 115200))))
    (check-true (serial-channel? instance))
    (check-false (sc-open? instance))
    (define health (check-health instance #f))
    (check-false (resource-health-result-ok health))
    (check-equal? (hash-ref (resource-health-result-details health) "port") "COM7"))

  (test-case "system serial factory rejects wrong capability"
    (define message
      (validation-message
       (lambda ()
         (((driver-factory-create (make-system-serial-resource-factory))
           "uart.ecu"
           (resource "system-serial" (list "flash") (hasheq)))))))
    (check-true (and message (string-contains? (string-foldcase message) "serial"))
                (format "message: ~a" message)))

  (test-case "system serial factory validates settings"
    (define factory (make-system-serial-resource-factory))
    (define (create settings)
      (validation-message
       (lambda ()
         ((driver-factory-create factory)
          "uart.ecu"
          (resource "system-serial" (list "serial") settings)))))
    (check-true (string-contains? (create (hasheq 'baud -5)) "invalid serial baud"))
    (check-true (string-contains? (create (hasheq 'port "COM7" 'newLine "")) "newLine cannot be empty"))
    (check-true (string-contains? (create (hasheq 'port "COM7" 'maxBufferedLines 10))
                                  "maxBufferedLines must be between 64 and 100000"))
    (check-true (string-contains? (create (hasheq 'port 7)) "must be a string")))

  (test-case "serial line buffer splits on CR and LF and keeps the partial line"
    (define ch (make-system-serial-channel #f 115200 "\n" 4096))
    (serial-consume-chunk! ch "abc\ndef\r\npartial")
    (check-equal? (unbox (system-serial-channel-lines-box ch)) (list "abc" "def"))
    (check-equal? (unbox (system-serial-channel-partial-box ch)) "partial")
    ;; The trailing partial line flushes on the next boundary.
    (serial-consume-chunk! ch "\r\n")
    (check-equal? (unbox (system-serial-channel-lines-box ch))
                  (list "abc" "def" "partial")))

  (test-case "serial line buffer is bounded to the newest maxBufferedLines"
    (define ch (make-system-serial-channel #f 115200 "\n" 2))
    (serial-consume-chunk! ch "one\ntwo\nthree\n")
    (check-equal? (unbox (system-serial-channel-lines-box ch)) (list "two" "three")))

  (test-case "serial wait without an open channel is a device error"
    (define ch (make-system-serial-channel "COM7" 115200 "\n" 4096))
    (define wait (sc-wait ch "Ready" 50 #f))
    (check-false (serial-wait-result-ok wait))
    (check-true (string-contains? (serial-wait-result-error wait) "not open"))
    (define send (sc-send ch "hi" #f))
    (check-false (serial-send-result-ok send)))

  ;; ---------------------------------------------------------------------------
  ;; DriverFactoryTests / CanUdsResourceFactory: can-iso-tp
  ;; ---------------------------------------------------------------------------

  (define (make-can-iso-tp-instance settings)
    ((driver-factory-create (make-can-iso-tp-resource-factory))
     "can.ecu"
     (resource "can-iso-tp" (list "diagnostics") settings)))

  (test-case "can-iso-tp factory requires request and response ids"
    (check-true (string-contains? (validation-message (lambda () (make-can-iso-tp-instance (hasheq 'interface "can0"))))
                                  "requestId"))
    (check-true (string-contains?
                 (validation-message
                  (lambda () (make-can-iso-tp-instance (hasheq 'interface "can0" 'requestId "0x7E0"))))
                 "responseId")))

  (test-case "can-iso-tp factory needs a transport setting"
    (check-true
     (string-contains?
      (validation-message (lambda () (make-can-iso-tp-instance (hasheq 'requestId "0x7E0" 'responseId "0x7E8"))))
      "needs 'interface'")))

  (test-case "can-iso-tp transport selection follows the platform"
    (cond
      [linux?
       (define instance
         (make-can-iso-tp-instance (hasheq 'interface "can0" 'requestId "0x7E0" 'responseId "0x7E8")))
       (check-true (diag-channel? instance))
       (check-true
        (string-contains?
         (validation-message
          (lambda () (make-can-iso-tp-instance (hasheq 'pcanChannel 81 'requestId "0x7E0" 'responseId "0x7E8"))))
         "needs 'interface'"))]
      [(eq? (system-path-convention-type) 'windows)
       (define instance
         (make-can-iso-tp-instance (hasheq 'pcanChannel 81 'requestId "0x7E0" 'responseId "0x7E8")))
       (check-true (diag-channel? instance))
       (check-true
        (string-contains?
         (validation-message
          (lambda () (make-can-iso-tp-instance (hasheq 'interface "can0" 'requestId "0x7E0" 'responseId "0x7E8"))))
         "needs 'pcanChannel'"))]
      [else
       ;; macOS: both transports are platform-mismatched by construction.
       (check-true
        (string-contains?
         (validation-message
          (lambda () (make-can-iso-tp-instance (hasheq 'interface "can0" 'requestId "0x7E0" 'responseId "0x7E8"))))
         "needs 'pcanChannel'"))
       (check-true
        (string-contains?
         (validation-message
          (lambda () (make-can-iso-tp-instance (hasheq 'pcanChannel 81 'requestId "0x7E0" 'responseId "0x7E8"))))
         "needs 'interface'"))]))

  ;; ---------------------------------------------------------------------------
  ;; SocketCAN wire-frame codec (pure; runs on every OS)
  ;; ---------------------------------------------------------------------------

  (test-case "socketcan wire frame round trips standard and extended ids"
    (define std (can-frame #x7E0 #f (list 2 1 0 3)))
    (define decoded (can-frame-try-decode (can-frame-encode std)))
    (check-equal? decoded std)
    (define ext (can-frame #x18FF0102 #t (list 9 8 7)))
    (define decoded-ext (can-frame-try-decode (can-frame-encode ext)))
    (check-equal? decoded-ext ext)
    (define buffer (can-frame-encode std))
    (check-equal? (bytes-length buffer) 16)
    (check-equal? (bytes-ref buffer 4) 4)
    (check-equal? (bytes->list (subbytes buffer 8 12)) (list 2 1 0 3)))

  (test-case "socketcan decode rejects RTR frames and illegal DLC"
    (define rtr (make-bytes 16 0))
    (integer->integer-bytes #x40000123 4 #f #f rtr 0)
    (bytes-set! rtr 4 2)
    (check-false (can-frame-try-decode rtr))
    (define bad-dlc (can-frame-encode (can-frame #x123 #f (list 1))))
    (bytes-set! bad-dlc 4 9)
    (check-false (can-frame-try-decode bad-dlc)))

  ;; ---------------------------------------------------------------------------
  ;; ScpiPowerTests: health check and factory validation
  ;; ---------------------------------------------------------------------------

  (define (make-fake-scpi-server responses)
    (define-values (listener port)
      (let probe ()
        (define candidate (+ 44800 (random 1000)))
        (with-handlers ([exn:fail:network? (lambda (_) (probe))])
          (define l (tcp-listen candidate 8 #t))
          (values l candidate))))
    (define commands-box (box '()))
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
    (lambda (msg)
      (case msg
        [(port) port]
        [(commands) (unbox commands-box)]
        [(close) (tcp-close listener) (kill-thread server-thread)])))

  (test-case "health check uses identify query without changing output state"
    (define server (make-fake-scpi-server (hash "*IDN?" "BenchCo,PSU-1,1234,1.0")))
    (define supply
      (make-scpi-power-driver
       (scpi-power-settings "127.0.0.1" (server 'port) 3000 2000 1.5 #f default-scpi-commands)))
    (define result (check-health supply #f))
    (check-true (resource-health-result-ok result) (or (resource-health-result-error result)
                                                       (resource-health-result-summary result)))
    (check-equal? (hash-ref (resource-health-result-details result) "idn")
                  "BenchCo,PSU-1,1234,1.0")
    (check-false (ps-on? supply))
    (define commands (server 'commands))
    (check-not-false (member "*IDN?" commands))
    (check-false (member "OUTP ON" commands))
    (check-false (member "OUTP OFF" commands))
    (server 'close))

  (test-case "scpi factory requires host and power capability"
    (define factory (make-scpi-power-resource-factory))
    (check-true
     (string-contains?
      (validation-message
       (lambda ()
         ((driver-factory-create factory)
          "psu" (resource "scpi-power" (list "power") (hasheq)))))
      "host"))
    (check-true
     (string-contains?
      (string-foldcase
       (validation-message
        (lambda ()
          ((driver-factory-create factory)
           "psu" (resource "scpi-power" (list "serial") (hasheq 'host "127.0.0.1"))))))
      "power")))

  (test-case "scpi factory rejects multiline command templates"
    (check-true
     (string-contains?
      (validation-message
       (lambda ()
         ((driver-factory-create (make-scpi-power-resource-factory))
          "psu"
          (resource "scpi-power"
                    (list "power")
                    (hasheq 'host "127.0.0.1" 'outputOn "OUTP ON\nOUTP OFF")))))
      "single-line")))

  ;; ---------------------------------------------------------------------------
  ;; JLinkProbeDiscoveryTests
  ;; ---------------------------------------------------------------------------

  (define probe-output-3
    (string-append
     "SEGGER J-Link Commander V7.88 ('?' for help)\n"
     "J-Link[0]: Connection: USB, Serial number: 59410000, ProductName: J-Link PLUS, Nickname: Bench-A\n"
     "J-Link[1]: Connection: IP, Serial number: 58012000, ProductName: J-Link REMOTE, ipaddr: 192.168.0.100\n"
     "J-Link[2]: Connection: USB, Serial number: 59410001, ProductName: J-Link EDGE, Nickname: Bench-B\n"))

  (test-case "parser extracts probe identity and optional nickname"
    (define probes (jlink-probe-parse probe-output-3))
    (check-equal? (length probes) 3)
    (check-equal? (jlink-probe-serial-number (first probes)) "59410000")
    (check-equal? (jlink-probe-product-name (first probes)) "J-Link PLUS")
    (check-equal? (jlink-probe-nickname (first probes)) "Bench-A")
    (check-equal? (jlink-probe-connection (second probes)) "IP")
    (check-false (jlink-probe-nickname (second probes)))
    (check-equal? (jlink-probe-nickname (third probes)) "Bench-B"))

  (test-case "evaluation fails when no usb probe is visible"
    (define probes (jlink-probe-parse probe-output-3))
    (define ip-only (filter (lambda (p) (not (string-ci=? (jlink-probe-connection p) "USB"))) probes))
    (define result (jlink-probe-evaluate ip-only #f))
    (check-false (resource-health-result-ok result))
    (check-true (string-contains? (resource-health-result-summary result) "No USB"))
    (check-equal? (hash-ref (resource-health-result-details result) "usbProbeCount") "0"))

  (test-case "evaluation accepts one usb probe without configured serial"
    (define one-usb (list (jlink-probe "USB" "59410000" "J-Link PLUS" #f)))
    (define result (jlink-probe-evaluate one-usb #f))
    (check-true (resource-health-result-ok result))
    (check-equal? (hash-ref (resource-health-result-details result) "selectedSerialNumber") "59410000")
    (check-equal? (hash-ref (resource-health-result-details result) "selectedProduct") "J-Link PLUS")
    (check-equal? (hash-ref (resource-health-result-details result) "targetConnectivityChecked") "false"))

  (test-case "evaluation requires serial number when multiple usb probes are visible"
    (define two-usb (list (jlink-probe "USB" "59410000" "J-Link PLUS" #f)
                          (jlink-probe "USB" "59410001" "J-Link EDGE" "Bench-B")))
    (define result (jlink-probe-evaluate two-usb #f))
    (check-false (resource-health-result-ok result))
    (check-true (string-contains? (resource-health-result-summary result) "2 USB"))
    (check-true (string-contains? (resource-health-result-error result) "serialNumber")))

  (test-case "evaluation accepts exact configured serial among multiple probes"
    (define two-usb (list (jlink-probe "USB" "59410000" "J-Link PLUS" "Bench-A")
                          (jlink-probe "USB" "59410001" "J-Link EDGE" "Bench-B")))
    (define result (jlink-probe-evaluate two-usb "59410001"))
    (check-true (resource-health-result-ok result))
    (check-equal? (hash-ref (resource-health-result-details result) "selectedSerialNumber") "59410001")
    (check-equal? (hash-ref (resource-health-result-details result) "selectedProduct") "J-Link EDGE")
    (check-equal? (hash-ref (resource-health-result-details result) "selectedNickname") "Bench-B"))

  (test-case "evaluation reports configured serial that is not connected"
    (define probes (jlink-probe-parse probe-output-3))
    (define usb (filter (lambda (p) (string-ci=? (jlink-probe-connection p) "USB")) probes))
    (define result (jlink-probe-evaluate usb "999999999"))
    (check-false (resource-health-result-ok result))
    (check-true (string-contains? (resource-health-result-summary result) "999999999"))
    (check-true (string-contains? (resource-health-result-error result) "59410000"))
    (check-true (string-contains? (resource-health-result-error result) "59410001")))

  (test-case "jlink factory requires device setting"
    (check-true
     (string-contains?
      (validation-message
       (lambda ()
         ((driver-factory-create (make-jlink-resource-factory))
          "probe.ecu" (resource "jlink" (list "flash") (hasheq 'interface "SWD")))))
      "device")))

  (test-case "jlink binary requires explicit address before process launch"
    (define bin-file (make-temporary-file "benchpilot-e2e-~a.bin"))
    (display-to-file #"FW" bin-file #:exists 'replace)
    (define driver
      ((driver-factory-create (make-jlink-resource-factory))
       "probe.ecu"
       (resource "jlink" (list "flash") (hasheq 'device "NRF52840_xxAA"))))
    (define result (ft-flash driver (path->string bin-file) #f))
    (check-false (flash-result-ok result))
    (check-true (string-contains? (flash-result-error result) "binAddress"))
    (check-false (string-contains? (flash-result-error result) "Could not start"))
    (with-handlers ([exn:fail? void]) (delete-file bin-file)))

  ;; ---------------------------------------------------------------------------
  ;; DriverFactoryTests: registry
  ;; ---------------------------------------------------------------------------

  (test-case "driver registry rejects unsupported profile driver"
    (define registry (make-driver-registry (list (make-simulator-factory))))
    (define message
      (validation-message
       (lambda ()
         (driver-create registry
                        "mystery"
                        (resource "who-knows" (list "power") (hasheq))))))
    (check-true (and message (string-contains? message "who-knows")))
    (check-true (and message (string-contains? message "Available drivers"))))
)
