#lang info

(define collection 'multi)
;; Racket package versions reject a trailing ".0" component; the C# side and
;; release tags stay three-component SemVer (see ADR 0002 for the parity gate).
(define version "0.6.0")
(define pkg-desc "BenchPilot: ECU bench runtime, Racket port of the C# product core")
(define pkg-authors '(turinglambdaai))
(define license 'AGPL-3.0)

(define deps
  '(["base" #:version "9.0"]))

(define build-deps
  '("rackunit-lib"))

(define compile-omit-paths
  '("benchpilot/core/profile-test.rkt"
    "benchpilot/core/readiness-test.rkt"
    "benchpilot/diagnostics/isotp/codec-test.rkt"
    "benchpilot/diagnostics/flash/workflow-test.rkt"))
