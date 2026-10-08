#lang racket/base

;; BenchPilot Studio Rivet backend: a typed RPC facade over the resident
;; BenchPilot runtime (benchpilotd). The GUI is a client, not the owner —
;; all bench policy stays in the daemon; this backend proxies loopback HTTP
;; calls and adapts the JSON API to RVT1 records. Long-running bench work
;; keeps its daemon-side operation identity; the Studio renders status,
;; operations, power, and flash control.
;;
;; RVT1 has no float: daemon `real` fields cross the boundary scaled to
;; integer units (volts -> millivolts, mA -> microamps).

(require rivet/backend
         racket/string
         "daemon-client.rkt")

(provide start)

;; --- Typed surface ---------------------------------------------------------

(define-record TargetSummary
  ([id : String]
   [name : String]
   [mcu : (Optional String)]
   [capabilities : (List String)]))

(define-record ResourceSummary
  ([id : String]
   [driver : String]
   [capabilities : (List String)]
   [registered : Bool]))

(define-record RuntimeStatus
  ([name : String]
   [schema-version : Int64]
   [default-target : (Optional String)]
   [targets : (List TargetSummary)]
   [resources : (List ResourceSummary)]
   [runtime-version : (Optional String)]))

(define-record OperationSummary
  ([id : String]
   [target-id : String]
   [kind : String]
   [resource-ids : (List String)]
   [started-at-utc : String]
   [deadline-at-utc : (Optional String)]
   [cancellation-requested : Bool]
   [deadline-exceeded : Bool]))

(define-record OperationHistoryItem
  ([id : String]
   [target-id : String]
   [kind : String]
   [resource-ids : (List String)]
   [started-at-utc : String]
   [completed-at-utc : String]
   [duration-ms : Int64]
   [deadline-at-utc : (Optional String)]
   [state : String]
   [error : (Optional String)]))

(define-record CancelResult
  ([ok : Bool]
   [operation-id : String]
   [cancel-requested : Bool]
   [error : (Optional String)]))

(define-record PowerOnResult
  ([ok : Bool]
   [voltage-millivolts : Int64]
   [current-microamps : Int64]
   [settled : Bool]
   [error : (Optional String)]))

(define-record ActionResult
  ([ok : Bool]
   [error : (Optional String)]))

(define-record FlashResult
  ([ok : Bool]
   [bytes : Int64]
   [duration-ms : Int64]
   [error : (Optional String)]))

;; --- jsexpr adapters -------------------------------------------------------

(define (jstr j key)
  (define v (jref j key))
  (if (string? v) v ""))

(define (jint j key)
  (define v (jref j key))
  (if (exact-integer? v) v 0))

(define (jbool j key)
  (and (jref j key) #t))

(define (jlist j key)
  (define v (jref j key))
  (if (list? v) v '()))

;; Optional fields use (void) as the absent representation on the RVT1 wire.
(define (jopt j key)
  (or (jref j key) (void)))

;; Scaled integer from a daemon real (or missing) field: volts -> millivolts,
;; mA -> microamps use scale 1000.0.
(define (jscaled j key scale)
  (define v (jref j key))
  (if (real? v)
      (inexact->exact (floor (* v scale)))
      0))

(define (j->target j)
  (TargetSummary (jstr j 'id)
                 (jstr j 'name)
                 (jopt j 'mcu)
                 (jlist j 'capabilities)))

(define (j->resource j)
  (ResourceSummary (jstr j 'id)
                   (jstr j 'driver)
                   (jlist j 'capabilities)
                   (jbool j 'registered)))

(define (j->operation j)
  (OperationSummary (jstr j 'id)
                    (jstr j 'targetId)
                    (jstr j 'kind)
                    (jlist j 'resourceIds)
                    (jstr j 'startedAtUtc)
                    (jopt j 'deadlineAtUtc)
                    (jbool j 'cancellationRequested)
                    (jbool j 'deadlineExceeded)))

(define (j->history j)
  (OperationHistoryItem (jstr j 'id)
                        (jstr j 'targetId)
                        (jstr j 'kind)
                        (jlist j 'resourceIds)
                        (jstr j 'startedAtUtc)
                        (jstr j 'completedAtUtc)
                        (jint j 'durationMs)
                        (jopt j 'deadlineAtUtc)
                        (jstr j 'state)
                        (jopt j 'error)))

(define (action-result j)
  (ActionResult (jbool j 'ok) (jopt j 'error)))

;; --- RPC surface -----------------------------------------------------------

(define-rpc (status : RuntimeStatus)
  (define j (api-get "/status"))
  (RuntimeStatus (jstr j 'name)
                 (jint j 'schemaVersion)
                 (jopt j 'defaultTarget)
                 (map j->target (jlist j 'targets))
                 (map j->resource (jlist j 'resources))
                 (jopt j 'runtimeVersion)))

(define-rpc (list-operations : (List OperationSummary))
  (map j->operation (jlist (api-get "/operations") 'operations)))

(define-rpc (operation-history [limit : Int64] : (List OperationHistoryItem))
  (map j->history
       (jlist (api-get "/operations/history" (hasheq 'limit (number->string limit))) 'operations)))

(define-rpc (cancel-operation [operation-id : String] : CancelResult)
  (define j (api-post "/operations/cancel" (hasheq 'operationId operation-id)))
  (CancelResult (jbool j 'ok)
                (jstr j 'operationId)
                (jbool j 'cancelRequested)
                (jopt j 'error)))

(define-rpc (power-on [target : String]
                      [voltage-millivolts : Int64]
                      [settle-ms : Int64]
                      : PowerOnResult)
  (define j (api-post "/power/on"
                      (hasheq 'target target)
                      (hasheq 'voltage (* voltage-millivolts 0.001)
                              'settleMs settle-ms)))
  (PowerOnResult (jbool j 'ok)
                 (jscaled j 'voltage 1000.0)
                 (jscaled j 'currentMa 1000.0)
                 (jbool j 'settled)
                 (jopt j 'error)))

(define-rpc (power-off [target : String] : ActionResult)
  (action-result (api-post "/power/off" (hasheq 'target target))))

(define-rpc (emergency-off [target : String] : ActionResult)
  (action-result (api-post "/power/emergency-off" (hasheq 'target target))))

(define-rpc (flash-write [target : String]
                         [firmware : String]
                         [confirm-target : (Optional String)]
                         : FlashResult)
  (define j (api-post "/flash/write"
                      (hasheq 'target target)
                      (hasheq 'firmware firmware
                              'confirmTarget (if (void? confirm-target) 'null confirm-target))))
  (FlashResult (jbool j 'ok)
               (jint j 'bytes)
               (jint j 'durationMs)
               (jopt j 'error)))

(define-rpc (flash-reset [target : String]
                         [confirm-target : (Optional String)]
                         : ActionResult)
  (action-result (api-post "/flash/reset"
                           (hasheq 'target target)
                           (hasheq 'confirmTarget (if (void? confirm-target) 'null confirm-target)))))

;; --- Entry -----------------------------------------------------------------

(define (start in-fd out-fd)
  (serve-fds in-fd out-fd))
