#lang racket/base

;; Moonbeam host daemon: pairing, terminal sessions, exec and file transfer.
;; M0 serves the text lane on the LAN; relay signaling and the video stack
;; arrive in later milestones.

(require json
         openssl/sha1
         racket/file
         racket/format
         racket/match
         racket/path
         racket/port
         racket/string
         racket/system
         racket/tcp
         "desktop.rkt"
         "httpmini.rkt"
         "netutil.rkt"
         "proto.rkt"
         "terminal.rkt")

;; ---- configuration ----

(define default-port 49090)

(define config-dir
  (make-parameter
   (build-path (find-system-path 'home-dir) ".config" "moonbeam")))

(define current-shell (make-parameter #f))
(define current-backend (make-parameter 'auto))
(define current-host-token (make-parameter #f))

(define (ensure-config-dir!)
  (make-directory* (config-dir)))

;; 64-hex token persisted at <config>/host-token (mode 0600).
(define (ensure-host-token)
  (ensure-config-dir!)
  (define p (build-path (config-dir) "host-token"))
  (cond
    [(file-exists? p) (string-trim (file->string p))]
    [else
     (define tok
       (apply string
              (for/list ([_i (in-range 64)])
                (string-ref "0123456789abcdef" (random 16)))))
     (display-to-file tok p #:exists 'truncate)
     (unless (eq? (system-type 'os) 'windows) (system* "/bin/chmod" "600" (path->string p)))
     tok]))

;; Six-digit pairing PIN derived from the token.
(define (host-pin token)
  (define h (sha1 (open-input-string token)))
  (define digits (regexp-replace* #rx"[^0-9]" h ""))
  (substring (string-append digits "000000") 0 6))

(define (ensure-incoming-dir!)
  (define p (build-path (config-dir) "incoming"))
  (make-directory* p)
  p)

(define (file-sha1 path)
  (call-with-input-file path (lambda (in) (sha1 in))))

;; Rejects path components that could escape the incoming directory.
(define (safe-name s)
  (define p (string->path s))
  (define base (file-name-from-path p))
  (define base-str (and base (path->string base)))
  (unless (and base-str
               (not (member base-str (list "." "..")))
               (not (string-contains? s "/"))
               (not (string-contains? s "\\")))
    (error 'safe-name "rejected file name: ~a" s))
  base-str)

;; ---- session ops ----

(define (op-exec out msg)
  (define argv (map ~a (hash-ref msg 'argv (list))))
  (cond
    [(null? argv)
     (write-json-frame out frame-ack (hasheq 'ok #f 'error "empty-argv"))]
    [else
     (define limit (arithmetic-shift 1 20)) ; 1 MiB per stream
     (define resolved (find-executable-path (car argv)))
     (cond
       [(not resolved)
        (write-json-frame out frame-ack
                          (hasheq 'ok #f 'error "not-found" 'cmd (car argv)))]
       [else
        (exec-run! out limit (path->string resolved) (cdr argv))])]))

;; Runs a resolved command with piped stdio and reports one JSON verdict.
(define (exec-run! out limit cmd args)
  (define-values (p stdout stdin stderr)
    (apply subprocess #f #f #f cmd args))
  (close-output-port stdin)
  (define sout (open-output-bytes))
  (define serr (open-output-bytes))
  (define t1 (thread (lambda () (copy-port stdout sout))))
  (define t2 (thread (lambda () (copy-port stderr serr))))
  (subprocess-wait p)
  (sync t1 t2)
  (define code (subprocess-status p))
  (define (bounded sp)
    (define b (get-output-bytes sp))
    (define clipped (if (> (bytes-length b) limit) (subbytes b 0 limit) b))
    (bytes->string/utf-8 clipped #\uFFFD))
  (write-json-frame
   out frame-ack
   (hasheq 'ok #t 'code (if (fixnum? code) code 0)
           'stdout (bounded sout) 'stderr (bounded serr))))

(define (op-put in out msg)
  (define name (safe-name (~a (hash-ref msg 'name "file"))))
  (define size (hash-ref msg 'size 0))
  (define want-sha (hash-ref msg 'sha1 #f))
  (define dest (build-path (ensure-incoming-dir!) name))
  (call-with-output-file dest #:exists 'truncate
    (lambda (fout)
      (let loop ([remaining size])
        (unless (<= remaining 0)
          (define-values (t payload) (read-frame in))
          (when (or (not t) (not (= t frame-data)))
            (error 'op-put "expected a data frame"))
          (write-bytes payload fout)
          (loop (- remaining (bytes-length payload)))))))
  (define actual (file-sha1 dest))
  (if (and (string? want-sha) (not (string=? want-sha actual)))
      (write-json-frame out frame-ack (hasheq 'ok #f 'error "sha1-mismatch"))
      (write-json-frame
       out frame-ack
       (hasheq 'ok #t 'path (path->string dest) 'sha1 actual))))

(define (op-get out msg)
  (define raw (~a (hash-ref msg 'path "")))
  ;; Bare names resolve against the incoming directory — the natural
  ;; counterpart of `put`.
  (define path
    (if (string-contains? raw "/")
        raw
        (path->string (build-path (ensure-incoming-dir!) (safe-name raw)))))
  (cond
    [(not (file-exists? path))
     (write-json-frame out frame-ack (hasheq 'ok #f 'error "not-found"))]
    [(not (file-exists? path)) (void)] ; race guard, do nothing
    [else
     (define name
       (path->string
        (or (file-name-from-path path) (string->path "file"))))
     (write-json-frame
      out frame-meta
      (hasheq 'ok #t 'name name 'size (file-size path) 'sha1 (file-sha1 path)))
     (call-with-input-file path
       (lambda (fin)
         (let loop ()
           (define b (read-bytes 65536 fin))
           (unless (eof-object? b)
             (write-frame out frame-data b)
             (loop)))))]))

;; ---- detachable terminal sessions (断线继承) ----
;;
;; A session owns its shell process, not its TCP connection. When the
;; connection drops the shell keeps running; a later `open-term` carrying the
;; session id reattaches. Sessions die only when the shell exits.

(define sessions (make-hash)) ; session-id -> record
(define session-seq (make-parameter 0))

(define (fresh-session-id)
  (let loop ()
    (define id (~a "s" (current-seconds) "-" (random 10000)))
    (if (hash-ref sessions id #f) (loop) id)))

;; record fields, positional: [id write-input! resize! wait close! out-box closed?]
(define (session-id rec) (vector-ref rec 0))
(define (session-write! rec) (vector-ref rec 1))
(define (session-resize! rec) (vector-ref rec 2))
(define (session-wait rec) (vector-ref rec 3))
(define (session-close! rec) (vector-ref rec 4))
(define (session-out-box rec) (vector-ref rec 5))
(define (session-closed? rec) (vector-ref rec 6))
(define (session-dead? rec) (unbox (session-closed? rec)))

(define (detach-session! rec out)
  (set-box! (session-out-box rec) #f)
  (void))

(define (op-open-term in out msg)
  (define resume-id (hash-ref msg 'resume #f))
  (define existing (and resume-id (hash-ref sessions resume-id #f)))
  (cond
    [(and resume-id (not existing))
     (write-json-frame out frame-ctl (hasheq 'ok #f 'error "no-such-session"))]
    [existing
     ;; Reattach: point the session's output at this connection and drive it.
     (set-box! (session-out-box existing) out)
     (write-json-frame out frame-ctl
                       (hasheq 'ok #t 'backend "resumed" 'session resume-id))
     (session-pump! in out existing)]
    [else
     (define rec (create-session in out msg))
     (session-pump! in out rec)]))

(define (create-session in out msg)
  (define cols (or (hash-ref msg 'cols #f) 80))
  (define rows (or (hash-ref msg 'rows #f) 24))
  (define backend-str (~a (hash-ref msg 'backend "auto")))
  (define requested
    (match backend-str
      ["pipe" 'pipe]
      ["pty" 'pty]
      [_ (if (pty-supported?) 'pty 'pipe)]))
  (define shell
    (or (current-shell)
        (or (getenv "SHELL") "/bin/sh")))
  (define sid (fresh-session-id))
  (define out-box (box out))
  (define closed? (box #f))
  ;; Shell bytes go to whoever is attached; detached = dropped.
  (define (emit b)
    (define o (unbox out-box))
    (when o
      (with-handlers ([exn:fail? void])
        (write-frame o frame-data b))))
  (define-values (write-input! close-input! wait resize!)
    (with-handlers ([exn:fail?
                     (lambda (e)
                       (eprintf "moonbeam-host: pty backend failed (~a); using pipe\n"
                                (exn-message e))
                       (spawn-terminal 'pipe shell (list) cols rows #:on-output emit))])
      (spawn-terminal requested shell (list) cols rows #:on-output emit)))
  (define effective
    (if resize! (if (eq? requested 'pty) 'pty requested) 'pipe))
  ;; Waiter: when the shell dies, retire the session and tell the client
  ;; that is currently attached, if any.
  (thread
   (lambda ()
     (define code (wait))
     (set-box! closed? #t)
     (hash-remove! sessions sid)
     (define o (unbox out-box))
     (when o
       (with-handlers ([exn:fail? void])
         (write-json-frame o frame-exit (hasheq 'code code 'session sid))))))
  (define rec (vector sid write-input! resize! wait close-input! out-box closed?))
  (hash-set! sessions sid rec)
  (write-json-frame out frame-ctl
                    (hasheq 'ok #t 'backend (~a effective) 'session sid))
  rec)

;; Drives one connection for a session. Connection EOF / bye = detach; the
;; shell lives on for the next attach.
(define (session-pump! in out rec)
  (define (detach!) (set-box! (session-out-box rec) #f))
  (let loop ()
    (cond
      [(session-dead? rec) (detach!)]
      [else
       (define-values (t payload) (read-frame in))
       (cond
         [(not t) (detach!)]
         [(= t frame-data)
          ((session-write! rec) payload)
          (loop)]
         [(= t frame-resize)
          (define r! (session-resize! rec))
          (when r!
            (r! (hash-ref payload 'cols 80) (hash-ref payload 'rows 24)))
          (loop)]
         [(= t frame-ctl)
          (if (equal? (hash-ref payload 'op #f) "bye")
              (detach!)
              (loop))]
         [else (loop)])]))
  (detach!))

;; ---- connection handling ----

(define (handle-conn in out token hostname)
  (with-handlers ([exn:fail?
                   (lambda (e)
                     (eprintf "moonbeam-host: ~a\n" (exn-message e))
                     (void))])
    (define first (read-json-frame in frame-ctl))
    (cond
      [(not first) (void)]
      [(equal? (hash-ref first 'op #f) "pair")
       (if (and (string? (hash-ref first 'pin #f))
                (string=? (~a (hash-ref first 'pin)) (host-pin token)))
           (begin
             (write-json-frame
              out frame-ctl (hasheq 'ok #t 'token token 'host hostname))
             (serve-ops in out))
           (write-json-frame out frame-ctl (hasheq 'ok #f 'error "bad-pin")))]
      [(and (equal? (hash-ref first 'op #f) "hello")
            (string? (hash-ref first 'token #f))
            (string=? (hash-ref first 'token) token))
       (write-json-frame out frame-ctl (hasheq 'ok #t 'host hostname))
       (serve-ops in out)]
      [else
       (write-json-frame out frame-ctl (hasheq 'ok #f 'error "auth"))])))

(define (serve-ops in out)
  (let loop ()
    (define msg (read-json-frame in frame-ctl))
    (when msg
      (case (hash-ref msg 'op #f)
        [("exec") (op-exec out msg)]
        [("put") (op-put in out msg)]
        [("get") (op-get out msg)]
        [("open-term") (op-open-term in out msg)]
        [("bye") (void)]
        [else (write-json-frame
               out frame-ack (hasheq 'ok #f 'error "unknown-op"))])
      (unless (equal? (hash-ref msg 'op #f) "open-term")
        (loop)))))

;; ---- daemon ----

;; Starts the daemon. Returns (values listener hostname port).
(define (start-daemon! #:port [port default-port]
                       #:host [host "0.0.0.0"]
                       #:shell [shell #f]
                       #:backend [backend 'auto]
                       #:token-override [token-override #f])
  (define token (or token-override (ensure-host-token)))
  (current-host-token token)
  (current-shell shell)
  (current-backend backend)
  (define-values (listener actual-port)
    (open-listener port (if (equal? host "0.0.0.0") #f host)))
  (define hostname
    (string-trim
     (with-output-to-string (lambda () (system "hostname")))))
  (thread
   (lambda ()
     (let accept ()
       (define-values (in out) (tcp-accept listener))
       (thread
        (lambda ()
          (with-handlers ([exn:fail? void])
            (handle-conn in out token hostname))))
       (accept))))
  (values listener hostname actual-port))

;; Registers this host with a relay so clients can look it up.
(define (register-with-relay! relay-host relay-port host-id advertise)
  (define token (current-host-token))
  (define-values (code resp)
    (http-post-json relay-host relay-port "/register"
                    (hasheq 'id host-id 'addrs (list advertise)) token))
  (values code resp))

;; ---- relay uplink (M1) ----
;;
;; Dials OUT to the relay and parks there as a waiting uplink. When the relay
;; welds a client onto it, the connection turns into a normal client session
;; (handle-conn). Reconnects a second after every session or failure.

(define uplink-pool-size (make-parameter 3))

(define (uplink-loop! relay-host relay-port host-id relay-token host-token)
  (for ([_slot (in-range (uplink-pool-size))])
    (thread
     (lambda ()
       (let loop ()
         (with-handlers ([exn:fail? void])
         ;; Advertise relay reachability for /lookup-based discovery.
         (with-handlers ([exn:fail? void])
           (http-post-json relay-host relay-port "/register"
                           (hasheq 'id host-id
                                   'addrs (list (format "relay:~a:~a"
                                                        relay-host relay-port)))
                           relay-token))
         (define-values (in out) (tcp-connect relay-host relay-port))
         (fprintf out "UP ~a ~a\n" host-id relay-token)
         (flush-output out)
         ;; The relay's first framed message is the tunnel verdict:
         ;; {"op":"go"} splices a client in; {"op":"deny"} means retry.
         (define verdict (read-json-frame in frame-ctl))
         (when (and verdict (equal? (hash-ref verdict 'op #f) "go"))
           (handle-conn in out host-token
                        (format "relay:~a:~a" relay-host relay-port)))
           (close-input-port in)
           (close-output-port out))
         (sleep 1)
         (loop)))))
  (void))

(provide default-port config-dir
         ensure-host-token host-pin
         start-daemon! register-with-relay! uplink-loop!)

(module+ main
  (require racket/cmdline
           racket/list)
  ;; Accept an optional leading "start" for readability.
  (define argv*
    (let ([argv (vector->list (current-command-line-arguments))])
      (if (and (pair? argv) (string=? (car argv) "start"))
          (cdr argv)
          argv)))
  ;; `setup` — desktop-view lane status/install (agent-friendly JSON).
  (when (and (pair? argv*) (string=? (car argv*) "setup"))
    (define install? (member "--install" argv*))
    (define status (desktop-status))
    (printf "~a\n" (jsexpr->string
                    (if install?
                        (hash-set status 'install-command (install-command))
                        status)))
    (exit 0))
  (parameterize ([current-command-line-arguments (list->vector argv*)])
  (define port default-port)
  (define shell #f)
  (define backend-str "auto")
  (define relay #f)
  (define host-id #f)
  (define relay-token-arg (getenv "MOONBEAM_RELAY_TOKEN"))
  (command-line
   #:program "moonbeam-host"
   #:once-each
   [("--port" "-p") p "TCP port to listen on (default 49090)"
    (set! port (string->number p))]
   [("--shell") s "Shell to spawn (default $SHELL or /bin/sh)"
    (set! shell s)]
   [("--backend") b "Terminal backend: auto | pty | pipe (default auto)"
    (set! backend-str b)]
   [("--relay") r "Relay URL host:port to register with (optional)"
    (set! relay r)]
   [("--host-id") h "Host id used at the relay (requires --relay)"
    (set! host-id h)]
   [("--relay-token") rt "Relay shared token (default $MOONBEAM_RELAY_TOKEN)"
    (set! relay-token-arg rt)])
  (current-backend
   (match backend-str ["pipe" 'pipe] ["pty" 'pty] [_ 'auto]))
  (when shell (current-shell shell))
  (define token (ensure-host-token))
  (define-values (_listener _hostname actual-port)
    (start-daemon! #:port port #:shell shell))
  (when (and relay host-id)
    (unless relay-token-arg
      (eprintf "warning: --relay needs --relay-token or MOONBEAM_RELAY_TOKEN\n"))
    (define parts (string-split relay ":"))
    (uplink-loop! (car parts) (string->number (cadr parts))
                  host-id relay-token-arg token))
  (printf "moonbeam-host listening on port ~a\npairing PIN: ~a\n"
          actual-port (host-pin token))
  (flush-output)
  (sync never-evt)))
