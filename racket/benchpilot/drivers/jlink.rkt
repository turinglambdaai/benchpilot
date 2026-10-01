#lang racket/base

;; JLinkFlashTarget.cs + factory + probe doctor port

(require racket/file
         racket/format
         racket/list
         racket/path
         racket/port
         racket/string)

(require benchpilot/core/bench-runtime
         benchpilot/core/contracts
         benchpilot/core/profile)

(provide make-jlink-resource-factory
         (struct-out jlink-probe)
         jlink-probe-parse
         jlink-probe-evaluate)

;; ---- settings parsing ----

(define (jlink-error msg) (raise-validation msg))

(define (parse-jlink-settings resource-id config)
  (unless (member "flash" (bench-resource-capabilities config) string-ci=?)
    (jlink-error
     (format "Resource '~a' uses jlink but does not declare the 'flash' capability." resource-id)))
  (define settings (bench-resource-settings config))
  (define (str key) (let ([v (hash-ref settings key #f)]) (and (string? v) v)))
  (define (int key) (let ([v (hash-ref settings key #f)]) (and v (exact-integer? v) v)))
  (define device (str 'device))
  (unless (and device (not (string-blank? device)))
    (jlink-error (format "Resource '~a' requires jlink setting 'device'." resource-id)))
  (define speed (int 'speedKhz))
  (when (and speed (<= speed 0))
    (jlink-error (format "Resource '~a' speedKhz must be greater than zero." resource-id)))
  (define timeout (int 'timeoutMs))
  (when (and timeout (or (< timeout 1000) (> timeout 1800000)))
    (jlink-error (format "Resource '~a' timeoutMs must be between 1000 and 1800000." resource-id)))
  (define raw-addr (hash-ref settings 'binAddress #f))
  (define bin-addr
    (cond
      [(not raw-addr) #f]
      [(exact-integer? raw-addr) raw-addr]
      [(string? raw-addr)
       (define s (string-trim raw-addr))
       (if (string-blank? s)
           #f
           (let ([h (if (string-prefix? (string-downcase s) "0x") (substring s 2) s)])
             (or (string->number h 16)
                 (jlink-error
                  (format "J-Link setting 'binAddress' must be an integer or hexadecimal string such as '0x80000000'.")))))]
      [else
       (jlink-error
        (format "J-Link setting 'binAddress' must be an integer or hexadecimal string such as '0x80000000'."))]))
  (jlink-settings
   (or (str 'executable) (if (eq? (system-type) 'windows) "JLink.exe" "JLinkExe"))
   device
   (or (str 'interface) "SWD")
   (or (int 'speedKhz) 4000)
   (str 'serialNumber)
   (or (int 'timeoutMs) 120000)
   bin-addr))

(struct jlink-settings (executable device interface speed-khz serial-number timeout-ms bin-address)
  #:transparent)

;; ---- executable resolution ----

(define (resolve-commander-executable configured)
  (if (string-blank? configured)
      #f
      (or (find-executable-path configured)
          (for/first ([candidate (in-list (install-candidates configured))]
                      #:when (file-exists? candidate))
            candidate))))

(define (install-candidates executable)
  (if (eq? (system-type) 'windows)
      (append*
       (for/list ([root (in-list (filter directory-exists?
                                          (list (getenv "ProgramFiles")
                                                (getenv "ProgramFiles(x86)"))))])
         (define segger (build-path root "SEGGER"))
         (if (directory-exists? segger)
             (for/list ([dir (in-list (sort (map path->string (directory-list segger)) string>?))]
                        #:when (string-prefix? (string-upcase dir) "JLINK"))
               (path->string (build-path segger dir executable)))
             (list))))
      (list (path->string (build-path "/usr/bin" executable))
            (path->string (build-path "/usr/local/bin" executable))
            (path->string (build-path "/opt/SEGGER/JLink" executable)))))

;; ---- commander run ----

(struct commander-run (ok error output) #:transparent)

(define (tail-output s)
  (define trimmed (string-trim s))
  (cond
    [(string-blank? trimmed) "No output was produced."]
    [(<= (string-length trimmed) 3000) trimmed]
    [else (substring trimmed (- (string-length trimmed) 3000))]))

(define (run-commander settings commands)
  (define executable (resolve-commander-executable (jlink-settings-executable settings)))
  (unless executable
    (jlink-error
     (format "Could not resolve '~a'. Install the SEGGER J-Link Software and Documentation Pack or configure settings.executable."
             (jlink-settings-executable settings))))
  (define cmd-file (make-temporary-file "benchpilot-jlink-~a.jlink"))
  (define output (open-output-string))
  (define done-sem (make-semaphore))
  (define proc-box (box #f))
  (dynamic-wind
   (lambda ()
     (display-lines-to-file commands cmd-file #:mode 'text #:exists 'replace))
   (lambda ()
     (define args
       (append (list executable)
               (list "-Device" (jlink-settings-device settings))
               (list "-If" (jlink-settings-interface settings))
               (list "-Speed" (~a (jlink-settings-speed-khz settings)))
               (list "-AutoConnect" "1")
               (list "-ExitOnError" "1")
               (list "-NoGui" "1")
               (if (jlink-settings-serial-number settings)
                   (list "-USB" (jlink-settings-serial-number settings))
                   null)
               (list "-CommandFile" cmd-file)))
     (thread
      (lambda ()
        (with-handlers ([exn:fail? void])
          ;; subprocess returns (proc stdout stdin stderr).
          (define-values (p child-stdout child-stdin child-stderr)
            (apply subprocess #f #f #f args))
          (set-box! proc-box p)
          (close-output-port child-stdin)
          (copy-port child-stdout output)
          (copy-port child-stderr output)
          (subprocess-wait p)
          (semaphore-post done-sem)))))
   (lambda ()
     (with-handlers ([exn:fail? void]) (delete-file cmd-file))))
  (if (sync/timeout (/ (jlink-settings-timeout-ms settings) 1000.0) done-sem)
      (let ([p (unbox proc-box)])
        (if (and p (zero? (subprocess-status p)))
            (commander-run #t #f (get-output-string output))
            (commander-run #f
                           (format "J-Link Commander exited with code ~a. ~a"
                                   (if p (subprocess-status p) -1)
                                   (tail-output (get-output-string output)))
                           (get-output-string output))))
      (commander-run #f
                     (format "J-Link Commander timed out after ~a ms."
                             (jlink-settings-timeout-ms settings))
                     (get-output-string output))))

;; ---- flash / reset / health ----

(define (jlink-do-flash settings firmware)
  (cond
    [(string-blank? firmware)
     (flash-result #f 0 0 "Firmware path is empty.")]
    [else
     (define full-path (path->string (simple-form-path firmware)))
     (cond
       [(not (file-exists? full-path))
        (flash-result #f 0 0 (format "Firmware file not found: ~a" full-path))]
       [(ormap (lambda (ch) (string-contains? full-path (string ch)))
               (list (integer->char 13) (integer->char 10) (integer->char 34)))
        (flash-result #f 0 0
                      "Firmware path contains characters unsupported by the J-Link command-file backend.")]
       [else
        (define ext (filename-extension full-path))
        (define is-bin (and ext (string-ci=? ext ".bin")))
        (define bin-addr (jlink-settings-bin-address settings))
        (cond
          [(and is-bin (not bin-addr))
           (flash-result #f 0 0
                         "Flashing a .bin file requires resources.<id>.settings.binAddress so BenchPilot never guesses a target address.")]
          [else
           (define loadfile
             (string-append
              "loadfile \"" full-path "\""
              (if is-bin
                  (format " 0x~a" (string-upcase (~r bin-addr #:base 16)))
                  "")))
           (define started (now-millis))
           (define run (run-commander settings (list "r" "h" loadfile "r" "g" "exit")))
           (define elapsed (- (now-millis) started))
           (if (commander-run-ok run)
               (flash-result #t
                             (min (file-size full-path) 2147483647)
                             (min elapsed 2147483647)
                             #f)
               (flash-result #f 0 (min elapsed 2147483647)
                             (commander-run-error run)))])])]))

(define (jlink-do-reset settings)
  (define run (run-commander settings (list "r" "g" "exit")))
  (if (commander-run-ok run)
      (reset-result #t #f)
      (reset-result #f (commander-run-error run))))

(define (jlink-do-health settings)
  (define executable (resolve-commander-executable (jlink-settings-executable settings)))
  (define base-details
    (hash "configuredExecutable" (jlink-settings-executable settings)
            "device" (jlink-settings-device settings)
            "interface" (jlink-settings-interface settings)
            "speedKhz" (~a (jlink-settings-speed-khz settings))
            "serialNumber" (or (jlink-settings-serial-number settings) "")
            "targetConnectivityChecked" "false"))
  (if (not executable)
      (resource-health-result
       #f "SEGGER J-Link Commander was not found." base-details
       (format "Could not resolve '~a'. Install the SEGGER J-Link Software and Documentation Pack or configure settings.executable."
               (jlink-settings-executable settings)))
      (let ([probe-file (make-temporary-file "benchpilot-jlink-probes-~a.jlink")])
        (dynamic-wind
         (lambda ()
           (display-lines-to-file '("ShowEmuList USB" "exit") probe-file
                                  #:mode 'text #:exists 'replace))
         (lambda ()
           (define args (list executable "-ExitOnError" "1" "-NoGui" "1"
                              "-CommandFile" probe-file))
           (define output (open-output-string))
           (define done-sem (make-semaphore))
           (define proc-box (box #f))
           (thread
            (lambda ()
              (with-handlers ([exn:fail? void])
                (define-values (p child-stdout child-stdin child-stderr)
                  (apply subprocess #f #f #f args))
                (set-box! proc-box p)
                (close-output-port child-stdin)
                (copy-port child-stdout output)
                (copy-port child-stderr output)
                (subprocess-wait p)
                (semaphore-post done-sem))))
           (define probe-timeout (/ (min (jlink-settings-timeout-ms settings) 15000) 1000.0))
           (define enriched
             (hash-set base-details "resolvedExecutable" executable))
           (if (sync/timeout probe-timeout done-sem)
               (let ([p (unbox proc-box)])
                 (if (and p (zero? (subprocess-status p)))
                     (jlink-probe-evaluate
                      (jlink-probe-parse (get-output-string output))
                      (jlink-settings-serial-number settings)
                      (hash-set enriched "probeEnumerationChecked" "true"))
                     (resource-health-result
                      #f "J-Link USB probe enumeration failed."
                      (hash-set enriched "probeEnumerationChecked" "true")
                      (tail-output (get-output-string output)))))
               (resource-health-result
                #f
                (format "J-Link USB probe enumeration timed out after ~a ms."
                        (min (jlink-settings-timeout-ms settings) 15000))
                (hash-set enriched "probeEnumerationChecked" "true")
                (tail-output (get-output-string output)))))
         (lambda ()
           (with-handlers ([exn:fail? void]) (delete-file probe-file)))))))

(define (filename-extension path)
  (define name* (last (string-split (last (string-split path "\\")) "/")))
  (define m (regexp-match #rx"[.][^.]+$" name*))
  (and m (first m)))

;; ---- probe discovery (JLinkProbeDiscovery.cs) ----
;;
;; One probe reported by J-Link Commander's non-destructive ShowEmuList
;; command. The parser tolerates additional fields in future Commander
;; versions while requiring the fields BenchPilot needs for safe selection.

(struct jlink-probe (connection serial-number product-name nickname) #:transparent)

(define (probe-line-fields line)
  ;; "J-Link[0]: Connection: USB, Serial number: 59410000, ..." -> alist
  (define marker (string-index-of line "]:"))
  (if (not marker)
      '()
      (for/list ([segment (in-list (string-split (substring line (+ marker 2)) ","))]
                 #:unless (string-blank? segment)
                 #:do [(define colon (string-index-of segment ":"))]
                 #:when (and colon (> colon 0) (< (add1 colon) (string-length segment))))
        (cons (string-trim (string-downcase (substring segment 0 colon)))
              (string-trim (substring segment (add1 colon)))))))

(define (string-index-of haystack needle)
  (define n (string-length needle))
  (let loop ([i 0])
    (cond
      [(> (+ i n) (string-length haystack)) #f]
      [(string=? (substring haystack i (+ i n)) needle) i]
      [else (loop (add1 i))])))

(define (field-value fields key)
  (cond
    [(assoc key fields) => cdr]
    [else #f]))

(define (jlink-probe-parse output)
  (for/list ([raw-line (in-list (string-split output "\n"))]
             #:do [(define line (string-trim raw-line))]
             #:when (and (>= (string-length line) 7)
                         (string-ci=? (substring line 0 7) "J-Link["))
             #:do [(define fields (probe-line-fields line))]
             #:do [(define connection (field-value fields "connection"))
                   (define serial (field-value fields "serial number"))
                   (define product (field-value fields "productname"))]
             #:unless (or (not connection) (string-blank? connection)
                          (not serial) (string-blank? serial)
                          (not product) (string-blank? product)))
    (jlink-probe connection serial product (field-value fields "nickname"))))

(define (probe-selected-details details probe)
  (define with-product
    (hash-set (hash-set details
                        "selectedSerialNumber" (jlink-probe-serial-number probe))
              "selectedProduct" (jlink-probe-product-name probe)))
  (define nickname (jlink-probe-nickname probe))
  (if (and nickname (not (string-blank? nickname)))
      (hash-set with-product "selectedNickname" nickname)
      with-product))

(define (jlink-probe-evaluate probes configured-serial [base-details #f])
  (define usb
    (filter (lambda (p) (string-ci=? (jlink-probe-connection p) "USB")) probes))
  (define details
    (hash-set (hash-set (hash-set (hash-set (hash-set
                                            (or base-details (hash))
                                            "usbProbeCount" (~a (length usb)))
                                           "discoveredSerialNumbers"
                                           (string-join (map jlink-probe-serial-number usb) ","))
                                  "discoveredProducts"
                                  (string-join (map jlink-probe-product-name usb) ","))
                           "probeEnumerationChecked" "true")
              "targetConnectivityChecked" "false"))
  (cond
    [(null? usb)
     (resource-health-result
      #f
      "No USB J-Link probe was enumerated."
      details
      "J-Link Commander is installed, but ShowEmuList USB did not report any USB probe.")]
    [(and configured-serial (not (string-blank? configured-serial)))
     (define match
       (findf (lambda (p)
                (string-ci=? (jlink-probe-serial-number p) configured-serial))
              usb))
     (if (not match)
         (resource-health-result
          #f
          (format "Configured J-Link serial number '~a' is not connected."
                  configured-serial)
          details
          (format "Connected USB J-Link serial numbers: ~a."
                  (string-join (map jlink-probe-serial-number usb) ", ")))
         (resource-health-result
          #t
          (format "Configured J-Link probe ~a (~a) is visible over USB."
                  (jlink-probe-serial-number match)
                  (jlink-probe-product-name match))
          (probe-selected-details details match)
          #f))]
    [(> (length usb) 1)
     (resource-health-result
      #f
      (format "~a USB J-Link probes are connected, but no serialNumber is configured."
              (length usb))
      details
      "Configure resources.<id>.settings.serialNumber so automated flashing selects one probe deterministically.")]
    [else
     (resource-health-result
      #t
      (format "One J-Link probe ~a (~a) is visible over USB."
              (jlink-probe-serial-number (car usb))
              (jlink-probe-product-name (car usb)))
      (probe-selected-details details (car usb))
      #f)]))

;; ---- driver struct ----

(struct jlink-driver (settings)
  #:methods gen:flash-target
  [(define (ft-flash d firmware cancel)
     (jlink-do-flash (jlink-driver-settings d) firmware))
   (define (ft-reset d cancel)
     (jlink-do-reset (jlink-driver-settings d)))]
  #:methods gen:resource-health-check
  [(define (check-health d cancel)
     (jlink-do-health (jlink-driver-settings d)))])

(define (make-jlink-resource-factory)
  (driver-factory "jlink"
                  (lambda (resource-id config)
                    (jlink-driver (parse-jlink-settings resource-id config)))))
