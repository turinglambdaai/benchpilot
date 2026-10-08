#lang racket/base

;; Loopback HTTP client for the resident BenchPilot runtime (benchpilotd).
;; Mirrors the CLI contract: BENCHPILOT_ENDPOINT overrides the endpoint
;; (default http://127.0.0.1:5640), one request per connection, token from
;; BENCHPILOT_TOKEN or the per-user token file the daemon creates.

(require json
         racket/format
         racket/list
         racket/port
         racket/string
         racket/tcp)

(require (only-in "../../racket/benchpilot/protocol/local-auth.rkt" read-token))

(provide api-get
         api-post
         exn:daemon?
         exn:daemon-code
         exn:daemon-message-detail
         daemon-endpoint-string
         jref)

;; Raised for transport failures (runtime not running) and non-2xx API
;; responses; `code` is the daemon's error code or "network".
(struct exn:daemon exn:fail (code) #:transparent)

(define (make-daemon-error code message)
  (exn:daemon message (current-continuation-marks) code))

(define (string-blank? s)
  (regexp-match? #px"^\\s*$" s))

(define (daemon-endpoint-string)
  (or (getenv "BENCHPILOT_ENDPOINT") "http://127.0.0.1:5640"))

(define (endpoint)
  (define text* (daemon-endpoint-string))
  (define m (regexp-match #px"^http://([^/:]+)(?::([0-9]+))?/?$" text*))
  (unless m
    (raise (make-daemon-error "endpoint" (format "Invalid BENCHPILOT_ENDPOINT: ~a" text*))))
  (values (second m) (or (and (third m) (string->number (third m))) 5640)))

(define (current-token)
  (or (getenv "BENCHPILOT_TOKEN") (read-token)))

(define (uri-encode-value v)
  (define s (if (string? v) v (format "~a" v)))
  (list->string
   (append* (for/list ([c (in-string s)])
              (if (or (char-alphabetic? c) (char-numeric? c) (member c '(#\- #\_ #\. #\~)))
                  (list c)
                  (let* ([code (char->integer c)]
                         [hex (string-upcase (~r code #:base 16 #:min-width 2 #:pad-string "0"))])
                    (list #\% (string-ref hex 0) (string-ref hex 1))))))))

(define (port->bytes* in)
  (define out (open-output-bytes))
  (copy-port in out)
  (get-output-bytes out))

;; One API call; returns the response jsexpr. Raises exn:daemon when the
;; runtime is unreachable or answers non-2xx.
(define (api-call method api-path query body)
  (define-values (host port) (endpoint))
  (define token (current-token))
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
  (define body-bytes (if body (jsexpr->bytes body) #""))

  (define (network-fail e)
    (raise (make-daemon-error
            "network"
            (format "BenchPilot Runtime is not reachable at ~a:~a (~a). Start benchpilotd first."
                    host port (exn-message e)))))
  (with-handlers ([exn:fail:network? network-fail]
                  [exn:fail:filesystem? network-fail])
    (define-values (in out) (tcp-connect host port))
    (dynamic-wind
      void
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
          (raise (make-daemon-error "network" "Connection closed before a response arrived.")))
        (define status
          (let ([m (regexp-match #px"HTTP/1\\.[01] ([0-9]{3})" status-line)])
            (or (and m (string->number (second m)))
                (raise (make-daemon-error
                        "network"
                        (format "Malformed HTTP status line: ~a" status-line))))))
        (let headers-loop ()
          (define line (read-line in 'return-linefeed))
          (unless (or (eof-object? line) (string-blank? line))
            (headers-loop)))
        (define body-result (port->bytes* in))
        (define payload
          (with-handlers ([exn:fail? (lambda (_) (hasheq))])
            (if (zero? (bytes-length body-result))
                (hasheq)
                (read-json (open-input-bytes body-result)))))
        (if (and (>= status 200) (< status 300))
            payload
            (raise (make-daemon-error
                    (or (jref payload 'code) "error")
                    (or (jref payload 'error)
                        (format "Runtime API returned HTTP ~a." status))))))
      (lambda ()
        (with-handlers ([exn:fail? void])
          (close-input-port in)
          (close-output-port out))))))

(define (api-get api-path [query (hasheq)])
  (api-call "GET" api-path query #f))

(define (api-post api-path [query (hasheq)] [body (hasheq)])
  (api-call "POST" api-path query body))

;; jsexpr accessors shared by the backend adapters.
(define (jref j key)
  (define v (hash-ref j key #f))
  (if (eq? v 'null) #f v))

(define (exn:daemon-message-detail e)
  (exn-message e))

;; (kept local; the backend re-provides its own typed accessors)
