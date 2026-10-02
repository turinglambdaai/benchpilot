#lang racket/base

;; Runtime state machine, port of src/Benchpilot.Runtime's
;; BenchRuntime.cs, RuntimeTypes.cs, RuntimeExecutionCancellation.cs and
;; BenchRuntimeDrain.cs. Semantics preserved exactly: target-first gate
;; acquisition with rollback, first-cause-wins cancellation, wall-clock
;; deadline rejection of late successes, bounded history stores, and the
;; drain/poll shutdown loop.

(require racket/list
         racket/string)

(require "contracts.rkt"
         "device-errors.rkt"
         "evidence.rkt"
         "persist.rkt"
         "profile.rkt")

(provide (struct-out exec-cancel)
         (struct-out runtime-state)
         (struct-out active-exec)
         (struct-out mutation-gate-request)
         (struct-out drain-result)
         check-disposed
         new-id
         now-millis
         set-runtime-store!
         seed-persisted-operations!
         seed-persisted-observations!
         make-exec-cancel
         cancel-evt
         exec-cancel-request-cancel!
         exec-cancel-cancellation-requested?
         exec-cancel-deadline-exceeded?
         make-runtime-state
         runtime-active-operations
         runtime-active-observations
         runtime-recent-operations
         runtime-recent-observations
         runtime-get-operation-evidence
         runtime-get-observation-evidence
         runtime-cancel-operation!
         runtime-cancel-observation!
         run-mutation
         run-observation
         run-ungated-safety-operation
         drain-runtime!
         bound-history-error
         duration-ms-between
         operation-history-capacity)

;; ----------------------------------------------------------------------------
;; Ids and clocks
;; ----------------------------------------------------------------------------

;; 32 lowercase hex chars, matching Guid.NewGuid().ToString("N").
(define (new-id)
  (list->string (for/list ([_ (in-range 32)])
                  (string-ref "0123456789abcdef" (random 16)))))

;; ----------------------------------------------------------------------------
;; Execution cancellation: caller cancel, explicit runtime cancel and the
;; operation deadline compete; the first observed cause wins.
;; ----------------------------------------------------------------------------

