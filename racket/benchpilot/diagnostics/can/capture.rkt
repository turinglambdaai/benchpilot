#lang racket/base

;; CAN capture sessions and DBC signal decoding.
;;
;; A capture session subscribes to a bus (gen:can-bus) and keeps a bounded
;; newest-first ring of frames with timestamps. Sessions can dump their ring
;; to a JSONL artifact (bounded capture artifacts) and answer signal queries
;; against a parsed DBC: wait/assert/measure without ever holding an
;; unbounded CAN log.

(require json
         racket/format
         racket/list
         racket/string)

(require racket/generic

         benchpilot/core/contracts
         benchpilot/core/persist
         benchpilot/core/runtime-state
         benchpilot/diagnostics/isotp/codec)

;; A diagnostics channel can expose its underlying bus for capture/transmit
;; when one exists (real CAN); simulated in-process channels do not.
(define-generics diag-bus-provider
  (diag-channel-bus diag-bus-provider)
  (diag-channel-bus-available? diag-bus-provider))

(provide (struct-out capture-session)
         make-capture-session
         capture-session-record!
         capture-session-frames
         capture-session-clear!
         stop-capture!
         capture-session-frames-json
         (struct-out dbc-message)
         (struct-out dbc-signal)
         parse-dbc
         dbc-messages
         dbc-decode-frame
         dbc-encode-signals
         can-frame-emit-json
         gen:diag-bus-provider
         diag-bus-provider?
         diag-channel-bus
         diag-channel-bus-available?)

;; ----------------------------------------------------------------------------
;; Capture sessions
;; ----------------------------------------------------------------------------

(struct capture-session
  (id target-id resource-id bus start-millis ring-box capacity stop-box))

