#lang racket/base

;; SelfUpdater.cs port: self-update for the shipped shells. Checks the
;; release feed, downloads the platform archive, verifies SHA256, stops the
;; resident daemon gracefully and swaps the executables in place. The next
;; CLI command restarts the daemon via autostart.
;;
;; Feed contract: by default the GitHub releases of BENCHPILOT_UPDATE_REPO
;; (default turinglambdaai/benchpilot) are used. BENCHPILOT_UPDATE_FEED
;; overrides this with a generic feed URL answering
;; {"tag_name": "...", "assets": [{"name": "...", "url"/"browser_download_url": ...}]}.
;; The platform archive must ship with a SHA256SUMS asset (releases older
;; than the family rename ship SHA256SUMS.txt; both names are accepted).
;;
;; Platform tools: checksums hash through sha256sum / shasum / certutil and
;; archives extract through the OS tar (bsdtar on Windows reads zip), so no
;; optional collection is required at runtime.

(require json
         net/url
         racket/file
         racket/format
         racket/list
         racket/port
         racket/string
         racket/system)

(require benchpilot/core/contracts
         benchpilot/protocol/local-auth)

(provide default-update-repository
         update-repository
         compare-versions
         platform-rid
         verify-checksum
         update-check
         update-run)

(define default-update-repository "turinglambdaai/benchpilot")