(struct exec-cancel (sema cause-box deadline-ms deadline-at-millis disposed-box) #:transparent)

(define (make-exec-cancel deadline-ms started-at-millis)
  (define deadline-at (and deadline-ms (+ started-at-millis deadline-ms)))
  (define ec (exec-cancel (make-semaphore) (box 'none) deadline-ms deadline-at (box #f)))
  (when deadline-ms
    (define delay (- deadline-at (now-millis)))
    ;; CancellationTokenSource(timeout) equivalent: the timer claims the
    ;; deadline cause when it fires; mark-cause! posts the semaphore only if
    ;; no earlier cause won the race.
    (thread (lambda ()
              (sleep (max 0 (/ delay 1000.0)))
              (unless (unbox (exec-cancel-disposed-box ec))
                (mark-cause! ec 'deadline)))))
  ec)

;; Poll handle for drivers: peeks at the cancellation signal without
;; consuming it, so multiple pollers can sync on the same event.
(define (cancel-evt ec)
  (semaphore-peek-evt (exec-cancel-sema ec)))

(define (mark-cause! ec cause)
  (define b (exec-cancel-cause-box ec))
  (let loop ()
    (define cur (unbox b))
    (cond
      [(not (eq? cur 'none)) cur]
      [(box-cas! b cur cause)
       (semaphore-post (exec-cancel-sema ec))
       cause]
      [else (loop)])))

(define (exec-cancel-request-cancel! ec)
  (if (unbox (exec-cancel-disposed-box ec))
      #f
      (begin
        (mark-cause! ec 'explicit)
        #t)))

(define (exec-cancel-cancellation-requested? ec)
  (not (eq? (unbox (exec-cancel-cause-box ec)) 'none)))

(define (exec-cancel-deadline-exceeded? ec)
  (define d (exec-cancel-deadline-at-millis ec))
  (when (and d (>= (now-millis) d))
    (mark-cause! ec 'deadline))
  (eq? (unbox (exec-cancel-cause-box ec)) 'deadline))

(define (exec-cancel-dispose! ec)
  (set-box! (exec-cancel-disposed-box ec) #t))

;; ----------------------------------------------------------------------------
;; State containers
;; ----------------------------------------------------------------------------

(define operation-history-capacity 128)
(define observation-history-capacity 128)
(define max-history-error-length 1000)

(struct runtime-state
        (profile resources
                 gates
                 operations
                 observations
                 operation-history
                 observation-history
                 history-mutex
                 op-evidence
                 obs-evidence
                 context-store
                 disposed-box
                 store-box)
  #:transparent)

;; One in-flight mutation/observation: identity, held gates, cancellation.
(struct active-exec (id target-id kind resource-ids started-at-millis cancel deadline-at-millis)
  #:transparent)

(struct mutation-gate-request (key scope id) #:transparent)

(define (make-runtime-state profile resources)
  (validate-profile profile)
  (runtime-state profile
                 resources
                 (make-hash)
                 (make-hash)
                 (make-hash)
                 (box '())
                 (box '())
                 (make-semaphore 1)
                 (make-evidence-store)
                 (make-evidence-store)
                 (make-context-store)
                 (box #f)
                 (box #f)))

(define (check-disposed rt)
  (when (unbox (runtime-state-disposed-box rt))
    (raise-validation "The runtime has been disposed.")))

;; Chronological queue in a box, capped like Queue<T> + while(Dequeue).
(define (history-push! hist-box record capacity)
  (define l (append (unbox hist-box) (list record)))
  (set-box! hist-box
            (if (> (length l) capacity)
                (list-tail l (- (length l) capacity))
                l)))

(define (history-latest hist-box limit)
  (take-right (unbox hist-box) (min limit (length (unbox hist-box)))))

(define (duration-ms-between started completed)
  (max 0 (- completed started)))

(define (bound-history-error value)
  (if (string-blank? value)
      value
      (if (<= (string-length value) max-history-error-length)
          value
          (substring value 0 max-history-error-length))))

;; ----------------------------------------------------------------------------
;; Active registries, history and evidence readers
;; ----------------------------------------------------------------------------

(define (active-sort actives)
  (sort actives
        (lambda (a b)
          (or (< (active-exec-started-at-millis a) (active-exec-started-at-millis b))
              (and (= (active-exec-started-at-millis a) (active-exec-started-at-millis b))
                   (string-ci<? (active-exec-id a) (active-exec-id b)))))))

(define (runtime-active-operations rt)
  (check-disposed rt)
  (active-sort (hash-values (runtime-state-operations rt))))

(define (runtime-active-observations rt)
  (check-disposed rt)
  (active-sort (hash-values (runtime-state-observations rt))))

(define (runtime-recent-operations rt [limit 50])
  (check-disposed rt)
  (unless (and (exact-integer? limit) (<= 1 limit operation-history-capacity))
    (raise-validation (format "Operation history limit must be between 1 and ~a."
                              operation-history-capacity)))
  (call-with-mutex (runtime-state-history-mutex rt)
                   (lambda () (history-latest (runtime-state-operation-history rt) limit))))

(define (runtime-recent-observations rt [limit 50])
  (check-disposed rt)
  (unless (and (exact-integer? limit) (<= 1 limit observation-history-capacity))
    (raise-validation (format "Observation history limit must be between 1 and ~a."
                              observation-history-capacity)))
  (call-with-mutex (runtime-state-history-mutex rt)
                   (lambda () (history-latest (runtime-state-observation-history rt) limit))))

(define (runtime-get-operation-evidence rt operation-id)
  (check-disposed rt)
  (when (string-blank? operation-id)
    (raise-argument-error 'runtime-get-operation-evidence "non-blank string" operation-id))
  (evidence-store-fetch (runtime-state-op-evidence rt) operation-id))

(define (runtime-get-observation-evidence rt observation-id)
  (check-disposed rt)
  (when (string-blank? observation-id)
    (raise-argument-error 'runtime-get-observation-evidence "non-blank string" observation-id))
  (evidence-store-fetch (runtime-state-obs-evidence rt) observation-id))

(define (runtime-cancel-operation! rt operation-id)
  (check-disposed rt)
  (when (string-blank? operation-id)
    (raise-argument-error 'runtime-cancel-operation! "non-blank string" operation-id))
  (define active (hash-ref (runtime-state-operations rt) operation-id #f))
  (and active (exec-cancel-request-cancel! (active-exec-cancel active))))

(define (runtime-cancel-observation! rt observation-id)
  (check-disposed rt)
  (when (string-blank? observation-id)
    (raise-argument-error 'runtime-cancel-observation! "non-blank string" observation-id))
  (define active (hash-ref (runtime-state-observations rt) observation-id #f))
  (and active (exec-cancel-request-cancel! (active-exec-cancel active))))

;; ----------------------------------------------------------------------------
;; Gate machinery
;; ----------------------------------------------------------------------------

(define (normalize-resources resource-ids)
  (sort (remove-duplicates (filter (lambda (x) (and (string? x) (not (string-blank? x))))
                                   resource-ids)
                           string-ci=?)
        string-ci<?))

(define (gate-acquire! rt key)
  (define gate (hash-ref! (runtime-state-gates rt) key (lambda () (make-semaphore 1))))
  (semaphore-try-wait? gate))

(define (gate-release! rt key)
  (define gate (hash-ref (runtime-state-gates rt) key #f))
  (when gate
    (semaphore-post gate)))

(define (find-owner rt scope id)
  (for/first ([active (in-list (runtime-active-operations rt))]
              #:when (cond
                       [(string-ci=? scope "target") (string-ci=? (active-exec-target-id active) id)]
                       [(string-ci=? scope "resource")
                        (member id (active-exec-resource-ids active) string-ci=?)]
                       [else #f]))
    active))

(define (validate-deadline deadline-ms)
  (when (and deadline-ms (<= deadline-ms 0))
    (raise-validation "Runtime deadlineMs must be greater than zero.")))

(define (request-cancelled? caller-cancel)
  (and caller-cancel (sync/timeout 0 caller-cancel)))

;; ----------------------------------------------------------------------------
;; Mutations: gates + identity + deadline + evidence + history
;; ----------------------------------------------------------------------------

(define (run-mutation rt
                      target-id
                      operation
                      resource-ids
                      action
                      #:deadline-ms [deadline-ms #f]
                      #:caller-cancel [caller-cancel #f])
  (check-disposed rt)
  (when (string-blank? target-id)
    (raise-argument-error 'run-mutation "non-blank target-id" target-id))
  (when (string-blank? operation)
    (raise-argument-error 'run-mutation "non-blank operation" operation))
  (validate-deadline deadline-ms)
  (when (request-cancelled? caller-cancel)
    (raise (make-cancelled-error)))

  (define normalized (normalize-resources resource-ids))
  (define requests
    (cons
     (mutation-gate-request (string-append "target:" (string-foldcase target-id)) "target" target-id)
     (for/list ([rid (in-list normalized)])
       (mutation-gate-request (string-append "resource:" (string-foldcase rid)) "resource" rid))))

  ;; Target ownership is the primary semantic boundary, so it is acquired
  ;; first; resource gates follow in deterministic order. Acquisition is
  ;; non-blocking and rolls back on any failure, so no deadlock can form.
  (define acquired
    (let loop ([pending requests]
               [held '()])
      (cond
        [(null? pending) held]
        [else
         (when (request-cancelled? caller-cancel)
           (release-all! rt held)
           (raise (make-cancelled-error)))
         (define request (car pending))
         (if (gate-acquire! rt (mutation-gate-request-key request))
             (loop (cdr pending) (cons request held))
             (begin
               (release-all! rt held)
               (let ([owner (find-owner rt
                                        (mutation-gate-request-scope request)
                                        (mutation-gate-request-id request))])
                 (raise (make-busy-error target-id
                                         operation
                                         (mutation-gate-request-scope request)
                                         (mutation-gate-request-id request)
                                         (and owner (active-exec-id owner))
                                         (and owner (active-exec-kind owner)))))))])))

  (define started-at (now-millis))
  (define operation-id (new-id))
  (define cancel (make-exec-cancel deadline-ms started-at))
  (define active
    (active-exec operation-id
                 target-id
                 operation
                 normalized
                 started-at
                 cancel
                 (and deadline-ms (+ started-at deadline-ms))))
  (hash-set! (runtime-state-operations rt) operation-id active)

  (define (cleanup)
    (hash-remove! (runtime-state-operations rt) operation-id)
    (exec-cancel-dispose! cancel)
    (release-all! rt acquired))

  (define (record! items state error)
    (define evidence
      (bench-operation-evidence operation-id
                                target-id
                                operation
                                normalized
                                (now-millis)
                                (evidence-bound-items items)))
    (evidence-store-put! (runtime-state-op-evidence rt) operation-id evidence)
    (define completed-at (now-millis))
    (define record
      (bench-operation-record operation-id
                              target-id
                              operation
                              normalized
                              started-at
                              completed-at
                              (duration-ms-between started-at completed-at)
                              (active-exec-deadline-at-millis active)
                              state
                              error))
    (history-push! (runtime-state-operation-history rt)
                   record
                   operation-history-capacity)
    (define store (unbox (runtime-state-store-box rt)))
    (when store
      (persist-operation! store record evidence)))

  (define (deadline-path)
    (record!
     (operation-deadline-evidence (exec-cancel-deadline-ms cancel)
                                  (utc-iso (active-exec-deadline-at-millis active)))
     "deadline_exceeded"
     (exn-message
      (make-deadline-error target-id operation deadline-ms (active-exec-deadline-at-millis active)))))

  (dynamic-wind
   void
   (lambda ()
     (with-handlers
         ([exn:benchpilot:cancelled?
           (lambda (e)
             (cond
               [(exec-cancel-deadline-exceeded? cancel)
                (deadline-path)
                (raise (make-deadline-error target-id
                                            operation
                                            deadline-ms
                                            (active-exec-deadline-at-millis active)))]
               [else
                (record! (operation-cancellation-evidence) "cancelled" "Operation cancelled.")
                (raise e)]))]
          [exn:fail? (lambda (e)
                       (record! (append (operation-exception-evidence
                                         (exn-message e)
                                         (exception-type-name e))
                                        (list (device-error-evidence-item
                                               (exn-message e))))
                                "faulted"
                                (bound-history-error (exn-message e)))
                       (raise e))])
       (define result (action cancel))
       ;; A runtime deadline differs from cancellation: once the wall-clock
       ;; budget has expired, a late success is never accepted.
       (when (exec-cancel-deadline-exceeded? cancel)
         (deadline-path)
         (raise (make-deadline-error target-id
                                     operation
                                     deadline-ms
                                     (active-exec-deadline-at-millis active))))
       (record! (extract-operation-evidence result) "completed" #f)
       result))
   cleanup))

(define (release-all! rt held)
  (for ([request (in-list (reverse held))])
    (gate-release! rt (mutation-gate-request-key request))))

(define (exception-type-name e)
  (cond
    [(exn:benchpilot:validation? e) "BenchValidationException"]
    [(exn:benchpilot:busy? e) "BenchBusyException"]
    [(exn:benchpilot:deadline-exceeded? e) "BenchDeadlineExceededException"]
    [(exn:benchpilot:cancelled? e) "OperationCanceledException"]
    [else "Exception"]))

;; ----------------------------------------------------------------------------
;; Observations: no mutation gates, but identity, cancellation, deadline,
;; history and bounded evidence are still owned by the runtime. The action
;; receives (observation-id cancel) and returns (values result evidence).
;; ----------------------------------------------------------------------------

(define (run-observation rt
                         target-id
                         observation
                         resource-ids
                         action
                         #:deadline-ms [deadline-ms #f]
                         #:caller-cancel [caller-cancel #f])
  (check-disposed rt)
  (when (string-blank? target-id)
    (raise-argument-error 'run-observation "non-blank target-id" target-id))
  (when (string-blank? observation)
    (raise-argument-error 'run-observation "non-blank observation" observation))
  (validate-deadline deadline-ms)
  (when (request-cancelled? caller-cancel)
    (raise (make-cancelled-error)))

  (define normalized (normalize-resources resource-ids))
  (define observation-id (new-id))
  (define started-at (now-millis))
  (define cancel (make-exec-cancel deadline-ms started-at))
  (define active
    (active-exec observation-id
                 target-id
                 observation
                 normalized
                 started-at
                 cancel
                 (and deadline-ms (+ started-at deadline-ms))))
  (hash-set! (runtime-state-observations rt) observation-id active)

  (define (record! items state error)
    (evidence-store-put! (runtime-state-obs-evidence rt)
                         observation-id
                         (bench-observation-evidence observation-id
                                                     target-id
                                                     observation
                                                     normalized
                                                     (now-millis)
                                                     (evidence-bound-items items)))
    (define completed-at (now-millis))
    (history-push! (runtime-state-observation-history rt)
                   (bench-observation-record observation-id
                                             target-id
                                             observation
                                             normalized
                                             started-at
                                             completed-at
                                             (duration-ms-between started-at completed-at)
                                             (active-exec-deadline-at-millis active)
                                             state
                                             error)
                   observation-history-capacity))

  (define (deadline-path)
    (record! (observation-deadline-evidence deadline-ms
                                            (utc-iso (active-exec-deadline-at-millis active)))
             "deadline_exceeded"
             (exn-message (make-deadline-error target-id
                                               observation
                                               deadline-ms
                                               (active-exec-deadline-at-millis active)))))

  (dynamic-wind
   void
   (lambda ()
     (with-handlers
         ([exn:benchpilot:cancelled?
           (lambda (e)
             (cond
               [(exec-cancel-deadline-exceeded? cancel)
                (deadline-path)
                (raise (make-deadline-error target-id
                                            observation
                                            deadline-ms
                                            (active-exec-deadline-at-millis active)))]
               [else
                (record! (observation-cancellation-evidence) "cancelled" "Observation cancelled.")
                (raise e)]))]
          [exn:fail? (lambda (e)
                       (record! (observation-exception-evidence (exn-message e)
                                                                (exception-type-name e))
                                "faulted"
                                (bound-history-error (exn-message e)))
                       (raise e))])
       (define-values (result evidence-items) (action observation-id cancel))
       (when (exec-cancel-deadline-exceeded? cancel)
         (deadline-path)
         (raise (make-deadline-error target-id
                                     observation
                                     deadline-ms
                                     (active-exec-deadline-at-millis active))))
       (record! evidence-items "completed" #f)
       result))
   (lambda ()
     (hash-remove! (runtime-state-observations rt) observation-id)
     (exec-cancel-dispose! cancel))))

;; ----------------------------------------------------------------------------
;; Ungated safety operation: not cancellable once accepted, no deadline,
;; always audited.
;; ----------------------------------------------------------------------------

(define (run-ungated-safety-operation rt target-id operation resource-ids action)
  (check-disposed rt)
  (when (string-blank? target-id)
    (raise-argument-error 'run-ungated-safety-operation "non-blank target-id" target-id))
  (when (string-blank? operation)
    (raise-argument-error 'run-ungated-safety-operation "non-blank operation" operation))

  (define normalized (normalize-resources resource-ids))
  (define operation-id (new-id))
  (define started-at (now-millis))

  (define (push! state error)
    (define completed-at (now-millis))
    (history-push! (runtime-state-operation-history rt)
                   (bench-operation-record operation-id
                                           target-id
                                           operation
                                           normalized
                                           started-at
                                           completed-at
                                           (duration-ms-between started-at completed-at)
                                           #f
                                           state
                                           error)
                   operation-history-capacity))

  (with-handlers ([exn:fail?
                   (lambda (e)
                     (evidence-store-put! (runtime-state-op-evidence rt)
                                          operation-id
                                          (bench-operation-evidence
                                           operation-id
                                           target-id
                                           operation
                                           normalized
                                           (now-millis)
                                           (evidence-bound-items (operation-exception-evidence
                                                                  (exn-message e)
                                                                  (exception-type-name e)))))
                     (push! "faulted" (bound-history-error (exn-message e)))
                     (raise e))])
    (define result (action))
    (evidence-store-put! (runtime-state-op-evidence rt)
                         operation-id
                         (bench-operation-evidence operation-id
                                                   target-id
                                                   operation
                                                   normalized
                                                   (now-millis)
                                                   (evidence-bound-items (extract-operation-evidence
                                                                          result))))
    (push! "completed" #f)
    result))

;; ----------------------------------------------------------------------------
;; Drain: cooperative cancel of everything active, then poll until the
;; registries empty or the timeout expires.
;; ----------------------------------------------------------------------------

(struct drain-result
        (drained cancel-requested-operations
                 cancel-requested-observations
                 remaining-operation-ids
                 remaining-observation-ids)
  #:transparent)

(define (drain-runtime! rt timeout-ms #:cancel-evt [ct #f])
  (define deadline-at (+ (now-millis) timeout-ms))
  (define cancelled-operations (make-hash))
  (define cancelled-observations (make-hash))

  (let loop ()
    (for ([op (in-list (runtime-active-operations rt))])
      (unless (hash-ref cancelled-operations (active-exec-id op) #f)
        (hash-set! cancelled-operations (active-exec-id op) #t)
        (runtime-cancel-operation! rt (active-exec-id op))))
    (for ([obs (in-list (runtime-active-observations rt))])
      (unless (hash-ref cancelled-observations (active-exec-id obs) #f)
        (hash-set! cancelled-observations (active-exec-id obs) #t)
        (runtime-cancel-observation! rt (active-exec-id obs))))

    (define remaining-operations (runtime-active-operations rt))
    (define remaining-observations (runtime-active-observations rt))
    (cond
      [(and (null? remaining-operations) (null? remaining-observations))
       (drain-result #t
                     (hash-count cancelled-operations)
                     (hash-count cancelled-observations)
                     '()
                     '())]
      [(or (>= (now-millis) deadline-at) (and ct (sync/timeout 0 ct)))
       (drain-result #f
                     (hash-count cancelled-operations)
                     (hash-count cancelled-observations)
                     (map active-exec-id remaining-operations)
                     (map active-exec-id remaining-observations))]
      [else
       (define remaining (- deadline-at (now-millis)))
       (when (> remaining 0)
         (sync/timeout (/ (min 25 remaining) 1000.0) (or ct never-evt)))
       (loop)])))

;; ----------------------------------------------------------------------------
;; Persistent store wiring (selected evidence/artifacts across restarts)
;; ----------------------------------------------------------------------------

(define (set-runtime-store! rt store)
  (set-box! (runtime-state-store-box rt) store))

(define (entry-item->struct item)
  (bench-evidence-item
   (hash-ref item 'kind "")
   (hash-ref item 'summary "")
   (let ([text (hash-ref item 'text 'null)]) (if (eq? text 'null) #f text))
   (hash-ref item 'metadata (hasheq))))

(define (seed-persisted-operations! rt entries)
  (define records
    (for/list ([e (in-list entries)])
      (bench-operation-record
       (hash-ref e 'id "")
       (hash-ref e 'targetId "")
       (hash-ref e 'operation "")
       (hash-ref e 'resourceIds '())
       (hash-ref e 'startedAtMillis 0)
       (hash-ref e 'completedAtMillis 0)
       (hash-ref e 'durationMs 0)
       (let ([d (hash-ref e 'deadlineAtMillis 'null)]) (if (eq? d 'null) #f d))
       (hash-ref e 'state "")
       (let ([err (hash-ref e 'error 'null)]) (if (eq? err 'null) #f err)))))
  (define evidences
    (for/list ([e (in-list entries)])
      (bench-operation-evidence
       (hash-ref e 'id "")
       (hash-ref e 'targetId "")
       (hash-ref e 'operation "")
       (hash-ref e 'resourceIds '())
       (hash-ref e 'completedAtMillis 0)
       (map entry-item->struct (hash-ref e 'items '())))))
  (for ([rec (in-list records)]
        [ev (in-list evidences)])
    (evidence-store-put! (runtime-state-op-evidence rt)
                         (bench-operation-record-id rec)
                         ev))
  (define capped
    (let* ([merged (append records (unbox (runtime-state-operation-history rt)))]
           [n (length merged)])
      (if (> n operation-history-capacity)
          (list-tail merged (- n operation-history-capacity))
          merged)))
  (set-box! (runtime-state-operation-history rt) capped))

(define (seed-persisted-observations! rt entries)
  (define records
    (for/list ([e (in-list entries)])
      (bench-observation-record
       (hash-ref e 'id "")
       (hash-ref e 'targetId "")
       (hash-ref e 'observation "")
       (hash-ref e 'resourceIds '())
       (hash-ref e 'startedAtMillis 0)
       (hash-ref e 'completedAtMillis 0)
       (hash-ref e 'durationMs 0)
       (let ([d (hash-ref e 'deadlineAtMillis 'null)]) (if (eq? d 'null) #f d))
       (hash-ref e 'state "")
       (let ([err (hash-ref e 'error 'null)]) (if (eq? err 'null) #f err)))))
  (define evidences
    (for/list ([e (in-list entries)])
      (bench-observation-evidence
       (hash-ref e 'id "")
       (hash-ref e 'targetId "")
       (hash-ref e 'observation "")
       (hash-ref e 'resourceIds '())
       (hash-ref e 'completedAtMillis 0)
       (map entry-item->struct (hash-ref e 'items '())))))
  (for ([rec (in-list records)]
        [ev (in-list evidences)])
    (evidence-store-put! (runtime-state-obs-evidence rt)
                         (bench-observation-record-id rec)
                         ev))
  (define capped
    (let* ([merged (append records (unbox (runtime-state-observation-history rt)))]
           [n (length merged)])
      (if (> n observation-history-capacity)
          (list-tail merged (- n observation-history-capacity))
          merged)))
  (set-box! (runtime-state-observation-history rt) capped))
