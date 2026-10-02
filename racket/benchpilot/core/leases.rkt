#lang racket/base

;; Team benches: resource leases + a persistent audit trail.
;;
;; A lease is an authenticated, time-bounded ownership claim on one target:
;; once a profile enables `leases.required`, mutations on that target are
;; rejected unless the caller holds a live lease (or the lease feature is
;; off). Owners are the caller's API token hash — the same authentication
;; the loopback API already uses. The audit trail appends one line per
;; mutation to the persistent store, so team/CI workflows can answer "who
;; did what, when" across daemon restarts.

(require json
         racket/file
         racket/format
         racket/list
         racket/string)

(require benchpilot/core/contracts
         benchpilot/core/hashing
         benchpilot/core/persist)



(provide (struct-out bench-lease)
         (struct-out exn:benchpilot:lease)
         make-lease-registry
         lease-acquire!
         lease-renew!
         lease-release!
         lease-check!
         lease-active-for
         lease-registry->jsexpr
         audit-append!)

(struct bench-lease (id target-id owner-hash acquired-at-millis expires-at-millis)
  #:transparent)

(struct exn:benchpilot:lease exn:benchpilot () #:transparent)

(struct lease-registry (hash mutex audit-dir required-box))

(define (make-lease-registry [audit-dir #f] [required #f])
  (lease-registry (make-hash) (make-semaphore 1) audit-dir (box required)))

(define (now-ms**)
  (inexact->exact (floor (current-inexact-milliseconds))))

(define (token-hash token)
  (define source
    (if (and token (not (string-blank? token)))
        token
        (or (getenv "BENCHPILOT_TOKEN") "")))
  ;; The owner identity is a truncated FNV-1a digest of the caller's
  ;; token — never the token itself. Self-contained: no subprocess, and
  ;; unlike equal-hash-code it does not collide distinct short tokens.
  (define h #xcbf29ce484222325)
  (for ([c (in-string source)])
    (set! h (bitwise-and #xFFFFFFFFFFFFFFFF
                         (bitwise-xor h (char->integer c))))
    (set! h (bitwise-and #xFFFFFFFFFFFFFFFF (* h #x100000001b3))))
  (~r h #:base 16 #:min-width 16 #:pad-string "0"))

(define (call-with-reg-mutex reg proc)
  (semaphore-wait/enable-break (lease-registry-mutex reg))
  (dynamic-wind
 (lambda () (void))
 proc
 (lambda () (semaphore-post (lease-registry-mutex reg)))))

(define (live-lease? lease now)
  (and lease (< now (bench-lease-expires-at-millis lease))))

;; Acquires or renews the lease for (target, owner). A conflicting live
;; lease from another owner raises the typed error (HTTP 409 at the API).
(define (lease-acquire! reg target-id owner-token ttl-seconds)
  (call-with-reg-mutex
   reg
   (lambda ()
     (define now (now-ms**))
     (define owner (token-hash owner-token))
     (define existing
       (findf (lambda (l)
                (and (string-ci=? (bench-lease-target-id l) target-id)
                     (live-lease? l now)))
              (hash-values (lease-registry-hash reg))))
     (when (and existing
                (not (string=? (bench-lease-owner-hash existing) owner)))
       (raise (exn:benchpilot:lease
               (format "Target '~a' is leased by owner ~a until ~a."
                       target-id
                       (bench-lease-owner-hash existing)
                       (utc-iso-millis (bench-lease-expires-at-millis existing)))
               (current-continuation-marks))))
     (define lease
       (bench-lease (format "~a-~a" target-id owner)
                    target-id owner
                    now
                    (+ now (* ttl-seconds 1000))))
     (hash-set! (lease-registry-hash reg) (bench-lease-id lease) lease)
     lease)))

(define (lease-renew! reg lease-id owner-token ttl-seconds)
  (call-with-reg-mutex
   reg
   (lambda ()
     (define lease (hash-ref (lease-registry-hash reg) lease-id #f))
     (unless (and lease
                  (string=? (bench-lease-owner-hash lease)
                            (token-hash owner-token)))
       (raise (exn:benchpilot:lease "Lease not found or not yours."
                                    (current-continuation-marks))))
     (define renewed
       (struct-copy bench-lease lease
                    [expires-at-millis (+ (now-ms**) (* ttl-seconds 1000))]))
     (hash-set! (lease-registry-hash reg) lease-id renewed)
     renewed)))

(define (lease-release! reg lease-id owner-token)
  (call-with-reg-mutex
   reg
   (lambda ()
     (define lease (hash-ref (lease-registry-hash reg) lease-id #f))
     (when (and lease
                (string=? (bench-lease-owner-hash lease)
                          (token-hash owner-token)))
       (hash-remove! (lease-registry-hash reg) lease-id))
     (and lease #t))))

;; Raises the typed error when the target requires a lease the caller
;; doesn't hold. `required` comes from the profile (safety.leasesRequired).
(define (lease-check! reg target-id owner-token)
  (unless (unbox (lease-registry-required-box reg))
    (void))
  (define now (now-ms**))
  (define held
    (findf (lambda (l)
             (and (string-ci=? (bench-lease-target-id l) target-id)
                  (string=? (bench-lease-owner-hash l) (token-hash owner-token))
                  (live-lease? l now)))
           (hash-values (lease-registry-hash reg))))
  (unless held
    (raise (exn:benchpilot:lease
            (format "Target '~a' requires an active lease before mutations (profile: safety.leasesRequired)."
                    target-id)
            (current-continuation-marks))))
  (void))

(define (lease-active-for reg target-id)
  (define now (now-ms**))
  (findf (lambda (l)
           (and (string-ci=? (bench-lease-target-id l) target-id)
                (live-lease? l now)))
         (hash-values (lease-registry-hash reg))))

(define (lease-registry->jsexpr reg)
  (define now (now-ms**))
  (hasheq 'kind "lease-list"
          'required (unbox (lease-registry-required-box reg))
          'leases
          (for/list ([l (in-list (hash-values (lease-registry-hash reg)))]
                     #:when (live-lease? l now))
            (hasheq 'id (bench-lease-id l)
                    'targetId (bench-lease-target-id l)
                    'ownerHash (bench-lease-owner-hash l)
                    'expiresAtUtc (or (utc-iso-millis (bench-lease-expires-at-millis l)) 'null)))))

;; Persistent audit: one JSONL line per audited event, into the same store
;; directory as the evidence (or its own dir when no store is configured).
(define (audit-append! reg event jsexpr)
  (define dir (lease-registry-audit-dir reg))
  (when dir
    (with-handlers ([exn:fail? (lambda (_) (void))])
      (call-with-output-file*
       (build-path dir "audit.jsonl")
       (lambda (out)
         (write-json (hasheq 'event event
                             'at (or (utc-iso-millis (now-ms**)) 'null)
                             'details jsexpr)
                     out)
         (newline out))
       #:mode 'text
       #:exists 'append))))