;; benchpilot, benchpilotd, benchpilot-mcp — the shipped launchers.
(define packaged-files '("benchpilot" "benchpilotd" "benchpilot-mcp"))

(define updater-user-agent "benchpilot-updater")

(define (update-repository)
  (or (getenv "BENCHPILOT_UPDATE_REPO") default-update-repository))

(define (feed-url)
  (define feed (getenv "BENCHPILOT_UPDATE_FEED"))
  (if (or (not feed) (string-blank? feed))
      (format "https://api.github.com/repos/~a/releases/latest" (update-repository))
      feed))

;; ----------------------------------------------------------------------------
;; Pure helpers
;; ----------------------------------------------------------------------------

;; Compares dotted numeric versions; positive when a is newer, negative when
;; b is newer, zero when equal. Non-numeric parts compare lexically after the
;; numeric prefix.
(define (compare-versions a b)
  (define (segments v)
    (define trimmed (string-trim v))
    (define stripped
      (if (and (>= (string-length trimmed) 1) (char=? (string-ref trimmed 0) #\v))
          (substring trimmed 1)
          trimmed))
    (string-split stripped "."))
  (define left (segments a))
  (define right (segments b))
  (let loop ([i 0])
    (if (>= i (max (length left) (length right)))
        0
        (let ([l (if (< i (length left)) (list-ref left i) "0")]
              [r (if (< i (length right)) (list-ref right i) "0")])
          (cond
            [(and (string->number l) (string->number r))
             (define li (string->number l))
             (define ri (string->number r))
             (cond [(< li ri) -1] [(> li ri) 1] [else (loop (add1 i))])]
            [(not (string-ci=? l r))
             (if (string<? (string-foldcase l) (string-foldcase r)) -1 1)]
            [else (loop (add1 i))])))))

(define (arch-is-arm64)
  (string-prefix? (format "~a" (system-library-subpath)) "aarch64"))

;; Maps the running platform to one of the release-packaging RIDs.
(define (platform-rid)
  (define arm64 (arch-is-arm64))
  (case (system-path-convention-type)
    [(windows) (if arm64 "win-arm64" "win-x64")]
    [else
     (cond
       [(regexp-match? #rx"macosx" (format "~a" (system-library-subpath)))
        (if arm64 "osx-arm64" "osx-x64")]
       [else (if arm64 "linux-arm64" "linux-x64")])]))

;; ----------------------------------------------------------------------------
;; Platform tool wrappers
;; ----------------------------------------------------------------------------

(define (find-system-tool name)
  (or (find-executable-path name) name))

(define (run-tool lines->value . argv)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    ;; subprocess returns (proc stdout stdin stderr): the read end of the
    ;; child's stdout first, then the write end of its stdin.
    (define-values (p child-stdout child-stdin child-stderr)
      (apply subprocess #f #f #f argv))
    (close-output-port child-stdin)
    (close-input-port child-stderr)
    (define output (open-output-string))
    (define collector
      (thread (lambda ()
                (copy-port child-stdout output)
                (close-input-port child-stdout))))
    (subprocess-wait p)
    (sync collector)
    (if (zero? (subprocess-status p))
        (lines->value (get-output-string output))
        #f)))

(define (sha256-hex path)
  (case (system-path-convention-type)
    [(windows)
     (run-tool
      (lambda (output)
        (for/first ([line (in-list (string-split output "\n"))]
                    #:when (regexp-match? #px"^[0-9a-fA-F]{64}$" (string-trim line)))
          (string-trim line)))
      (find-system-tool "certutil.exe") "-hashfile" path "SHA256")]
    [else
     (or (run-tool
          (lambda (output)
            (and (>= (string-length (string-trim output)) 64)
                 (first (string-split (string-trim output)))))
          (find-system-tool "sha256sum") path)
         (run-tool
          (lambda (output)
            (and (>= (string-length (string-trim output)) 64)
                 (first (string-split (string-trim output)))))
          (find-system-tool "shasum") "-a" "256" path))]))

;; "<hex>  <name>" (sha256sum output, two spaces), name matched
;; case-insensitively; raises on a missing or tampered entry.
(define (verify-checksum archive-path sums-path archive-name)
  (define expected
    (for/first ([line (in-list (file->lines sums-path))]
                #:do [(define parts
                        (filter (lambda (p) (not (string-blank? p)))
                                (string-split line " ")))
                      (define entry
                        (if (>= (length parts) 2)
                            (string-trim (second parts))
                            #f))]
                #:when (and entry (string-ci=? entry archive-name)))
      (string-trim (first parts))))
  (unless expected
    (raise (exn:fail (format "SHA256SUMS has no entry for '~a'." archive-name)
                     (current-continuation-marks))))
  (define actual (sha256-hex archive-path))
  (unless actual
    (raise (exn:fail "Could not hash the downloaded archive with a local SHA-256 tool."
                     (current-continuation-marks))))
  (unless (string-ci=? actual expected)
    (raise (exn:fail
            (format "Checksum mismatch: the downloaded archive does not match the SHA256SUMS manifest (expected ~a, got ~a)."
                    (string-downcase expected)
                    (string-downcase actual))
            (current-continuation-marks))))
  (void))

(define (extract-archive archive-path destination)
  (case (system-path-convention-type)
    [(windows)
     (run-extraction destination (find-system-tool "tar.exe") "-xf" archive-path)]
    [else
     (run-extraction destination "tar" "-xzf" archive-path)])
  ;; Archives wrap files in one directory; flatten it.
  (define entries (directory-list destination #:build? #t))
  (when (and (= (length entries) 1) (directory-exists? (first entries)))
    (define inner (first entries))
    (for ([entry (in-list (directory-list inner #:build? #t))])
      (define target (build-path destination (last (explode-path entry))))
      (when (file-exists? target) (delete-file target))
      (rename-file-or-directory entry target #f))
    (delete-directory inner)))

(define (run-extraction destination tool . argv)
  (parameterize ([current-directory destination])
    (define p (apply subprocess #f (current-input-port) 'stdout tool argv))
    (subprocess-wait p)
    (unless (zero? (subprocess-status p))
      (raise (exn:fail (format "Archive extraction failed (tool exit ~a)."
                               (subprocess-status p))
                       (current-continuation-marks))))))

;; ----------------------------------------------------------------------------
;; HTTP (feed over HTTPS; the resident daemon over loopback)
;; ----------------------------------------------------------------------------

(define (http-get-string url-string)
  (define url* (string->url url-string))
  (call/input-url
   url*
   (lambda (u) (get-pure-port u (list (format "User-Agent: ~a" updater-user-agent))))
   port->bytes))

(define (fetch-latest)
  (define feed (feed-url))
  (define body (http-get-string feed))
  (unless body
    (raise (exn:fail (format "Update feed '~a' returned no response." feed)
                     (current-continuation-marks))))
  (define doc
    (with-handlers ([exn:fail? void])
      (read-json (open-input-bytes body))))
  (unless (and (hash? doc) (list? (hash-ref doc 'assets #f)))
    (raise (exn:fail (format "Update feed '~a' returned an unrecognized shape." feed)
                     (current-continuation-marks))))
  (define tag (hash-ref doc 'tag_name #f))
  (define version
    (if (and (string? tag) (>= (string-length tag) 1) (char=? (string-ref tag 0) #\v))
        (substring tag 1)
        (format "~a" tag)))
  (define release-url
    (let ([u (hash-ref doc 'html_url #f)]) (if (string? u) u feed)))
  (define assets
    (filter
     values
     (for/list ([asset (in-list (hash-ref doc 'assets))])
       (and (hash? asset)
            (let ([name (hash-ref asset 'name #f)]
                  [url (or (hash-ref asset 'browser_download_url #f)
                           (hash-ref asset 'url #f))])
              (and (string? name) (not (string-blank? name))
                   (string? url) (not (string-blank? url))
                   (cons name url)))))))
  (values version assets release-url))

(define (download-to url-string destination)
  (define body (http-get-string url-string))
  (unless body
    (raise (exn:fail (format "Could not download '~a'." url-string)
                     (current-continuation-marks))))
  (display-to-file body destination #:mode 'binary #:exists 'replace))

;; ----------------------------------------------------------------------------
;; Daemon coordination
;; ----------------------------------------------------------------------------

(define (resolve-endpoint)
  (define endpoint (getenv "BENCHPILOT_ENDPOINT"))
  (if (or (not endpoint) (string-blank? endpoint))
      "http://127.0.0.1:5640/"
      endpoint))

(define (daemon-call method path)
  (define url* (string->url (string-append (resolve-endpoint) path)))
  (define token (read-token))
  (define headers
    (cons (format "User-Agent: ~a" updater-user-agent)
          (if token
              (list (format "X-Benchpilot-Token: ~a" token))
              '())))
  (define in
    (if (string=? method "POST")
        (post-pure-port url* #"{}" headers)
        (get-pure-port url* headers)))
  (define body (port->bytes in))
  (close-input-port in)
  body)

(define (probe-daemon)
  ;; (values was-running active-operations)
  (with-handlers ([exn:fail? (lambda (_) (values #f 0))])
    (define body (daemon-call "GET" "/api/v1/operations"))
    (define doc (with-handlers ([exn:fail? void]) (read-json (open-input-bytes body))))
    (define ops (if (hash? doc) (hash-ref doc 'operations '()) '()))
    (values #t (length ops))))

(define (daemon-reachable?)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (define url* (string->url (string-append (resolve-endpoint) "healthz")))
    (define in (get-pure-port url*
                              (list (format "User-Agent: ~a" updater-user-agent))))
    (port->bytes in)
    (close-input-port in)
    #t))

(define (kill-resident-daemons)
  (with-handlers ([exn:fail? void])
    (case (system-path-convention-type)
      [(windows)
       (subprocess-wait
        (subprocess #f (current-input-port) 'stdout
                    (find-system-tool "taskkill.exe") "/F" "/IM" "benchpilotd.exe" "/T"))]
      [else
       (subprocess-wait
        (subprocess #f (current-input-port) 'stdout
                    (find-system-tool "pkill") "-x" "benchpilotd"))])))

(define (stop-daemon! was-running)
  (when was-running
    (with-handlers ([exn:fail? void])
      (daemon-call "POST" "/api/v1/shutdown"))
    ;; Wait for the graceful drain to finish (bounded; the daemon releases
    ;; hardware resources before exiting).
    (let loop ([i 0])
      (when (and (< i 50) (daemon-reachable?))
        (sleep 0.2)
        (loop (add1 i)))))
  ;; Hard fallback: anything still holding the daemon binary is killed so
  ;; the file swap cannot fail on Windows file locks.
  (kill-resident-daemons))

;; ----------------------------------------------------------------------------
;; Install
;; ----------------------------------------------------------------------------

(define (current-executable-path)
  (path->string (find-system-path 'exec-file)))

;; install.sh/deb/brew wrap the real launcher in a tiny shell script so the
;; packaged lib tree keeps resolving; the updater follows that wrapper back.
(define (resolve-launcher-path path)
  (with-handlers ([exn:fail? (lambda (_) path)])
    (define lines (file->lines path))
    (if (and (>= (length lines) 3)
             (string-contains? (second lines) "benchpilot wrapper")
             (string-contains? (third lines) "exec "))
        (let ([m (regexp-match #rx"exec \"([^\"]+)\"" (third lines))])
          (if m (second m) path))
        path)))

(define (install-files! extract-dir)
  (define launcher-path
    (if (eq? (system-path-convention-type) 'windows)
        (current-executable-path)
        (resolve-launcher-path (current-executable-path))))
  (define install-dir
    (let-values ([(dir _name _dir?) (split-path (path->complete-path
                                                 launcher-path))])
      (path->string dir)))
  (define windows? (eq? (system-path-convention-type) 'windows))
  (define suffix (if windows? ".exe" ""))
  ;; Unix archives carry the launchers under bin/ next to lib/.
  (define source-dir
    (if windows? extract-dir (build-path extract-dir "bin")))
  (define swapped 0)
  (for ([base-name (in-list packaged-files)])
    (define source (build-path source-dir (string-append base-name suffix)))
    (when (file-exists? source)
      (define target (build-path install-dir (string-append base-name suffix)))
      (define backup (string-append (path->string target) ".old"))
      (when (file-exists? backup)
        (with-handlers ([exn:fail? void]) (delete-file backup)))
      ;; Renaming a running executable is allowed on Windows (the image
      ;; section stays with the old name), so even benchpilot.exe replacing
      ;; itself mid-run works; deleting does not.
      (when (file-exists? target)
        (rename-file-or-directory target backup #f))
      (rename-file-or-directory source target #f)
      (set! swapped (add1 swapped))))
  swapped)

;; ----------------------------------------------------------------------------
;; Entry points
;; ----------------------------------------------------------------------------

(define (update-check)
  (define current benchpilot-version)
  (with-handlers
      ([exn:fail?
        (lambda (e)
          (update-check-result #f current #f #f (exn-message e)))])
    (define-values (latest _assets release-url) (fetch-latest))
    (update-check-result (> (compare-versions latest current) 0)
                         current latest release-url #f)))

(define (with-temp-directory proc)
  (define dir (make-temporary-file "benchpilot-update-~a" 'directory))
  (dynamic-wind
   void
   (lambda () (proc dir))
   (lambda ()
     (with-handlers ([exn:fail? void])
       (delete-directory/files dir)))))

;; Runs the full update: download, verify, stop daemon, swap, optionally
;; restart the daemon. Files are only touched after verification passes.
(struct exn:refused-result exn:fail () #:transparent)

(define (update-run)
  (define current benchpilot-version)
  (with-temp-directory
   (lambda (work-dir)
     (with-handlers
         ([exn:refused-result?
           (lambda (e)
             ;; A refused update is a clean negative result, not a failure.
             (update-result #f (exn-message e) current #f (exn-message e)))]
          [exn:fail?
           (lambda (e)
             (update-result #f (format "Update failed: ~a" (exn-message e)) current #f
                            (exn-message e)))])
       (define-values (latest assets _release-url) (fetch-latest))
       (cond
         [(<= (compare-versions latest current) 0)
          (update-result #t (format "Already up to date (~a)." current) current #f #f)]
         [else
          (define rid (platform-rid))
          (define extension (if (equal? rid "win-x64") "zip" "tar.gz"))
          (define archive-name (format "benchpilot-~a-~a.~a" latest rid extension))
          (define archive (findf (lambda (a) (string-ci=? (car a) archive-name)) assets))
          (unless archive
            (raise (exn:fail (format "Release ~a has no asset '~a'." latest archive-name)
                             (current-continuation-marks))))
          ;; Family manifest name is SHA256SUMS; releases older than the
          ;; rename ship SHA256SUMS.txt — accept either so a self-update can
          ;; cross the transition.
          (define sums (findf (lambda (a) (or (string-ci=? (car a) "SHA256SUMS")
                                              (string-ci=? (car a) "SHA256SUMS.txt")))
                              assets))
          (unless sums
            (raise (exn:fail (format "Release ~a has no SHA256SUMS asset." latest)
                             (current-continuation-marks))))
          (define archive-path (build-path work-dir archive-name))
          (download-to (cdr archive) archive-path)
          (define sums-path (build-path work-dir (car sums)))
          (download-to (cdr sums) sums-path)
          (verify-checksum archive-path sums-path archive-name)

          (define extract-dir (build-path work-dir "extract"))
          (make-directory* extract-dir)
          (extract-archive archive-path extract-dir)

          ;; Refuse to interrupt active hardware work before touching files.
          (define-values (daemon-was-running active-operations) (probe-daemon))
          (when (> active-operations 0)
            (raise (exn:refused-result
                    (format "The daemon has ~a active operation(s); update refused. Wait for them to finish or cancel them, then retry."
                            active-operations)
                    (current-continuation-marks))))
          (stop-daemon! daemon-was-running)

          (define installed (install-files! extract-dir))
          (when (zero? installed)
            (raise (exn:fail
                    (format "Archive '~a' contained none of the BenchPilot executables."
                            archive-name)
                    (current-continuation-marks))))
          (update-result
           #t
           (string-append
            (format "Updated to ~a (~a executable(s) swapped). " latest installed)
            (if daemon-was-running
                "The daemon restarts automatically on the next command. "
                "")
            "If an agent hosts benchpilot-mcp, restart that MCP server.")
           latest
           daemon-was-running
           #f)])))))
