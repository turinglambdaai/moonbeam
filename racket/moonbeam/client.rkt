#lang racket/base

;; Moonbeam client: pairing, exec, terminal and file transfer against a host.
;; Agent-first: `run` returns a deterministic JSON verdict, everything is
;; scriptable from a plain CLI.
;;
;; M1 routing ladder: try the stored LAN address first (short timeout), then
;; fall back to the relay tunnel — the client and the host both dial OUT to
;; the relay, which splices the two connections into one byte pipe.

(require json
         openssl/sha1
         racket/file
         racket/format
         racket/list
         racket/match
         racket/path
         racket/port
         racket/string
         racket/system
         racket/tcp
         "proto.rkt"
         "terminal.rkt")

(define config-dir
  (make-parameter
   (build-path (find-system-path 'home-dir) ".config" "moonbeam")))

(define direct-timeout-ms (make-parameter 1500))

;; ---- token & route store ----
;;
;; hosts.rktd: alist of (id token direct-host direct-port). Legacy M0 files
;; stored (id . token) — such entries keep working with the id as the LAN
;; address.

(define store-path
  (make-parameter
   (build-path (config-dir) "hosts.rktd")))

(define (load-store)
  (define p (store-path))
  (if (file-exists? p)
      (with-handlers ([exn:fail? (lambda (_) (list))])
        (call-with-input-file p read))
      (list)))

(define (save-store! alist)
  (make-directory* (config-dir))
  (write-to-file alist (store-path) #:exists 'truncate)
  (unless (eq? (system-type 'os) 'windows)
    (system* "/bin/chmod" "600" (path->string (store-path)))))

(define (save-entry! id token direct-host direct-port)
  (define rest
    (filter (lambda (e) (not (equal? (car e) id))) (load-store)))
  (save-store! (cons (cons id (list token direct-host direct-port)) rest)))

;; Returns (list token direct-host direct-port) or #f.
(define (lookup-entry id)
  (define e (assoc id (load-store)))
  (cond
    [(not e) #f]
    [(string? (cdr e)) (list (cdr e) (cdr e) 49090)] ; M0 legacy
    [(pair? (cdr e)) (cdr e)]
    [else #f]))

(define (lookup-token id)
  (define e (lookup-entry id))
  (and e (car e)))

;; ---- relay config ----

(define relay-config-path
  (make-parameter
   (build-path (config-dir) "relay.rktd")))

;; Returns (list host port token) or #f.
(define (relay-cfg)
  (define p (relay-config-path))
  (and (file-exists? p)
       (with-handlers ([exn:fail? (lambda (_) #f)])
         (call-with-input-file p read))))

(define (set-relay-config! host port token)
  (make-directory* (config-dir))
  (write-to-file (list host port token) (relay-config-path)
                 #:exists 'truncate)
  (unless (eq? (system-type 'os) 'windows)
    (system* "/bin/chmod" "600" (path->string (relay-config-path)))))

;; ---- low-level connect ----

;; tcp-connect with a timeout; #f when it fails or stalls. On success the
;; attempt custodian is deliberately left un-shutdown — shutting it down
;; would close the live socket ports it created.
(define (tcp-connect/timeout host port ms)
  (define cust (make-custodian))
  (parameterize ([current-custodian cust])
    (define ch (make-channel))
    (thread
     (lambda ()
       (with-handlers ([exn:fail? (lambda (_) (channel-put ch #f))])
         (define-values (in out) (tcp-connect host port))
         (channel-put ch (cons in out)))))
    (define r (sync/timeout (/ ms 1000) ch))
    (if r
        (cons (car r) (cdr r))
        (begin
          (custodian-shutdown-all cust)
          #f))))

;; ---- pairing ----

;; Direct pairing: host-id doubles as the LAN address unless #:direct given.
;; With #:via-relay the pairing handshake goes through the relay tunnel.
(define (pair! host-id #:pin pin
               #:direct [direct-host host-id]
               #:direct-port [direct-port 49090]
               #:via-relay [via-relay #f])
  (define rc (and via-relay (relay-cfg)))
  (when (and via-relay (not rc))
    (error 'pair "no relay configured; run: moonbeam use-relay HOST PORT TOKEN"))
  (define token
    (if via-relay
        (let-values ([(in out)
                      (open-relay-tunnel (car rc) (cadr rc) host-id (caddr rc))])
          (begin0 (pair-over in out pin)
            (close-input-port in)
            (close-output-port out)))
        (let-values ([(in out) (tcp-connect direct-host direct-port)])
          (begin0 (pair-over in out pin)
            (close-input-port in)
            (close-output-port out)))))
  (save-entry! host-id token
               (if via-relay #f direct-host)
               (if via-relay #f direct-port))
  token)

(define (pair-over in out pin)
  (write-json-frame out frame-ctl
                    (hasheq 'op "pair" 'pin (~a pin) 'proto proto-version))
  (define resp (read-json-frame in frame-ctl))
  (cond
    [(and resp (hash-ref resp 'ok #f)) (hash-ref resp 'token)]
    [else
     (error 'pair "pairing failed: ~a"
            (if resp (hash-ref resp 'error "unknown") "no response"))]))

;; ---- connection ladder ----

(define (hello-handshake in out token)
  (write-json-frame out frame-ctl
                    (hasheq 'op "hello" 'token token 'proto proto-version))
  (define resp (read-json-frame in frame-ctl))
  (unless (and resp (hash-ref resp 'ok #f))
    (close-input-port in)
    (close-output-port out)
    (error 'moonbeam "authentication failed"))
  (values in out))

;; Dials the host through the relay: CLIENT line, then the relay welds this
;; connection to the host's waiting uplink.
(define (open-relay-tunnel relay-host relay-port host-id relay-token)
  (define-values (in out) (tcp-connect relay-host relay-port))
  (fprintf out "CLIENT ~a ~a\n" host-id relay-token)
  (flush-output out)
  (define resp (string-trim (~a (read-line in 'any))))
  (unless (string-prefix? resp "RDY")
    (close-input-port in)
    (close-output-port out)
    (error 'moonbeam "relay refused tunnel to ~a: ~a" host-id resp))
  (values in out))

;; Returns (values in out route) where route is 'direct or 'relay.
(define (connect-auth host-id)
  (define entry (lookup-entry host-id))
  (unless entry
    (error 'moonbeam
           "no entry for ~a; run: moonbeam pair ~a --pin <NNNNNN>" host-id host-id))
  (define token (car entry))
  (define direct-host (list-ref entry 1))
  (define direct-port (list-ref entry 2))
  (define rc (relay-cfg))
  ;; Runs thunk under a custodian with a hard deadline: on timeout every
  ;; resource the attempt opened is torn down and #f is returned. Without
  ;; this a stale LAN route (e.g. an answering VPN interface) would hang
  ;; the hello handshake forever.
  (define (attempt ms thunk)
    (define cust (make-custodian))
    (parameterize ([current-custodian cust])
      (define ch (make-channel))
      (thread
       (lambda ()
         (with-handlers ([exn:fail? (lambda (_) (channel-put ch #f))])
           (channel-put ch (call-with-values thunk list)))))
      (define r (sync/timeout (/ ms 1000) ch))
      (if (and r (car r))
          (car r)
          (begin
            (custodian-shutdown-all cust)
            #f))))
  ;; Each rung returns (values in out route) or #f.
  (define (try-direct)
    (if (not direct-host)
        #f
        (attempt (direct-timeout-ms)
                  (lambda ()
                    (define-values (in out) (tcp-connect direct-host direct-port))
                    (define-values (i2 o2) (hello-handshake in out token))
                    (list i2 o2 'direct)))))
  (define (try-relay)
    (if (not rc)
        #f
        (attempt (direct-timeout-ms)
                 (lambda ()
                   (define-values (tin tout)
                     (open-relay-tunnel (car rc) (cadr rc) host-id (caddr rc)))
                   (define-values (in out) (hello-handshake tin tout token))
                   (list in out 'relay)))))
  (define r (or (try-direct) (try-relay)))
  (unless r
    (error 'moonbeam "cannot reach ~a: direct and relay both failed" host-id))
  (apply values r))

;; ---- exec ----

;; Returns the ack jsexpr: {"ok":true,"code":N,"stdout":"...","stderr":"..."}.
(define (run-command host-id argv)
  (define-values (in out route) (connect-auth host-id))
  (dynamic-wind
    (lambda () (void))
    (lambda ()
      (write-json-frame out frame-ctl (hasheq 'op "exec" 'argv argv))
      (read-json-frame in frame-ack))
    (lambda ()
      (close-input-port in)
      (close-output-port out))))

;; ---- terminal ----

;; Opens a terminal session; returns (values in out backend session-id).
(define (open-terminal host-id
                       #:cols [cols 80] #:rows [rows 24]
                       #:backend [backend "auto"]
                       #:resume [resume-id #f])
  (define-values (in out route) (connect-auth host-id))
  (define msg
    (hasheq 'op "open-term" 'cols cols 'rows rows 'backend backend
            'resume resume-id))
  (write-json-frame out frame-ctl msg)
  (define resp (read-json-frame in frame-ctl))
  (unless (and resp (hash-ref resp 'ok #f))
    (close-input-port in)
    (close-output-port out)
    (error 'moonbeam "open-term failed: ~a"
           (if resp (hash-ref resp 'error "unknown") "no response")))
  (values in out (~a (hash-ref resp 'backend "pipe"))
          (and (hash-ref resp 'session #f)
               (~a (hash-ref resp 'session)))))

;; Convenience for agents and tests: open a pipe terminal, run one command,
;; collect the output, and return (values output exit-code).
(define (terminal-command host-id command-str)
  (define out-buf (open-output-bytes))
  (define-values (in out backend sid) (open-terminal host-id #:backend "pipe"))
  ;; Send the command, then exit; collect data frames until the exit frame.
  (write-frame out frame-data
               (string->bytes/utf-8 (string-append command-str "\nexit\n")))
  (define code 0)
  (let loop ()
    (define-values (t payload) (read-frame in))
    (cond
      [(not t) (void)]
      [(= t frame-data)
       (write-bytes payload out-buf)
       (loop)]
      [(= t frame-exit)
       (set! code
             (hash-ref (string->jsexpr (bytes->string/utf-8 payload)) 'code 0))]
      [else (loop)]))
  (close-input-port in)
  (close-output-port out)
  (values (bytes->string/utf-8 (get-output-bytes out-buf) #\uFFFD) code))

;; Interactive passthrough: local stdin -> frames, frames -> local stdout.
(define (terminal-interactive host-id #:resume [resume-id #f])
  (define backend-str (if (pty-supported?) "pty" "pipe"))
  (define-values (in out backend sid)
    (open-terminal host-id #:backend backend-str #:resume resume-id))
  (eprintf "session backend: ~a\n" backend)
  ;; Reader: remote -> stdout.
  (define reader
    (thread
     (lambda ()
       (let loop ()
         (define-values (t payload) (read-frame in))
         (cond
           [(not t) (void)]
           [(= t frame-data) (write-bytes payload) (flush-output) (loop)]
           [(= t frame-exit)
            (eprintf "\n[session ended, code ~a]\n" (hash-ref payload 'code 0))]
           [else (loop)])))))
  ;; Writer: stdin -> remote. EOF on stdin detaches (the shell lives on).
  (let loop ()
    (define b (read-bytes 4096))
    (unless (eof-object? b)
      (write-frame out frame-data b)
      (loop)))
  (write-json-frame out frame-ctl (hasheq 'op "bye"))
  (thread-wait reader)
  (close-input-port in)
  (close-output-port out)
  sid)

;; ---- file transfer ----

;; Sends a local file; returns the ack jsexpr.
(define (put-file host-id local [remote-name #f])
  (define name
    (or remote-name
        (path->string
         (file-name-from-path (simple-form-path local)))))
  (define payload (file->bytes local))
  (define sha (sha1 (open-input-bytes payload)))
  (define-values (in out route) (connect-auth host-id))
  (dynamic-wind
    (lambda () (void))
    (lambda ()
      (write-json-frame out frame-ctl
                        (hasheq 'op "put" 'name name
                                'size (bytes-length payload) 'sha1 sha))
      (let loop ([off 0])
        (when (< off (bytes-length payload))
          (define end (min (+ off 65536) (bytes-length payload)))
          (write-frame out frame-data (subbytes payload off end))
          (loop end)))
      (read-json-frame in frame-ack))
    (lambda ()
      (close-input-port in)
      (close-output-port out))))

;; Fetches a remote file; returns the result jsexpr.
(define (get-file* host-id remote [local #f])
  (define-values (in out route) (connect-auth host-id))
  (dynamic-wind
    (lambda () (void))
    (lambda ()
      (write-json-frame out frame-ctl (hasheq 'op "get" 'path remote))
      (define meta (read-json-frame in frame-meta))
      (cond
        [(and meta (hash-ref meta 'ok #f))
         (define size (hash-ref meta 'size 0))
         (define dest (or local (~a (hash-ref meta 'name "file"))))
         (define buf (open-output-bytes))
         (let loop ([got 0])
           (when (< got size)
             (define-values (t payload) (read-frame in))
             (when (not t) (error 'get "connection closed mid-transfer"))
             (unless (= t frame-data) (error 'get "unexpected frame ~a" t))
             (write-bytes payload buf)
             (loop (+ got (bytes-length payload)))))
         (define b (get-output-bytes buf))
         (define sha (sha1 (open-input-bytes b)))
         (unless (string=? sha (~a (hash-ref meta 'sha1)))
           (error 'get "sha1 mismatch"))
         (call-with-output-file dest
           (lambda (fout) (write-bytes b fout)) #:exists 'truncate)
         (hasheq 'ok #t 'path dest 'size (bytes-length b) 'sha1 sha)]
        [meta meta]
        [else (hasheq 'ok #f 'error "no response")]))
    (lambda ()
      (close-input-port in)
      (close-output-port out))))

(provide pair! run-command open-terminal terminal-command terminal-interactive
         put-file get-file*
         config-dir store-path relay-config-path relay-cfg set-relay-config!
         save-store! lookup-entry)

(module+ main
  (require racket/cmdline
           racket/system)
  (define (usage)
    (eprintf "usage:\n")
    (eprintf "  moonbeam pair HOST [PORT] --pin NNNNNN [--via]\n")
    (eprintf "  moonbeam use-relay HOST PORT TOKEN\n")
    (eprintf "  moonbeam run HOST-ID CMD [ARGS...]\n")
    (eprintf "  moonbeam sh HOST-ID [--command STR] [--resume ID]\n")
    (eprintf "  moonbeam put HOST-ID LOCAL [REMOTE-NAME]\n")
    (eprintf "  moonbeam get HOST-ID REMOTE [LOCAL]\n")
    (exit 2))
  (define args (vector->list (current-command-line-arguments)))
  (when (null? args) (usage))
  (define cmd (car args))
  (define rest (cdr args))
  (define (want-n n)
    (unless (>= (length rest) n) (usage))
    (take rest n))
  (match cmd
    ["pair"
     (define pin-flag (member "--pin" rest))
     (unless (and pin-flag (cdr pin-flag)) (usage))
     (define pin (cadr pin-flag))
     (define via (member "--via" rest))
     (define pin-val (cadr pin-flag))
     (define positional
       (filter (lambda (x)
                 (and (not (equal? x "--pin"))
                      (not (equal? x "--via"))
                      (not (equal? x pin-val))))
               rest))
     (define host-id (if (null? positional) (usage) (car positional)))
     (define port
       (if (>= (length positional) 2) (string->number (cadr positional)) 49090))
     (pair! host-id #:pin pin
            #:direct-port port
            #:via-relay (and via #t))
     (printf "paired with ~a\n" host-id)]
    ["use-relay"
     (define r (want-n 3))
     (set-relay-config! (car r) (string->number (cadr r)) (caddr r))
     (printf "relay set to ~a:~a\n" (car r) (cadr r))]
    ["run"
     (unless (>= (length rest) 2) (usage))
     (define host-id (car rest))
     (define argv (cdr rest))
     (define resp (run-command host-id argv))
     (printf "~a\n" (jsexpr->string resp))
     (exit (if (hash-ref resp 'ok #f) (hash-ref resp 'code 0) 1))]
    ["sh"
     (unless (pair? rest) (usage))
     (define host-id (car rest))
     (define command-flag (member "--command" rest))
     (define resume-flag (member "--resume" rest))
     (cond
       [command-flag
        (define-values (out code)
          (terminal-command host-id (cadr command-flag)))
        (display out)
        (exit code)]
       [else
        (terminal-interactive host-id
                              #:resume (and resume-flag (cadr resume-flag)))])]
    ["put"
     (unless (>= (length rest) 2) (usage))
     (define host-id (car rest))
     (define local (cadr rest))
     (define name (if (>= (length rest) 3) (caddr rest) #f))
     (printf "~a\n" (jsexpr->string (put-file host-id local name)))]
    ["get"
     (unless (>= (length rest) 2) (usage))
     (define host-id (car rest))
     (define remote (cadr rest))
     (define local (if (>= (length rest) 3) (caddr rest) #f))
     (printf "~a\n" (jsexpr->string (get-file* host-id remote local)))]
    [else (usage)]))
