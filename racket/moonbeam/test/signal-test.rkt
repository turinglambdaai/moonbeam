#lang racket/base

;; WebSocket signaling: presence snapshot, host-up on uplink park,
;; host-down on splice end and on a queued uplink vanishing, plus auth
;; — all against the real single-port relay.

(require rackunit
         racket/port
         racket/string
         racket/tcp
         json
         websocket
         "../relay.rkt")

(define TOKEN "sig-token")

(define (recv/timeout conn secs what)
  (define ch (make-channel))
  (define t (thread (λ () (channel-put ch (ws-recv conn)))))
  (or (sync/timeout secs ch)
      (begin (kill-thread t) #f)))

(define (recv-event conn secs what)
  (define m (recv/timeout conn secs what))
  (unless (and (ws-message? m) (not (vector? m)))
    (error 'recv-event "no message for ~a: ~a" what m))
  (read-json (open-input-string (bytes->string/utf-8 (ws-message-payload m)))))

(define (connect-signal port token)
  (ws-connect
   (if token
       (format "ws://127.0.0.1:~a/signal?token=~a" port token)
       (format "ws://127.0.0.1:~a/signal" port))))

;; parks a fake host uplink over raw TCP, exactly like host.rkt does
(define (park-uplink port id token)
  (define-values (in out) (tcp-connect "127.0.0.1" port))
  (display (format "UP ~a ~a\n" id token) out)
  (flush-output out)
  (cons in out))

(module+ test
  ;; unconfigured relay: /signal answers 503 like every authed route
  (define-values (_l0 open-port0) (serve-relay! #:port 0))
  (check-exn exn:fail:websocket?
             (λ () (connect-signal open-port0 TOKEN)))

  ;; configured relay
  (define-values (_l1 port) (serve-relay! #:port 0 #:token TOKEN))

  ;; auth: missing and wrong tokens are rejected at the HTTP layer
  (check-exn exn:fail:websocket? (λ () (connect-signal port #f)))
  (check-exn exn:fail:websocket? (λ () (connect-signal port "nope")))

  ;; subscriber gets the presence snapshot (empty at first)
  (define gui (connect-signal port TOKEN))
  (define snap (recv-event gui 5 "snapshot"))
  (check-equal? (hash-ref snap 'event) "hosts")
  (check-equal? (hash-ref snap 'ids) (list))

  ;; a parked uplink broadcasts host-up
  (define uplink (park-uplink port "host-a" TOKEN))
  (define up (recv-event gui 5 "host-up"))
  (check-equal? (hash-ref up 'event) "host-up")
  (check-equal? (hash-ref up 'id) "host-a")

  ;; a client splice ends -> host-down
  (define-values (cin cout) (tcp-connect "127.0.0.1" port))
  (display (format "CLIENT host-a ~a\n" TOKEN) cout)
  (flush-output cout)
  (define rdy (read-line cin 'any))
  (check-equal? (string-trim rdy) "RDY")
  (close-input-port cin)
  (close-output-port cout)
  (close-input-port (car uplink))
  (close-output-port (cdr uplink))
  (define down (recv-event gui 5 "host-down after splice"))
  (check-equal? (hash-ref down 'event) "host-down")
  (check-equal? (hash-ref down 'id) "host-a")

  ;; a queued uplink that vanishes broadcasts host-down too
  (define uplink2 (park-uplink port "host-b" TOKEN))
  (define up2 (recv-event gui 5 "host-up b"))
  (check-equal? (hash-ref up2 'id) "host-b")
  (close-input-port (car uplink2))
  (close-output-port (cdr uplink2))
  (define down2 (recv-event gui 8 "host-down queued vanish"))
  (check-equal? (hash-ref down2 'event) "host-down")
  (check-equal? (hash-ref down2 'id) "host-b")

  ;; plain HTTP still works on the same port (regression)
  (define-values (hin hout) (tcp-connect "127.0.0.1" port))
  (display "GET /health HTTP/1.1\r\nHost: x\r\n\r\n" hout)
  (flush-output hout)
  (define health (port->string hin))
  (check-true (string-contains? health "200"))
  (check-true (string-contains? health "moonbeam-relay"))
  (close-input-port hin)
  (close-output-port hout)
  (ws-close! gui))
