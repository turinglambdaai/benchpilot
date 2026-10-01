#lang racket/base

;; Evidence pipeline, port of OperationEvidence.cs, ObservationEvidence.cs
;; and TargetContextEvidence.cs. Pure stores and extractors; the runtime
;; state machine drives them. All bounds mirror the C# constants.

(require racket/format
         racket/list
         racket/match
         racket/string)

(require "contracts.rkt")

;; evidence store
(provide (struct-out evidence-store)
         make-evidence-store
         call-with-mutex
         evidence-store-put!
         evidence-store-fetch
         ;; context rings
         (struct-out context-store)
         make-context-store
         context-store-record!
         context-store-snapshot
         ;; failure scope
         make-failure-scope
         failure-scope?
         failure-scope-runtime-store
         failure-scope-target-id
         call-with-failure-scope
         append-failure-context
         ;; extractors
         extract-operation-evidence
         extract-serial-observation-evidence
         operation-cancellation-evidence
         operation-deadline-evidence
         operation-exception-evidence
         observation-cancellation-evidence
         observation-deadline-evidence
         observation-exception-evidence
         evidence-bound-items
         format-number-0-3
         evidence-bound-item)

;; ----------------------------------------------------------------------------
;; Constants (OperationEvidenceStore / ObservationEvidenceStore)
;; ----------------------------------------------------------------------------

(define evidence-capacity 128)
(define evidence-max-items 8)
(define evidence-max-text-length 4000)
(define evidence-max-summary-length 512)
(define evidence-max-metadata-items 16)
(define evidence-max-metadata-value-length 512)
(define context-capacity-per-target 8)
(define context-default-snapshot-count 3)
(define context-max-age-millis (* 10 60 1000))

;; ----------------------------------------------------------------------------
;; Bounded in-memory evidence store (one bundle per operation/observation).
;; ----------------------------------------------------------------------------

