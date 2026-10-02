#lang racket/base

;; The persistent evidence/artifact store: records round-trip through the
;; JSONL files, artifacts land with checksums, and the runtime seeds its
;; in-memory history from a store created by a previous "session".

(module+ test
  (require benchpilot/core/contracts
           benchpilot/core/persist
           benchpilot/core/profile
           benchpilot/core/runtime-state
           benchpilot/core/bench-runtime
           benchpilot/diagnostics/channels/sim-uds-channel
           benchpilot/simulator/simulated-bench
           racket/file
           racket/list
           racket/string
           rackunit)

  (define dir (path->string (make-temporary-file "benchpilot-persist-~a" 'directory)))
  (define store (open-persist-store dir))

  (define record
    (bench-operation-record "op-1" "demo" "power.on"
                            (list "sim.demo")
                            1000 1060 60 #f "completed" #f))
  (define evidence
    (bench-operation-evidence "op-1" "demo" "power.on"
                              (list "sim.demo") 1060
                              (list (bench-evidence-item
                                     "power.result" "Power-on completed." #f
                                     (hasheq "ok" "true" "voltageV" "12")))))

  (test-case "records survive a store round trip"
    (persist-operation! store record evidence)
    (define loaded (persist-load-recent store "operations.jsonl" 10))
    (check-equal? (length loaded) 1)
    (define entry (first loaded))
    (check-equal? (hash-ref entry 'id) "op-1")
    (check-equal? (hash-ref entry 'state) "completed")
    (check-equal? (hash-ref entry 'durationMs) 60)
    (check-equal? (hash-ref entry 'deadlineAtMillis) 'null)
    (check-equal? (hash-ref (first (hash-ref entry 'items)) 'metadata)
                  '#hasheq((ok . "true") (voltageV . "12"))))

  (test-case "artifacts land under the store with a checksum"
    (define ref (persist-artifact! store "op-1" "capture.json" #"[]"))
    (check-equal? (hash-ref ref 'bytes) 2)
    (check-true (string-contains? (hash-ref ref 'artifactId) "op-1"))
    (define path (persist-artifact-file store (hash-ref ref 'artifactId)))
    (check-true (and path (file-exists? path)))
    (check-equal? (file->bytes path) #"[]")
    (check-false (persist-artifact-file store "../escape")))

  (test-case "the runtime seeds its history from a previous session"
    (persist-operation! store
                        (struct-copy bench-operation-record record [id "op-0"])
                        (struct-copy bench-operation-evidence evidence [operation-id "op-0"]))
    (define registry
      (make-driver-registry (list (make-simulator-factory)
                                  (make-sim-diagnostics-factory))))
    (define rt (make-bench-runtime registry (default-simulator-profile)))
    (define state (bench-runtime-state rt))
    (set-runtime-store! state store)
    (seed-persisted-operations! state (persist-load-recent store "operations.jsonl" 128))
    ;; Both persisted operations are queryable in write (chronological) order.
    (define history (runtime-recent-operations state 10))
    (check-equal? (length history) 2)
    (check-equal? (bench-operation-record-id (first history)) "op-1")
    (check-equal? (bench-operation-record-id (last history)) "op-0")
    (check-not-false (runtime-get-operation-evidence state "op-0"))
    ;; A new operation appends after the seeded entries and lands in the file.
    (define t (runtime-target rt "demo"))
    (target-power-on rt t 12 0)
    (define history* (runtime-recent-operations state 10))
    (check-equal? (length history*) 3)
    (check-equal? (bench-operation-record-kind (last history*)) "power.on")
    (check-equal? (length (persist-load-recent store "operations.jsonl" 128)) 3))

  (test-case "disabled store raises the typed error"
    (putenv "BENCHPILOT_STORE" "0")
    (check-exn exn:fail:persist-disabled? open-persist-store)
    (putenv "BENCHPILOT_STORE" "")))
