#lang racket/base

;; Security Provider abstraction: vendor seed-key algorithms beyond the
;; registered derivers plug in as external commands. A provider is named
;; `command:<id>` in driver settings; BenchPilot runs
;;   <executable> <args...> --seed <hex>
;; and parses the stdout as the key hex. Vendor code stays in the vendor's
;; own binary — Core only sees bytes.

(require racket/format
         racket/list
         racket/port
         racket/string)

(require benchpilot/core/contracts)

(provide register-key-provider!
         key-provider-names
         resolve-key-deriver
         run-key-provider-command)

;; name (string, case-folded) -> (lambda (seed-bytes) -> key-bytes)
(define providers (make-hash))
(define providers-mutex (make-semaphore 1))

(define (register-key-provider! name deriver)
  (semaphore-wait/enable-break providers-mutex)
  (begin0 (hash-set! providers (string-foldcase name) deriver)
    (semaphore-post providers-mutex)))

(define (key-provider-names)
  (sort (hash-keys providers) string<?))

;; settings-value: the keyDeriver setting string. Names without a command
;; prefix fall back to the registered provider table (the built-in
;; derivers live there too, installed by the flash engine).
(define (resolve-key-deriver name)
  (and (string? name)
       (let ([m (regexp-match #rx"^command:(.+)$" name)])
         (if m
             (lambda (seed)
               (run-key-provider-command (second m) seed))
             (with-handlers ([exn:fail? (lambda (_) #f)])
               (semaphore-wait/enable-break providers-mutex)
               (begin0 (hash-ref providers (string-foldcase name) #f)
                 (semaphore-post providers-mutex)))))))

;; Runs the provider command; the seed arrives as `--seed <hex>`. Output is
;; parsed as hex (whitespace tolerated). Non-zero exit or unparsable output
;; raises — the flash engine reports it as a failed security-access step.
(define (run-key-provider-command spec seed)
  (define parts (string-split spec))
  (define seed-hex
    (apply string-append
           (for/list ([b (in-list seed)])
             (~r b #:base 16 #:min-width 2 #:pad-string "0"))))
  (define argv
    (append (take parts (max 1 (sub1 (length parts))))
            (list "--seed" seed-hex)))
  (define-values (p stdout stdin stderr)
    (apply subprocess #f #f #f argv))
  (close-output-port stdin)
  (define output (open-output-string))
  (define collector
    (thread (lambda ()
              (copy-port stdout output)
              (close-input-port stdout))))
  (subprocess-wait p)
  (sync collector)
  (unless (zero? (subprocess-status p))
    (raise-validation
     (format "The security provider command failed with exit code ~a."
             (subprocess-status p))))
  (define hex
    (string-append* (string-split (string-trim (get-output-string output)))))
  (unless (and (>= (string-length hex) 2) (even? (string-length hex))
               (andmap hex-digit? (string->list hex)))
    (raise-validation
     "The security provider command did not print a hex key."))
  (hex-parse hex))
