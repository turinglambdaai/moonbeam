#lang racket/base

;; Moonbeam client: pairing, exec, terminal and file transfer against a host.
;; Built agent-first: `run` returns a deterministic JSON verdict, everything
;; is scriptable from a plain CLI.

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
         "proto.rkt"
         "terminal.rkt")

(define config-dir
  (make-parameter
   (build-path (find-system-path 'home-dir) ".config" "moonbeam")))

;; ---- token store ----

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

(define (store-token! host-id token)
  (define rest
    (filter (lambda (e) (not (equal? (car e) host-id))) (load-store)))
  (save-store! (cons (cons host-id token) rest)))

(define (lookup-token host-id)
  (define e (assoc host-id (load-store)))
  (and e (cdr e)))

;; ---- connection ----

(define (pair! host-id host port pin)
  (define-values (in out) (tcp-connect host port))
  (define resp
    (dynamic-wind
      (lambda () (void))
      (lambda ()
        (write-json-frame out frame-ctl
                          (hasheq 'op "pair" 'pin (~a pin) 'proto proto-version))
        (read-json-frame in frame-ctl))
      (lambda ()
        (close-input-port in)
        (close-output-port out))))
  (cond
    [(and resp (hash-ref resp 'ok #f))
     (define token (hash-ref resp 'token))
     (store-token! host-id token)
     token]
    [else
     (error 'pair "pairing failed: ~a"
            (if resp (hash-ref resp 'error "unknown") "no response"))]))

(define (connect-auth host-id host port)
  (define token
    (or (lookup-token host-id)
        (error 'moonbeam "no token for ~a; run: moonbeam pair ~a <port> --pin <NNNNNN>"
               host-id host-id)))
  (define-values (in out) (tcp-connect host port))
  (write-json-frame out frame-ctl
                    (hasheq 'op "hello" 'token token 'proto proto-version))
  (define resp (read-json-frame in frame-ctl))
  (unless (and resp (hash-ref resp 'ok #f))
    (close-input-port in)
    (close-output-port out)
    (error 'moonbeam "authentication failed for ~a" host-id))
  (values in out))

;; ---- exec ----

;; Returns the ack jsexpr: {"ok":true,"code":N,"stdout":"...","stderr":"..."}.
(define (run-command host-id host port argv)
  (define-values (in out) (connect-auth host-id host port))
  (dynamic-wind
    (lambda () (void))
    (lambda ()
      (write-json-frame out frame-ctl (hasheq 'op "exec" 'argv argv))
      (read-json-frame in frame-ack))
    (lambda ()
      (close-input-port in)
      (close-output-port out))))

;; ---- terminal ----

;; Opens a terminal session; returns (values in out backend-string).
(define (open-terminal host-id host port
                       #:cols [cols 80] #:rows [rows 24]
                       #:backend [backend "auto"])
  (define-values (in out) (connect-auth host-id host port))
  (write-json-frame out frame-ctl
                    (hasheq 'op "open-term" 'cols cols 'rows rows 'backend backend))
  (define resp (read-json-frame in frame-ctl))
  (unless (and resp (hash-ref resp 'ok #f))
    (close-input-port in)
    (close-output-port out)
    (error 'moonbeam "open-term failed: ~a"
           (if resp (hash-ref resp 'error "unknown") "no response")))
  (values in out (~a (hash-ref resp 'backend "pipe"))))

;; Convenience for agents and tests: open a pipe terminal, run one command,
;; collect the output, and return (values output exit-code).
(define (terminal-command host-id host port command-str)
  (define out-buf (open-output-bytes))
  (define-values (in out backend) (open-terminal host-id host port #:backend "pipe"))
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
(define (terminal-interactive host-id host port)
  (define backend-str (if (pty-supported?) "pty" "pipe"))
  (define-values (in out backend) (open-terminal host-id host port #:backend backend-str))
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
  ;; Writer: stdin -> remote. EOF on stdin closes the session.
  (let loop ()
    (define b (read-bytes 4096))
    (unless (eof-object? b)
      (write-frame out frame-data b)
      (loop)))
  (write-json-frame out frame-ctl (hasheq 'op "bye"))
  (thread-wait reader)
  (close-input-port in)
  (close-output-port out))

;; ---- file transfer ----

;; Sends a local file; returns the ack jsexpr.
(define (put-file host-id host port local [remote-name #f])
  (define name
    (or remote-name
        (path->string
         (file-name-from-path (simple-form-path local)))))
  (define payload (file->bytes local))
  (define sha (sha1 (open-input-bytes payload)))
  (define-values (in out) (connect-auth host-id host port))
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
(define (get-file* host-id host port remote [local #f])
  (define-values (in out) (connect-auth host-id host port))
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
           (lambda (fout) (write-bytes b fout)) #:exists (quote truncate))
         (hasheq 'ok #t 'path dest 'size (bytes-length b) 'sha1 sha)]
        [meta meta]
        [else (hasheq 'ok #f 'error "no response")]))
    (lambda ()
      (close-input-port in)
      (close-output-port out))))

(provide pair! run-command open-terminal terminal-command terminal-interactive
         put-file get-file*
         config-dir store-path)

(module+ main
  (require racket/cmdline
           racket/list
           racket/system)
  (define (usage)
    (eprintf "usage:\n")
    (eprintf "  moonbeam pair HOST [PORT] --pin NNNNNN\n")
    (eprintf "  moonbeam run HOST CMD [ARGS...]\n")
    (eprintf "  moonbeam sh HOST [--command STR]\n")
    (eprintf "  moonbeam put HOST LOCAL [REMOTE-NAME]\n")
    (eprintf "  moonbeam get HOST REMOTE [LOCAL]\n")
    (exit 2))
  (define args (vector->list (current-command-line-arguments)))
  (when (null? args) (usage))
  (define cmd (car args))
  (define rest (cdr args))
  (define (want-n n)
    (unless (>= (length rest) n) (usage))
    (take rest n))
  (define default-port 49090)
  (match cmd
    ["pair"
     (define pin-flag (member "--pin" rest))
     (unless (and pin-flag (cdr pin-flag)) (usage))
     (define pin (cadr pin-flag))
     (define positional (take rest (- (length rest) (length pin-flag))))
     (define host (if (null? positional) (usage) (car positional)))
     (define port (if (>= (length positional) 2) (string->number (cadr positional)) default-port))
     (pair! host host port pin)
     (printf "paired with ~a\n" host)]
    ["run"
     (unless (>= (length rest) 2) (usage))
     (define host (car rest))
     (define argv (cdr rest))
     (define resp (run-command host host default-port argv))
     (printf "~a\n" (jsexpr->string resp))
     (exit (if (hash-ref resp 'ok #f) (hash-ref resp 'code 0) 1))]
    ["sh"
     (unless (pair? rest) (usage))
     (define host (car rest))
     (define command-flag (member "--command" rest))
     (if command-flag
         (let-values ([(out code) (terminal-command host host default-port (cadr command-flag))])
           (display out)
           (exit code))
         (terminal-interactive host host default-port))]
    ["put"
     (unless (>= (length rest) 2) (usage))
     (define host (car rest))
     (define local (cadr rest))
     (define name (if (>= (length rest) 3) (caddr rest) #f))
     (printf "~a\n" (jsexpr->string (put-file host host default-port local name)))]
    ["get"
     (unless (>= (length rest) 2) (usage))
     (define host (car rest))
     (define remote (cadr rest))
     (define local (if (>= (length rest) 3) (caddr rest) #f))
     (printf "~a\n" (jsexpr->string (get-file* host host default-port remote local)))]
    [else (usage)]))
