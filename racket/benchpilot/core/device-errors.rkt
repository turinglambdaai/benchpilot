#lang racket/base

;; Device/runtime error taxonomy: vendor SDK messages are classified into a
;; small, stable set of classes without ever leaking vendor types or vendor
;; SDK details into Core. Faulted operations carry a `device.error` evidence
;; item whose metadata names the class and the pattern that matched, so
;; agents can branch on behavior instead of parsing vendor strings.

(require racket/string)

(require benchpilot/core/contracts)

(provide device-error-classes
         classify-device-error
         device-error-evidence-item)

;; Each class lists the case-insensitive substrings that indicate it. The
;; first matching class wins; unmatched failures classify as `unknown`.
(define device-error-classes
  (list
   (cons "timeout"
         '("timed out" "timeout" "deadline exceeded" "no response"))
   (cons "transport"
         '("connection refused" "connection closed" "no route" "unreachable"
           "broken pipe" "reset by peer" "socket"))
   (cons "device-state"
         '("busy" "not ready" "device is off" "power is off" "no power"
           "already open" "not open"))
   (cons "permission"
         '("access denied" "permission" "unauthorized" "in use by another"
           "locked"))
   (cons "not-found"
         '("not found" "no such file" "no such device" "was not found"
           "not visible" "not installed" "could not resolve"))
   (cons "protocol"
         '("checksum" "crc" "invalid response" "unexpected response"
           "malformed" "nrc" "flow control" "iso-tp"))))

(define (contains-ci? haystack needle)
  (string-contains? (string-foldcase haystack) (string-foldcase needle)))

;; -> (values class matched-pattern)
(define (classify-device-error message)
  (let loop ([classes device-error-classes])
    (cond
      [(null? classes) (values "unknown" "")]
      [else
       (define match
         (findf (lambda (pat) (contains-ci? message pat))
                (cdr (car classes))))
       (if match
           (values (car (car classes)) match)
           (loop (cdr classes)))])))

;; The evidence item attached to faulted operations.
(define (device-error-evidence-item message)
  (define-values (class pattern) (classify-device-error message))
  (bench-evidence-item
   "device.error"
   (format "Failure classified as ~a." class)
   (let ([bounded (if (<= (string-length message) 2000)
                      message
                      (string-append (substring message 0 2000) "…"))])
     bounded)
   (hasheq "class" class
           "matchedPattern" (if (string=? pattern "") "" pattern))))
