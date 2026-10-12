#lang racket/base

;; PTY backend sanity check (macOS/Linux): start the host daemon with a real
;; pseudo-terminal and verify the shell talks, reports a TTY, and exits.

        (require racket/file
         racket/format
         racket/string
         rackunit
         moonbeam/client
         moonbeam/proto
         json
         (prefix-in host: moonbeam/host))

(define tmp (make-temporary-file "moonbeam-pty~a" 'directory))
(define cfg (build-path tmp "config"))
(define token "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210")

(parameterize ([config-dir cfg]
               [store-path (build-path cfg "hosts.rktd")]
               [host:config-dir cfg])
  (thread (lambda () (sleep 30)
                    (eprintf "pty-check: timed out\n")
                    (exit 1)))
  (define shell
    (or (getenv "SHELL") "/bin/sh"))
  (define-values (_listener hostname port)
    (host:start-daemon! #:port 0 #:shell shell #:backend "pty" #:token-override token))
  (pair! "ptyhost" "127.0.0.1" port (host:host-pin token))
  (define-values (in out backend) (open-terminal "ptyhost" "127.0.0.1" port #:backend "pty"))
  (eprintf "pty-check: backend=~a shell=~a\n" backend shell)
  ;; Ask the shell whether it is a TTY, then leave.
  (write-frame out frame-data
               (string->bytes/utf-8 "test -t 0 && echo TTY-YES || echo TTY-NO\nexit\n"))
  (define buf (open-output-bytes))
  (define code 0)
  (let loop ()
    (define-values (t payload) (read-frame in))
    (cond
      [(not t) (void)]
      [(= t frame-data)
       (write-bytes payload buf)
       (loop)]
      [(= t frame-exit)
       (set! code (hash-ref (string->jsexpr (bytes->string/utf-8 payload)) 'code 0))]
      [else (loop)]))
  (define output (bytes->string/utf-8 (get-output-bytes buf) #\uFFFD))
  (eprintf "pty-check: output=~s exit=~a\n" (string-trim output) code)
  (check-true (string-contains? output "TTY-YES")
              "the shell should see a real TTY through the pty backend")
  (check-equal? code 0)
  (check-eq? (string->symbol backend) 'pty)
  (exit 0))
