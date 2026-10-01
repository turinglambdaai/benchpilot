#lang racket/base

;; Benchpilot.Mcp port: the MCP adapter is a thin, resident-Runtime proxy —
;; 26 tools over the same /api/v1 surface the CLI uses, served over stdio
;; JSON-RPC (one newline-delimited message per line). It never owns hardware;
;; it starts the daemon on demand like every other shell.

(require json
         racket/format
         racket/list
         racket/port
         racket/string
         racket/tcp)

(require benchpilot/core/contracts
         benchpilot/client/cli)

(provide run-mcp-server
         make-mcp-dispatch
         (struct-out mcp-tool))

;; ----------------------------------------------------------------------------
;; Tool table
;;
;; parameters: (list name type required? default description); build maps the
;; call arguments to (values method api-path query body).
;; ----------------------------------------------------------------------------

(struct mcp-tool (name description parameters build) #:transparent)

(define (a args key [default #f])
  (define v (hash-ref args (string->symbol key) default))
  (if (eq? v 'null) default v))

(define (ai args key [default #f])
  (define v (a args key default))
  (and v (inexact->exact (truncate v))))

(define (target-query args #:deadline [deadline #t])
  (define query (make-hasheq))
  (define target (a args "target"))
  (when target (hash-set! query 'target target))
  (when deadline
    (define dl (ai args "deadlineMs"))
    (when dl (hash-set! query 'deadlineMs dl)))
  query)

(define (tool name description parameters build)
  (mcp-tool name description parameters build))

(define mcp-tools
  (list
   ;; ---- bench ----
   (tool "BenchStatus"
         "Read the resident runtime status: profile, targets, resources."
         '()
         (lambda (_args) (values "GET" "/status" (hasheq) #f)))
   (tool "BenchPreflight"
         "Run non-destructive health checks on a target's resources."
         '(("target" "string" #f #f "Target id (defaults to the profile default)."))
         (lambda (args)
           (define query (make-hasheq))
           (define target (a args "target"))
           (when target (hash-set! query 'target target))
           (values "POST" "/preflight" query #f)))
   (tool "BenchValidate"
         "Validate a target's real-ECU readiness (safety policy, drivers, placeholders)."
         '(("target" "string" #f #f "Target id (defaults to the profile default)."))
         (lambda (args)
           (define query (make-hasheq))
           (define target (a args "target"))
           (when target (hash-set! query 'target target))
           (values "POST" "/validate" query #f)))
   ;; ---- operations ----
   (tool "ListOperations" "List the runtime's active operations." '()
         (lambda (_args) (values "GET" "/operations" (hasheq) #f)))
   (tool "ListOperationHistory" "List recent completed operations (bounded newest-first)."
         '(("limit" "integer" #f 50 "Maximum entries (1-128)."))
         (lambda (args)
           (values "GET" "/operations/history" (hasheq 'limit (or (ai args "limit" 50) 50)) #f)))
   (tool "GetOperationEvidence"
         "Get the semantic evidence recorded for one operation."
         '(("operationId" "string" #t #f "Operation id from history or status."))
         (lambda (args)
           (values "GET" "/operations/evidence"
                   (hasheq 'operationId (a args "operationId")) #f)))
   (tool "CancelOperation" "Request cooperative cancellation of an active operation."
         '(("operationId" "string" #t #f "Operation id."))
         (lambda (args)
           (values "POST" "/operations/cancel"
                   (hasheq 'operationId (a args "operationId")) #f)))
   ;; ---- observations ----
   (tool "ListObservations" "List the runtime's active observations." '()
         (lambda (_args) (values "GET" "/observations" (hasheq) #f)))
   (tool "ListObservationHistory" "List recent completed observations."
         '(("limit" "integer" #f 50 "Maximum entries (1-128)."))
         (lambda (args)
           (values "GET" "/observations/history" (hasheq 'limit (or (ai args "limit" 50) 50)) #f)))
   (tool "GetObservationEvidence" "Get the evidence recorded for one observation."
         '(("observationId" "string" #t #f "Observation id."))
         (lambda (args)
           (values "GET" "/observations/evidence"
                   (hasheq 'observationId (a args "observationId")) #f)))
   (tool "CancelObservation" "Request cooperative cancellation of an active observation."
         '(("observationId" "string" #t #f "Observation id."))
         (lambda (args)
           (values "POST" "/observations/cancel"
                   (hasheq 'observationId (a args "observationId")) #f)))
   ;; ---- power ----
   (tool "PowerOn" "Switch the target's power supply on and wait for settle."
         '(("voltage" "number" #f 12 "Target voltage (V).")
           ("settleMs" "integer" #f 2000 "Settle window before measuring (ms).")
           ("target" "string" #f #f "Target id.")
           ("deadlineMs" "integer" #f #f "Runtime execution budget (ms)."))
         (lambda (args)
           (values "POST" "/power/on"
                   (target-query args)
                   (hasheq 'voltage (or (a args "voltage") 12)
                           'settleMs (or (ai args "settleMs") 2000)))))
   (tool "PowerOff" "Switch the target's power supply off."
         '(("target" "string" #f #f "Target id.")
           ("deadlineMs" "integer" #f #f "Runtime execution budget (ms)."))
         (lambda (args) (values "POST" "/power/off" (target-query args) (hasheq))))
   (tool "EmergencyPowerOff"
         "Emergency power-off: bypasses mutation gates, is not cancellable once accepted, and is audited."
         '(("target" "string" #f #f "Target id."))
         (lambda (args) (values "POST" "/power/emergency-off" (target-query args #:deadline #f) (hasheq))))
   (tool "ReadCurrent" "Sample the target's current over a window."
         '(("windowMs" "integer" #f 500 "Sampling window (ms).")
           ("target" "string" #f #f "Target id."))
         (lambda (args)
           (values "POST" "/power/current/read" (target-query args #:deadline #f)
                   (hasheq 'windowMs (or (ai args "windowMs" 500) 500)))))
   (tool "CheckCurrent" "Assert the target's current against lt/gt thresholds (mA)."
         '(("lt" "number" #f #f "Assert current below this value (mA).")
           ("gt" "number" #f #f "Assert current above this value (mA).")
           ("target" "string" #f #f "Target id."))
         (lambda (args)
           (values "POST" "/power/current/check" (target-query args #:deadline #f)
                   (hasheq 'ltMa (a args "lt") 'gtMa (a args "gt")))))
   ;; ---- flash / reset ----
   (tool "Flash" "Flash firmware through the target's flash driver (destructive)."
         '(("firmware" "string" #f "build/app.elf" "Firmware file path.")
           ("target" "string" #f #f "Target id.")
           ("confirmTarget" "string" #f #f "Required when the profile demands destructive confirmation; must equal the target id.")
           ("deadlineMs" "integer" #f #f "Runtime execution budget (ms)."))
         (lambda (args)
           (values "POST" "/flash/write"
                   (target-query args)
                   (hasheq 'firmware (or (a args "firmware") "build/app.elf")
                           'confirmTarget (a args "confirmTarget")))))
   (tool "Reset" "Reset the target through its flash driver (destructive)."
         '(("target" "string" #f #f "Target id.")
           ("confirmTarget" "string" #f #f "Required when the profile demands destructive confirmation.")
           ("deadlineMs" "integer" #f #f "Runtime execution budget (ms)."))
         (lambda (args)
           (values "POST" "/flash/reset" (target-query args)
                   (hasheq 'confirmTarget (a args "confirmTarget")))))
   ;; ---- serial ----
   (tool "SerialOpen" "Open the target's serial console."
         '(("port" "string" #f #f "Port override (e.g. COM7 or /dev/ttyUSB0).")
           ("baud" "integer" #f #f "Baud override.")
           ("target" "string" #f #f "Target id.")
           ("deadlineMs" "integer" #f #f "Runtime execution budget (ms)."))
         (lambda (args)
           (values "POST" "/serial/open" (target-query args)
                   (hasheq 'port (a args "port") 'baud (ai args "baud")))))
   (tool "SerialWaitFor"
         "Wait for a line on the target's serial console (observation; never blocks mutations)."
         '(("pattern" "string" #t #f "Case-insensitive substring to wait for.")
           ("timeoutMs" "integer" #f 10000 "Semantic wait window (ms).")
           ("target" "string" #f #f "Target id.")
           ("deadlineMs" "integer" #f #f "Runtime execution budget (ms)."))
         (lambda (args)
           (values "POST" "/serial/wait" (target-query args)
                   (hasheq 'pattern (a args "pattern")
                           'timeoutMs (or (ai args "timeoutMs") 10000)))))
   (tool "SerialReadWindow" "Read the last lines from the target's serial console buffer."
         '(("lines" "integer" #f 50 "Maximum lines.")
           ("filter" "string" #f #f "Case-insensitive substring filter.")
           ("target" "string" #f #f "Target id.")
           ("deadlineMs" "integer" #f #f "Runtime execution budget (ms)."))
         (lambda (args)
           (values "POST" "/serial/window" (target-query args)
                   (hasheq 'lines (or (ai args "lines" 50) 50)
                           'filter (a args "filter")))))
   (tool "SerialSend" "Send one line to the target's serial console."
         '(("data" "string" #t #f "Line to send.")
           ("target" "string" #f #f "Target id.")
           ("deadlineMs" "integer" #f #f "Runtime execution budget (ms)."))
         (lambda (args)
           (values "POST" "/serial/send" (target-query args)
                   (hasheq 'data (a args "data")))))
   ;; ---- diagnostics ----
   (tool "UdsRequest" "Send one raw UDS request over the target's diagnostics channel."
         '(("requestHex" "string" #t #f "Request bytes as hex, e.g. 22F195.")
           ("p2TimeoutMs" "integer" #f #f "P2 timeout override (ms).")
           ("p2StarTimeoutMs" "integer" #f #f "P2* timeout override (ms).")
           ("target" "string" #f #f "Target id."))
         (lambda (args)
           (values "POST" "/uds/request" (target-query args #:deadline #f)
                   (hasheq 'requestHex (a args "requestHex")
                           'p2TimeoutMs (ai args "p2TimeoutMs")
                           'p2StarTimeoutMs (ai args "p2StarTimeoutMs")))))
   (tool "UdsReadDid" "Read one UDS DID (synthesizes the 22XXXX request)."
         '(("did" "integer" #t #f "DID identifier, e.g. 61957 for F195.")
           ("target" "string" #f #f "Target id."))
         (lambda (args)
           (define did (ai args "did"))
           (unless did (raise-validation "did is required."))
           (values "POST" "/uds/request" (target-query args #:deadline #f)
                   (hasheq 'requestHex
                           (string-append "22"
                                          (string-upcase
                                           (~r did #:base 16 #:min-width 4 #:pad-string "0")))))))
   (tool "UdsFlash" "Run the UDS flash workflow (destructive)."
         '(("firmware" "string" #f #f "Firmware file path.")
           ("address" "integer" #f #f "Flash start address (required without planPath).")
           ("planPath" "string" #f #f "Flash plan JSON file path.")
           ("target" "string" #f #f "Target id.")
           ("confirmTarget" "string" #f #f "Required when the profile demands destructive confirmation.")
           ("deadlineMs" "integer" #f #f "Runtime execution budget (ms)."))
         (lambda (args)
           (values "POST" "/uds/flash" (target-query args)
                   (hasheq 'firmware (a args "firmware")
                           'address (ai args "address")
                           'planPath (a args "planPath")
                           'confirmTarget (a args "confirmTarget")))))
   (tool "DoipDiscover" "Discover DoIP vehicles on the network."
         '(("windowMs" "integer" #f 800 "Discovery window (ms)."))
         (lambda (args)
           (values "POST" "/doip/discover" (hasheq)
                   (hasheq 'windowMs (or (ai args "windowMs" 800) 800)))))))

(define (tool->definition t)
  (hasheq 'name (mcp-tool-name t)
          'description (mcp-tool-description t)
          'inputSchema
          (let ([properties
                 (for/hash ([p (in-list (mcp-tool-parameters t))])
                   (define key (string->symbol (first p)))
                   (values key
                           (hasheq 'type (second p)
                                   'description (fifth p))))])
            (hasheq 'type "object"
                    'properties properties
                    'required
                    (for/list ([p (in-list (mcp-tool-parameters t))]
                               #:when (third p))
                      (first p))))))

;; ----------------------------------------------------------------------------
;; Server
;; ----------------------------------------------------------------------------

(define (mcp-log message)
  (eprintf "benchpilot-mcp: ~a~n" message))

(define (ensure-daemon! host port)
  (define (reachable?)
    (with-handlers ([exn:fail? (lambda (_) #f)])
      (define-values (in out) (tcp-connect host port))
      (close-input-port in)
      (close-output-port out)
      #t))
  (unless (reachable?)
    (try-autostart host port)))

(define (json-rpc-result id result)
  (jsexpr->string (hasheq 'jsonrpc "2.0" 'id id 'result result)))

(define (json-rpc-error id code message)
  (jsexpr->string (hasheq 'jsonrpc "2.0"
                          'id id
                          'error (hasheq 'code code 'message message))))

(define (call-tool host port arguments name)
  (define t
    (findf (lambda (t) (string-ci=? (mcp-tool-name t) name)) mcp-tools))
  (unless t
    (raise (exn:fail (format "Unknown tool: ~a" name) (current-continuation-marks))))
  (define-values (method api-path query body)
    ((mcp-tool-build t) (if (hash? arguments) arguments (hasheq))))
  (define-values (status result)
    (api-call host port method api-path query body))
  (if (and (>= status 200) (< status 300))
      (hasheq 'content (list (hasheq 'type "text"
                                     'text (jsexpr->string result)))
              'isError #f)
      ;; Errors keep the API error body visible to the agent.
      (hasheq 'content (list (hasheq 'type "text"
                                     'text (jsexpr->string result)))
              'isError #t)))

;; Returns the reply string or #f for notifications.
(define (make-mcp-dispatch host port)
  (lambda (message)
    (define method (hash-ref message 'method #f))
    (define id (hash-ref message 'id #f))
    (define params (hash-ref message 'params (hasheq)))
    (cond
      [(not method) #f]
      [(string-prefix? method "notifications/") #f]
      [(string=? method "initialize")
       (json-rpc-result
        id
        (hasheq 'protocolVersion (let ([v (hash-ref params 'protocolVersion #f)])
                                   (if (string? v) v "2024-11-05"))
                'capabilities (hasheq 'tools (hasheq 'listChanged #f))
                'serverInfo (hasheq 'name "benchpilot-mcp"
                                    'version benchpilot-version)))]
      [(string=? method "ping") (json-rpc-result id (hasheq))]
      [(string=? method "tools/list")
       (json-rpc-result id (hasheq 'tools (map tool->definition mcp-tools)))]
      [(string=? method "tools/call")
       (define name (hash-ref params 'name #f))
       (define arguments (hash-ref params 'arguments (hasheq)))
       (with-handlers
           ([exn:benchpilot:network?
             (lambda (e)
               (json-rpc-result
                id
                (hasheq 'content
                        (list (hasheq 'type "text"
                                      'text (format "Runtime unavailable: ~a"
                                                    (exn-message e))))
                        'isError #t)))]
            [exn:fail?
             (lambda (e)
               (json-rpc-result
                id
                (hasheq 'content
                        (list (hasheq 'type "text" 'text (exn-message e)))
                        'isError #t)))])
         (json-rpc-result id (call-tool host port arguments name)))]
      [id (json-rpc-error id -32601 (format "Method not found: ~a" method))]
      [else #f])))

(define (run-mcp-server [in (current-input-port)] [out (current-output-port)])
  (define-values (host port) (resolve-endpoint #f))
  (with-handlers ([exn:fail:network?
                   (lambda (e)
                     ;; The daemon must be running for an MCP session to be
                     ;; useful; autostart once, then surface failures per call.
                     (with-handlers ([exn:fail? void])
                       (ensure-daemon! host port)))])
    (define-values (_in _out) (tcp-connect host port))
    (close-input-port _in)
    (close-output-port _out))
  (define dispatch (make-mcp-dispatch host port))
  (let loop ()
    (define line (read-line in 'any))
    (unless (eof-object? line)
      (unless (string-blank? line)
        (define message
          (with-handlers ([exn:fail? (lambda (_) #f)])
            (read-json (open-input-string line))))
        (when (hash? message)
          (define reply (with-handlers ([exn:fail?
                                         (lambda (e)
                                           (json-rpc-error (hash-ref message 'id #f)
                                                           -32700
                                                           (exn-message e)))])
                          (dispatch message)))
          (when reply
            (displayln reply out)
            (flush-output out))))
      (loop))))

(module+ main
  (run-mcp-server))