(struct evidence-store (mutex by-id order) #:transparent)

(define (make-evidence-store)
  (evidence-store (make-semaphore 1) (make-hash) (make-queue*)))

(define (make-queue*)
  (box '()))

(define (evidence-store-put! store id evidence)
  (call-with-mutex (evidence-store-mutex store)
                   (lambda ()
                     (hash-set! (evidence-store-by-id store) (string-foldcase id) evidence)
                     (define q (evidence-store-order store))
                     (unless (member (string-foldcase id) (unbox q))
                       (set-box! q (append (unbox q) (list (string-foldcase id))))
                       (let loop ()
                         (when (> (length (unbox q)) evidence-capacity)
                           (hash-remove! (evidence-store-by-id store) (car (unbox q)))
                           (set-box! q (cdr (unbox q)))
                           (loop)))))))

(define (evidence-store-fetch store id)
  (hash-ref (evidence-store-by-id store) (string-foldcase id) #f))

(define (call-with-mutex sema proc)
  (semaphore-wait/enable-break sema)
  (with-handlers ([exn:fail? (lambda (e)
                               (semaphore-post sema)
                               (raise e))])
    (begin0 (proc)
      (semaphore-post sema))))

;; Items of one bundle: bounded like the C# BoundItem.
(define (evidence-bound-items items)
  (for/list ([item (in-list (take items (min evidence-max-items (length items))))])
    (evidence-bound-item item)))

(define (evidence-bound-item item)
  (struct-copy
   bench-evidence-item
   item
   [kind (or (bound-string (bench-evidence-item-kind item) 128) "evidence")]
   [summary (or (bound-string (bench-evidence-item-summary item) evidence-max-summary-length) "")]
   [text (bound-string (bench-evidence-item-text item) evidence-max-text-length)]
   [metadata
    (let ([md (bench-evidence-item-metadata item)])
      (and md
           (for/hash ([pair (in-list (hash-take md
                                                (min evidence-max-metadata-items (hash-count md))))])
             (values (or (bound-string (car pair) 128) "")
                     (or (bound-string (cdr pair) evidence-max-metadata-value-length) "")))))]))

(define (hash-take h n)
  (for/list ([pair (in-hash-pairs h)]
             [i (in-range n)])
    pair))

(define (bound-string v max-length)
  (and v
       (string? v)
       (not (zero? (string-length v)))
       (if (<= (string-length v) max-length)
           v
           (substring v 0 max-length))))

;; ----------------------------------------------------------------------------
;; Per-target context rings (TargetContextEvidence). The runtime owns one
;; store; only caller-requested results are recorded, no background I/O.
;; ----------------------------------------------------------------------------

(struct context-store (mutex by-target) #:transparent)
(struct context-entry (captured-at-millis item) #:transparent)

(define (make-context-store)
  (context-store (make-semaphore 1) (make-hash)))

(define (context-store-record! store target-id item)
  (call-with-mutex (context-store-mutex store)
                   (lambda ()
                     (define key (string-foldcase target-id))
                     (define entries
                       (append (hash-ref (context-store-by-target store) key '())
                               (list (context-entry (now-millis*) item))))
                     (hash-set! (context-store-by-target store)
                                key
                                (if (> (length entries) context-capacity-per-target)
                                    (list-tail entries
                                               (- (length entries) context-capacity-per-target))
                                    entries)))))

(define (context-store-snapshot store target-id [max-items context-default-snapshot-count])
  (when (<= max-items 0)
    (raise-argument-error 'context-store-snapshot "positive integer" max-items))
  (call-with-mutex
   (context-store-mutex store)
   (lambda ()
     (define key (string-foldcase target-id))
     (define now (now-millis*))
     (define fresh
       (filter (lambda (e) (<= (- now (context-entry-captured-at-millis e)) context-max-age-millis))
               (hash-ref (context-store-by-target store) key '())))
     (define newest-first (reverse fresh))
     (for/list ([entry (in-list
                        (take newest-first
                              (min max-items context-default-snapshot-count (length newest-first))))])
       (with-age (context-entry-item entry) (context-entry-captured-at-millis entry) now)))))

(define (with-age item captured-at-millis now)
  (define md
    (hash-set* (or (bench-evidence-item-metadata item) (hasheq))
               "capturedAtUtc"
               (utc-iso captured-at-millis)
               "ageMs"
               (~a (max 0 (- now captured-at-millis)) #:min-width 1 #:pad-string "0")))
  (struct-copy bench-evidence-item item [metadata md]))

(define now-millis* (lambda () (inexact->exact (floor (current-inexact-milliseconds)))))

;; ----------------------------------------------------------------------------
;; Failure scope: the Racket analogue of TargetContextEvidence's AsyncLocal
;; scope marking flash/reset calls so their failures gain target context.
;; ----------------------------------------------------------------------------

(struct failure-scope (runtime-store target-id operation-kind) #:transparent)

(define failure-scope-parameter (make-parameter #f))

(define (make-failure-scope runtime-store target-id operation-kind)
  (failure-scope runtime-store target-id operation-kind))

(define (call-with-failure-scope scope thunk)
  (parameterize ([failure-scope-parameter scope])
    (thunk)))

(define (append-failure-context primary-items)
  (define scope (failure-scope-parameter))
  (if (not scope)
      primary-items
      (let ([context (context-store-snapshot (failure-scope-runtime-store scope)
                                             (failure-scope-target-id scope))])
        (if (null? context)
            primary-items
            (append primary-items context)))))

;; ----------------------------------------------------------------------------
;; Operation evidence extractor (OperationEvidenceExtractor). Input results
;; are already bounded by the drivers; this layer only renders them.
;; ----------------------------------------------------------------------------

(define (bool-str v)
  (if v "true" "false"))
(define (format-number-0-3 v)
  (define s (~r v #:precision '(= 3)))
  (if (string-contains? s ".")
      (regexp-replace #rx"\\.?0+$" s "")
      s))

(define (item kind summary [text #f] [metadata #f])
  (bench-evidence-item kind summary text metadata))

(define (extract-operation-evidence result)
  (define primary
    (cond
      [(power-on-result? result)
       (list (item "power.result"
                   (if (power-on-result-ok result)
                       "Power-on completed."
                       "Power-on returned a device error.")
                   (power-on-result-error result)
                   (hasheq "ok"
                           (bool-str (power-on-result-ok result))
                           "voltageV"
                           (format-number-0-3 (power-on-result-voltage result))
                           "currentMa"
                           (format-number-0-3 (power-on-result-current-ma result))
                           "settled"
                           (bool-str (power-on-result-settled result)))))]
      [(power-off-result? result)
       (list (item "power.result"
                   (if (power-off-result-ok result)
                       "Power-off completed."
                       "Power-off returned a device error.")
                   (power-off-result-error result)
                   (hasheq "ok" (bool-str (power-off-result-ok result)))))]
      [(flash-result? result)
       (list (item "flash.result"
                   (if (flash-result-ok result) "Flash completed." "Flash returned a device error.")
                   (flash-result-error result)
                   (hasheq "ok"
                           (bool-str (flash-result-ok result))
                           "bytes"
                           (~a (flash-result-bytes result))
                           "durationMs"
                           (~a (flash-result-duration-ms result)))))]
      [(reset-result? result)
       (list (item "reset.result"
                   (if (reset-result-ok result) "Reset completed." "Reset returned a device error.")
                   (reset-result-error result)
                   (hasheq "ok" (bool-str (reset-result-ok result)))))]
      [else (list (item "operation.result" "Operation returned no result payload."))]))
  (if (and (or (flash-result? result) (reset-result? result))
           (not (if (flash-result? result)
                    (flash-result-ok result)
                    (reset-result-ok result))))
      (append-failure-context primary)
      primary))

(define (operation-cancellation-evidence)
  (list (item "runtime.cancelled"
              "Operation was cancelled before normal completion."
              "Operation cancelled.")))

(define (operation-deadline-evidence deadline-ms deadline-at-iso)
  (append-failure-context
   (list (item "runtime.deadline"
               "Operation exceeded its Runtime deadline."
               #f
               (hasheq "deadlineMs" (~a deadline-ms) "deadlineAtUtc" deadline-at-iso)))))

(define (operation-exception-evidence message exception-type)
  (append-failure-context (list (item "runtime.exception"
                                      "Operation terminated with an infrastructure exception."
                                      message
                                      (hasheq "exceptionType" exception-type)))))

;; ----------------------------------------------------------------------------
;; Serial observation evidence extractor (SerialObservationEvidenceExtractor).
;; ----------------------------------------------------------------------------

(define (extract-serial-observation-evidence kind result [extra #f])
  (match (list kind result)
    [(list 'open (serial-open-result ok port baud error _))
     (list (item "serial.open"
                 (if ok "Serial channel opened." "Serial open returned a device error.")
                 error
                 (hasheq "ok" (bool-str ok) "port" port "baud" (~a baud))))]
    [(list 'wait (serial-wait-result ok matched matched-line elapsed-ms error _))
     (define base
       (list (item "serial.wait"
                   (cond
                     [matched "Serial pattern matched."]
                     [ok "Serial wait completed without a match."]
                     [else "Serial wait returned a device error."])
                   (or error matched-line)
                   (hasheq "ok"
                           (bool-str ok)
                           "matched"
                           (bool-str matched)
                           "pattern"
                           (first extra)
                           "timeoutMs"
                           (~a (second extra))
                           "elapsedMs"
                           (~a elapsed-ms)))))
     (define window (third extra))
     (cond
       [(and (serial-window-result? window)
             (serial-window-result-ok window)
             (not (null? (serial-window-result-lines window))))
        (append
         base
         (list
          (item "serial.failure-window"
                (format "Recent serial context captured around an unmatched/failed wait (~a lines)."
                        (length (serial-window-result-lines window)))
                (string-join (serial-window-result-lines window) "\n")
                (hasheq "lineCount" (~a (length (serial-window-result-lines window)))))))]
       [(and (serial-window-result? window) (not (serial-window-result-ok window)))
        (append base
                (list (item "serial.failure-window"
                            "Recent serial context could not be read."
                            (serial-window-result-error window))))]
       [else base])]
    [(list 'window (serial-window-result ok lines error _))
     (list (item "serial.window"
                 (if ok
                     (format "Serial window returned ~a lines." (length lines))
                     "Serial window returned a device error.")
                 (if ok
                     (string-join lines "\n")
                     error)
                 (hasheq "ok" (bool-str ok) "lineCount" (~a (length lines)))))]
    [(list 'send (serial-send-result ok error _))
     (list (item "serial.send"
                 (if ok "Serial send completed." "Serial send returned a device error.")
                 error
                 (hasheq "ok" (bool-str ok) "charCount" (~a (second extra)))))]
    [_ (error 'extract-serial-observation-evidence "unknown observation result")]))

(define (observation-cancellation-evidence)
  (list (item "runtime.cancelled"
              "Observation was cancelled before normal completion."
              "Observation cancelled.")))

(define (observation-deadline-evidence deadline-ms deadline-at-iso)
  (list (item "runtime.deadline"
              "Observation exceeded its Runtime deadline."
              #f
              (hasheq "deadlineMs" (~a deadline-ms) "deadlineAtUtc" deadline-at-iso))))

(define (observation-exception-evidence message exception-type)
  (list (item "runtime.exception"
              "Observation terminated with an infrastructure exception."
              message
              (hasheq "exceptionType" exception-type))))
