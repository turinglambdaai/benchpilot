#lang racket/base

;; Minimal loopback HTTP/1.1 transport for the resident runtime: one
;; request per connection (Connection: close), JSON in/out. The API is a
;; localhost tool protocol, so the hand-rolled server keeps the dependency
;; surface at base while giving full control over status codes and the
;; token/stopping middleware ordering.

(require json
         racket/format
         racket/port
         racket/string
         racket/tcp
         racket/list)

(require benchpilot/core/contracts
         benchpilot/core/profile)

(provide http-serve
         query-ref
         query-int
         query-int-opt
         body-ref
         body-int
         body-int-opt
         body-real
         body-real-opt
         body-string
         body-string-opt)

;; ----------------------------------------------------------------------------
;; Server
;;
;; http-serve accepts connections forever. Each connection reads exactly
;; one request. Returns when the listener errors (process exit paths close
;; it from the shutdown handler via exit).
;; ----------------------------------------------------------------------------

(define (http-serve #:host host
                    #:port port
                    #:token token
                    #:admit admit
                    #:exit-request exit-request
                    #:health-handler health-handler
                    #:handler handler)
  (define listener (tcp-listen port 64 #t host))
  (let accept-loop ()
    (with-handlers ([exn:fail? (lambda (_) (void))])
      (define-values (in out) (tcp-accept listener))
      (thread (lambda () (serve-connection in out token admit exit-request health-handler handler))))
    (accept-loop)))

(define (serve-connection in out token admit exit-request health-handler handler)
  (with-handlers ([exn:fail? (lambda (_) (void))])
    (define request-line (read-line in 'return-linefeed))
    (when (or (eof-object? request-line) (string-blank? request-line))
      (raise-argument-error 'serve-connection "http request line" request-line))
    (define parts (string-split request-line " "))
    (define method
      (if (null? parts)
          "GET"
          (first parts)))
    (define raw-target
      (if (>= (length parts) 2)
          (second parts)
          "/"))

    ;; Headers.
    (define content-length 0)
    ;; equal?-based keys: header names are dynamic strings, and hasheq's
    ;; eq? hashing would never match them at lookup time.
    (define headers
      (let headers-loop ([headers (make-immutable-hash '())])
        (define line (read-line in 'return-linefeed))
        (if (or (eof-object? line) (string-blank? line))
            headers
            (let ([m (regexp-match #rx"(?i:^content-length:[ 	]*([0-9]+))" line)]
                  [hm (regexp-match #rx"^([^:]+):[ 	]*(.*)$" line)])
              (when m
                (set! content-length (string->number (second m))))
              (headers-loop (if hm
                                (hash-set headers
                                          (string-downcase (string-trim (second hm)))
                                          (string-trim (third hm)))
                                headers))))))

    (define body
      (if (> content-length 0)
          (bytes->jsexpr (read-bytes content-length in))
          (hasheq)))

    ;; Split path and query.
    (define-values (path query-string)
      (let ([qm (regexp-match #rx"^([^?]*)\\?(.*)$" raw-target)])
        ;; regexp-match yields (full match group1 group2).
        (if qm
            (values (second qm) (third qm))
            (values raw-target ""))))
    (define query (parse-query query-string))
    (define is-health (string-prefix? path "/healthz"))

    ;; Authentication precedes everything: an unauthenticated caller learns
    ;; nothing, not even shutdown state. healthz stays open.
    (define presented (hash-ref headers "x-benchpilot-token" ""))
    (cond
      [(and (not is-health) (not (string=? presented token)))
       (write-response
        out
        401
        (api-error-jsexpr
         "unauthorized"
         "Missing or invalid BenchPilot token. The token file is created by benchpilotd; clients read it automatically or honor BENCHPILOT_TOKEN."))]
      [else
       (if is-health
           (let ([result (health-handler)]) (write-response out (car result) (cdr result)))
           ;; Admit/stopping middleware.
           (if (admit)
               (begin0 (let ([result (handler method path query body)])
                         (write-response out (car result) (cdr result)))
                 (exit-request))
               (write-response out
                               503
                               (api-error-jsexpr
                                "runtime_stopping"
                                "BenchPilot Runtime is stopping and is not accepting new work."))))]))
  (close-input-port in)
  (close-output-port out))

(define (api-error-jsexpr code message)
  (api->jsexpr (api-error #f code message #f #f #f #f #f)))

(define (bytes->jsexpr bs)
  (with-handlers ([exn:fail? (lambda (_) (hasheq))])
    (if (zero? (bytes-length bs))
        (hasheq)
        (read-json (open-input-bytes bs)))))

(define (write-response out status payload)
  (define body (jsexpr->bytes payload))
  (fprintf out "HTTP/1.1 ~a ~a\r\n" status (status-text status))
  (fprintf out "Content-Type: application/json\r\n")
  (fprintf out "Content-Length: ~a\r\n" (bytes-length body))
  (fprintf out "Connection: close\r\n\r\n")
  (write-bytes body out)
  (flush-output out))

(define (status-text status)
  (case status
    [(200) "OK"]
    [(400) "Bad Request"]
    [(401) "Unauthorized"]
    [(404) "Not Found"]
    [(408) "Request Timeout"]
    [(409) "Conflict"]
    [(500) "Internal Server Error"]
    [(503) "Service Unavailable"]
    [else "Status"]))

;; ----------------------------------------------------------------------------
;; Query and body accessors. The C# minimal-API binds query parameters
;; case-insensitively; ci-ref keeps that behavior.
;; ----------------------------------------------------------------------------

(define (parse-query query-string)
  (for/hash ([pair (in-list (string-split query-string "&"))]
             #:unless (string-blank? pair))
    (define kv (string-split pair "="))
    (values (uri-decode (first kv))
            (uri-decode (if (null? (cdr kv))
                            ""
                            (second kv))))))

(define (uri-decode s)
  (with-handlers ([exn:fail? (lambda (_) s)])
    (bytes->string/utf-8 (apply bytes
                                (let loop ([chars (string->list s)])
                                  (cond
                                    [(null? chars) '()]
                                    [(char=? (car chars) #\%)
                                     (if (>= (length chars) 3)
                                         (let ([hex (implode-string (take (cdr chars) 2))])
                                           (cons (read-hex-byte hex) (loop (drop chars 3))))
                                         (cons (char->integer (car chars)) (loop (cdr chars))))]
                                    [(char=? (car chars) #\+) (cons 32 (loop (cdr chars)))]
                                    [else (cons (char->integer (car chars)) (loop (cdr chars)))]))))))

(define (implode-string chars)
  (list->string chars))

(define (read-hex-byte hex)
  (or (string->number hex 16) 32))

(define (query-ref query key)
  (ci-ref query key ""))

(define (query-int query key default)
  (define raw (ci-ref query key #f))
  (if (or (not raw) (string-blank? raw))
      default
      (or (string->number raw)
          (raise-validation (format "The query value '~a' is invalid for ~a." raw key)))))

(define (query-int-opt query key)
  (define raw (ci-ref query key #f))
  (if (or (not raw) (string-blank? raw))
      #f
      (or (string->number raw)
          (raise-validation (format "The query value '~a' is invalid for ~a." raw key)))))

(define (body-ref body key)
  (define v (hash-ref body key #f))
  (and v (not (eq? v 'null)) v))

(define (body-int body key default)
  (define v (body-ref body key))
  (cond
    [(not v) default]
    [(exact-integer? v) v]
    [else (raise-validation (format "Invalid type for field '~a': expected an integer." key))]))

(define (body-int-opt body key)
  (define v (body-ref body key))
  (cond
    [(not v) #f]
    [(exact-integer? v) v]
    [else (raise-validation (format "Invalid type for field '~a': expected an integer." key))]))

(define (body-real body key default)
  (define v (body-ref body key))
  (cond
    [(not v) default]
    [(real? v) v]
    [else (raise-validation (format "Invalid type for field '~a': expected a number." key))]))

(define (body-real-opt body key)
  (define v (body-ref body key))
  (cond
    [(not v) #f]
    [(real? v) v]
    [else (raise-validation (format "Invalid type for field '~a': expected a number." key))]))

(define (body-string body key)
  (define v (body-ref body key))
  (cond
    [(not v) (raise-validation (format "The request field '~a' is required." key))]
    [(string? v) v]
    [else (raise-validation (format "Invalid type for field '~a': expected a string." key))]))

(define (body-string-opt body key)
  (define v (body-ref body key))
  (cond
    [(not v) #f]
    [(string? v) v]
    [else (raise-validation (format "Invalid type for field '~a': expected a string." key))]))
