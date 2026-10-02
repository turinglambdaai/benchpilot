#lang racket/base

;; Intel HEX / S-record parsing: golden fixtures, checksum enforcement,
;; address bases and segment merging.

(module+ test
  (require benchpilot/diagnostics/flash/image
           racket/format
           racket/list
           rackunit)

  ;; Fixture builders: correct checksums are computed, not hand-written.
  (define (ihex addr type data)
    (define count (length data))
    (define body
      (append (list count
                    (arithmetic-shift addr -8)
                    (bitwise-and addr #xFF)
                    type)
              data))
    (define checksum (bitwise-and (- 256 (apply + body)) #xFF))
    (format ":~a"
            (apply string-append
                   (append (for/list ([b (in-list body)])
                             (~r b #:base 16 #:min-width 2 #:pad-string "0"))
                           (list (~r checksum #:base 16 #:min-width 2 #:pad-string "0"))))))

  (define (ihex-line addr type data)
    (string-append (ihex addr type data) "\n"))

  (define data-16a (for/list ([i 16]) (modulo (* i 7) 256)))
  (define data-16b (for/list ([i 16]) (modulo (+ i 3) 256)))
  (define data-11 (for/list ([i 11]) (modulo (+ (* i 5) 2) 256)))

  (define ihex-sample
    (string-append
     (ihex-line #x0100 0 data-16a)
     (ihex-line #x0110 0 data-16b)
     (ihex-line #x0120 0 data-11)
     (ihex-line 0 1 '())))

  (define (srec type addr data)
    (define addr-bytes (case type [(1 9) 2] [(2 8) 3] [(3 7) 4] [else 0]))
    (define addr-list
      (for/list ([i (in-range addr-bytes)])
        (bitwise-and (arithmetic-shift addr (* -8 (- addr-bytes 1 i))) #xFF)))
    (define count (+ addr-bytes (length data) 1))
    (define sum (apply + count (append addr-list data)))
    (define checksum (bitwise-and (bitwise-not sum) #xFF))
    (define all (append (list count) addr-list data (list checksum)))
    (format "S~a~a\n"
            type
            (apply string-append
                   (for/list ([b (in-list all)])
                     (~r b #:base 16 #:min-width 2 #:pad-string "0")))))

  (define srec-sample
    (string-append
     (srec 0 0 (map char->integer (string->list "HDR")))
     (srec 1 #x1000 (list #x61 #x42 #x43))
     (srec 1 #x1008 (list #x61 #x42 #x43))
     (srec 9 0 '())))

  (test-case "intel hex parses records into ordered segments"
    (define segs (parse-intel-hex ihex-sample))
    (check-equal? (length segs) 3)
    (check-equal? (image-segment-address (first segs)) #x0100)
    (check-equal? (bytes-length (image-segment-data (first segs))) 16)
    (check-equal? (bytes-ref (image-segment-data (first segs)) 0) 0)
    (check-equal? (bytes-ref (image-segment-data (first segs)) 1) 7)
    (check-equal? (image-segment-address (third segs)) #x0120))

  (test-case "intel hex extended linear address raises the base"
    (define text
      (string-append
       (ihex-line 0 4 (list #x08 #x00))
       (ihex-line 0 0 (list #x11 #x22 #x33 #x44))
       (ihex-line 0 1 '())))
    (define segs (parse-intel-hex text))
    (check-equal? (length segs) 1)
    (check-equal? (image-segment-address (first segs)) #x08000000))

  (test-case "intel hex checksums are enforced"
    (define good (ihex 0 0 (list 1 2 3)))
    (define corrupted
      (string-append
       (substring good 0 (- (string-length good) 2))
       (if (string=? (substring good (- (string-length good) 2) (- (string-length good) 1))
                     "F")
           "0"
           "F")
       "\n"))
    (check-exn exn:fail:image? (lambda () (parse-intel-hex corrupted))))

  (test-case "s-record parses data records with checksum validation"
    (define segs (parse-srecord srec-sample))
    (check-equal? (length segs) 2)
    (check-equal? (image-segment-address (first segs)) #x1000)
    (check-equal? (bytes->list (image-segment-data (first segs)))
                  (list #x61 #x42 #x43)))

  (test-case "s-record rejects corrupted bytes"
    (define good (srec 1 #x1000 (list #x61 #x42 #x43)))
    (define corrupted
      (string-append
       (substring good 0 8)
       (string (if (char=? (string-ref good 8) #\6) #\7 #\6))
       (substring good 9)))
    (check-exn exn:fail:image? (lambda () (parse-srecord corrupted))))

  (test-case "adjacent records merge into contiguous segments"
    (define segs (parse-intel-hex ihex-sample))
    (define merged (merge-image-segments segs))
    (check-equal? (length merged) 1)
    (check-equal? (bytes-length (image-segment-data (first merged))) 43)
    (check-equal? (image-segment-address (first merged)) #x0100))

  (test-case "format detection covers the common extensions"
    (check-equal? (image-format-for-path "fw.hex") "hex")
    (check-equal? (image-format-for-path "app.ihex") "hex")
    (check-equal? (image-format-for-path "app.s19") "srecord")
    (check-equal? (image-format-for-path "app.srec") "srecord")
    (check-false (image-format-for-path "app.bin"))))
