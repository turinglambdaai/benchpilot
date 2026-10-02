#lang racket/base

;; The static evidence report: sections render from the wire JSON, user
;; strings are escaped, and the page stays self-contained.

(module+ test
  (require benchpilot/client/html-report
           json
           racket/port
           racket/string
           rackunit)

  (define sample
    (read-json
     (open-input-string
      #<<JSON
{
  "status": {
    "name": "Bench <Inj> & Co",
    "schemaVersion": 1,
    "defaultTarget": "demo",
    "runtimeVersion": "0.6.0",
    "targets": [{"id": "demo", "name": "Demo ECU", "mcu": "simulated-mcu",
                 "capabilities": ["power", "serial"]}],
    "resources": [{"id": "sim.demo", "driver": "simulator",
                   "capabilities": ["power"], "registered": true}]
  },
  "validate": {
    "mode": "simulator",
    "readyForRealEcuLoop": false,
    "checks": [{"code": "target.real-hardware", "passed": false,
                "severity": "error", "summary": "not a physical bench",
                "remediation": "replace simulators"}]
  },
  "operations": [{"id": "op1", "kind": "power.on", "targetId": "demo",
                  "state": "completed", "durationMs": 12,
                  "completedAtUtc": "2026-10-02T00:00:00.0000000+00:00"}],
  "observations": [],
  "operation-evidence": {
    "operationId": "op1",
    "items": [{"kind": "flash.result", "summary": "Flash completed.",
               "text": "line1\nline2", "metadata": {}}]
  }
}
JSON
      )))

  (define page (build-html-report sample))

  (test-case "renders the main sections"
    (for ([needle (in-list '("BenchPilot bench report" "Bench" "Readiness"
                             "Operation history" "Observation history"
                             "Operation evidence" "power.on" "flash.result"))])
      (check-true (string-contains? page needle) needle)))

  (test-case "escapes user-controlled strings"
    (check-true (string-contains? page "Bench &lt;Inj&gt; &amp; Co"))
    (check-false (string-contains? page "Bench <Inj>")))

  (test-case "evidence text renders as a pre block"
    (check-true (string-contains? page "<pre>line1\nline2</pre>")))

  (test-case "static contract: no scripts, no external fetches"
    (check-false (string-contains? page "<script"))
    (check-false (string-contains? page "http://"))
    (check-false (string-contains? page "https://"))))
