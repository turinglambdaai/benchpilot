#lang racket/base

;; Firmware image model: Intel HEX and Motorola S-record files parse into
;; address/data segments, so one declarative flash plan can flash a
;; multi-region image the same way it flashes inline hex data. BIN stays
;; explicit-address by design (BenchPilot never guesses flash addresses).

(require racket/format
         racket/list
         racket/string)

(require benchpilot/core/contracts)

(provide (struct-out image-segment)
         (struct-out exn:fail:image)
         parse-intel-hex
         parse-srecord
         image-segments?
         merge-image-segments
         image-format-for-path)

(struct image-segment (address data) #:transparent)
(struct exn:fail:image exn:fail () #:transparent)

(define (image-error message)
  (raise (exn:fail:image message (current-continuation-marks))))

(define (hex-digit? c)
  (or (char-numeric? c)
      (and (char>=? (char-upcase c) #\A) (char-upcase c) (char<=? (char-upcase c) #\F))))

(define (hex-byte s i)
  (string->number (substring s i (+ i 2)) 16))

(define (byte-list s offset count)
  (for/list ([i (in-range count)])
    (hex-byte s (+ offset (* 2 i)))))

;; ---------------------------------------------------------------------------
;; Intel HEX (I32HEX): :llaaaatt[dd...]cc, types 00 data, 01 EOF,
;; 02 extended segment address, 04 extended linear address.
;; ---------------------------------------------------------------------------

(define (parse-intel-hex text)
  (define segments
    (let loop ([lines (string-split text "\n")]
               [base 0]
               [acc '()]
               [at-eof? #f])
      (if (or (null? lines) at-eof?)
          (reverse acc)
          (let* ([raw (string-trim (car lines))])
            (cond
              [(string-blank? raw) (loop (cdr lines) base acc at-eof?)]
              [(not (string-prefix? raw ":"))
               (image-error "Intel HEX line does not start with ':'")]
              [else
               (define body (substring raw 1))
               (define count (hex-byte body 0))
               (define offset (+ (arithmetic-shift (hex-byte body 2) 8)
                                 (hex-byte body 4)))
               (define type (hex-byte body 6))
               (define expected-len (+ 5 count)) ; count + addr + type + cksum
               (unless (>= (quotient (string-length body) 2) expected-len)
                 (image-error "Intel HEX record is truncated"))
               (define checksum (hex-byte body (* 2 (+ 4 count))))
               (define sum
                 (for/sum ([i (in-range (+ 4 count))])
                   (hex-byte body (* 2 i))))
               (unless (zero? (modulo (+ sum checksum) 256))
                 (image-error "Intel HEX checksum mismatch"))
               (define data (byte-list body 8 count))
               (case type
                 [(0)
                  (define addr (+ base offset))
                  (loop (cdr lines) base
                        (cons (image-segment addr (list->bytes data)) acc)
                        at-eof?)]
                 [(1) (loop (cdr lines) base acc #t)]
                 [(2)
                  ;; extended segment: base = value << 4
                  (loop (cdr lines)
                        (* (+ (arithmetic-shift (first data) 8) (second data)) 16)
                        acc at-eof?)]
                 [(4)
                  ;; extended linear: base = value << 16
                  (loop (cdr lines)
                        (* (+ (arithmetic-shift (first data) 8) (second data))
                           65536)
                        acc at-eof?)]
                 [else (loop (cdr lines) base acc at-eof?)])])))))
  segments)

;; ---------------------------------------------------------------------------
;; Motorola S-record: S0 header, S1/S2/S3 data, S7/S8/S9 stop; one's
;; complement checksum over count+address+data.
;; ---------------------------------------------------------------------------

(define (srec-address-length type)
  (case type
    [(1 9) 2]
    [(2 8) 3]
    [(3 7) 4]
    [else 0]))

(define (parse-srecord text)
  (let loop ([lines (string-split text "\n")]
             [acc '()]
             [at-stop? #f])
    (if (or (null? lines) at-stop?)
        (reverse acc)
        (let ([line (string-trim (car lines))])
          (cond
            [(string-blank? line) (loop (cdr lines) acc at-stop?)]
            [(not (string-prefix? line "S"))
             (image-error "S-record line does not start with 'S'")]
            [else
             (define type (string->number (substring line 1 2)))
             (define count (hex-byte line 2))
             ;; "S" and the type are not bytes: byte i lives at char 2+2i.
             (define total (quotient (- (string-length line) 2) 2))
             (unless (= count (- total 1))
               (image-error "S-record byte count mismatch"))
             (define sum
               (for/sum ([i (in-range count)])
                 (hex-byte line (* 2 (+ 1 i)))))
             (define checksum (hex-byte line (* 2 (+ 1 count))))
             (unless (= (bitwise-and (bitwise-not sum) #xFF) checksum)
               (image-error "S-record checksum mismatch"))
             (case type
               [(1 2 3)
                (define addr-bytes (srec-address-length type))
                (define addr
                  (for/sum ([i (in-range addr-bytes)])
                    (arithmetic-shift (hex-byte line (* 2 (+ 2 i)))
                                      (* 8 (- addr-bytes 1 i)))))
                ;; byte 0 is the count; data begins after count + address.
            (define data-start (+ 2 (* 2 (add1 addr-bytes))))
                (define data-count (- count addr-bytes 1))
                (define data (byte-list line data-start data-count))
                (loop (cdr lines)
                      (cons (image-segment addr (list->bytes data)) acc)
                      at-stop?)]
               [(7 8 9) (loop (cdr lines) acc #t)]
               [else (loop (cdr lines) acc at-stop?)])])))))

;; ---------------------------------------------------------------------------
;; Shared helpers
;; ---------------------------------------------------------------------------

(define (image-segments? v)
  (and (list? v)
       (andmap (lambda (s) (image-segment? s)) v)))

(define (merge-image-segments segments [gap 0])
  ;; Coalesces adjacent records into contiguous segments so a flash plan
  ;; carries one segment per contiguous region.
  (define sorted
    (sort segments (lambda (a b) (< (image-segment-address a)
                                    (image-segment-address b)))))
  (let loop ([remaining sorted]
             [current #f]
             [acc '()])
    (cond
      [(null? remaining)
       (reverse (if current (cons current acc) acc))]
      [else
       (define seg (car remaining))
       (if (not current)
           (loop (cdr remaining) seg acc)
           (let* ([cur-end (+ (image-segment-address current)
                              (bytes-length (image-segment-data current)))]
                  [next-start (image-segment-address seg)]
                  [next-end (+ next-start (bytes-length (image-segment-data seg)))])
             (cond
               [(<= next-start cur-end)
                ;; overlapping or adjacent: extend
                (if (<= next-end cur-end)
                    (loop (cdr remaining) current acc)
                    (let* ([merged (make-bytes (- next-end
                                                  (image-segment-address current)))]
                           [_ (memcpy-bytes merged 0 (image-segment-data current))]
                           [_ (memcpy-bytes merged
                                            (- next-start
                                               (image-segment-address current))
                                            (image-segment-data seg))])
                      (loop (cdr remaining)
                            (image-segment (image-segment-address current) merged)
                            acc)))]
               [(<= (- next-start cur-end) gap)
                (let* ([merged (make-bytes (- next-end
                                              (image-segment-address current)))]
                       [_ (memcpy-bytes merged 0 (image-segment-data current))]
                       [_ (memcpy-bytes merged
                                        (- next-start
                                           (image-segment-address current))
                                        (image-segment-data seg))])
                  (loop (cdr remaining)
                        (image-segment (image-segment-address current) merged)
                        acc))]
               [else
                (loop (cdr remaining) seg (cons current acc))])))])))

(define (memcpy-bytes dest dest-offset src)
  (for ([b (in-bytes src)]
        [i (in-naturals)])
    (bytes-set! dest (+ dest-offset i) b)))

(define (image-format-for-path path)
  (define lower (string-downcase path))
  (cond
    [(or (string-suffix? lower ".hex") (string-suffix? lower ".ihex")) "hex"]
    [(or (string-suffix? lower ".s19") (string-suffix? lower ".srec")
         (string-suffix? lower ".s28") (string-suffix? lower ".sx")
         (string-suffix? lower ".s")) "srecord"]
    [else #f]))
