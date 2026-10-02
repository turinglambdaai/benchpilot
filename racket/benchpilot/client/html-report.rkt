#lang racket/base

;; The human-facing evidence layer: `benchpilot report --format html` renders
;; one self-contained static page (no scripts, no external assets) covering
;; the bench status, readiness verdict, operation/observation history and the
;; evidence recorded for the most recent mutations — the artifact an engineer
;; attaches to a bench session or an ECU release note.

(require json
         racket/format
         racket/list
         racket/port
         racket/string)

(require benchpilot/protocol/local-auth)

(provide build-html-report)

;; ----------------------------------------------------------------------------
;; Escaping + small render helpers
;; ----------------------------------------------------------------------------

(define (esc v)
  (define s (if (string? v) v (format "~a" v)))
  (list->string
   (append*
    (for/list ([c (in-string s)])
      (case c
        [(#\<) (string->list "&lt;")]
        [(#\>) (string->list "&gt;")]
        [(#\&) (string->list "&amp;")]
        [(#\") (string->list "&quot;")]
        [else (list c)])))))

(define (jstr v [default "—"])
  (cond [(not v) default]
        [(eq? v 'null) default]
        [(string? v) v]
        [else (format "~a" v)]))

(define (jbool v)
  (cond [(eq? v #t) "pass"]
        [(eq? v #f) "fail"]
        [else "—"]))

(define (section title body)
  (format "<section><h2>~a</h2>~a</section>\n" (esc title) body))

(define (table headers rows)
  (define head
    (string-append
     "<thead><tr>"
     (string-join (map (lambda (h) (format "<th>~a</th>" (esc h))) headers) "")
     "</tr></thead>"))
  (define body-rows
    (string-join
     (for/list ([row (in-list rows)])
       (format "<tr>~a</tr>"
               (string-join (map (lambda (cell) (format "<td>~a</td>" cell)) row) "")))
     "\n"))
  (format "<table>~a<tbody>~a</tbody></table>\n" head body-rows))

(define (badge ok)
  (format "<span class=\"badge ~a\">~a</span>"
          (if (eq? ok #t) "ok" (if (eq? ok #f) "bad" "na"))
          (jbool ok)))

;; ----------------------------------------------------------------------------
;; Sections
;; ----------------------------------------------------------------------------

(define (status-section status)
  (define targets
    (for/list ([t (in-list (hash-ref status 'targets '()))])
      (list (esc (jstr (hash-ref t 'id)))
            (esc (jstr (hash-ref t 'name)))
            (esc (jstr (hash-ref t 'mcu)))
            (esc (string-join (map ~a (hash-ref t 'capabilities '())) ", ")))))
  (define resources
    (for/list ([r (in-list (hash-ref status 'resources '()))])
      (list (esc (jstr (hash-ref r 'id)))
            (esc (jstr (hash-ref r 'driver)))
            (esc (string-join (map ~a (hash-ref r 'capabilities '())) ", "))
            (badge (hash-ref r 'registered 'null)))))
  (string-append
   (section "Bench"
            (format "<p><strong>~a</strong> · schema v~a · default target: ~a · runtime ~a</p>"
                    (esc (jstr (hash-ref status 'name)))
                    (esc (jstr (hash-ref status 'schemaVersion)))
                    (esc (jstr (hash-ref status 'defaultTarget)))
                    (esc (jstr (hash-ref status 'runtimeVersion)))))
   (section "Targets" (table '("Id" "Name" "MCU" "Capabilities") targets))
   (section "Resources" (table '("Id" "Driver" "Capabilities" "Live") resources))))

(define (readiness-section validate)
  (define checks
    (for/list ([c (in-list (hash-ref validate 'checks '()))])
      (list (badge (hash-ref c 'passed 'null))
            (esc (jstr (hash-ref c 'code)))
            (esc (jstr (hash-ref c 'severity)))
            (esc (jstr (hash-ref c 'summary)))
            (esc (jstr (hash-ref c 'remediation))))))
  (string-append
   (section "Readiness"
            (format "<p>Mode <strong>~a</strong> · ready for the real ECU loop: ~a</p>"
                    (esc (jstr (hash-ref validate 'mode)))
                    (badge (hash-ref validate 'readyForRealEcuLoop 'null))))
   (table '("passed" "code" "severity" "summary" "remediation") checks)))

(define (history-table entries kind)
  (table
   '("Id" "Kind" "Target" "State" "Duration (ms)" "Completed")
   (for/list ([op (in-list entries)])
     (list (esc (jstr (hash-ref op 'id)))
           (esc (jstr (hash-ref op 'kind)))
           (esc (jstr (hash-ref op 'targetId)))
           (badge (if (equal? (hash-ref op 'state) "completed") #t
                      (if (equal? (hash-ref op 'state) "cancelled") 'null #f)))
           (esc (jstr (hash-ref op 'durationMs)))
           (esc (jstr (hash-ref op 'completedAtUtc)))))))

(define (evidence-section evidence kind label)
  (if (not evidence)
      ""
      (let ()
        (define items
          (for/list ([item (in-list (hash-ref evidence 'items '()))])
            (format "<div class=\"evidence\"><h4>~a · ~a</h4><p>~a</p>~a</div>"
                    (esc (jstr (hash-ref item 'kind)))
                    (badge #t)
                    (esc (jstr (hash-ref item 'summary)))
                    (let ([text (hash-ref item 'text 'null)])
                      (if (null? text)
                          ""
                          (format "<pre>~a</pre>" (esc (jstr text))))))))
        (section (format "~a evidence (~a)" label (jstr (hash-ref evidence kind) "—"))
                 (string-join items "\n")))))

;; ----------------------------------------------------------------------------
;; Page
;; ----------------------------------------------------------------------------

(define style
  "<style>
body{font-family:-apple-system,'Segoe UI',Roboto,sans-serif;margin:2rem auto;max-width:60rem;color:#1c1c1c;line-height:1.5}
h1{font-size:1.5rem}h2{font-size:1.1rem;border-bottom:1px solid #ddd;padding-bottom:.2rem;margin-top:2rem}
table{border-collapse:collapse;width:100%;font-size:.85rem}
th,td{text-align:left;padding:.35rem .5rem;border-bottom:1px solid #eee;vertical-align:top}
th{color:#666;font-weight:600}
.badge{display:inline-block;padding:.05rem .45rem;border-radius:.6rem;font-size:.75rem;font-weight:600}
.badge.ok{background:#e6f4ea;color:#137333}.badge.bad{background:#fce8e6;color:#c5221f}.badge.na{background:#f1f3f4;color:#5f6368}
.evidence{border-left:3px solid #ddd;padding-left:.8rem;margin:.8rem 0}
pre{background:#f6f8fa;padding:.5rem;overflow-x:auto;font-size:.78rem}
footer{margin-top:2rem;color:#666;font-size:.75rem}
</style>")

;; api-results: hash with status/validate/operations/observations/
;; operation-evidence/observation-evidence jsexpr values. History values
;; arrive as full API responses ({ok, operations: [...]}) — unwrap them.
(define (entry-list v key)
  (define inner (hash-ref v key (hasheq)))
  (if (hash? inner) (hash-ref inner key '()) inner))

(define (build-html-report api-results0)
  ;; A fresh immutable view with histories unwrapped to entry lists.
  (define api-results
    (hash-set (hash-set (make-immutable-hash (hash->list api-results0))
                        'operations (entry-list api-results0 'operations))
              'observations (entry-list api-results0 'observations)))
  (format
   "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>BenchPilot report</title>\n~a\n</head>\n<body>\n<h1>BenchPilot bench report</h1>\n~a~a~a~a~a~a<footer>Generated by benchpilot ~a · static evidence report — no scripts, no network.</footer>\n</body>\n</html>\n"
   style
   (status-section (hash-ref api-results 'status (hasheq)))
   (readiness-section (hash-ref api-results 'validate (hasheq)))
   (section "Operation history"
            (history-table (hash-ref api-results 'operations '()) 'operationId))
   (section "Observation history"
            (history-table (hash-ref api-results 'observations '()) 'observationId))
   (evidence-section (hash-ref api-results 'operation-evidence #f) 'operationId "Operation")
   (evidence-section (hash-ref api-results 'observation-evidence #f) 'observationId "Observation")
   benchpilot-version))
