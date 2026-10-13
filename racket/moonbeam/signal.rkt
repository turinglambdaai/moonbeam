#lang racket/base

;; WebSocket signaling fan-out for the relay: host presence for GUIs.
;;
;; GUI clients subscribe at ws://relay:8090/signal?token=<relay token>
;; (query param, because browsers cannot send custom headers). Right
;; after the handshake they get one snapshot frame
;; {"event":"hosts","ids":[...]} and then live {"event":"host-up" /
;; "host-down","id":...} frames as hosts park and leave the uplink
;; queue. This is the CONTROL plane only — desktop frames keep flowing
;; through the existing byte splice untouched.

(require racket/async-channel
         racket/contract
         racket/string
         racket/tcp
         json
         openssl
         websocket)

(struct signal-hub (subs-box lock))

(struct signal-sub (conn channel thread))

(provide (contract-out
          [signal-hub? (-> any/c boolean?)]
          [make-signal-hub (-> signal-hub?)]
          [signal-hub-broadcast! (-> signal-hub? jsexpr? void?)]
          [handle-ws-signal!
           (-> signal-hub? input-port? output-port? string?
               (hash/c string? string?) (or/c string? #f)
               (-> (listof string?))
               any/c)]))

;; ---- subscribers ------------------------------------------------------------

(define (make-signal-hub)
  (signal-hub (box null) (make-semaphore 1)))

(define (hub-add! h s)
  (call-with-semaphore
   (signal-hub-lock h)
   (λ () (set-box! (signal-hub-subs-box h)
                   (cons s (unbox (signal-hub-subs-box h)))))))

(define (hub-remove! h s)
  (call-with-semaphore
   (signal-hub-lock h)
   (λ () (set-box! (signal-hub-subs-box h)
                   (remq s (unbox (signal-hub-subs-box h)))))))

(define (signal-hub-broadcast! h j)
  (define payload (jsexpr->string j))
  (for ([s (in-list (unbox (signal-hub-subs-box h)))])
    (async-channel-put (signal-sub-channel s) payload)))

;; one writer thread per subscriber; broadcast only does channel puts so
;; a slow GUI can never stall relay threads
(define (writer-loop conn ch cleanup)
  (let loop ()
    (define msg (sync/timeout 30 ch))
    (cond
      [(not msg)
       ;; idle keepalive — nobody reads this side
       (with-handlers ([exn:fail? (λ (_) (cleanup))])
         (ws-ping! conn))
       (loop)]
      [(eq? msg 'stop)
       (with-handlers ([exn:fail? void]) (ws-close! conn))
       (cleanup)]
      [else
       (with-handlers ([exn:fail? (λ (_) (cleanup))])
         (ws-send-text! conn msg))
       (loop)])))

;; ---- handshake ----------------------------------------------------------------

(define (read-remaining-headers in)
  (let loop ([acc (hash)])
    (define line (read-line in 'any))
    (cond
      [(eof-object? line) acc]
      [(string=? (string-trim line) "") acc]
      [else
       (define idx
         (for/first ([i (in-range (string-length line))]
                     #:when (char=? (string-ref line i) #\:))
           i))
       (if idx
           (loop (hash-set acc
                           (string-downcase
                            (string-trim (substring line 0 idx)))
                           (string-trim (substring line (+ idx 1)))))
           acc)])))

(define (query-token target)
  (and target
       (let ([m (regexp-match #rx"[?&]token=([^& ]+)" target)])
         (and m (cadr m)))))

(define (close-ports in out)
  (with-handlers ([exn:fail? void])
    (unless (port-closed? in) (close-input-port in))
    (unless (port-closed? out) (close-output-port out))))

(define (plain-reject! in out code j)
  (with-handlers ([exn:fail? void])
    (define body (jsexpr->string j))
    (fprintf out "HTTP/1.1 ~a ~a\r\nContent-Type: application/json\r\nContent-Length: ~a\r\nConnection: close\r\n\r\n~a"
             code
             (if (= code 401) "Unauthorized" "Service Unavailable")
             (string-length body)
             body)
    (flush-output out))
  (close-ports in out))

;; The relay's first-line dispatcher already consumed the request line;
;; this consumes the remaining headers, checks token + path, completes
;; the upgrade, and parks the subscriber.
(define (handle-ws-signal! h in out first-line headers token hosts-snapshot)
  (with-handlers ([exn:fail? (λ (_) (close-ports in out))])
    (define target
      (let ([parts (string-split (string-trim first-line) " ")])
        (if (>= (length parts) 2) (list-ref parts 1) "/")))
    (define path (car (string-split target "?")))
    (cond
      [(not token)
       (plain-reject! in out 503 (hasheq 'ok #f 'error "relay-not-configured"))]
      [(or (not (string=? path "/signal"))
           (not (equal? (query-token target) token)))
       (plain-reject! in out 401 (hasheq 'ok #f 'error "unauthorized"))]
      [else
       (define key (hash-ref headers "sec-websocket-key" #f))
       (unless key
         (error 'signal "missing Sec-WebSocket-Key"))
       (define conn (ws-adopt in out key))
       (define ch (make-async-channel))
       (define s
         (signal-sub conn ch
                     (thread (λ () (writer-loop conn ch
                                                (λ () (hub-remove! h s)))))))
       (hub-add! h s)
       ;; presence snapshot first, then live events from the tail
       (async-channel-put
        ch (jsexpr->string (hasheq 'event "hosts" 'ids (hosts-snapshot))))])))
