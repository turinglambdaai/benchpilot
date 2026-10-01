#lang racket/base

;; SystemSerialChannel.cs + SystemSerialResourceFactory.cs port: stateful
;; serial console. The resource owns one OS handle, keeps a bounded line
;; buffer locally and exposes semantic WaitFor / ReadWindow operations so
;; agents do not consume an unbounded raw stream.
;;
;; POSIX talks to libc directly (open/read/write + termios; macOS and Linux
;; struct layouts and flag values dispatch at open time). Windows talks to
;; kernel32 (CreateFileW/SetCommState/ReadFile). Both feed the same bounded
;; line-buffer state machine, and nothing below the gen:serial-channel
;; surface leaks platform detail.
;;
;; The OS handle opens lazily on the first Open, never at factory time.

(require ffi/unsafe
         racket/format
         racket/generic
         racket/list
         racket/string)

(require benchpilot/core/contracts
         benchpilot/core/bench-runtime
         benchpilot/core/profile
         benchpilot/core/runtime-state)

(provide (struct-out system-serial-channel)
         make-system-serial-channel
         make-system-serial-resource-factory
         serial-consume-chunk!
         serial-discover-ports)

(define darwin?
  (and (eq? (system-path-convention-type) 'unix)
       (regexp-match? #rx"macosx" (format "~a" (system-library-subpath)))))

;; ----------------------------------------------------------------------------
;; Channel: one OS handle, a bounded line buffer, semantic operations
;; ----------------------------------------------------------------------------

(struct system-serial-channel
  (default-port default-baud new-line max-buffered-lines
   port-gate line-gate
   lines-box partial-box
   open-port-box open-baud-box handle-box
   stop-box pump-thread-box)
  #:methods gen:serial-channel
  [(define (sc-open ch port baud cancel)
     (when cancel
       (when (sync/timeout 0 (cancel-evt cancel))
         (raise (make-cancelled-error))))
     (define requested-port
       (if (and port (not (string-blank? port)))
           port
           (system-serial-channel-default-port ch)))
     (define resolved-port
       (and requested-port (not (string-blank? requested-port)) requested-port))
     (define resolved-baud (or baud (system-serial-channel-default-baud ch)))
     (cond
       [(not resolved-port)
        (serial-open-result
         #f "" resolved-baud
         "No serial port was configured. Set resources.<id>.settings.port or pass an explicit override."
         #f)]
       [(<= resolved-baud 0)
        (serial-open-result #f resolved-port resolved-baud
                            "Baud must be greater than zero." #f)]
       [else
        (with-port-gate
         ch
         (lambda ()
           (if (and (channel-open? ch)
                    (string-ci=? (unbox (system-serial-channel-open-port-box ch)) resolved-port)
                    (= (unbox (system-serial-channel-open-baud-box ch)) resolved-baud))
               (serial-open-result #t resolved-port resolved-baud #f #f)
               (begin
                 (close-port-locked! ch)
                 (clear-buffer! ch)
                 (with-handlers
                     ([exn:fail?
                       (lambda (e)
                         (close-port-locked! ch)
                         (serial-open-result #f resolved-port resolved-baud
                                             (exn-message e) #f))])
                   (platform-open! ch resolved-port resolved-baud)
                   (serial-open-result #t resolved-port resolved-baud #f #f))))))]))

   (define (sc-wait ch pattern timeout-ms cancel)
     (define start (now-millis))
     (if (not (channel-open? ch))
         (serial-wait-result #f #f #f 0 "Serial channel is not open." #f)
         (let loop ()
           (define matched-line (find-matching-line ch pattern))
           (cond
             [matched-line
              (serial-wait-result #t #t matched-line (- (now-millis) start) #f #f)]
             [(>= (- (now-millis) start) timeout-ms)
              (serial-wait-result #t #f #f (- (now-millis) start) #f #f)]
             [else
              (if cancel
                  (when (sync/timeout 0.025 (cancel-evt cancel))
                    (raise (make-cancelled-error)))
                  (sleep 0.025))
              (loop)]))))

   (define (sc-window ch lines filter cancel)
     (if (not (channel-open? ch))
         (serial-window-result #f '() "Serial channel is not open." #f)
         (let ()
           (define snapshot (lines-snapshot ch))
           (define filtered
             (if (and filter (not (string-blank? filter)))
                 (for/list ([line (in-list snapshot)]
                            #:when (string-contains-ci? line filter))
                   line)
                 snapshot))
           (define take (min (max 1 (min lines (system-serial-channel-max-buffered-lines ch)))
                             (length filtered)))
           (serial-window-result #t (take-right filtered take) #f #f))))

   (define (sc-send ch data cancel)
     (if (not (channel-open? ch))
         (serial-send-result #f "Serial channel is not open." #f)
         (with-port-gate
          ch
          (lambda ()
            (with-handlers ([exn:fail? (lambda (e) (serial-send-result #f (exn-message e) #f))])
              (platform-send! ch data)
              (serial-send-result #t #f #f))))))
   (define (sc-open? ch)
     (channel-open? ch))]
  #:methods gen:resource-health-check
  [(define (check-health ch cancel)
     (cond
       [(channel-open? ch)
        (resource-health-result
         #t
         "Serial channel is already open."
         (hash "port" (unbox (system-serial-channel-open-port-box ch))
                 "baud" (~a (unbox (system-serial-channel-open-baud-box ch)))
                 "open" "true")
         #f)]
       [(not (system-serial-channel-default-port ch))
        (resource-health-result
         #f
         "No serial port is configured."
         (hash)
         "Set resources.<id>.settings.port before running preflight.")]
       [else
        (with-handlers
            ([exn:fail?
              (lambda (e)
                (resource-health-result #f
                                        "Could not enumerate serial ports."
                                        (hasheq)
                                        (exn-message e)))])
          (define default-port (system-serial-channel-default-port ch))
          (define discovered (serial-discover-ports))
          (define present
            (or (member default-port discovered string-ci=?)
                (file-exists? default-port)))
          (define ordered (sort discovered string-ci<?))
          (resource-health-result
           present
           (if present
               (format "Configured serial port '~a' is present." default-port)
               (format "Configured serial port '~a' was not found." default-port))
           (hash "port" default-port
                 "baud" (~a (system-serial-channel-default-baud ch))
                   "open" "false"
                   "discoveredPorts"
                   (string-join (take ordered (min 32 (length ordered))) ","))
           (if present
               #f
               (format "Serial port '~a' is not currently visible to the OS." default-port))))]))])

(define (make-system-serial-channel [default-port #f]
                                    [default-baud 115200]
                                    [new-line "\n"]
                                    [max-buffered-lines 4096])
  (system-serial-channel
   (and default-port (not (string-blank? default-port)) default-port)
   default-baud new-line max-buffered-lines
   (make-semaphore 1) (make-semaphore 1)
   (box '()) (box "")
   (box #f) (box #f) (box #f)
   (box #f) (box #f)))

(define (with-port-gate ch proc)
  (semaphore-wait/enable-break (system-serial-channel-port-gate ch))
  (begin0 (proc)
    (semaphore-post (system-serial-channel-port-gate ch))))

(define (with-line-gate ch proc)
  (semaphore-wait/enable-break (system-serial-channel-line-gate ch))
  (begin0 (proc)
    (semaphore-post (system-serial-channel-line-gate ch))))

(define (channel-open? ch)
  (and (unbox (system-serial-channel-handle-box ch)) #t))

(define (string-contains-ci? haystack needle)
  (string-contains? (string-foldcase haystack) (string-foldcase needle)))

;; ----------------------------------------------------------------------------
;; Line buffer (shared state machine; C# ConsumeChunk/EnqueueLine/ClearBuffer)
;; ----------------------------------------------------------------------------

(define (serial-consume-chunk! ch chunk)
  (with-line-gate
   ch
   (lambda ()
     (let loop ([i 0])
       (when (< i (string-length chunk))
         (define c (string-ref chunk i))
         (cond
           [(or (char=? c #\return) (char=? c #\linefeed))
            (define partial (unbox (system-serial-channel-partial-box ch)))
            (unless (string=? partial "")
              (enqueue-line! ch partial)
              (set-box! (system-serial-channel-partial-box ch) ""))
            (loop (add1 i))]
           [else
            (set-box! (system-serial-channel-partial-box ch)
                      (string-append (unbox (system-serial-channel-partial-box ch))
                                     (string c)))
            (loop (add1 i))]))))))

(define (enqueue-line! ch text)
  (define b (system-serial-channel-lines-box ch))
  (define next (append (unbox b) (list text)))
  (set-box! b
            (if (> (length next) (system-serial-channel-max-buffered-lines ch))
                (cdr next)
                next)))

(define (clear-buffer! ch)
  (set-box! (system-serial-channel-lines-box ch) '())
  (set-box! (system-serial-channel-partial-box ch) ""))

(define (lines-snapshot ch)
  (with-line-gate ch (lambda () (unbox (system-serial-channel-lines-box ch)))))

(define (find-matching-line ch pattern)
  (for/first ([line (in-list (lines-snapshot ch))]
              #:when (string-contains-ci? line pattern))
    line))

;; ----------------------------------------------------------------------------
;; Port discovery (health check)
;; ----------------------------------------------------------------------------

(define (serial-discover-ports)
  (case (system-path-convention-type)
    [(windows) (win-discover-ports)]
    [else
     (define names
       (with-handlers ([exn:fail? (lambda (_) '())])
         (for/list ([entry (in-list (directory-list "/dev"))]
                    #:when (regexp-match? #px"^(tty|cu|rfcomm)" (path->string entry)))
           (path->string entry))))
     (sort names string-ci<?)]))

;; ----------------------------------------------------------------------------
;; Platform plumbing
;; ----------------------------------------------------------------------------

(define (platform-open! ch port baud)
  (case (system-path-convention-type)
    [(windows) (win-open! ch port baud)]
    [else (posix-open! ch port baud)]))

(define (platform-send! ch data)
  (define handle (unbox (system-serial-channel-handle-box ch)))
  (define payload
    (string->bytes/utf-8 (string-append data (system-serial-channel-new-line ch))))
  (case (system-path-convention-type)
    [(windows) (win-write-all handle payload)]
    [else (posix-write-all handle payload)]))

(define (start-pump! ch)
  (set-box! (system-serial-channel-stop-box ch) #f)
  (set-box! (system-serial-channel-pump-thread-box ch)
            (thread (lambda ()
                      (case (system-path-convention-type)
                        [(windows) (win-pump ch)]
                        [else (posix-pump ch)])))))

(define (close-port-locked! ch)
  (define handle (unbox (system-serial-channel-handle-box ch)))
  (when handle
    (set-box! (system-serial-channel-stop-box ch) #t)
    (define pump-thread (unbox (system-serial-channel-pump-thread-box ch)))
    (when pump-thread
      (sync/timeout 1.0 (thread-dead-evt pump-thread)))
    (with-handlers ([exn:fail? (lambda (_) (void))])
      (case (system-path-convention-type)
        [(windows) (win-close-handle handle)]
        [else (posix-close-fd handle)]))
    (set-box! (system-serial-channel-handle-box ch) #f)
    (set-box! (system-serial-channel-open-port-box ch) #f)
    (set-box! (system-serial-channel-open-baud-box ch) #f)))

;; ----------------------------------------------------------------------------
;; POSIX backend (libc + termios; macOS and Linux layouts differ)
;; ----------------------------------------------------------------------------

(struct posix-ffi
  (open read write close tcgetattr tcsetattr cfsetispeed cfsetospeed tcflush poll errno-box))

(define posix-ffi-box (box #f))

(define (posix-ffi*)
  (or (unbox posix-ffi-box)
      (let ([f (load-posix-ffi!)])
        (set-box! posix-ffi-box f)
        f)))

(define (load-posix-ffi!)
  (define lib (ffi-lib '("libc.so.6" "libc.dylib")))
  (define errno-box (box 0))
  (posix-ffi
   (get-ffi-obj "open" lib (_fun #:save-errno errno-box _string _int _int -> _int))
   (get-ffi-obj "read" lib (_fun #:save-errno errno-box _int _bytes _int -> _ssize))
   (get-ffi-obj "write" lib (_fun #:save-errno errno-box _int _bytes _int -> _ssize))
   (get-ffi-obj "close" lib (_fun #:save-errno errno-box _int -> _int))
   (get-ffi-obj "tcgetattr" lib (_fun #:save-errno errno-box _int _pointer -> _int))
   (get-ffi-obj "tcsetattr" lib (_fun #:save-errno errno-box _int _int _pointer -> _int))
   (get-ffi-obj "cfsetispeed" lib (_fun #:save-errno errno-box _pointer _int -> _int))
   (get-ffi-obj "cfsetospeed" lib (_fun #:save-errno errno-box _pointer _int -> _int))
   (get-ffi-obj "tcflush" lib (_fun #:save-errno errno-box _int _int -> _int))
   (get-ffi-obj "poll" lib (_fun #:save-errno errno-box _pointer _int _int -> _int))
   errno-box))

;; termios layout and flag constants differ per platform.
(define termios-size (if darwin? 72 60))
(define t-iflag 0)
(define t-oflag (if darwin? 8 4))
(define t-cflag (if darwin? 16 8))
(define t-lflag (if darwin? 24 12))
(define t-cc (if darwin? 32 17))
(define t-ispeed (if darwin? 56 52))
(define t-ospeed (if darwin? 64 56))
(define vmin-index (if darwin? 16 6))
(define vtime-index (if darwin? 17 5))
(define cs8-flag (if darwin? #x300 #x30))
(define cread-flag (if darwin? #x800 #x80))
(define clocal-flag (if darwin? #x8000 #x800))
(define o-rdwr 2)
(define o-noctty (if darwin? #x20000 #o400))
(define tcsanow 0)

;; Baud constants: Linux encodes them into c_cflag's CBAUD field; macOS uses
;; the literal rate.
(define linux-baud-bits
  '((300 . #x7) (600 . #x8) (1200 . #x9) (2400 . #xB) (4800 . #xC)
    (9600 . #xD) (19200 . #xE) (38400 . #xF)
    (57600 . #x1001) (115200 . #x1002) (230400 . #x1003) (460800 . #x1004)
    (500000 . #x1005) (576000 . #x1006) (921600 . #x1007) (1000000 . #x1008)))
(define darwin-bauds
  '(300 600 1200 2400 4800 9600 19200 38400 57600 115200 230400))

(define (posix-baud-code baud)
  (cond
    [darwin?
     (unless (member baud darwin-bauds)
       (raise (exn:fail (format "Unsupported serial baud rate: ~a." baud)
                        (current-continuation-marks))))
     baud]
    [else
     (define bits (assv baud linux-baud-bits))
     (unless bits
       (raise (exn:fail (format "Unsupported serial baud rate: ~a." baud)
                        (current-continuation-marks))))
     (cdr bits)]))

(define (posix-open! ch port baud)
  (define ffi (posix-ffi*))
  (define baud-code (posix-baud-code baud))
  (define fd ((posix-ffi-open ffi) port (+ o-rdwr o-noctty) 0))
  (when (< fd 0)
    (raise (exn:fail (format "Could not open serial port '~a' (errno ~a)."
                             port
                             (lookup-errno (unbox (posix-ffi-errno-box ffi))))
                     (current-continuation-marks))))
  (with-handlers
      ([exn:fail?
        (lambda (e)
          (with-handlers ([exn:fail? (lambda (_) (void))])
            ((posix-ffi-close ffi) fd))
          (raise e))])
    (configure-termios! ffi fd baud baud-code)
    (set-box! (system-serial-channel-handle-box ch) fd)
    (set-box! (system-serial-channel-open-port-box ch) port)
    (set-box! (system-serial-channel-open-baud-box ch) baud)
    (start-pump! ch)))

(define (configure-termios! ffi fd baud baud-code)
  (define buf (make-bytes termios-size 0))
  (when (< ((posix-ffi-tcgetattr ffi) fd buf) 0)
    (raise (exn:fail (format "Could not read terminal settings for the serial port (errno ~a)."
                             (lookup-errno (unbox (posix-ffi-errno-box ffi))))
                     (current-continuation-marks))))
  (if darwin?
      (begin
        (integer->integer-bytes 0 8 #f #f buf t-iflag)
        (integer->integer-bytes 0 8 #f #f buf t-oflag)
        (integer->integer-bytes 0 8 #f #f buf t-lflag)
        (integer->integer-bytes
         (bitwise-ior cs8-flag cread-flag clocal-flag baud-code) 8 #f #f buf t-cflag)
        (bytes-set! buf (+ t-cc vmin-index) 0)
        (bytes-set! buf (+ t-cc vtime-index) 0)
        ((posix-ffi-cfsetispeed ffi) buf baud)
        ((posix-ffi-cfsetospeed ffi) buf baud)
        (integer->integer-bytes baud 8 #f #f buf t-ispeed)
        (integer->integer-bytes baud 8 #f #f buf t-ospeed))
      (begin
        (integer->integer-bytes 0 4 #f #f buf t-iflag)
        (integer->integer-bytes 0 4 #f #f buf t-oflag)
        (integer->integer-bytes 0 4 #f #f buf t-lflag)
        (integer->integer-bytes
         (bitwise-ior cs8-flag cread-flag clocal-flag baud-code) 4 #f #f buf t-cflag)
        (bytes-set! buf (+ t-cc vmin-index) 0)
        (bytes-set! buf (+ t-cc vtime-index) 0)
        (integer->integer-bytes baud-code 4 #f #f buf t-ispeed)
        (integer->integer-bytes baud-code 4 #f #f buf t-ospeed)))
  (when (< ((posix-ffi-tcsetattr ffi) fd tcsanow buf) 0)
    (raise (exn:fail (format "Could not apply serial port settings (errno ~a)."
                             (lookup-errno (unbox (posix-ffi-errno-box ffi))))
                     (current-continuation-marks))))
  ((posix-ffi-tcflush ffi) fd 0))

(define (posix-pump ch)
  (define ffi (posix-ffi*))
  (define fd (unbox (system-serial-channel-handle-box ch)))
  (define buf (make-bytes 4096 0))
  (define pfd (make-bytes 8 0))
  (let loop ()
    (cond
      [(unbox (system-serial-channel-stop-box ch)) (void)]
      [else
       (integer->integer-bytes fd 4 #f #f pfd 0)
       (bytes-set! pfd 4 1)               ; POLLIN
       (bytes-set! pfd 5 0)
       (bytes-set! pfd 6 0)
       (bytes-set! pfd 7 0)
       (define r ((posix-ffi-poll ffi) pfd 1 50))
       (cond
         [(unbox (system-serial-channel-stop-box ch)) (void)]
         [(> r 0)
          (define n ((posix-ffi-read ffi) fd buf 4096))
          (cond
            [(> n 0)
             (serial-consume-chunk!
              ch
              (bytes->string/utf-8 (subbytes buf 0 n) #\uFFFD))
             (loop)]
            [(zero? n)
             (sleep 0.01)
             (loop)]
            [else
             (sleep 0.01)
             (loop)])]
         [else (loop)])])))

(define (posix-write-all fd payload)
  (define ffi (posix-ffi*))
  (let loop ([off 0])
    (when (< off (bytes-length payload))
      (define n ((posix-ffi-write ffi) fd (subbytes payload off) (- (bytes-length payload) off)))
      (when (< n 0)
        (raise (exn:fail "Serial write failed." (current-continuation-marks))))
      (loop (+ off n)))))

(define (posix-close-fd fd)
  ((posix-ffi-close (posix-ffi*)) fd))

;; ----------------------------------------------------------------------------
;; Windows backend (kernel32)
;; ----------------------------------------------------------------------------

(struct win-ffi
  (create-file close-handle set-comm-state set-comm-timeouts read-file write-file
               query-dos-device get-last-error))

(define win-ffi-box (box #f))

(define (win-ffi*)
  (or (unbox win-ffi-box)
      (let ([f (load-win-ffi!)])
        (set-box! win-ffi-box f)
        f)))

(define (load-win-ffi!)
  (define k32 (ffi-lib "kernel32"))
  (win-ffi
   (get-ffi-obj "CreateFileW" k32
                (_fun _string/utf-16 _uint32 _uint32 _pointer
                      _uint32 _uint32 _pointer -> _intptr))
   (get-ffi-obj "CloseHandle" k32 (_fun _intptr -> _int))
   (get-ffi-obj "SetCommState" k32 (_fun _intptr _pointer -> _int))
   (get-ffi-obj "SetCommTimeouts" k32 (_fun _intptr _pointer -> _int))
   (get-ffi-obj "ReadFile" k32 (_fun _intptr _bytes _int (_ptr o _int) _pointer -> _int))
   (get-ffi-obj "WriteFile" k32 (_fun _intptr _bytes _int (_ptr o _int) _pointer -> _int))
   (get-ffi-obj "QueryDosDeviceW" k32 (_fun _string/utf-16 _bytes _int -> _int))
   (get-ffi-obj "GetLastError" k32 (_fun -> _uint32))))

(define generic-read #x80000000)
(define generic-write #x40000000)
(define open-existing 3)
(define invalid-handle -1)

(define (win-device-path port)
  (if (string-prefix? port "\\\\.\\")
      port
      (string-append "\\\\.\\" port)))

(define (win-open! ch port baud)
  (define ffi (win-ffi*))
  (define handle
    ((win-ffi-create-file ffi)
     (win-device-path port)
     (bitwise-and (+ generic-read generic-write) #xFFFFFFFF)
     0 #f open-existing 0 #f))
  (when (= handle invalid-handle)
    (raise (exn:fail (format "Could not open serial port '~a' (Win32 error ~a)."
                             port
                             ((win-ffi-get-last-error ffi)))
                     (current-continuation-marks))))
  (with-handlers
      ([exn:fail?
        (lambda (e)
          (with-handlers ([exn:fail? (lambda (_) (void))])
            ((win-ffi-close-handle ffi) handle))
          (raise e))])
    (define dcb (make-bytes 28 0))
    (integer->integer-bytes 28 4 #f #f dcb 0)          ; DCBlength
    (integer->integer-bytes baud 4 #f #f dcb 4)        ; BaudRate
    (integer->integer-bytes 1 4 #f #f dcb 8)           ; fBinary, no flow control
    (bytes-set! dcb 18 8)                           ; ByteSize
    (bytes-set! dcb 19 0)                           ; Parity = none
    (bytes-set! dcb 20 0)                           ; StopBits = one
    (unless (= 1 ((win-ffi-set-comm-state ffi) handle dcb))
      (raise (exn:fail (format "Could not configure serial port '~a' (Win32 error ~a)."
                               port
                               ((win-ffi-get-last-error ffi)))
                       (current-continuation-marks))))
    (define timeouts (make-bytes 20 0))
    (integer->integer-bytes 50 4 #f #f timeouts 0)     ; ReadIntervalTimeout
    (integer->integer-bytes 0 4 #f #f timeouts 4)      ; ReadTotalTimeoutMultiplier
    (integer->integer-bytes 50 4 #f #f timeouts 8)     ; ReadTotalTimeoutConstant
    (integer->integer-bytes 0 4 #f #f timeouts 12)     ; WriteTotalTimeoutMultiplier
    (integer->integer-bytes 2000 4 #f #f timeouts 16)  ; WriteTotalTimeoutConstant
    (unless (= 1 ((win-ffi-set-comm-timeouts ffi) handle timeouts))
      (raise (exn:fail (format "Could not set serial port timeouts for '~a' (Win32 error ~a)."
                               port
                               ((win-ffi-get-last-error ffi)))
                       (current-continuation-marks))))
    (set-box! (system-serial-channel-handle-box ch) handle)
    (set-box! (system-serial-channel-open-port-box ch) port)
    (set-box! (system-serial-channel-open-baud-box ch) baud)
    (start-pump! ch)))

(define (win-pump ch)
  (define ffi (win-ffi*))
  (define buf (make-bytes 4096 0))
  (let loop ()
    (cond
      [(unbox (system-serial-channel-stop-box ch)) (void)]
      [else
       (define handle (unbox (system-serial-channel-handle-box ch)))
       (define-values (ok n)
         ((win-ffi-read-file ffi) handle buf 4096))
       (cond
         [(unbox (system-serial-channel-stop-box ch)) (void)]
         [(and ok (> n 0))
          (serial-consume-chunk!
           ch
           (bytes->string/utf-8 (subbytes buf 0 n) #\uFFFD))
          (loop)]
         [else
          (sleep 0.005)
          (loop)])])))

(define (win-write-all handle payload)
  (define ffi (win-ffi*))
  (let loop ([off 0])
    (when (< off (bytes-length payload))
      (define-values (ok n)
        ((win-ffi-write-file ffi) handle (subbytes payload off) (- (bytes-length payload) off)))
      (unless (and ok (> n 0))
        (raise (exn:fail "Serial write failed." (current-continuation-marks))))
      (loop (+ off n)))))

(define (win-close-handle handle)
  ((win-ffi-close-handle (win-ffi*)) handle))

(define (win-discover-ports)
  (define ffi (win-ffi*))
  (define buf (make-bytes 1024 0))
  (for/list ([i (in-range 1 256)]
             #:do
             [(define name (format "COM~a" i))
              (define n ((win-ffi-query-dos-device ffi) name buf 1024))]
             #:when (> n 0))
    name))

;; ----------------------------------------------------------------------------
;; Construction (SystemSerialResourceFactory)
;; ----------------------------------------------------------------------------

(define (make-system-serial-resource-factory)
  (driver-factory
   "system-serial"
   (lambda (resource-id config)
     (unless (member "serial" (bench-resource-capabilities config) string-ci=?)
       (raise-validation
        (format "Resource '~a' uses system-serial but does not declare the 'serial' capability."
                resource-id)))
     (define settings (bench-resource-settings config))
     (define (get-string key)
       (define v (hash-ref settings key #f))
       (when (and v (not (string? v)))
         (raise-validation (format "Serial setting '~a' must be a string." key)))
       v)
     (define (get-int key)
       (define v (hash-ref settings key #f))
       (when (and v (not (and (real? v) (integer? v) (<= v 2147483647))))
         (raise-validation (format "Serial setting '~a' must be an integer." key)))
       (and v (inexact->exact (truncate v))))
     (define port (get-string 'port))
     (define baud (or (get-int 'baud) 115200))
     (define new-line (or (get-string 'newLine) "\n"))
     (define max-buffered-lines (or (get-int 'maxBufferedLines) 4096))
     (when (<= baud 0)
       (raise-validation (format "Resource '~a' has invalid serial baud ~a." resource-id baud)))
     ;; C# parity: string.IsNullOrEmpty, not IsNullOrWhiteSpace.
     (when (= (string-length new-line) 0)
       (raise-validation (format "Resource '~a' newLine cannot be empty." resource-id)))
     (when (or (< max-buffered-lines 64) (> max-buffered-lines 100000))
       (raise-validation
        (format "Resource '~a' maxBufferedLines must be between 64 and 100000." resource-id)))
     (make-system-serial-channel port baud new-line max-buffered-lines))))
