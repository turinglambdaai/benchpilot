#lang racket/base

;; IsotpCodecTests.cs port: codec round trips, escape forms and STmin ranges.

(module+ test
  (require benchpilot/diagnostics/isotp/codec
           racket/list
           rackunit)

  (test-case "single frame round trip, short payload"
    (define payload '(#x10 #x03))
    (define frame (encode-single payload))
    (check-equal? (length frame) 8)
    (check-equal? (car frame) #x02)
    (define decoded (try-decode-frame frame))
    (check-true (isotp-frame? decoded))
    (check-equal? (isotp-frame-type decoded) 'single)
    (check-equal? (isotp-frame-payload decoded) payload))

  (test-case "single frame over seven bytes is rejected"
    (check-exn exn:fail:contract? (lambda () (encode-single (make-list 8 #x00)))))

  (test-case "first frame carries length prefix"
    (define payload (make-list 100 #x00))
    (define frame (encode-first-prefix payload))
    (check-equal? (arithmetic-shift (car frame) -4) 1)
    (check-equal? (+ (arithmetic-shift (bitwise-and (car frame) #x0F) 8) (second frame)) 100)
    (define decoded (try-decode-frame frame))
    (check-equal? (isotp-frame-type decoded) 'first)
    (check-equal? (length (isotp-frame-payload decoded)) 6))

  (test-case "first frame escape handles large lengths"
    (define payload (make-list 5000 #x00))
    (define frame (encode-first-prefix payload))
    (check-equal? (car frame) #x10)
    (check-equal? (second frame) #x00)
    (check-equal? (+ (arithmetic-shift (third frame) 24)
                     (arithmetic-shift (fourth frame) 16)
                     (arithmetic-shift (fifth frame) 8)
                     (sixth frame))
                  5000))

  (test-case "consecutive and flow control round trip"
    (define cf (encode-consecutive 5 '(#xAA #xBB)))
    (check-equal? (car cf) #x25)
    (define cf-decoded (try-decode-frame cf))
    (check-equal? (isotp-frame-type cf-decoded) 'consecutive)
    (check-equal? (isotp-frame-sequence cf-decoded) 5)

    (define fc (encode-flow-control 'continue-to-send 8 10))
    (define fc-decoded (try-decode-frame fc))
    (check-equal? (isotp-frame-flow-status fc-decoded) 'continue-to-send)
    (check-equal? (isotp-frame-block-size fc-decoded) 8)
    (check-equal? (isotp-frame-st-min-ms fc-decoded) 10))

  (test-case "STmin encoding follows ISO ranges"
    (check-equal? (encode-st-min 0) #x00)
    (check-equal? (encode-st-min 10) #x0A)
    (check-equal? (encode-st-min 200) #x7F)
    (check-equal? (encode-st-min 0.3) #xF3)
    (check-= (decode-st-min #xF3) 0.3 0.001)
    (check-equal? (decode-st-min #x80) 0))

  (test-case "decode rejects malformed frames"
    (check-false (try-decode-frame '()))
    (check-false (try-decode-frame '(#x05))) ; single claims 5 bytes, none present
    (check-false (try-decode-frame '(#x30 #x08))) ; flow control too short
    (check-false (try-decode-frame '(#x40 #x01 #x02))))) ; reserved type
