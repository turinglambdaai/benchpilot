#lang racket/base

;; E2EEnvironment.cs + SharedDaemonFixture.cs port: spawns the REAL resident
;; daemon and the REAL CLI as processes over loopback, mirroring the release
;; layout (benchpilot and benchpilotd side by side in one stage directory).
;;
;; Racket subprocesses inherit the parent environment, so each stage's
;; wrappers embed their own BENCHPILOT_ENDPOINT instead: envs stay isolated
;; and the CLI's autostart (sibling benchpilotd) works through the real path.

(require json
         racket/file
         racket/format
         racket/list
         racket/port
         racket/string
         racket/tcp)

(require benchpilot/core/contracts
         benchpilot/protocol/local-auth)

(provide (struct-out e2e-env)
         make-e2e-env
         start-daemon!
         daemon-healthy?
         daemon-process
         kill-daemon!
         run-cli
         run-cli-json
         raw-api-call)

(struct e2e-env (stage host port daemon-process-box))

;; 'exec-file is this script's path when run via `racket file.rkt`; the real
;; racket binary is what child processes must exec.
(define (racket-binary)
  (or (find-executable-path "racket") (find-system-path 'exec-file)))

(define (write-wrapper! stage name endpoint-expr body)
  (define path (build-path stage name))
  (display-to-file
   (string-append
    "#lang racket/base\n"
    "(require benchpilot/core/contracts
         benchpilot/protocol/local-auth)\n"
    "(void (putenv \"BENCHPILOT_ENDPOINT\" " endpoint-expr "))\n"
    body)
   path
   #:exists 'replace)
  path)

(define (free-port)
  (let probe ()
    (define candidate (+ 47200 (random 2000)))
    (with-handlers ([exn:fail:network? (lambda (_) (probe))])
      (define l (tcp-listen candidate 8 #t))
      (tcp-close l)
      candidate)))

;; Creates the stage (benchpilot + benchpilotd wrappers side by side, a
;; build/app.elf firmware) without starting anything.
(define (make-e2e-env)
  (define stage (make-temporary-file "benchpilot-e2e-~a" 'directory))
  (make-directory* (build-path stage "build"))
  (display-to-file #"E2E firmware image bytes" (build-path stage "build" "app.elf")
                   #:exists 'replace)
  (define port (free-port))
  (define endpoint (format "\"http://127.0.0.1:~a/\"" port))
  (write-wrapper! stage "benchpilotd.rkt" endpoint
                  (string-append
                   "(require benchpilot/runtime-host/daemon)\n"
                   "(run-daemon)\n"))
  (write-wrapper! stage "benchpilot.rkt" endpoint
                  (string-append
                   "(require benchpilot/client/cli)\n"
                   "(exit (bench-client-run!"
                   " (parse-cli-args (vector->list (current-command-line-arguments)))))\n"))
  (e2e-env stage "127.0.0.1" port (box #f)))

(define (start-daemon! env)
  (unless (unbox (e2e-env-daemon-process-box env))
    (define log-file (build-path (e2e-env-stage env) "benchpilotd-e2e.log"))
    (define log-out
      (open-output-file log-file #:mode 'text #:exists 'append))
    (define-values (p stdout stdin stderr)
      (subprocess #f #f log-out
                  (racket-binary)
                  (path->string (build-path (e2e-env-stage env) "benchpilotd.rkt"))))
    (close-output-port stdin)
    (close-output-port log-out)
    (set-box! (e2e-env-daemon-process-box env) p)
    (define deadline (+ (current-inexact-milliseconds) 60000))
    (let wait ()
      (unless (or (daemon-healthy? env) (> (current-inexact-milliseconds) deadline))
        (sleep 0.2)
        (wait)))
    (unless (daemon-healthy? env)
      (kill-daemon! env)
      (raise (exn:fail "E2E daemon did not become healthy in time."
                       (current-continuation-marks))))))

(define (daemon-healthy? env)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (define-values (in out) (tcp-connect (e2e-env-host env) (e2e-env-port env)))
    (close-input-port in)
    (close-output-port out)
    #t))

(define (daemon-process env)
  (unbox (e2e-env-daemon-process-box env)))

(define (kill-daemon! env)
  (define p (daemon-process env))
  (when p
    (with-handlers ([exn:fail? void])
      (subprocess-kill p #t))
    (set-box! (e2e-env-daemon-process-box env) #f)))

;; Runs the real CLI from the stage as a process. Returns (values exit-code
;; stdout).
(define (run-cli env . args)
  (define-values (p stdout stdin stderr)
    (parameterize ([current-directory (e2e-env-stage env)])
      (apply subprocess #f #f #f
             (racket-binary)
             (path->string (build-path (e2e-env-stage env) "benchpilot.rkt"))
             (map ~a args))))
  (close-output-port stdin)
  (close-input-port stderr)
  (define output (open-output-string))
  (define collector
    (thread (lambda ()
              (copy-port stdout output)
              (close-input-port stdout))))
  (sync collector)
  (subprocess-wait p)
  (values (subprocess-status p)
          (string-trim (get-output-string output))))

;; Runs the CLI expecting success and parses the last stdout line as JSON.
(define (run-cli-json env . args)
  (define-values (code stdout) (apply run-cli env args))
  (unless (zero? code)
    (raise (exn:fail (format "CLI ~a exited ~a: ~a" args code stdout)
                     (current-continuation-marks))))
  (define lines (filter (lambda (l) (not (string-blank? l)))
                        (string-split stdout "\n")))
  (read-json (open-input-string (last lines))))

;; Raw loopback API call with an optional token; returns (values status
;; body-text).
(define (raw-api-call env method path [body-json #f] [with-token #t] [token-override #f])
  (define token (if with-token (or token-override (read-token)) #f))
  (define-values (in out)
    (tcp-connect (e2e-env-host env) (e2e-env-port env)))
  (define body-bytes
    (if body-json (jsexpr->bytes body-json) #""))
  (fprintf out "~a ~a HTTP/1.1\r\n" method path)
  (fprintf out "Host: ~a:~a\r\n" (e2e-env-host env) (e2e-env-port env))
  (when token
    (fprintf out "X-Benchpilot-Token: ~a\r\n" token))
  (when body-json
    (fprintf out "Content-Type: application/json\r\n"))
  (fprintf out "Content-Length: ~a\r\n" (bytes-length body-bytes))
  (fprintf out "Connection: close\r\n\r\n")
  (unless (zero? (bytes-length body-bytes))
    (write-bytes body-bytes out))
  (flush-output out)
  (define response (port->string in))
  (close-input-port in)
  (close-output-port out)
  (define status
    (let ([m (regexp-match #px"HTTP/1\\.[01] ([0-9]{3})" response)])
      (and m (string->number (second m)))))
  (define body-text
    (let ([m (regexp-match #rx"\r\n\r\n(.*)" response)])
      (or (and m (second m)) "")))
  (values status body-text))
