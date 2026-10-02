#lang racket/base

;; MCP adapter smoke test: boots the resident daemon in-process, then drives
;; the stdio JSON-RPC server through initialize / tools/list / tools/call.
;; The C# tree had no MCP tests; this pins the adapter's proxy contract.

(module+ test
  (require json
           racket/format
           racket/list
           racket/port
           racket/string
           racket/tcp
           rackunit)

  (require benchpilot/core/contracts
           benchpilot/mcp/server
           benchpilot/runtime-host/daemon)

  (define mcp-test-port (+ 46900 (random 300)))

  (putenv "BENCHPILOT_ENDPOINT" (format "http://127.0.0.1:~a/" mcp-test-port))

  (define daemon-thread (thread run-daemon))

  (let wait ()
    (with-handlers ([exn:fail? (lambda (_) (sleep 0.1) (wait))])
      (define-values (in out) (tcp-connect "127.0.0.1" mcp-test-port))
      (close-input-port in)
      (close-output-port out)))

  (define (rpc id method [params (hasheq)])
    (jsexpr->string (hasheq 'jsonrpc "2.0" 'id id 'method method 'params params)))

  (define input
    (open-input-string
     (string-append
      (rpc 1 "initialize" (hasheq 'protocolVersion "2024-11-05"
                                  'capabilities (hasheq)))
      "\n"
      (rpc 2 "tools/list")
      "\n"
      (rpc 3 "tools/call" (hasheq 'name "BenchStatus" 'arguments (hasheq)))
      "\n"
      (rpc 4 "tools/call" (hasheq 'name "PowerOn" 'arguments (hasheq 'voltage 12 'settleMs 100)))
      "\n"
      (rpc 5 "bogus/method")
      "\n")))
  (define output (open-output-string))
  (run-mcp-server input output)

  (define replies
    (for/list ([line (in-list (string-split (get-output-string output) "\n"))]
               #:unless (string-blank? line))
      (read-json (open-input-string line))))

  (check-equal? (length replies) 5)

  (define (result-of id)
    (for/first ([r (in-list replies)] #:when (equal? (hash-ref r 'id) id))
      (hash-ref r 'result)))

  (test-case "initialize answers with tools capability"
    (define result (result-of 1))
    (check-equal? (hash-ref result 'protocolVersion) "2024-11-05")
    (check-true (hash-has-key? (hash-ref result 'capabilities) 'tools))
    (check-equal? (hash-ref (hash-ref result 'serverInfo) 'name) "benchpilot-mcp"))

  (test-case "tools list exposes the full proxy surface"
    (define tools (hash-ref (result-of 2) 'tools))
    (check-equal? (length tools) 26)
    (define names (map (lambda (t) (hash-ref t 'name)) tools))
    (for ([expected (in-list '("BenchStatus" "BenchPreflight" "BenchValidate"
                               "ListOperations" "ListOperationHistory"
                               "GetOperationEvidence" "CancelOperation"
                               "ListObservations" "ListObservationHistory"
                               "GetObservationEvidence" "CancelObservation"
                               "PowerOn" "PowerOff" "EmergencyPowerOff"
                               "ReadCurrent" "CheckCurrent" "Flash" "Reset"
                               "SerialOpen" "SerialWaitFor" "SerialReadWindow"
                               "SerialSend" "UdsRequest" "UdsReadDid" "UdsFlash"
                               "DoipDiscover"))])
      (check-not-false (member expected names))))

  (test-case "tools call proxies the resident daemon"
    (define result (result-of 3))
    (check-false (hash-ref result 'isError))
    (define text (hash-ref (first (hash-ref result 'content)) 'text))
    (define payload (read-json (open-input-string text)))
    (check-true (hash-ref payload 'ok))
    (check-equal? (hash-ref payload 'defaultTarget) "demo"))

  (test-case "power tool call returns the power result shape"
    (define result (result-of 4))
    (check-false (hash-ref result 'isError))
    (define payload
      (read-json (open-input-string
                  (hash-ref (first (hash-ref result 'content)) 'text))))
    (check-true (hash-ref payload 'ok))
    (check-equal? (hash-ref payload 'voltage) 12))

  (test-case "unknown method is a JSON-RPC error"
    (define reply
      (for/first ([r (in-list replies)] #:when (equal? (hash-ref r 'id) 5))
        r))
    (check-true (hash-has-key? reply 'error))
    (check-equal? (hash-ref (hash-ref reply 'error) 'code) -32601))

  (kill-thread daemon-thread))
