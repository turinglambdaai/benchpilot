#lang racket/base

;; SelfUpdaterTests.cs port: version comparison, platform RID mapping and
;; checksum verification. Network paths are exercised only through the
;; pure helpers; the live feed contract is validated at release time.

(module+ test
  (require benchpilot/client/updater
           racket/file
           racket/string
           rackunit)

  ;; sha256("hello") — the C# theory hashes a 5-byte file too.
  (define hello-sha256
    "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")

  (define (version-sign a b)
    (define v (compare-versions a b))
    (cond [(negative? v) -1] [(positive? v) 1] [else 0]))

  (test-case "versions compare numerically"
    (check-equal? (version-sign "0.5.0" "0.5.1") -1)
    (check-equal? (version-sign "0.5.1" "0.5.0") 1)
    (check-equal? (version-sign "0.5.0" "0.5.0") 0)
    (check-equal? (version-sign "v0.10.0" "v0.9.0") 1)
    (check-equal? (version-sign "1.0.0" "0.99.99") 1)
    (check-equal? (version-sign "0.5.0" "0.5.0-old") -1))

  (test-case "platform rid is a package rid"
    (check-not-false (member (platform-rid)
                             '("win-x64" "win-arm64" "linux-x64" "linux-arm64"
                               "osx-arm64" "osx-x64")
                             string=?)
                     (format "rid: ~a" (platform-rid))))

  (test-case "checksum verification accepts a matching entry"
    (define dir (make-temporary-file "benchpilot-update-test-~a" 'directory))
    (define archive (build-path dir "archive.bin"))
    (define sums (build-path dir "SHA256SUMS"))
    (display-to-file #"hello" archive #:exists 'replace)
    (display-to-file
     (string-append
      "0000000000000000000000000000000000000000000000000000000000000000  other-file.zip\n"
      hello-sha256 "  benchpilot-0.5.1-win-x64.zip\n")
     sums #:exists 'replace)
    (verify-checksum archive sums "benchpilot-0.5.1-win-x64.zip")
    (check-true #t)
    (delete-directory/files dir))

  (test-case "checksum verification rejects a tampered archive"
    (define dir (make-temporary-file "benchpilot-update-test-~a" 'directory))
    (define archive (build-path dir "archive.bin"))
    (define sums (build-path dir "SHA256SUMS"))
    (display-to-file #"hello" archive #:exists 'replace)
    (display-to-file
     (string-append "0000000000000000000000000000000000000000000000000000000000000000"
                    "  benchpilot-0.5.1-win-x64.zip\n")
     sums #:exists 'replace)
    (define message
      (with-handlers ([exn:fail? exn-message])
        (verify-checksum archive sums "benchpilot-0.5.1-win-x64.zip")
        #f))
    (check-true (and message (string-contains? message "Checksum mismatch"))
                (format "message: ~a" message))
    (delete-directory/files dir))

  (test-case "checksum verification rejects a missing entry"
    (define dir (make-temporary-file "benchpilot-update-test-~a" 'directory))
    (define archive (build-path dir "archive.bin"))
    (define sums (build-path dir "SHA256SUMS"))
    (display-to-file #"hello" archive #:exists 'replace)
    (display-to-file
     (string-append hello-sha256 "  some-other-archive.zip\n")
     sums #:exists 'replace)
    (define message
      (with-handlers ([exn:fail? exn-message])
        (verify-checksum archive sums "benchpilot-0.5.1-win-x64.zip")
        #f))
    (check-true
     (and message (string-contains? message "SHA256SUMS has no entry for"))
     (format "message: ~a" message))
    (delete-directory/files dir)))
