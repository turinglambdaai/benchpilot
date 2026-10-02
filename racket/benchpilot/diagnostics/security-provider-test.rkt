#lang racket/base

;; Security Provider: an external command computes the security key from the
;; seed (`command:<id>` deriver names), so vendor algorithms stay in vendor
;; binaries while Core only sees bytes.

(module+ test
  (require benchpilot/diagnostics/flash/engine
           benchpilot/diagnostics/security-provider
           racket/file
           racket/format
           racket/runtime-path
           rackunit)

  (test-case "external command provider computes the key from the seed"
    (define script-path (make-temporary-file "keyprov-~a.sh"))
    (display-to-file
     #<<SCRIPT
#!/bin/sh
# echoes the seed with every byte XORed by 0x5A, one test-visible algorithm
for c in $(printf "%s" "$2" | sed 's/--seed//; s/^ //; s/\(..\)/\1 /g'); do
  printf "%02x" $(( 0x$c ^ 0x5A ))
done
SCRIPT
     script-path #:exists 'replace)
    (file-or-directory-permissions script-path (bitwise-ior user-read-bit user-write-bit user-execute-bit))
    (define deriver (resolve-key-deriver
                     (string-append "command:" (path->string script-path))))
    (check-not-false deriver)
    ;; seed AA -> AA xor 5A = F0
    (check-equal? (deriver (list #xAA)) (list #xF0))
    (delete-file script-path))

  (test-case "unknown deriver names resolve to nothing"
    (check-false (resolve-key-deriver "no-such-deriver")))

  (test-case "builtin derivers stay in the engine's builtin table"
    ;; the provider table only answers command: names; the engine resolves
    ;; builtin names first
    (check-false (resolve-key-deriver "xor0x5a"))))
