#lang racket/base

;; Moonbeam relay server (M1): health, register/lookup signaling, wake-on-LAN
;; dispatch, and the TCP splice tunnel that lets a NATed host and a NATed
;; client meet — both dial OUT to the relay, which then welds the two
;; connections into one dumb byte pipe. Plain HTTP/1.1 plus a line-based
;; tunnel handshake on the same port; put TLS in front at the edge.

(require json
         racket/cmdline
         racket/format
         racket/match
         racket/port
         racket/string
         racket/tcp
         "netutil.rkt"
         "proto.rkt"
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

;; Parses the request given its already-read first line.
(define (read-request/from in first-line)
  (and (not (eof-object? first-line))
       (let* ([parts (string-split (string-trim first-line) " ")]
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

(define (handle-http in out first-line registry)
  (define-values (method target headers body) (read-request/from in first-line))
  (unless (string=? method "")
    (define path (car (string-split (if (string=? target "") "/" target) "?")))
    (define auth-ok
      (and (relay-token)
           (equal? (hash-ref headers "x-moonbeam-token" #f) (relay-token))))
    (cond
      [(and (string=? method "GET") (string=? path "/health"))
       (send-response out 200 (hasheq 'ok #t 'service "moonbeam-relay" 'milestone "m1"))]
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

;; ---- tunnel (M1) ----
;;
;; Dumb byte splice between a host uplink and a client. Handshake order
;; matters: the relay writes the framed GO marker into the uplink BEFORE
;; starting the copiers — one socket, sequential writes — so the host reads
;; [go][client frames...] in order and never races the relay for bytes.

(define tunnels (make-hash))   ; host-id -> list of waiting uplink (cons in out)

(define (tunnel-denied out why)
  (fprintf out "~a\n" why)
  (flush-output out)
  (close-output-port out))

(define (handle-tunnel in out first-line)
  (eprintf "relay: tunnel [~a] waiting=~a\n"
           (string-trim first-line)
           (length (hash-ref tunnels
                             (list-ref (string-split (string-trim first-line) " ") 1)
                             (list))))
  (flush-output (current-error-port))
  (define parts (string-split (string-trim first-line) " "))
  (define token-ok (and (relay-token) (>= (length parts) 3)
                        (string=? (list-ref parts 2) (relay-token))))
  (match parts
    ;; Host uplink: park the socket. No reply yet — the host's next read is
    ;; the framed GO marker that arrives when a client shows up.
    [(list "UP" id _token)
     #:when (and token-ok (valid-id? id))
     (cond
       [(>= (length (hash-ref tunnels id (list))) 3)
        (tunnel-denied out "BUSY")]
       [else
        (hash-set! tunnels id (append (hash-ref tunnels id (list))
                                      (list (cons in out))))])]
    ;; Client: weld the waiting uplink to this connection.
    [(list "CLIENT" id _token)
     #:when (and token-ok (valid-id? id))
     (define waiting (hash-ref tunnels id (list)))
     (cond
       [(null? waiting) (tunnel-denied out "NOUP")]
       [else
        ;; Take the OLDEST waiting uplink (FIFO keeps pairing predictable).
        (fprintf out "RDY\n")
        (flush-output out)
        (define up-in (car (car waiting)))
        (define up-out (cdr (car waiting)))
        (hash-set! tunnels id (cdr waiting))
        ;; GO first: the host reads this before any spliced client bytes.
        (write-json-frame up-out frame-ctl (hasheq 'op "go"))
        (flush-output up-out)
        ;; Weld: client -> uplink and uplink -> client.
        (thread
         (lambda ()
           (with-handlers ([exn:fail? void])
             (copy-port in up-out)
             (close-output-port up-out))))
        (thread
         (lambda ()
           (with-handlers ([exn:fail? void])
             (copy-port up-in out)
             (close-input-port up-in)
             (close-output-port out))))])]
    [(list "UP" _id _token) (tunnel-denied out "DENY")]
    [(list "CLIENT" _id _token) (tunnel-denied out "DENY")]
    [_ (tunnel-denied out "DENY")]))

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
          (with-handlers
              ([exn:fail?
                (lambda (e)
                  (eprintf "moonbeam-relay: ~a\n" (exn-message e))
                  (flush-output (current-error-port))
                  (with-handlers ([exn:fail? void])
                    (send-response out 400 (hasheq 'ok #f 'error "bad-request"))))])
            (define first-line (read-line in 'any))
            (cond
              [(eof-object? first-line) (void)]
              [(or (string-prefix? (string-trim first-line) "UP ")
                   (string-prefix? (string-trim first-line) "CLIENT "))
               (handle-tunnel in out (string-trim first-line))]
              [else (handle-http in out first-line registry)]))))
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
