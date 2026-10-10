#lang racket/base

;; Updater tests for the Studio backend: platform mapping, manifest URL
;; construction, download progress accounting, the sticky rollout bucket,
;; and the offline trust chain — craft a manifest, sign it with a throwaway
;; Ed25519 key, verify it, and select updates the same way the live checker
;; does. (fetch-update-manifest itself only accepts HTTPS, so the network
;; half is exercised in production; everything it does with the bytes is
;; tested here, plus the error path against a closed local port.)
;;
;; The typed RPC handlers (check-updates / update-state) are exercised
;; directly through the backend's `rpcs` test seam: failures must surface
;; as records/phases, never as raised errors that could take a host down.

(require crypto
         crypto/all
         rackunit
         rivet/backend
         rivet/distribution
         racket/file
         racket/path
         racket/runtime-path
         racket/string
         (submod "../app/backend.rkt" rpcs)
         "../app/updater.rkt")

(use-all-factories!)

;; The rollout bucket and the updater state live under ~/.benchpilot/studio;
;; point USERPROFILE/HOME at a scratch directory so tests never touch the
;; real one (each rackunit file runs in its own process, so this is safe).
(define-runtime-path here ".")
(define scratch-home
  (make-temporary-file "benchpilot-updater-home-~a" 'directory))
(putenv "USERPROFILE" (path->string scratch-home))
(putenv "HOME" (path->string scratch-home))

(test-case "platform symbols match rivet release manifests"
  (case (system-type 'os)
    [(macosx) (check-equal? (platform-symbol) 'macos)]
    [(windows) (check-equal? (platform-symbol) 'windows)]
    [else (check-equal? (platform-symbol) 'linux)])
  (check-not-false (memq (architecture-symbol) '(arm64 x64))))

(test-case "installer extension follows platform"
  (check-not-false
   (member (installer-extension) '(".zip" ".tar.gz"))
   "known installer extension"))

(test-case "manifest url joins base and file name"
  (check-equal? (manifest-url)
                (string-append default-update-base-url "/update-manifest.json"))
  (check-equal?
   (parameterize ([current-update-base-url "https://dl.example/benchpilot/"])
     (manifest-url))
   "https://dl.example/benchpilot/update-manifest.json")
  (check-equal?
   (parameterize ([current-update-base-url "https://dl.example/benchpilot"])
     (manifest-url))
   "https://dl.example/benchpilot/update-manifest.json"))

(test-case "download progress copies bytes and reports percent"
  (reset-update-state!)
  (define payload (make-bytes 250000 7))
  (define out (open-output-bytes))
  (copy-with-progress! (open-input-bytes payload) out 250000)
  (check-equal? (bytes-length (get-output-bytes out)) 250000)
  (check-equal? (hash-ref (update-state-snapshot) 'percent) 100)
  ;; percent tracks the declared total, not the end of input
  (reset-update-state!)
  (define short-out (open-output-bytes))
  (copy-with-progress! (open-input-bytes payload) short-out 1000000)
  (check-equal? (hash-ref (update-state-snapshot) 'percent) 25)
  (reset-update-state!))

(test-case "rollout bucket is sticky and persists under the studio home"
  (check-true (exact-integer? (rollout-bucket)))
  (define first (rollout-bucket))
  (check-true (<= 0 first 99))
  ;; a second read returns the persisted bucket, not a fresh draw
  (check-equal? (rollout-bucket) first)
  (check-equal?
   (string-trim
    (file->string
     (build-path scratch-home ".benchpilot" "studio" "rollout-bucket")))
   (number->string first)))

(test-case "check against an unreachable feed reports error state"
  (parameterize ([current-update-base-url "https://127.0.0.1:9/benchpilot"])
    (reset-update-state!)
    (define result (perform-check!))
    (check-equal? (hash-ref result 'status) "error")
    (check-equal? (hash-ref (update-state-snapshot) 'phase) "error")
    (check-true (string? (hash-ref (update-state-snapshot) 'message)))))

(test-case "signed manifest verifies and selects updates"
  ;; throwaway keypair: same DER formats the release pipeline uses
  (define priv (generate-private-key 'eddsa '((curve ed25519))))
  (define priv-der (pk-key->datum priv 'OneAsymmetricKey))
  (define priv-path (make-temporary-file "benchpilot-test-key-~a.der"))
  (with-output-to-file priv-path
    #:exists 'truncate
    (lambda () (write-bytes priv-der)))
  (define pub (datum->pk-key (pk-key->datum priv 'rkt-public) 'rkt-public))
  (define artifact-file (make-temporary-file "benchpilot-artifact-~a.zip"))
  (call-with-output-file artifact-file
    #:exists 'truncate
    (lambda (out) (write-bytes (make-bytes 128 3) out)))
  (define manifest
    (update-manifest
     app-identifier "9.9.9" 7 'stable
     "2026-10-09T00:00:00Z" "0.0.0" #f #t 100
     (list (update-artifact (platform-symbol) (architecture-symbol)
                            "https://dl.example/benchpilot/studio.zip"
                            (sha256-file/hex artifact-file)
                            (file-size artifact-file)
                            'zip '()))))
  ;; write-signed-manifest refuses malformed manifests before signing
  (define wrapped (open-output-bytes))
  (write-signed-manifest manifest priv "benchpilot-test" wrapped)
  (define verified
    (verify-signed-manifest (open-input-bytes (get-output-bytes wrapped))
                            pub
                            #:key-id "benchpilot-test"))
  (check-equal? (update-manifest-version verified) "9.9.9")
  ;; a different key-id fails closed
  (check-exn exn:fail?
             (lambda ()
               (verify-signed-manifest
                (open-input-bytes (get-output-bytes wrapped))
                pub
                #:key-id "some-other-key")))
  (delete-file priv-path)
  (delete-file artifact-file))

;; --- typed RPC surface (backend test seam) ------------------------------------

(test-case "check-updates surfaces feed failures as an error record"
  (parameterize ([current-update-base-url "https://127.0.0.1:9/benchpilot"])
    (define record (check-updates))
    (check-equal? (record-ref record 'status) "error")
    (check-true (string? (record-ref record 'error)))
    (check-equal? (record-ref record 'current-version) app-version)
    (check-true (void? (record-ref record 'available-version)))))

(test-case "start-download without a candidate lands in the error phase"
  (reset-update-state!)
  (start-download)
  (define record (update-state))
  (check-equal? (record-ref record 'phase) "error")
  (check-true (string? (record-ref record 'message)))
  (check-equal? (record-ref record 'percent) 0))

(test-case "embedded release identity is coherent"
  (check-equal? app-identifier "site.jrtx.benchpilot-studio")
  (check-equal? app-channel 'stable)
  (check-equal? update-key-id "benchpilot-2026-10")
  ;; the updater's embedded version tracks the repository VERSION file
  (check-equal?
   app-version
   (string-trim
    (file->string (build-path here ".." ".." "VERSION")))))
