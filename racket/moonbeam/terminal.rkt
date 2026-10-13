#lang racket/base

;; Terminal backends for the host daemon.
;;
;;  - 'pty  (unix/macOS): a real pseudo-terminal. All FFI lives in the `pty`
;;          submodule, which is only loaded on unix — Windows never touches
;;          it. Limitation (M0): no controlling terminal, so Ctrl-C/SIGWINCH
;;          delivery is best-effort.
;;  - 'pipe (all platforms): plain subprocess pipes. Always available; the
;;          shell runs non-interactive (no TUI, no line editing). What agents
;;          use by default.

(require ffi/unsafe
         ffi/unsafe/define
         racket/port
         racket/string)

;; Anchored to this file so dynamic-require works from any CWD.
(define pty-module-path
  (let-values ([(dir _name _dir?)
                (split-path (resolved-module-path-name
                             (variable-reference->resolved-module-path
                              (#%variable-reference))))])
    (build-path dir "terminal-pty.rkt")))

(define (pty-supported?)
  (memq (system-type 'os) '(unix macosx)))

;; ---- interface ----
;;
;; spawn-terminal backend shell-path args cols rows #:on-output proc
;;   -> (values write-input! close-input! wait resize!)
;;   write-input!  : bytes? -> void
;;   close-input!  : -> void          (signals EOF to the shell)
;;   wait          : -> exit-code     (exact-nonnegative-integer?)
;;   resize!       : cols rows -> void, or #f when unsupported

(define (spawn-terminal backend shell-path args cols rows #:on-output on-output)
  (case backend
    [(pty)
     (unless (pty-supported?)
       (error 'spawn-terminal "pty backend requires unix/macOS"))
     (define spawn-pty (dynamic-require pty-module-path 'spawn-pty))
     (spawn-pty shell-path args cols rows on-output)]
    [else (spawn-pipe shell-path args on-output)]))

;; ---- pipe backend ----

(define (spawn-pipe shell-path args on-output)
  (define-values (p stdout stdin stderr)
    (apply subprocess #f #f #f shell-path args))
  ;; Pump stdout and stderr to the caller.
  (define (pump port)
    (thread
     (lambda ()
       (define buf (make-bytes 65536))
       (let loop ()
         (define n (read-bytes-avail! buf port))
         (cond
           [(eof-object? n) (void)]
           [(and (fixnum? n) (> n 0))
            (on-output (subbytes buf 0 n))
            (loop)]
           [else (loop)])))))
  (pump stdout)
  (pump stderr)
  (values (lambda (bstr)
            (write-bytes bstr stdin)
            (flush-output stdin))
          (lambda () (close-output-port stdin))
          (lambda ()
            (subprocess-wait p)
            (define st (subprocess-status p))
            (if (fixnum? st) st 0))
          #f))

(provide pty-supported?
         spawn-terminal)

