#lang racket/base

;; Moonbeam relay server (M0): health, register/lookup signaling, and
;; wake-on-LAN dispatch. Plain HTTP/1.1 over TCP with a shared-token check;
;; put TLS in front at the edge (nginx/Caddy) — the server itself stays
;; dependency-free.

(require json
         racket/cmdline
         racket/format
         racket/match
         racket/port
         racket/string
         racket/system
         racket/tcp
         "netutil.rkt"
         "wol.rkt")

(define relay-token (make-parameter #f))

;; ---- HTTP plumbing ----

(define (read-headers in)
  (let loop ([acc (hash)])
    (define line (read-line in 'any))
    (cond
      [(eof-object? line) acc]
      [(string=? (string-trim line) "") acc]
      [else
       (define idx (string-index-of line #\:))
       (if idx
           (loop (hash-set acc
                           (string-downcase (string-trim (substring line 0 idx)))
                           (string-trim (substring line (+ idx 1) (string-length line)))))
           acc)])))

(define (string-index-of s ch)
  (for/first ([i (in-range (string-length s))]
              #:when (char=? (string-ref s i) ch))
    i))

(define (read-request in)
  (define request-line (read-line in 'any))
  (and (not (eof-object? request-line))
       (let* ([parts (string-split (string-trim request-line) " ")]
              [method (if (pair? parts) (car parts) "")]
              [target (if (>= (length parts) 2) (list-ref parts 1) "")]
              [headers (read-headers in)]
              [len-str (hash-ref headers "content-length" "0")]
              [len (or (string->number len-str) 0)]
              [body
               (if (> len 0)
                   (let ([b (read-bytes len in)])
                     (with-handlers ([exn:fail? (lambda (_) (hasheq))])
                       (string->jsexpr (bytes->string/utf-8 b))))
                   (hasheq))])
         (values method target headers body))))

(define (status-text code)
  (case code
    [(200) "OK"] [(400) "Bad Request"] [(401) "Unauthorized"]
    [(404) "Not Found"] [(405) "Method Not Allowed"]
    [(503) "Service Unavailable"] [else "Error"]))

(define (send-response out code j)
  (define body (jsexpr->string j))
  (fprintf out "HTTP/1.1 ~a ~a\r\n" code (status-text code))
  (fprintf out "Content-Type: application/json\r\n")
  (fprintf out "Content-Length: ~a\r\n" (string-length body))
  (fprintf out "Connection: close\r\n\r\n~a" body)
  (flush-output out)
  (close-output-port out))

;; ---- routing ----

(define valid-id? (lambda (s) (regexp-match? #px"^[a-z0-9][a-z0-9-]{0,63}$" s)))

(define (handle in out registry)
  (define-values (method target headers body) (read-request in))
  (unless (string=? method "")
    (define path (car (string-split (if (string=? target "") "/" target) "?")))
    (define auth-ok
      (and (relay-token)
           (equal? (hash-ref headers "x-moonbeam-token" #f) (relay-token))))
    (cond
      [(and (string=? method "GET") (string=? path "/health"))
       (send-response out 200 (hasheq 'ok #t 'service "moonbeam-relay" 'milestone "m0"))]
      [(not (relay-token))
       (send-response out 503 (hasheq 'ok #f 'error "relay-not-configured"))]
      [(not auth-ok)
       (send-response out 401 (hasheq 'ok #f 'error "unauthorized"))]
      [(and (string=? method "POST") (string=? path "/register"))
       (define id (~a (hash-ref body 'id "")))
       (define addrs (hash-ref body 'addrs (list)))
       (cond
         [(not (valid-id? id))
          (send-response out 400 (hasheq 'ok #f 'error "invalid-id"))]
         [(not (and (list? addrs) (pair? addrs)))
          (send-response out 400 (hasheq 'ok #f 'error "addrs-required"))]
         [else
          (hash-set! registry id (map ~a addrs))
          (send-response out 200 (hasheq 'ok #t))])]
      [(and (string=? method "GET")
            (string-prefix? path "/lookup/"))
       (define id (substring path (string-length "/lookup/")))
       (define addrs (hash-ref registry id #f))
       (if addrs
           (send-response out 200 (hasheq 'ok #t 'id id 'addrs addrs))
           (send-response out 404 (hasheq 'ok #f 'error "not-found")))]
      [(and (string=? method "POST") (string=? path "/wake"))
       (define macs (hash-ref body 'macs (list)))
       (cond
         [(not (and (list? macs) (pair? macs)))
          (send-response out 400 (hasheq 'ok #f 'error "macs-required"))]
         [else
          (define sent
            (for/sum ([m macs])
              (with-handlers ([exn:fail? (lambda (_) 0)])
                (send-wol (~a m))
                1)))
          (send-response out 200 (hasheq 'ok #t 'sent sent))])]
      [else (send-response out 404 (hasheq 'ok #f 'error "not-found"))])))

;; ---- server ----

;; Starts the relay. Returns (values listener port).
(define (serve-relay! #:port [port 8090] #:token [token #f])
  (relay-token token)
  (define-values (listener actual-port) (open-listener port))
  (define registry (make-hash))
  (thread
   (lambda ()
     (let accept ()
       (define-values (in out) (tcp-accept listener))
       (thread
        (lambda ()
          (with-handlers ([exn:fail? (lambda (e)
                                       (eprintf "moonbeam-relay: ~a\n" (exn-message e))
                                       (flush-output (current-error-port))
                                       (with-handlers ([exn:fail? void])
                                         (send-response out 400
                                           (hasheq 'ok #f 'error "bad-request"))))])
            (handle in out registry))))
       (accept))))
  (values listener actual-port))

(module+ main
  (define port 8090)
  (define token (getenv "MOONBEAM_RELAY_TOKEN"))
  (command-line
   #:program "moonbeam-relay"
   #:once-each
   [("--port" "-p") p "HTTP port (default 8090)"
    (set! port (string->number p))]
   [("--token" "-t") t "Shared token (default $MOONBEAM_RELAY_TOKEN)"
    (set! token t)])
  (unless token
    (eprintf "warning: no token configured; authed routes return 503\n"))
  (serve-relay! #:port port #:token token)
  (printf "moonbeam-relay listening on port ~a\n" port)
  (flush-output)
  (sync never-evt))

(provide serve-relay!)