(define (make-capture-session id target-id resource-id bus [capacity 4096])
  (capture-session id target-id resource-id bus (now-millis)
                   (box '()) capacity (box #f)))

(define (capture-session-record! session frame)
  (unless (unbox (capture-session-stop-box session))
    (define b (capture-session-ring-box session))
    (define next (cons (cons (now-millis) frame) (unbox b)))
    (set-box! b (if (> (length next) (capture-session-capacity session))
                    ;; the front of the list is the newest; drop from the back
                    (take next (capture-session-capacity session))
                    next))))

(define (capture-session-frames session)
  ;; newest first
  (unbox (capture-session-ring-box session)))

(define (capture-session-clear! session)
  (set-box! (capture-session-ring-box session) '()))

(define (stop-capture! session)
  (set-box! (capture-session-stop-box session) #t))

(define (capture-session-frames-json session [limit 256])
  (define frames (capture-session-frames session))
  (for/list ([entry (in-list (take frames (min limit (length frames))))])
    (can-frame-emit-json (car entry) (cdr entry))))

(define (can-frame-emit-json millis frame)
  (hasheq 't (or (utc-iso-millis millis) 'null)
          'id (format "0x~a" (string-upcase (~r (can-frame-id frame) #:base 16)))
          'extended (can-frame-extended? frame)
          'data (apply string-append
                       (for/list ([b (in-list (can-frame-data frame))])
                         (~r b #:base 16 #:min-width 2 #:pad-string "0")))))

;; ----------------------------------------------------------------------------
;; DBC: the BO_/SG_ subset — message headers, signal layout (Intel and
;; Motorola byte order), factors, offsets, signedness.
;; ----------------------------------------------------------------------------

(struct dbc-message (id name length signals) #:transparent)
(struct dbc-signal (name start-bit bit-length little-endian signed factor offset) #:transparent)

(define (dbc-messages db) db)

(define (parse-dbc text)
  (define messages (make-hash)) ; id -> dbc-message (signals accumulated)
  (define order '())
  (for ([raw (in-list (string-split text "\n"))])
    (define line (string-trim raw))
    (cond
      [(string-prefix? line "BO_ ")
       (define m (regexp-match #rx"^BO_ ([0-9]+) ([A-Za-z0-9_]+): *([0-9]+)" line))
       (when m
         (define id (string->number (second m)))
         (hash-set! messages id (dbc-message id (third m)
                                             (string->number (fourth m)) '()))
         (set! order (cons id order)))]
      [(string-prefix? line "SG_ ")
       (define m (regexp-match
                  #rx"^SG_ ([A-Za-z0-9_]+) *: *([0-9]+)\\|([0-9]+)@([01])([+-]) \\(([0-9.+-]+),([0-9.+-]+)\\)"
                  line))
       ;; SG_ lines follow their BO_; attach to the most recent message.
       (define last-id (and (pair? order) (car order)))
       (when (and m last-id)
         (define msg (hash-ref messages last-id))
         (define signal
           (dbc-signal (second m)
                       (string->number (third m))
                       (string->number (fourth m))
                       (string=? (fifth m) "1")
                       (string=? (sixth m) "-")
                       (string->number (seventh m))
                       (string->number (eighth m))))
         (define updated
           (struct-copy dbc-message msg
                        [signals (append (dbc-message-signals msg)
                                         (list signal))]))
         (hash-set! messages last-id updated))]))
  (for/list ([id (in-list (reverse order))])
    (hash-ref messages id)))

;; Extracts a bit field from bytes (MSB-first bit numbering like DBC).
(define (extract-bits data start-bit bit-length little-endian)
  (define total (bytes-length data))
  (if little-endian
      ;; Intel: frame bit (start+i) carries raw bit i (LSB first).
      (let loop ([i 0] [acc 0])
        (if (= i bit-length)
            acc
            (let* ([bit-pos (+ start-bit i)]
                   [byte-idx (quotient bit-pos 8)]
                   [bit-in-byte (modulo bit-pos 8)])
              (loop (add1 i)
                    (bitwise-ior acc
                                 (arithmetic-shift
                                  (if (>= byte-idx total)
                                      0
                                      (if (zero? (bitwise-and
                                                  (bytes-ref data byte-idx)
                                                  (arithmetic-shift 1 bit-in-byte)))
                                          0 1))
                                  i))))))
      ;; Motorola: bits are MSB-first across the frame window.
      (let loop ([i 0] [acc 0])
        (if (= i bit-length)
            acc
            (let* ([bit-pos (+ start-bit i)]
                   [byte-idx (quotient bit-pos 8)]
                   [bit-in-byte (modulo bit-pos 8)])
              (loop (add1 i)
                    (bitwise-ior
                     (arithmetic-shift acc 1)
                     (if (>= byte-idx total)
                         0
                         (if (zero? (bitwise-and (bytes-ref data byte-idx)
                                                 (arithmetic-shift 1 (- 7 bit-in-byte))))
                             0 1)))))))))

(define (dbc-decode-frame db frame-id data)
  (define msg (findf (lambda (m) (= (dbc-message-id m) frame-id)) db))
  (and msg
       (for/hash ([sig (in-list (dbc-message-signals msg))])
         (values (string->symbol (dbc-signal-name sig))
                 (let* ([raw (extract-bits data
                                           (dbc-signal-start-bit sig)
                                           (dbc-signal-bit-length sig)
                                           (dbc-signal-little-endian sig))]
                        [raw* (if (dbc-signal-signed sig)
                                  (let ([bits (dbc-signal-bit-length sig)])
                                    (if (>= raw (arithmetic-shift 1 (sub1 bits)))
                                        (- raw (arithmetic-shift 1 bits))
                                        raw))
                                  raw)]
                        [value (+ (* (dbc-signal-factor sig) raw*)
                                  (dbc-signal-offset sig))])
                   (if (and (integer? value) (= (dbc-signal-factor sig) 1)
                            (= (dbc-signal-offset sig) 0))
                       value
                       (exact->inexact value)))))))

(define (dbc-encode-signals msg values)
  ;; Encodes only the named signals; unsupported packing (non-byte-aligned
  ;; Motorola) raises validation instead of guessing.
  (define data (make-bytes (max 1 (dbc-message-length msg)) 0))
  (for ([sig (in-list (dbc-message-signals msg))])
    (define v (hash-ref values (string->symbol (dbc-signal-name sig)) #f))
    (when v
      (unless (dbc-signal-little-endian sig)
        (raise-validation
         (format "Signal '~a' uses Motorola byte order; transmit packing for it is not supported yet."
                 (dbc-signal-name sig))))
      (define raw
        (inexact->exact
         (floor (/ (- v (dbc-signal-offset sig)) (dbc-signal-factor sig)))))
      (define bits (dbc-signal-bit-length sig))
      (when (or (negative? raw) (>= raw (arithmetic-shift 1 bits)))
        (raise-validation
         (format "Value for '~a' does not fit in ~a bits." (dbc-signal-name sig) bits)))
      (for ([i (in-range bits)])
        (define bit-pos (+ (dbc-signal-start-bit sig) i))
        (define byte-idx (quotient bit-pos 8))
        (define bit-in-byte (modulo bit-pos 8))
        (define bit-val
          (arithmetic-shift 1 bit-in-byte))
        (if (bitwise-bit-set? raw i)
            (bytes-set! data byte-idx (bitwise-ior (bytes-ref data byte-idx) bit-val))
            (bytes-set! data byte-idx
                        (bitwise-and (bytes-ref data byte-idx)
                                     (bitwise-not bit-val)))))))
  data)
