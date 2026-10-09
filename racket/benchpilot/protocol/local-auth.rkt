#lang racket/base

;; LocalAuth.cs + RuntimeInfo.cs port: per-user loopback API token shared by
;; benchpilotd and every client shell, plus the product version constant.

(require racket/file
         racket/format
         racket/string)

(require (only-in benchpilot/core/contracts now-millis))

(provide local-auth-directory-path
         local-auth-token-path
         local-auth-log-directory
         resolve-or-create-token
         read-token
         benchpilot-version)

(define benchpilot-version "1.1.0")

(define (user-profile-dir)
  (define home (getenv "USERPROFILE"))
  (or home (getenv "HOME") "."))

(define (local-auth-directory-path)
  (path->string (build-path (user-profile-dir) ".benchpilot")))

(define (local-auth-token-path)
  (path->string (build-path (local-auth-directory-path) "token")))

(define (local-auth-log-directory)
  (path->string (build-path (local-auth-directory-path) "logs")))

;; Returns the local API token, generating and persisting one on first use.
(define (resolve-or-create-token)
  (define existing (read-token))
  (or existing
      (let ([token (list->string (for/list ([_ (in-range 64)])
                                   (string-ref "0123456789abcdef" (random 16))))])
        (make-directory* (local-auth-directory-path))
        (display-to-file token (local-auth-token-path) #:mode 'text #:exists 'replace)
        token)))

;; Returns the local API token for client shells, or #f when the daemon has
;; not created one yet (for example before the first start).
(define (read-token)
  (with-handlers ([exn:fail:filesystem? (lambda (_) #f)])
    (define value (string-trim (file->string (local-auth-token-path))))
    (if (zero? (string-length value)) #f value)))
