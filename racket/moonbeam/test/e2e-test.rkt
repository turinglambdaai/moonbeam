#lang racket/base

;; End-to-end M0 test: relay + host daemon + client, all on loopback.
;; Exercises: pairing (good and bad PIN), exec, the pipe terminal lane,
;; file put/get round-trip, relay register/lookup/wake and auth rejection.
;; Skipped on Windows: the host daemon is unix-first in M0.

(require json
         racket/file
         racket/format
         racket/port
         racket/string
         rackunit
         moonbeam/client
         (prefix-in host: moonbeam/host)
         moonbeam/httpmini
         moonbeam/relay)

(define (run)
  ;; Sandbox all state in a temp directory.
  (define tmp (make-temporary-file "moonbeam-e2e~a" 'directory))
  (define cfg (build-path tmp "config"))
  (parameterize ([config-dir cfg]
                  [store-path (build-path cfg "hosts.rktd")]
                  [host:config-dir cfg])
    ;; 60s watchdog so a broken lane fails loudly instead of hanging CI.
    (thread (lambda () (sleep 60)
                    (eprintf "e2e: timed out\n")
                    (exit 1)))

    ;; -- relay --
    (define-values (relay-listener relay-port) (serve-relay! #:token "test-token"))

    ;; -- health + auth rejection --
    (define-values (hcode hbody)
      (http-get-json "127.0.0.1" relay-port "/health" #f))
    (check-equal? hcode 200)
    (check-true (hash-ref hbody 'ok))
    (define-values (acode _abody)
      (http-get-json "127.0.0.1" relay-port "/lookup/nope" "wrong-token"))
    (check-equal? acode 401)

    ;; -- host daemon --
    (define token "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
    (define-values (host-listener hostname port)
      (host:start-daemon! #:shell "/bin/sh" #:token-override token))
    (check-equal? (host:host-pin token) (host:host-pin token)) ; deterministic

    ;; -- pairing: wrong PIN rejected, right PIN accepted --
    (check-exn exn:fail?
               (lambda () (pair! "testhost" "127.0.0.1" port "000000")))
    (define paired-token (pair! "testhost" "127.0.0.1" port (host:host-pin token)))
    (check-equal? paired-token token)

    ;; -- exec: the agent workhorse --
    (define exec-resp (run-command "testhost" "127.0.0.1" port
                                   (list "echo" "moonbeam-m0")))
    (check-true (hash-ref exec-resp 'ok))
    (check-equal? (hash-ref exec-resp 'code) 0)
    (check-true (string-contains? (hash-ref exec-resp 'stdout) "moonbeam-m0"))

    (define exec2 (run-command "testhost" "127.0.0.1" port
                               (list "sh" "-c" "exit 7")))
    (check-equal? (hash-ref exec2 'code) 7)

    ;; -- terminal lane over pipes --
    (define-values (tout tcode)
      (terminal-command "testhost" "127.0.0.1" port "echo tty-lane"))
    (check-true (string-contains? tout "tty-lane"))
    (check-equal? tcode 0)

    ;; -- file transfer: put then get, byte-identical --
    (define src (build-path tmp "in.bin"))
    (define payload (make-bytes (* 1024 1024)))
    (for ([i (in-range (bytes-length payload))])
      (bytes-set! payload i (modulo i 256)))
    (display-to-file "" src #:exists 'truncate) ; placeholder
    (call-with-output-file src
      (lambda (fout) (write-bytes payload fout)) #:exists 'truncate)
    (define put-ack (put-file "testhost" "127.0.0.1" port src "roundtrip.bin"))
    (check-true (hash-ref put-ack 'ok))
    (define stored (build-path cfg "incoming" "roundtrip.bin"))
    (check-true (file-exists? stored))
    (check-equal? (file->bytes stored) payload)

    (define get-resp (get-file* "testhost" "127.0.0.1" port
                                (path->string stored)
                                (path->string (build-path tmp "out.bin"))))
    (check-true (hash-ref get-resp 'ok))
    (check-equal? (file->bytes (build-path tmp "out.bin")) payload)

    ;; -- relay signaling + wake --
    (define-values (rcode _rbody)
      (http-post-json "127.0.0.1" relay-port "/register"
                      (hasheq 'id "test-host"
                              'addrs (list (format "127.0.0.1:~a" port)))
                      "test-token"))
    (check-equal? rcode 200)
    (define-values (lcode lbody)
      (http-get-json "127.0.0.1" relay-port "/lookup/test-host" "test-token"))
    (check-equal? lcode 200)
    (check-equal? (hash-ref lbody 'addrs)
                  (list (format "127.0.0.1:~a" port)))
    (define-values (wcode wbody)
      (http-post-json "127.0.0.1" relay-port "/wake"
                      (hasheq 'macs (list "00:11:22:33:44:55")) "test-token"))
    (check-equal? wcode 200)
    (check-true (hash-ref wbody 'ok))

    (eprintf "e2e: all checks passed (host port ~a, relay port ~a)\n"
             port relay-port)
    (exit 0)))

(when (eq? (system-type 'os) 'windows)
  (eprintf "e2e: skipped on windows (host daemon is unix-first in M0)\n"))
(unless (eq? (system-type 'os) 'windows)
  (run))
