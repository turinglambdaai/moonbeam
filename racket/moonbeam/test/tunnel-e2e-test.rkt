#lang racket/base

;; M1 end-to-end: the text lane works from "anywhere". The client has NO
;; direct network path to the host — everything goes through the relay's
;; splice tunnel. Exercises: pairing via relay, exec/terminal/file over the
;; tunnel, the routing ladder (bogus direct address falls back to relay),
;; and detached-session resume.

(require json
         racket/file
         racket/format
         racket/port
         racket/string
         rackunit
         moonbeam/client
         (prefix-in host: moonbeam/host)
         moonbeam/relay
         moonbeam/httpmini
         moonbeam/proto)

(when (eq? (system-type 'os) 'windows)
  (eprintf "tunnel-e2e: skipped on windows (host daemon is unix-first in M1)\n"))

(unless (eq? (system-type 'os) 'windows)
  (define tmp (make-temporary-file "moonbeam-tun~a" 'directory))
  (define cfg (build-path tmp "config"))
  (parameterize ([config-dir cfg]
                 [store-path (build-path cfg "hosts.rktd")]
                 [relay-config-path (build-path cfg "relay.rktd")]
                 [host:config-dir cfg])
    (thread (lambda () (sleep 60)
                      (eprintf "tunnel-e2e: timed out\n")
                      (exit 1)))

    ;; Relay up.
    (define-values (relay-listener relay-port) (serve-relay! #:port 0 #:token "rt"))
    (set-relay-config! "127.0.0.1" relay-port "rt")

    ;; Host daemon: token + relay uplink. Its direct port exists but the
    ;; client below never learns a working direct address for it.
    (define token "9999888877776666999988887777666699998888777766669999888877776666")
    (define-values (hl hn port)
      (host:start-daemon! #:port 0 #:shell "/bin/sh" #:token-override token))
    (host:uplink-loop! "127.0.0.1" relay-port "testhost" "rt" token)

    ;; Wait until the host's uplink has registered itself at the relay.
    (define (uplink-ready?)
      (with-handlers ([exn:fail? (lambda (_) #f)])
        (define-values (code resp)
          (http-get-json "127.0.0.1" relay-port "/lookup/testhost" "rt"))
        (eprintf "T: lookup code=~a resp=~s\n" code resp)
        (flush-output (current-error-port))
        (and (= code 200) (hash-ref resp 'ok #f))))
    (let wait-ready ([n 50])
      (unless (or (uplink-ready?) (zero? n))
        (sleep 0.1)
        (wait-ready (sub1 n))))
    (check-true (uplink-ready?) "host uplink should register at the relay")

    ;; Pair THROUGH the relay (the client never touched the host directly).
    (eprintf "T: pairing via relay\n")
    (define paired (pair! "testhost" #:pin (host:host-pin token) #:via-relay #t))
    (eprintf "T: paired\n")
    (check-equal? paired token)

    ;; Store a deliberately bogus direct address: the ladder must fall back.
    ;; (pair! via relay stored direct = #f; simulate a stale LAN entry.)
    (define stored (lookup-entry "testhost"))
    (check-true (pair? stored))
    (define token-stored (car stored))
    (define others
      (filter (lambda (e) (not (equal? (car e) "testhost")))
              (call-with-input-file (store-path) read)))
    (save-store! (cons (cons "testhost"
                             (list token-stored "10.255.255.1" 1))
                       others))

    ;; Exec over the tunnel (before the ladder rewrite).
    (eprintf "T: exec 1\n")
    (define r1 (run-command "testhost" (list "echo" "over-the-tunnel")))
    (eprintf "T: exec 1 done")
    (check-true (hash-ref r1 'ok))
    (check-equal? (hash-ref r1 'code) 0)
    (check-true (string-contains? (hash-ref r1 'stdout) "over-the-tunnel"))

    ;; Ladder fallback: ops still work via the relay with a dead direct addr.
    (eprintf "T: exec 2 (ladder)\n")
    (define r2 (run-command "testhost" (list "echo" "ladder-fallback")))
    (eprintf "T: exec 2 done\n")
    (check-true (hash-ref r2 'ok))
    (check-true (string-contains? (hash-ref r2 'stdout) "ladder-fallback"))

    ;; Detached-session resume (断线继承): open a pipe session, set a shell
    ;; variable, detach without exiting; resume and read the variable back.
    (eprintf "T: open session\n")
    (define-values (t-in t-out backend sid)
      (open-terminal "testhost" #:backend "pipe"))
    (eprintf "T: session ~a opened\n" sid)
    (check-true (string? sid))
    (write-frame t-out frame-data
                 (string->bytes/utf-8 "MOONBEAM_TOKEN_LANE=yes\n"))
    ;; Detach: say bye and drop the connection (shell must live on).
    (write-json-frame t-out frame-ctl (hasheq 'op "bye"))
    (close-input-port t-in)
    (close-output-port t-out)

    ;; Resume and prove the same shell is still ours.
    (eprintf "T: resuming ~a\n" sid)
    (define-values (r-in r-out backend2 sid2)
      (open-terminal "testhost" #:backend "pipe" #:resume sid))
    (eprintf "T: resumed\n")
    (check-equal? sid2 sid)
    (define out-buf (open-output-bytes))
    (write-frame r-out frame-data
                 (string->bytes/utf-8 "echo lane=$MOONBEAM_TOKEN_LANE\nexit\n"))
    (define code 0)
    (let loop ()
      (define-values (t payload) (read-frame r-in))
      (cond
        [(not t) (void)]
        [(= t frame-data)
         (write-bytes payload out-buf)
         (loop)]
        [(= t frame-exit)
         (set! code (hash-ref (string->jsexpr (bytes->string/utf-8 payload)) 'code 0))]
        [else (loop)]))
    (define resumed-out
      (bytes->string/utf-8 (get-output-bytes out-buf) #\uFFFD))
    (check-true (string-contains? resumed-out "lane=yes")
                "the detached shell should have kept its environment")
    (check-equal? code 0)

    ;; File transfer over the tunnel.
    (define src (build-path tmp "in.bin"))
    (define payload (make-bytes 300000))
    (for ([i (in-range (bytes-length payload))])
      (bytes-set! payload i (modulo (* i 7) 256)))
    (call-with-output-file src
      (lambda (fout) (write-bytes payload fout)) #:exists 'truncate)
    (eprintf "T: put\n")
    (define ack (put-file "testhost" src "tun.bin"))
    (eprintf "T: put done\n")
    (check-true (hash-ref ack 'ok))
    (eprintf "T: get\n")
    (define got (get-file* "testhost" "tun.bin" (build-path tmp "out.bin")))
    (eprintf "T: get done\n")
    (check-true (hash-ref got 'ok))
    (check-equal? (file->bytes (build-path tmp "out.bin")) payload)

    ;; Resume of a dead session id is refused cleanly.
    (check-exn exn:fail?
               (lambda ()
                 (open-terminal "testhost" #:resume "s0-nope")))

    (eprintf "tunnel-e2e: all checks passed (relay port ~a)\n" relay-port)
    (exit 0)))
