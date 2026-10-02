#lang racket/base

;; Leases: acquire/renew/release/check semantics, ownership separation and
;; expiry; the audit trail appends through the same store directory.

(module+ test
  (require benchpilot/core/leases
           benchpilot/core/persist
           racket/file
           racket/list
           racket/string
           rackunit)

  (define dir (path->string (make-temporary-file "benchpilot-lease-~a" 'directory)))
  (define reg (make-lease-registry dir #t))

  (eprintf "T1...\n")
  (test-case "acquire + check pass for the same owner"
    (lease-acquire! reg "ecu" "token-A" 60)
    (lease-check! reg "ecu" "token-A")
    (check-not-false (lease-active-for reg "ecu")))

  (eprintf "T2...\n")
  (test-case "another owner is rejected while the lease is live"
    (check-exn exn:benchpilot:lease?
               (lambda () (lease-acquire! reg "ecu" "token-B" 60)))
    (check-exn exn:benchpilot:lease?
               (lambda () (lease-check! reg "ecu" "token-B"))))

  (eprintf "T3...\n")
  (test-case "release frees the target for the next owner"
    (define active (lease-active-for reg "ecu"))
    (check-not-false active)
    (check-true (lease-release! reg (bench-lease-id active) "token-A"))
    (lease-acquire! reg "ecu" "token-B" 60)
    (lease-check! reg "ecu" "token-B"))

  (eprintf "T4...\n")
  (test-case "leases expire"
    (define reg2 (make-lease-registry #f #t))
    (lease-acquire! reg2 "ecu" "token-A" 0) ; ttl 0 = immediately expired
    (check-exn exn:benchpilot:lease?
               (lambda () (lease-check! reg2 "ecu" "token-A")))
    ;; expired leases can be taken over
    (lease-acquire! reg2 "ecu" "token-B" 60)
    (check-not-false (lease-active-for reg2 "ecu")))

  (eprintf "T5...\n")
  (test-case "renew requires ownership"
    (define reg3 (make-lease-registry #f #t))
    (define lease (lease-acquire! reg3 "ecu" "token-A" 60))
    (check-exn exn:benchpilot:lease?
               (lambda () (lease-renew! reg3 (bench-lease-id lease) "token-B" 60)))
    (define renewed (lease-renew! reg3 (bench-lease-id lease) "token-A" 120))
    (check-equal? (bench-lease-id renewed) (bench-lease-id lease)))

  (eprintf "T6...\n")
  (test-case "audit trail lands in the store directory"
    (audit-append! reg "flash.executed" (hasheq 'target "ecu" 'ok #t))
    (audit-append! reg "lease.acquired" (hasheq 'target "ecu"))
    (define lines (file->lines (build-path dir "audit.jsonl")))
    (check-equal? (length lines) 2)
    (check-true (string-contains? (second lines) "lease.acquired")))

  (eprintf "T7...\n")
  (test-case "registry listing hides expired leases"
    (define listing (lease-registry->jsexpr reg))
    (check-true (hash-ref listing 'required))
    (check-true (>= (length (hash-ref listing 'leases)) 1))))
