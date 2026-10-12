#lang racket/base

;; Small TCP listener helper: bind a preferred port, or pick a free one.
;; open-listener returns (values listener actual-port) — Racket exposes no
;; port accessor on a listener, so the chosen port travels with it.

(require racket/tcp)

;; Binds `port` when non-zero (strictly), else picks a free random port.
(define (open-listener [port 0] [host #f] [tries 25])
  (define (try-bind p)
    (with-handlers ([exn:fail? (lambda (_e) (values #f #f))])
      (define l
        (if host
            (tcp-listen p 16 #t host)
            (tcp-listen p 16 #t)))
      (values l p)))
  (if (not (zero? port))
      (let-values ([(l got) (try-bind port)])
        (if l
            (values l got)
            (error 'open-listener "port ~a is taken" port)))
      (let loop ([remaining tries])
        (define p (+ 40000 (random 20000)))
        (define-values (l got) (try-bind p))
        (cond
          [l (values l got)]
          [(<= remaining 1)
           (error 'open-listener "no free port found")]
          [else (loop (sub1 remaining))]))))

;; Binds a specific port and fails loudly if taken. Returns (values l p).
(define (open-listener/strict port [host #f])
  (open-listener port host))

(provide open-listener open-listener/strict)
