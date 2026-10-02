#lang racket/base

;; BenchClient.cs + RuntimeAutoStart.cs + Program.cs (CLI) port: the
;; benchpilot CLI — a thin JSON client of the resident runtime with the
;; stable exit-code contract, one-retry autostart and the doctor check.

(require json
         net/base64
         racket/format
         racket/list
         racket/port
         racket/set
         racket/string
         racket/tcp)

(require benchpilot/core/contracts
         benchpilot/core/profile
         racket/file
         racket/path
         benchpilot/client/html-report
         benchpilot/client/updater
         benchpilot/diagnostics/flash/engine
         benchpilot/diagnostics/uds/protocol
         benchpilot/protocol/local-auth)

(provide bench-client-run!
         parse-cli-args
         last-printed-box
         resolve-endpoint
         api-call
         require-ok
         try-autostart
         (struct-out exn:benchpilot:network)
         (struct-out bench-client-error)
         benchpilot-version)

;; ----------------------------------------------------------------------------
;; Errors: code → exit code, mirroring the C# BenchClientException switch.
;; ----------------------------------------------------------------------------

(struct bench-client-error
        (code message status-code operation-id busy-scope busy-id deadline-ms deadline-at-utc)
  #:transparent)

(define (error-exit-code e)
  ;; codes are strings on the wire; case datums are symbols.
  (case (string->symbol (bench-client-error-code e))
    [(busy) 5]
    [(deadline_exceeded) 6]
    [(cancelled) 1]
    [(runtime_state) 4]
    [(unauthorized) 4]
    [else
     (case (bench-client-error-status-code e)
       [(400) 2]
       [(404) 3]
       [else 1])]))

(define (validation-error message)
  (exn:benchpilot:validation message (current-continuation-marks)))

(define (raise-validation message)
  (raise (validation-error message)))

;; ----------------------------------------------------------------------------
;; CLI arguments (CliArguments): long options, `--opt value` or `--opt=value`,
;; and the flag set. Option lookup is case-insensitive like the C# dictionary.
;; ----------------------------------------------------------------------------

(struct cli-args (positionals options))

(define cli-flags (set 'json 'help 'version 'check 'format))

(define (parse-cli-args args)
  (define positionals '())
  (define options (make-hash))
  (let loop ([i 0])
    (when (< i (length args))
      (define token (list-ref args i))
      (if (string-prefix? token "--")
          (let* ([option (substring token 2)]
                 [eq (string-index-of option #\=)])
            (cond
              [(and eq (> eq 0))
               (hash-set! options
                          (string-downcase (substring option 0 eq))
                          (substring option (add1 eq)))
               (loop (add1 i))]
              [(set-member? cli-flags (string->symbol (string-downcase option)))
               (hash-set! options (string-downcase option) #t)
               (loop (add1 i))]
              [(or (>= (add1 i) (length args)) (string-prefix? (list-ref args (add1 i)) "--"))
               (raise-validation (format "Option --~a requires a value." option))]
              [else
               (hash-set! options (string-downcase option) (list-ref args (add1 i)))
               (loop (+ i 2))]))
          (begin
            (set! positionals (append positionals (list token)))
            (loop (add1 i))))))
  (cli-args positionals options))

(define (string-index-of s ch)
  (or (for/first ([c (in-string s)]
                  [i (in-naturals)]
                  #:when (char=? c ch))
        i)
      -1))

(define (arg-name name)
  (string-downcase (if (symbol? name)
                       (symbol->string name)
                       name)))
(define (args-flag a name)
  (hash-has-key? (cli-args-options a) (arg-name name)))
(define (args-get a name)
  (hash-ref (cli-args-options a) (arg-name name) #f))
(define (args-positional a index)
  (and (< index (length (cli-args-positionals a))) (list-ref (cli-args-positionals a) index)))

(define (args-int-opt args name)
  (define v (args-get args (arg-name name)))
  (and v (or (string->number v) (raise-validation (format "Option --~a must be an integer." name)))))
(define (args-real-opt args name)
  (define v (args-get args (arg-name name)))
  (and v (or (string->number v) (raise-validation (format "Option --~a must be a number." name)))))
(define (args-hex-opt args name)
  (define v (args-get args (arg-name name)))
  (and v (parse-hex-or-dec v)))
(define (parse-hex-or-dec text)
  (define cleaned (string-trim text))
  (if (string-prefix? (string-downcase cleaned) "0x")
      (string->number (substring cleaned 2) 16)
      (string->number cleaned)))

;; ----------------------------------------------------------------------------
;; HTTP client (loopback, one request per connection)
;; ----------------------------------------------------------------------------

(define (resolve-endpoint override)
  (define text (or override (getenv "BENCHPILOT_ENDPOINT") ""))
  (define text* (if (string-blank? text) "http://127.0.0.1:5640/" text))
  (define m (regexp-match #px"^http://([^/:]+)(?::([0-9]+))?/?$" text*))
  (unless m
    (raise-validation (format "Invalid BENCHPILOT_ENDPOINT: ~a" text*)))
  (values (second m) (or (and (third m) (string->number (third m))) 5640)))

(struct exn:benchpilot:network exn:benchpilot () #:transparent)
(define (make-network-error message)
  (exn:benchpilot:network message (current-continuation-marks)))

(define (uri-encode-value v)
  (define s
    (if (string? v)
        v
        (format "~a" v)))
  (list->string
   (append* (for/list ([c (in-string s)])
              (if (or (char-alphabetic? c) (char-numeric? c) (member c '(#\- #\_ #\. #\~)))
                  (list c)
                  (let* ([code (char->integer c)]
                         [hex (string-upcase (~r code #:base 16 #:min-width 2 #:pad-string "0"))])
                    (list #\% (string-ref hex 0) (string-ref hex 1))))))))

;; Performs one API call; returns (values status body-jsexpr). Raises
;; exn:benchpilot:network on connection failures (the autostart trigger).
(define (api-call host port method api-path query body)
  (define token (read-token))
  (define query-string
    (string-join (for/list ([pair (in-hash-pairs query)])
                   (format "~a=~a" (car pair) (uri-encode-value (cdr pair))))
                 "&"))
  (define target
    (string-append "/api/v1"
                   api-path
                   (if (string-blank? query-string)
                       ""
                       (string-append "?" query-string))))
  (define body-bytes
    (if body
        (jsexpr->bytes body)
        #""))

  (with-handlers ([exn:fail:network? (lambda (e) (raise (make-network-error (exn-message e))))]
                  [exn:fail:filesystem? (lambda (e) (raise (make-network-error (exn-message e))))])
    (define-values (in out) (tcp-connect host port))
    (dynamic-wind (lambda () void)
                  (lambda ()
                    (fprintf out "~a ~a HTTP/1.1\r\n" method target)
                    (fprintf out "Host: ~a:~a\r\n" host port)
                    (when token
                      (fprintf out "X-Benchpilot-Token: ~a\r\n" token))
                    (fprintf out "Content-Type: application/json\r\n")
                    (fprintf out "Content-Length: ~a\r\n" (bytes-length body-bytes))
                    (fprintf out "Connection: close\r\n\r\n")
                    (unless (zero? (bytes-length body-bytes))
                      (write-bytes body-bytes out))
                    (flush-output out)

                    (define status-line (read-line in 'return-linefeed))
                    (when (eof-object? status-line)
                      (raise (make-network-error "Connection closed before a response arrived.")))
                    (define status
                      (let ([m (regexp-match #px"HTTP/1\\.[01] ([0-9]{3})" status-line)])
                        (or (and m (string->number (second m)))
                            (raise (make-network-error (format "Malformed HTTP status line: ~a"
                                                               status-line))))))
                    (let headers-loop ()
                      (define line (read-line in 'return-linefeed))
                      (unless (or (eof-object? line) (string-blank? line))
                        (headers-loop)))
                    (define body-result (port->bytes* in))
                    (values status
                            (with-handlers ([exn:fail? (lambda (_) (hasheq))])
                              (if (zero? (bytes-length body-result))
                                  (hasheq)
                                  (read-json (open-input-bytes body-result))))))
                  (lambda ()
                    (with-handlers ([exn:fail? void])
                      (close-input-port in)
                      (close-output-port out))))))

(define (port->bytes* in)
  (define out (open-output-bytes))
  (copy-port in out)
  (get-output-bytes out))

;; Raises a typed client error for non-2xx API responses.
(define (require-ok status body)
  (if (and (>= status 200) (< status 300))
      body
      (raise (bench-client-error (body-string-field body 'code "unknown")
                                 (body-string-field body 'error "Request failed.")
                                 status
                                 (opt-string body 'operationId)
                                 (opt-string body 'busyScope)
                                 (opt-string body 'busyId)
                                 (let ([v (hash-ref body 'deadlineMs #f)]) (and (exact-integer? v) v))
                                 (opt-string body 'deadlineAtUtc)))))

(define (body-string-field body key default)
  (define v (hash-ref body key #f))
  (if (or (not v) (eq? v 'null)) default v))
(define (opt-string body key)
  (define v (hash-ref body key #f))
  (and v (not (eq? v 'null)) v))

;; ----------------------------------------------------------------------------
;; Autostart (RuntimeAutoStart)
;; ----------------------------------------------------------------------------

(define (autostart-disabled?)
  (equal? (getenv "BENCHPILOT_AUTOSTART") "0"))

(define (resolve-daemon-path)
  (define self (find-system-path 'run-file))
  (define dir (path-only self))
  (define exe-name (if (eq? (system-type) 'windows) "benchpilotd.exe" "benchpilotd"))
  (define candidate
    (and dir
         (let ()
           (define exe (build-path dir exe-name))
           (define rkt (build-path dir "benchpilotd.rkt"))
           (cond [(file-exists? exe) exe]
                 [(file-exists? rkt) rkt]
                 [else #f]))))
  (or (and candidate (path->string candidate))
      (let ([p (find-executable-path exe-name)]) (and p (path->string p)))))

(define (try-autostart host port)
  (and (not (autostart-disabled?))
       (let ([daemon (resolve-daemon-path)])
         (when daemon
           (define log-dir (local-auth-log-directory))
           (make-directory* log-dir)
           (define log-file (build-path log-dir "autostart.log"))
           (define log-out
             (with-handlers ([exn:fail? (lambda (_) (open-output-nowhere))])
               (open-output-file log-file #:mode 'text #:exists 'append)))
           ;; Spawn detached: the daemon detaches console handles itself
           ;; under BENCHPILOT_QUIET, so the parent's readers see EOF. A
           ;; staged .rkt daemon (E2E) runs through the racket binary.
           (define racket-exe (or (find-executable-path "racket")
                                  (find-system-path 'exec-file)))
           (define-values (spawn-cmd spawn-args)
             (if (regexp-match? #rx"[.]rkt$" daemon)
                 (values racket-exe (list daemon))
                 (values daemon '())))
           (define-values (p daemon-stdout daemon-stdin daemon-stderr)
             (apply subprocess #f #f log-out spawn-cmd spawn-args))
           ;; Streams the parent inherited arrive as #f.
           (when daemon-stdout (close-input-port daemon-stdout))
           (when daemon-stdin (close-output-port daemon-stdin))
           (when daemon-stderr (close-input-port daemon-stderr))
           (close-output-port log-out)
           ;; Wait for the endpoint to answer (up to ~5 s).
           (let wait ([attempts 50])
             (sleep 0.1)
             (or (with-handlers ([exn:fail? (lambda (_) #f)])
                   (define-values (in out) (tcp-connect host port))
                   (close-input-port in)
                   (close-output-port out)
                   #t)
                 (and (> attempts 0) (wait (sub1 attempts)))))))))

;; ----------------------------------------------------------------------------
;; Print: default output is indented JSON; --json is the compact form.
;; ----------------------------------------------------------------------------

;; The most recent payload, for exit-code decisions (matched/passed/ready).
(define last-printed-box (box (hasheq)))

(define (print-result value compact)
  (define jsexpr (api->jsexpr-or-value value))
  (set-box! last-printed-box jsexpr)
  (define s (jsexpr->string jsexpr))
  (if compact
      (displayln s)
      (displayln (pretty-json s))))

(define (api->jsexpr-or-value value)
  (cond
    [(hash? value) value]
    [(doctor-report? value) (doctor->jsexpr value)]
    [(struct? value) (api->jsexpr value)]
    [else value]))

(define (pretty-json s)
  ;; Indented re-render via read+custom writer.
  (define v (read-json (open-input-string s)))
  (define out (open-output-string))
  (let loop ([v v]
             [indent 0])
    (cond
      [(hash? v)
       (if (zero? (hash-count v))
           (display "{}" out)
           (begin
             (display "{\n" out)
             (for ([pair (in-hash-pairs v)]
                   [i (in-naturals)])
               (display (make-string (* (add1 indent) 2) #\space) out)
               (fprintf out "~s: " (string->symbol (~s (car pair))))
               (loop (cdr pair) (add1 indent))
               (unless (= i (sub1 (hash-count v)))
                 (display "," out))
               (newline out))
             (display (make-string (* indent 2) #\space) out)
             (display "}" out)))]
      [(list? v)
       (if (null? v)
           (display "[]" out)
           (begin
             (display "[\n" out)
             (for ([item (in-list v)]
                   [i (in-naturals)])
               (display (make-string (* (add1 indent) 2) #\space) out)
               (loop item (add1 indent))
               (unless (= i (sub1 (length v)))
                 (display "," out))
               (newline out))
             (display (make-string (* indent 2) #\space) out)
             (display "]" out)))]
      [else (display (jsexpr->string v) out)]))
  (get-output-string out))

(define (doctor->jsexpr report)
  (hasheq 'ok
          (doctor-report-ok report)
          'endpoint
          (doctor-report-endpoint report)
          'cliVersion
          (doctor-report-cli-version report)
          'runtimeReachable
          (doctor-report-runtime-reachable report)
          'runtimeVersion
          (or (doctor-report-runtime-version report) 'null)
          'apiVersion
          (doctor-report-api-version report)
          'statusError
          (or (doctor-report-status-error report) 'null)
          'tokenFound
          (doctor-report-token-found report)
          'tokenPath
          (doctor-report-token-path report)
          'daemonFound
          (doctor-report-daemon-found report)
          'daemonPath
          (or (doctor-report-daemon-path report) 'null)
          'profileName
          (or (doctor-report-profile-name report) 'null)
          'targetCount
          (doctor-report-target-count report)
          'versionMatch
          (doctor-report-version-match report)
          'remediation
          (or (doctor-report-remediation report) 'null)))

;; ----------------------------------------------------------------------------
;; Doctor (installation check; never starts the daemon)
;; ----------------------------------------------------------------------------

(struct doctor-report
        (ok endpoint
            cli-version
            runtime-reachable
            runtime-version
            api-version
            status-error
            token-found
            token-path
            daemon-found
            daemon-path
            profile-name
            target-count
            version-match
            remediation)
  #:transparent)

(define (build-doctor-report host port)
  (define token (read-token))
  (define daemon-path (resolve-daemon-path))
  (define runtime-version #f)
  (define status-error #f)
  (define profile-name #f)
  (define target-count 0)
  (define reachable #f)

  ;; The network subtype must come first: exn:benchpilot? matches it too.
  (with-handlers ([exn:benchpilot:network? (lambda (e) (set! status-error (exn-message e)))]
                  [exn:benchpilot? (lambda (e)
                                     (set! status-error
                                           (format "~a: ~a"
                                                   (bench-client-error-code e)
                                                   (bench-client-error-message e)))
                                     (set! reachable (= (bench-client-error-status-code e) 401)))])
    (define-values (status body) (api-call host port "GET" "/status" (hasheq) #f))
    (when (< status 300)
      (set! reachable #t)
      (set! runtime-version (opt-string body 'runtimeVersion))
      (set! profile-name (opt-string body 'name))
      (set! target-count (length (hash-ref body 'targets '())))))

  (define version-match (or (not runtime-version) (string=? runtime-version benchpilot-version)))

  (doctor-report
   reachable
   (format "http://~a:~a" host port)
   benchpilot-version
   reachable
   runtime-version
   1
   status-error
   (and token #t)
   (local-auth-token-path)
   (and daemon-path #t)
   daemon-path
   profile-name
   target-count
   version-match
   (if reachable
       #f
       (cond
         [(autostart-disabled?)
          "The daemon is not reachable and BENCHPILOT_AUTOSTART=0 disables automatic start. Run benchpilotd manually."]
         [(not daemon-path)
          "The daemon is not reachable and no benchpilotd executable was found next to the CLI or on PATH."]
         [else "The daemon will start automatically on the next benchpilot command."]))))

;; ----------------------------------------------------------------------------
;; Command execution
;; ----------------------------------------------------------------------------

(define (print-error code message compact)
  (print-result (api-error #f code message #f #f #f #f #f) compact))

(define (print-unavailable message host port compact)
  (define hint
    (cond
      [(autostart-disabled?) "Start the resident runtime with: benchpilotd"]
      [(not (resolve-daemon-path))
       "No benchpilotd executable was found next to the CLI or on PATH. Install BenchPilot or start the runtime manually."]
      [else "Automatic daemon start failed. Start the resident runtime with: benchpilotd"]))
  (print-result
   (api-error
    #f
    "runtime_unavailable"
    (format "BenchPilot runtime at http://~a:~a is not reachable: ~a. ~a" host port message hint)
    #f
    #f
    #f
    #f
    #f)
   compact))

(define (bench-client-run! args)
  (with-handlers ([exn:benchpilot:validation?
                   (lambda (e)
                     (print-error "validation" (exn-message e) (args-flag args 'json))
                     2)]
                  [exn:benchpilot:cancelled?
                   (lambda (e)
                     (print-error "cancelled" "Request cancelled." (args-flag args 'json))
                     1)]
                  [bench-client-error? (lambda (e)
                                         ;; Structured fields (operationId,
                                         ;; busyScope, deadlineMs, ...) stay
                                         ;; visible on the wire.
                                         (print-result
                                          (api-error #f
                                                     (bench-client-error-code e)
                                                     (bench-client-error-message e)
                                                     (bench-client-error-operation-id e)
                                                     (bench-client-error-busy-scope e)
                                                     (bench-client-error-busy-id e)
                                                     (bench-client-error-deadline-ms e)
                                                     (bench-client-error-deadline-at-utc e))
                                          (args-flag args 'json))
                                         (error-exit-code e))])
    (define positionals (cli-args-positionals args))

    (cond
      [(or (args-flag args 'version)
           (and (= (length positionals) 1) (string-ci=? (first positionals) "version")))
       (displayln benchpilot-version)
       0]
      [(or (args-flag args 'help) (null? positionals))
       (print-usage)
       0]
      [else
       (define-values (host port) (resolve-endpoint (args-get args 'endpoint)))
       (define command (string->symbol (string-downcase (first positionals))))
       (define subcommand
         (string->symbol (string-downcase (if (> (length positionals) 1)
                                              (second positionals)
                                              ""))))
       (with-handlers
           ([exn:benchpilot:network?
             (lambda (e)
               (if (try-autostart host port)
                   (with-handlers
                       ([exn:benchpilot:network?
                         (lambda (e2)
                           (print-unavailable (exn-message e2) host port (args-flag args 'json))
                           4)])
                     (run-command args command subcommand host port))
                   (begin
                     (print-unavailable (exn-message e) host port (args-flag args 'json))
                     4)))])
         (run-command args command subcommand host port))])))

(define (run-command args command subcommand host port)
  (define compact (args-flag args 'json))
  (define (call method path [query (hasheq)] [body #f])
    (define-values (status result) (api-call host port method path query body))
    (require-ok status result))

  (define (require-positional index label)
    (or (args-positional args index) (raise-validation (format "Missing required ~a." label))))

  (define (hex-string->bytes hex)
    (list->bytes (hex-parse hex)))
  (define (bytes->hex-string bs)
    (bytes->hex (bytes->list bs)))

  (define (maybe-did text)
    (define n (parse-hex-or-dec text))
    (unless (and n (>= n 0) (<= n #xFFFF))
      (raise-validation (format "Invalid DID: '~a' (expected 0x0000-0xFFFF)." text)))
    n)

  (define (maybe-session text)
    (case (string-downcase text)
      [("default") uds-session-default]
      [("programming") uds-session-programming]
      [("extended") uds-session-extended]
      [else
       (define n (parse-hex-or-dec text))
       (unless (and n (>= n 1) (<= n #x7F))
         (raise-validation
          (format "Invalid session level '~a' (default|programming|extended|0x01-0x7F)." text)))
       n]))

  (define (target-query #:deadline [deadline #f])
    (define q (make-hash))
    (define target (args-get args 'target))
    (when target
      (hash-set! q 'target target))
    (when deadline
      (define dl (args-int-opt args 'deadline-ms))
      (when dl
        (hash-set! q 'deadlineMs dl)))
    q)

  (define (field key)
    (define v (hash-ref (unbox last-printed-box) key #f))
    (and v (not (eq? v 'null))))

  (case command
    [(status)
     (print-result (call "GET" "/status") compact)
     0]
    [(doctor)
     (define report (build-doctor-report host port))
     (print-result report compact)
     (if (doctor-report-ok report) 0 4)]
    [(operations)
     (print-result (call "GET" "/operations") compact)
     0]
    [(history)
     (print-result
      (call "GET" "/operations/history" (hasheq 'limit (or (args-int-opt args 'limit) 50)))
      compact)
     0]
    [(evidence)
     (print-result
      (call "GET" "/operations/evidence" (hasheq 'operationId (require-positional 1 "operation id")))
      compact)
     0]
    [(cancel)
     (print-result
      (call "POST" "/operations/cancel" (hasheq 'operationId (require-positional 1 "operation id")))
      compact)
     0]
    [(observe)
     (case subcommand
       [(list)
        (print-result (call "GET" "/observations") compact)
        0]
       [(history)
        (print-result
         (call "GET" "/observations/history" (hasheq 'limit (or (args-int-opt args 'limit) 50)))
         compact)
        0]
       [(evidence)
        (print-result (call "GET"
                            "/observations/evidence"
                            (hasheq 'observationId (require-positional 2 "observation id")))
                      compact)
        0]
       [(cancel)
        (print-result (call "POST"
                            "/observations/cancel"
                            (hasheq 'observationId (require-positional 2 "observation id")))
                      compact)
        0]
       [else (raise-validation (format "Unknown command: observe ~a" subcommand))])]
    [(preflight)
     (print-result (call "POST" "/preflight" (target-query)) compact)
     (if (field 'ok) 0 4)]
    [(bench)
     (unless (eq? subcommand (quote validate))
       (raise-validation (format "Unknown command: bench ~a" subcommand)))
     (print-result (call "POST" "/validate" (target-query)) compact)
     (if (field 'readyForRealEcuLoop) 0 1)]
    [(power)
     (case subcommand
       [(on)
        (print-result (call "POST"
                            "/power/on"
                            (target-query #:deadline #t)
                            (hasheq 'voltage
                                    (or (args-real-opt args 'voltage) 12)
                                    'settleMs
                                    (or (args-int-opt args 'settle-ms) 2000)))
                      compact)
        0]
       [(off)
        (print-result (call "POST" "/power/off" (target-query #:deadline #t) (hasheq)) compact)
        0]
       [(emergency-off)
        (print-result (call "POST" "/power/emergency-off" (target-query) (hasheq)) compact)
        0]
       [(current)
        (print-result (call "POST"
                            "/power/current/read"
                            (target-query)
                            (hasheq 'windowMs (or (args-int-opt args 'window-ms) 500)))
                      compact)
        0]
       [(check)
        (print-result
         (call "POST"
               "/power/current/check"
               (target-query)
               (hasheq 'ltMa (args-real-opt args 'lt-ma) 'gtMa (args-real-opt args 'gt-ma)))
         compact)
        (if (field 'passed) 0 1)]
       [else (raise-validation (format "Unknown command: power ~a" subcommand))])]
    [(flash)
     (case subcommand
       [(write)
        (print-result (call "POST"
                            "/flash/write"
                            (target-query #:deadline #t)
                            (hasheq 'firmware
                                    (require-positional 2 "firmware path")
                                    'confirmTarget
                                    (args-get args 'confirm-target)))
                      compact)
        0]
       [(reset)
        (print-result (call "POST"
                            "/flash/reset"
                            (target-query #:deadline #t)
                            (hasheq 'confirmTarget (args-get args 'confirm-target)))
                      compact)
        0]
       [else (raise-validation (format "Unknown command: flash ~a" subcommand))])]
    [(serial)
     (case subcommand
       [(open)
        (print-result (call "POST"
                            "/serial/open"
                            (target-query #:deadline #t)
                            (hasheq 'port (args-get args 'port) 'baud (args-int-opt args 'baud)))
                      compact)
        0]
       [(wait)
        (print-result (call "POST"
                            "/serial/wait"
                            (target-query #:deadline #t)
                            (hasheq 'pattern
                                    (require-positional 2 "pattern")
                                    'timeoutMs
                                    (or (args-int-opt args 'timeout-ms) 10000)))
                      compact)
        (if (field 'matched) 0 1)]
       [(window)
        (print-result
         (call "POST"
               "/serial/window"
               (target-query #:deadline #t)
               (hasheq 'lines (or (args-int-opt args 'lines) 50) 'filter (args-get args 'filter)))
         compact)
        0]
       [(send)
        (print-result (call "POST"
                            "/serial/send"
                            (target-query #:deadline #t)
                            (hasheq 'data (require-positional 2 "data")))
                      compact)
        0]
       [else (raise-validation (format "Unknown command: serial ~a" subcommand))])]
    [(uds)
     (case subcommand
       [(request)
        (print-result (call "POST"
                            "/uds/request"
                            (target-query)
                            (hasheq 'requestHex
                                    (require-positional 2 "request hex")
                                    'p2TimeoutMs
                                    (args-int-opt args 'p2-ms)
                                    'p2StarTimeoutMs
                                    (args-int-opt args 'p2-star-ms)))
                      compact)
        (if (field 'positive) 0 1)]
       [(read-did)
        (define did (maybe-did (require-positional 2 "did")))
        (print-result (call "POST"
                            "/uds/request"
                            (target-query)
                            (hasheq 'requestHex
                                    (bytes->hex (uds-read-did did))
                                    'p2TimeoutMs
                                    (args-int-opt args 'p2-ms)
                                    'p2StarTimeoutMs
                                    (args-int-opt args 'p2-star-ms)))
                      compact)
        (if (field 'positive) 0 1)]
       [(session)
        (define level (maybe-session (require-positional 2 "session level")))
        (print-result (call "POST"
                            "/uds/request"
                            (target-query)
                            (hasheq 'requestHex
                                    (bytes->hex (uds-diagnostic-session level))
                                    'p2TimeoutMs
                                    (args-int-opt args 'p2-ms)
                                    'p2StarTimeoutMs
                                    (args-int-opt args 'p2-star-ms)))
                      compact)
        (if (field 'positive) 0 1)]
       [(flash)
        (print-result (call "POST"
                            "/uds/flash"
                            (target-query #:deadline #t)
                            (hasheq 'firmware
                                    (require-positional 2 "firmware path")
                                    'planPath
                                    (args-get args 'plan)
                                    'address
                                    (args-hex-opt args 'address)
                                    'maxBlockPayload
                                    (args-int-opt args 'max-block)
                                    'confirmTarget
                                    (args-get args 'confirm-target)))
                      compact)
        0]
       [(dtc)
        (define action
          (string->symbol (string-downcase
                           (or (args-positional args 2) ""))))
        (case action
          [(read)
           (define mask (args-hex-opt args 'mask))
           (define request (uds-read-dtcs (or mask #xFF)))
           (define result
             (call "POST" "/uds/request"
                   (target-query)
                   (hasheq 'requestHex (bytes->hex-string (list->bytes request)))))
           (unless (hash-ref result 'positive #f)
             (print-result result compact)
             1)
           ;; responseHex already excludes the SID.
           (define payload (hex-string->bytes (hash-ref result 'responseHex "")))
           (define parsed (parse-dtc-response (bytes->list payload)))
           (define out
             (if (eq? parsed 'unsupported)
                 (hasheq 'ok #t 'positive #f 'error "ECU does not support DTC read (NRC or odd response).")
                 (hasheq 'ok #t
                         'positive #t
                         'availableMask (format "0x~a" (~r (hash-ref parsed 'availableMask) #:base 16 #:min-width 2 #:pad-string "0"))
                         'dtcs (hash-ref parsed 'dtcs '()))))
           (print-result out compact)
           0]
          [(clear)
           (define group (args-hex-opt args 'group))
           (define request (uds-clear-dtcs (or group #xFFFFFF)))
           (define result
             (call "POST" "/uds/request"
                   (target-query)
                   (hasheq 'requestHex (bytes->hex-string (list->bytes request)))))
           (if (not (hash-ref result 'positive #f))
               (begin (print-result result compact) 1)
               (let ()
                 ;; ClearDiagnosticInformation answers with the bare 0x54
                 ;; positive SID; responseHex is empty by design.
                 (print-result (hasheq 'ok #t 'positive #t 'cleared #t) compact)
                 0))]
          [else (raise-validation (format "Unknown command: uds dtc ~a" action))])]
       [else (raise-validation (format "Unknown command: uds ~a" subcommand))])]
    [(doip)
     (unless (eq? subcommand (quote discover))
       (raise-validation (format "Unknown command: doip ~a" subcommand)))
     (print-result
      (call "POST" "/doip/discover" (hasheq) (hasheq 'windowMs (args-int-opt args 'window-ms)))
      compact)
     (if (> (length (hash-ref (unbox last-printed-box) 'vehicles '())) 0) 0 1)]
    [(store)
     (case subcommand
       [(evidence)
        (print-result (call "GET" "/store/operations"
                            (hasheq 'limit (or (args-int-opt args 'limit) 50)))
                      compact)
        0]
       [(observations)
        (print-result (call "GET" "/store/observations"
                            (hasheq 'limit (or (args-int-opt args 'limit) 50)))
                      compact)
        0]
       [(artifacts)
        (print-result (call "GET" "/store/artifacts" (hasheq)) compact)
        0]
       [(artifact)
        (define id (require-positional 2 "artifact id"))
        (define result (call "GET" "/store/artifact" (hasheq 'artifactId id)))
        (define content (base64-decode (string->bytes/latin-1
                                        (hash-ref result 'contentBase64))))
        (define out (args-get args 'out))
        (if out
            (begin
              (display-to-file content out #:mode 'binary #:exists 'replace)
              (print-result (hasheq 'ok #t
                                    'artifactId (hash-ref result 'artifactId)
                                    'bytes (hash-ref result 'bytes)
                                    'sha256 (hash-ref result 'sha256)
                                    'output out)
                            compact))
            (begin
              (write-bytes content)
              (newline)))
        0]
       [else (raise-validation (format "Unknown command: store ~a" subcommand))])]
    [(report)
     ;; --format html: one static evidence report for the bench session.
     (define results (make-hasheq))
     (define (fetch! key method path query)
       (define-values (st body) (api-call host port method path query #f))
       (when (< st 300) (hash-set! results key body)))
     (fetch! 'status "GET" "/status" (hasheq))
     (fetch! 'validate "POST" "/validate"
             (let ([t (args-get args 'target)])
               (if t (hasheq 'target t) (hasheq))))
     (fetch! 'operations "GET" "/operations/history" (hasheq 'limit 50))
     (fetch! 'observations "GET" "/observations/history" (hasheq 'limit 50))
     (define op-entries
       (hash-ref (hash-ref results 'operations (hasheq)) 'operations '()))
     (define obs-entries
       (hash-ref (hash-ref results 'observations (hasheq)) 'observations '()))
     (define latest-op
       (findf (lambda (op) (equal? (hash-ref op 'state) "completed"))
              op-entries))
     (when latest-op
       (fetch! 'operation-evidence "GET" "/operations/evidence"
               (hasheq 'operationId (hash-ref latest-op 'id))))
     (define latest-obs
       (findf (lambda (op) (equal? (hash-ref op 'state) "completed"))
              obs-entries))
     (when latest-obs
       (fetch! 'observation-evidence "GET" "/observations/evidence"
               (hasheq 'observationId (hash-ref latest-obs 'id))))
     (define out-path (or (args-get args 'out) "benchpilot-report.html"))
     (display-to-file (build-html-report results) out-path #:exists 'replace)
     (print-result (hasheq 'ok #t
                           'format "html"
                           'output out-path
                           'runtimeVersion benchpilot-version)
                   compact)
     0]
    [(update)
     (define result (if (args-get args 'check) (update-check) (update-run)))
     (print-result result compact)
     (if (if (update-check-result? result)
             (update-check-result-error result)
             (not (update-result-ok result)))
         4
         0)]
    [(shutdown)
     (with-handlers ([exn:benchpilot:network? (lambda (_)
                                                (print-result (shutdown-result #t "not_running" #f)
                                                              compact)
                                                0)])
       (print-result (call "POST" "/shutdown" (hasheq) (hasheq)) compact)
       0)]
    [else
     (raise-validation (format "Unknown command: ~a" (string-join (cli-args-positionals args))))]))

;; ----------------------------------------------------------------------------
;; Usage
;; ----------------------------------------------------------------------------

(define (print-usage)
  (displayln
   (string-append
    "BenchPilot CLI - client for the resident ECU bench runtime ("
    benchpilot-version
    ")\n"
    "
Usage:
  benchpilot status                  [--json] [--endpoint URL]
  benchpilot doctor                  [--json] [--endpoint URL]
  benchpilot operations              [--json] [--endpoint URL]
  benchpilot history                 [--limit N] [--json] [--endpoint URL]
  benchpilot evidence <operation-id> [--json] [--endpoint URL]
  benchpilot cancel <operation-id>   [--json] [--endpoint URL]

  benchpilot observe list                      [--json] [--endpoint URL]
  benchpilot observe history                   [--limit N] [--json] [--endpoint URL]
  benchpilot observe evidence <observation-id> [--json] [--endpoint URL]
  benchpilot observe cancel <observation-id>   [--json] [--endpoint URL]
  benchpilot report                            [--format html] [--out PATH]
                                               [--target ID] [--json] [--endpoint URL]
  benchpilot uds dtc read                      [--mask XX] [--target ID] [--json]
  benchpilot uds dtc clear                     [--group XXXXXX] [--target ID] [--json]
  benchpilot store evidence                    [--limit N] [--json]
  benchpilot store observations                [--limit N] [--json]
  benchpilot store artifacts                   [--json]
  benchpilot store artifact <id> [--out PATH]  [--json]

  benchpilot preflight              [--target ID] [--json]
  benchpilot bench validate         [--target ID] [--json]

  benchpilot power on            [--target ID] [--voltage V] [--settle-ms N] [--deadline-ms N] [--json]
  benchpilot power off           [--target ID] [--deadline-ms N] [--json]
  benchpilot power emergency-off [--target ID] [--json]
  benchpilot power current       [--target ID] [--window-ms N] [--json]
  benchpilot power check         [--target ID] [--lt-ma N] [--gt-ma N] [--json]

  benchpilot flash write <firmware> [--target ID] [--confirm-target ID] [--deadline-ms N] [--json]
  benchpilot flash reset            [--target ID] [--confirm-target ID] [--deadline-ms N] [--json]

  benchpilot serial open            [--target ID] [--port NAME] [--baud N] [--deadline-ms N] [--json]
  benchpilot serial wait <pattern>  [--target ID] [--timeout-ms N] [--deadline-ms N] [--json]
  benchpilot serial window          [--target ID] [--lines N] [--filter TEXT] [--deadline-ms N] [--json]
  benchpilot serial send <data>     [--target ID] [--deadline-ms N] [--json]

  benchpilot uds request <hex>      [--target ID] [--p2-ms N] [--p2-star-ms N] [--json]
  benchpilot uds read-did <did>     [--target ID] [--json]
  benchpilot uds session <level>    [--target ID] [--json]
  benchpilot uds flash <firmware>   [--target ID] (--address 0xA | --plan FILE) [--max-block N]
                                    [--confirm-target ID] [--deadline-ms N] [--json]
  benchpilot doip discover          [--window-ms N] [--json]

  benchpilot shutdown               [--json] [--endpoint URL]

  benchpilot version | --version

Exit codes:
  0 success / readiness passed
  1 operation/assertion/readiness failure or cancellation
  2 validation error
  3 target/resource/operation/observation/evidence not found
  4 runtime/device unavailable, unauthorized, or device/preflight error
  5 target/resource busy (another mutating operation is active)
  6 Runtime deadline exceeded

Resident runtime:
  The first benchpilot command starts benchpilotd automatically (autostart)
  and every later command reuses that resident process and its hardware
  state. Set BENCHPILOT_AUTOSTART=0 to require a manually started daemon.

Authentication:
  benchpilotd binds to loopback only and additionally requires a per-user
  token stored at "
    (local-auth-token-path)
    ".
  Clients attach it automatically; BENCHPILOT_TOKEN overrides the file.

Environment:
  BENCHPILOT_ENDPOINT    Runtime endpoint (default http://127.0.0.1:5640/)
  BENCHPILOT_TOKEN       Local API token (default: token file)
  BENCHPILOT_AUTOSTART   Set to 0 to disable automatic daemon start
")))

(module+ main
  (define args (parse-cli-args (vector->list (current-command-line-arguments))))
  (define exit-code (bench-client-run! args))
  (exit exit-code))
