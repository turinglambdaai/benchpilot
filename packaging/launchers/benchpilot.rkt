#lang racket/base

;; The shipped `benchpilot` launcher entry: identical to the staged E2E
;; wrapper, so the packaged CLI behaves exactly like the tested one.

(require benchpilot/client/cli)

(exit (bench-client-run!
       (parse-cli-args (vector->list (current-command-line-arguments)))))
