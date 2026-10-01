#lang racket/base

;; IsotpCodec.cs port: ISO 15765-2 frames on classic 8-byte CAN, standard
;; addressing. SF escape for payloads over 7 bytes and FF escape for lengths
;; over 4095 are both supported.

(require racket/contract
         racket/format
         racket/list
         racket/math)

(require benchpilot/core/contracts)

(provide (struct-out isotp-frame)
         isotp-frame-type?
         flow-control-status?
         classic-data-length
         try-decode-frame
         encode-single
         encode-first-prefix
         encode-consecutive
         encode-flow-control
         encode-st-min
         decode-st-min
         (struct-out can-frame))

;; ----------------------------------------------------------------------------
;; Model
;; ----------------------------------------------------------------------------

(struct isotp-frame (type sequence payload flow-status block-size st-min-ms) #:transparent)
(struct can-frame (id extended? data) #:transparent)

;; frame types: 'single 'first 'consecutive 'flow-control
(define (isotp-frame-type? v)
  (memq v '(single first consecutive flow-control)))
;; flow statuses: 'continue-to-send 'wait 'overflow
(define (flow-control-status? v)
  (memq v '(continue-to-send wait overflow)))

(define classic-data-length 8)
(define type-mask #xF0)
(define nibble-mask #x0F)

;; ----------------------------------------------------------------------------
;; Decode
;; ----------------------------------------------------------------------------

(define (try-decode-frame data)
  (cond
    [(null? data) #f]
    [else
     (define pci (car data))
     (case (arithmetic-shift (bitwise-and pci type-mask) -4)
       [(0)
        ;; Single frame; zero length nibble escapes to a 12-bit length.
        (define nibble (bitwise-and pci nibble-mask))
        (if (not (zero? nibble))
            (let ([len nibble])
              (if (< (length data) (add1 len))
                  #f
                  (isotp-frame 'single 0 (take (cdr data) len) #f 0 0)))
            (let ()
              (cond
                [(< (length data) 2) #f]
                [else
                 (define len
                   (bitwise-ior (arithmetic-shift (bitwise-and (second data) nibble-mask) 8)
                                (third data)))
                 (cond
                   [(or (zero? len) (< (length data) (+ 3 len))) #f]
                   [else (isotp-frame 'single 0 (take (list-tail data 3) len) #f 0 0)])])))]
       [(1)
        ;; First frame; the escaped form is exactly 0x10 0x00 + 32-bit length.
        (define short-form?
          (or (not (zero? (bitwise-and pci nibble-mask)))
              (and (> (length data) 1) (not (zero? (second data))))))
        (if short-form?
            (if (< (length data) 2)
                #f
                (isotp-frame 'first 0 (drop data 2) #f 0 0))
            (if (< (length data) 6)
                #f
                (isotp-frame 'first 0 (drop data 6) #f 0 0)))]
       [(2)
        (if (< (length data) 2)
            #f
            (isotp-frame 'consecutive (bitwise-and pci nibble-mask) (cdr data) #f 0 0))]
       [(3)
        (cond
          [(< (length data) 3) #f]
          [else
           (define status-nibble (bitwise-and pci nibble-mask))
           (define status
             (case status-nibble
               [(0) 'continue-to-send]
               [(1) 'wait]
               [(2) 'overflow]
               [else #f]))
           (if (not status)
               #f
               (isotp-frame 'flow-control 0 '() status (second data) (decode-st-min (third data))))])]
       [else #f])]))

;; ----------------------------------------------------------------------------
;; Encode
;; ----------------------------------------------------------------------------

(define (pad-8 frame)
  (take (append frame (make-list classic-data-length 0)) classic-data-length))

(define (encode-single payload)
  (when (> (length payload) 7)
    (raise-argument-error
     'encode-single
     "payload of at most 7 bytes (classic CAN single frames); use first/consecutive frames"
     payload))
  (pad-8 (cons (length payload) payload)))

(define (encode-first-prefix payload)
  (define n (length payload))
  (if (<= n 4095)
      (pad-8 (append (list (bitwise-ior #x10 (arithmetic-shift (bitwise-and n #x0F00) -8))
                           (bitwise-and n #xFF))
                     (take payload (min 6 n))
                     (make-list 8 0)))
      (pad-8 (append (list #x10
                           #x00
                           (bitwise-and (arithmetic-shift n -24) #xFF)
                           (bitwise-and (arithmetic-shift n -16) #xFF)
                           (bitwise-and (arithmetic-shift n -8) #xFF)
                           (bitwise-and n #xFF))
                     (take payload (min 2 n))
                     (make-list 8 0)))))

(define (encode-consecutive sequence chunk)
  (pad-8 (cons (bitwise-ior #x20 (bitwise-and sequence nibble-mask))
               (take chunk (min (length chunk) (sub1 classic-data-length))))))

(define (encode-flow-control status block-size st-min-ms)
  (define status-nibble
    (case status
      [(continue-to-send) 0]
      [(wait) 1]
      [(overflow) 2]
      [else (raise-argument-error 'encode-flow-control "flow-control-status?" status)]))
  (list (bitwise-ior #x30 status-nibble) block-size (encode-st-min st-min-ms) 0 0 0 0 0))

;; ----------------------------------------------------------------------------
;; STmin: 0x00-0x7F milliseconds, 0xF1-0xF9 hundreds of microseconds.
;; ----------------------------------------------------------------------------

(define (encode-st-min st-min-ms)
  (cond
    [(<= st-min-ms 0) #x00]
    [(< st-min-ms 1)
     (define hundreds-of-us (exact-round (* st-min-ms 10)))
     (+ #xF0 (min (max hundreds-of-us 1) 9))]
    [else (min (exact-round st-min-ms) #x7F)]))

(define (decode-st-min value)
  (cond
    [(and (>= value #xF1) (<= value #xF9)) (* (- value #xF0) 0.1)]
    [(<= value #x7F) value]
    [else 0]))
