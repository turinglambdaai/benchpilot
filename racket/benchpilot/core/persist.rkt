#lang racket/base

;; Persistent evidence/artifact store: selected evidence and larger artifacts
;; survive daemon restarts. Layout under the store directory (default
;; ~/.benchpilot/store; BENCHPILOT_STORE_DIR overrides; BENCHPILOT_STORE=0
;; disables):
;;
;;   operations.jsonl    one completed operation record + evidence per line
;;   observations.jsonl  the same for observations
;;   artifacts/<opid>.<name>   larger evidence that must stay out of LLM context
;;
;; The daemon seeds its in-memory history/evidence from these files at start
;; and appends on every completed record.

(require json
         racket/date
         racket/file
         racket/format
         racket/list
         racket/string)

(require benchpilot/core/contracts
         benchpilot/core/hashing)

(provide (struct-out exn:fail:persist-disabled)
         (struct-out persist-store)
         persist-store-path
         open-persist-store
         persist-operation!
         persist-observation!
         record->jsexpr
         observation-record->jsexpr
         persist-load-recent
         persist-artifact!
         persist-artifact-file
         utc-iso-millis)

(struct exn:fail:persist-disabled exn:fail () #:transparent)

;; ----------------------------------------------------------------------------
;; Time
;; ----------------------------------------------------------------------------

(define (utc-iso-millis millis)
  (and millis
       (let* ([sec (quotient millis 1000)]
              [frac (modulo millis 1000)]
              [d (seconds->date sec #f)])
         (string-append
          (~a (date-year d) #:width 4 #:pad-string "0")
          "-" (~r (date-month d) #:min-width 2 #:pad-string "0")
          "-" (~r (date-day d) #:min-width 2 #:pad-string "0")
          "T" (~r (date-hour d) #:min-width 2 #:pad-string "0")
          ":" (~r (date-minute d) #:min-width 2 #:pad-string "0")
          ":" (~r (date-second d) #:min-width 2 #:pad-string "0")
          "." (~r frac #:min-width 3 #:pad-string "0")
          "Z"))))

;; ----------------------------------------------------------------------------
;; Store
;; ----------------------------------------------------------------------------

(struct persist-store (path mutex))

(define (open-persist-store [dir #f])
  (when (equal? (getenv "BENCHPILOT_STORE") "0")
    (raise (exn:fail:persist-disabled
            "The persistent store is disabled (BENCHPILOT_STORE=0)."
            (current-continuation-marks))))
  (define path
    (or dir
        (getenv "BENCHPILOT_STORE_DIR")
        (path->string (build-path (or (getenv "USERPROFILE") (getenv "HOME") ".")
                                  ".benchpilot" "store"))))
  (make-directory* (build-path path "artifacts"))
  (persist-store path (make-semaphore 1)))

(define (with-store-mutex store proc)
  (semaphore-wait/enable-break (persist-store-mutex store))
  (begin0 (proc)
    (semaphore-post (persist-store-mutex store))))

(define (append-line! store file-name jsexpr)
  ;; Serialize first: a serialization failure then leaves no torn line
  ;; behind for the next append to concatenate onto.
  (define line (jsexpr->string jsexpr))
  (with-store-mutex
   store
   (lambda ()
     (call-with-output-file*
      (build-path (persist-store-path store) file-name)
      (lambda (out)
        (display line out)
        (newline out))
      #:mode 'text
      #:exists 'append))))

;; ----------------------------------------------------------------------------
;; Record persistence
;; ----------------------------------------------------------------------------

(define (json-keys->symbols h)
  (for/hash ([(k v) (in-hash h)])
    (values (if (symbol? k) k (string->symbol (format "~a" k))) v)))

(define (evidence-items->jsexpr items)
  (for/list ([item (in-list items)])
    (hasheq 'kind (bench-evidence-item-kind item)
            'summary (bench-evidence-item-summary item)
            'text (or (bench-evidence-item-text item) 'null)
            'metadata
            (json-keys->symbols
             (or (bench-evidence-item-metadata item) (hasheq))))))

(define (record->jsexpr record evidence)
  (hasheq 'kind "operation"
          'id (bench-operation-record-id record)
          'targetId (bench-operation-record-target-id record)
          'operation (bench-operation-record-kind record)
          'resourceIds (bench-operation-record-resource-ids record)
          'startedAtUtc (or (utc-iso-millis (bench-operation-record-started-at-millis record)) 'null)
          'startedAtMillis (bench-operation-record-started-at-millis record)
          'completedAtUtc (or (utc-iso-millis (bench-operation-record-completed-at-millis record)) 'null)
          'completedAtMillis (bench-operation-record-completed-at-millis record)
          'durationMs (bench-operation-record-duration-ms record)
          'deadlineAtUtc (or (utc-iso-millis (bench-operation-record-deadline-at-millis record)) 'null)
          'deadlineAtMillis (or (bench-operation-record-deadline-at-millis record) 'null)
          'state (bench-operation-record-state record)
          'error (or (bench-operation-record-error record) 'null)
          'items (if evidence
                     (evidence-items->jsexpr (bench-operation-evidence-items evidence))
                     '())))

(define (observation-record->jsexpr record evidence)
  (hasheq 'kind "observation"
          'id (bench-observation-record-id record)
          'targetId (bench-observation-record-target-id record)
          'observation (bench-observation-record-kind record)
          'resourceIds (bench-observation-record-resource-ids record)
          'startedAtUtc (or (utc-iso-millis (bench-observation-record-started-at-millis record)) 'null)
          'startedAtMillis (bench-observation-record-started-at-millis record)
          'completedAtUtc (or (utc-iso-millis (bench-observation-record-completed-at-millis record)) 'null)
          'completedAtMillis (bench-observation-record-completed-at-millis record)
          'durationMs (bench-observation-record-duration-ms record)
          'deadlineAtUtc (or (utc-iso-millis (bench-observation-record-deadline-at-millis record)) 'null)
          'deadlineAtMillis (or (bench-observation-record-deadline-at-millis record) 'null)
          'state (bench-observation-record-state record)
          'error (or (bench-observation-record-error record) 'null)
          'items (if evidence
                     (evidence-items->jsexpr (bench-observation-evidence-items evidence))
                     '())))

(define (persist-operation! store record evidence)
  (with-handlers ([exn:fail? (lambda (_) (void))])
    (append-line! store "operations.jsonl" (record->jsexpr record evidence))))

(define (persist-observation! store record evidence)
  (with-handlers ([exn:fail? (lambda (_) (void))])
    (append-line! store "observations.jsonl" (observation-record->jsexpr record evidence))))

;; Reads the most recent entries, oldest-first (file order on the tail).
(define (persist-load-recent store file-name limit)
  (with-handlers ([exn:fail? (lambda (_) '())])
    (with-store-mutex
     store
     (lambda ()
       (define path (build-path (persist-store-path store) file-name))
       (if (file-exists? path)
           (let ()
             (define entries
               (for/list ([line (in-list (file->lines path))]
                          #:unless (string-blank? line))
                 (with-handlers ([exn:fail? (lambda (_) #f)])
                   (read-json (open-input-string line)))))
             (define parsed (filter hash? entries))
             (take-right parsed (min (max 0 limit) (length parsed))))
           '())))))

;; ----------------------------------------------------------------------------
;; Artifacts: larger evidence that stays out of LLM context
;; ----------------------------------------------------------------------------

(define (persist-artifact! store operation-id name bytes)
  (define safe-name (regexp-replace* #rx"[^A-Za-z0-9._-]" name "_"))
  (define file-name (format "~a.~a" operation-id safe-name))
  (define path (build-path (persist-store-path store) "artifacts" file-name))
  (display-to-file bytes path #:mode 'binary #:exists 'replace)
  (hasheq 'artifactId file-name
          'name name
          'bytes (bytes-length bytes)
          'sha256 (or (sha256-hex path) "")
          'createdAtUtc (or (utc-iso-millis (now-millis)) 'null)))

(define (persist-artifact-file store artifact-id)
  ;; Only the bare file name is accepted; traversal stays impossible.
  (define safe (regexp-replace* #rx"[^A-Za-z0-9._-]" artifact-id ""))
  (define path (build-path (persist-store-path store) "artifacts" safe))
  (and (file-exists? path) (path->string path)))
