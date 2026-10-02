#lang racket/base

;; Shared SHA-256 hashing through whatever tool the OS ships: sha256sum,
;; shasum, or certutil. No optional collection is required at runtime.

(require racket/file
         racket/list
         racket/port
         racket/string)

(provide sha256-hex)

(define (find-system-tool name)
  (or (find-executable-path name) name))

(define (run-tool lines->value . argv)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (define output (open-output-string))
    (define p (apply subprocess output #f 'stdout argv))
    (subprocess-wait p)
    (if (zero? (subprocess-status p))
        (lines->value (get-output-string output))
        #f)))

(define (sha256-hex path)
  (case (system-path-convention-type)
    [(windows)
     (run-tool
      (lambda (output)
        (for/first ([line (in-list (string-split output "\n"))]
                    #:when (regexp-match? #px"^[0-9a-fA-F]{64}$" (string-trim line)))
          (string-trim line)))
      (find-system-tool "certutil.exe") "-hashfile" path "SHA256")]
    [else
     (or (run-tool
          (lambda (output)
            (and (>= (string-length (string-trim output)) 64)
                 (first (string-split (string-trim output)))))
          (find-system-tool "sha256sum") path)
         (run-tool
          (lambda (output)
            (and (>= (string-length (string-trim output)) 64)
                 (first (string-split (string-trim output)))))
          (find-system-tool "shasum") "-a" "256" path))]))
