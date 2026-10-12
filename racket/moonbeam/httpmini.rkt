#lang racket/base

;; Tiny HTTP client helpers for talking to the relay server.
;; Deliberately dependency-free: one JSON POST, one JSON GET, nothing else.

(require json
         racket/string
         racket/port
         racket/tcp)

;; Returns (values status-code jsexpr).
(define (http-call method host port path body-jsexpr-or-#f token)
  (define-values (in out) (tcp-connect host port))
  (define body-str (if body-jsexpr-or-#f (jsexpr->string body-jsexpr-or-#f) ""))
  (dynamic-wind
    (lambda () (void))
    (lambda ()
      (fprintf out "~a ~a HTTP/1.1\r\n" method path)
      (fprintf out "Host: ~a:~a\r\n" host port)
      (fprintf out "Content-Type: application/json\r\n")
      (when token (fprintf out "X-Moonbeam-Token: ~a\r\n" token))
      (fprintf out "Content-Length: ~a\r\n" (string-length body-str))
      (fprintf out "Connection: close\r\n\r\n")
      (unless (zero? (string-length body-str))
        (display body-str out))
      (flush-output out)
      (define status-line (read-line in 'any))
      (define code
        (let ([parts (string-split (string-trim (if (eof-object? status-line) "" status-line)) " ")])
          (if (>= (length parts) 2)
              (or (string->number (list-ref parts 1)) 0)
              0)))
      ;; Skip headers.
      (let loop ()
        (define line (read-line in 'any))
        (unless (or (eof-object? line) (string=? (string-trim line) ""))
          (loop)))
      (define body-out (port->string in))
      (values code
              (if (string=? (string-trim body-out) "")
                  (hasheq)
                  (string->jsexpr body-out))))
    (lambda ()
      (close-input-port in)
      (close-output-port out))))

(define (http-post-json host port path body token)
  (http-call "POST" host port path body token))

(define (http-get-json host port path token)
  (http-call "GET" host port path #f token))

(provide http-post-json http-get-json)
