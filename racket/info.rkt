#lang info

(define collection 'multi)
(define pkg-desc "Moonbeam: self-hosted remote access for the agent era (text lane)")
(define pkg-authors '(turinglambdaai))
(define license 'MIT)

(define deps
  '(["base" #:version "9.0"]
    "websocket"))

(define build-deps
  '("rackunit-lib"))

;; terminal-pty.rkt resolves unix FFI at load; its behavior is covered by
;; test/pty-check.rkt through the daemon, so raco test skips the file.
(define test-omit-paths
  '("moonbeam/terminal-pty.rkt"))
