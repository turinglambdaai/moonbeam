#lang racket/base

;; Shared wire protocol for the moonbeam host, client and tooling.
;;
;; Frame format: one type byte + one big-endian uint32 payload length + payload.
;; Control payloads are JSON (jsexpr); data payloads are raw bytes.

(require json)

(define proto-version 1)

(define frame-ctl    #x01) ; JSON control message
(define frame-data   #x02) ; raw bytes: terminal IO / file chunks
(define frame-resize #x03) ; JSON {"cols":N,"rows":N}
(define frame-exit   #x04) ; JSON {"code":N} session ended
(define frame-meta   #x05) ; JSON file metadata before a transfer
(define frame-ack    #x06) ; JSON ack / error reply

(define max-frame-size (arithmetic-shift 1 24)) ; 16 MiB

(define (u32->bytes n)
  (bytes (bitwise-and (arithmetic-shift n -24) #xFF)
         (bitwise-and (arithmetic-shift n -16) #xFF)
         (bitwise-and (arithmetic-shift n -8)  #xFF)
         (bitwise-and n #xFF)))

(define (bytes->u32 bstr [offset 0])
  (+ (arithmetic-shift (bytes-ref bstr offset) 24)
     (arithmetic-shift (bytes-ref bstr (+ offset 1)) 16)
     (arithmetic-shift (bytes-ref bstr (+ offset 2)) 8)
     (bytes-ref bstr (+ offset 3))))

(define (write-frame out type payload)
  (unless (<= (bytes-length payload) max-frame-size)
    (error 'write-frame "payload too large: ~a bytes" (bytes-length payload)))
  (write-byte type out)
  (write-bytes (u32->bytes (bytes-length payload)) out)
  (write-bytes payload out)
  (flush-output out))

;; Returns (values type payload) or (values #f #f) at end of stream.
(define (read-frame in)
  (define b (read-byte in))
  (if (eof-object? b)
      (values #f #f)
      (let* ([len-bstr (read-bytes 4 in)])
        (when (or (eof-object? len-bstr) (< (bytes-length len-bstr) 4))
          (error 'read-frame "truncated frame header"))
        (define len (bytes->u32 len-bstr))
        (when (> len max-frame-size)
          (error 'read-frame "frame too large: ~a bytes" len))
        (values b (read-bytes-exact in len)))))

(define (read-bytes-exact in n)
  (if (zero? n)
      #""
      (let ([bstr (read-bytes n in)])
        (cond
          [(eof-object? bstr) (error 'read-frame "truncated frame payload")]
          [(= (bytes-length bstr) n) bstr]
          [else
           (bytes-append bstr (read-bytes-exact in (- n (bytes-length bstr))))]))))

(define (write-json-frame out type j)
  (write-frame out type (string->bytes/utf-8 (jsexpr->string j))))

;; Reads one frame of the given type and decodes its JSON payload.
;; Returns a jsexpr, or #f at end of stream.
(define (read-json-frame in [type frame-ctl])
  (define-values (t payload) (read-frame in))
  (cond [(not t) #f]
        [(= t type) (string->jsexpr (bytes->string/utf-8 payload))]
        [else (error 'read-json-frame "expected frame type ~a, got ~a" type t)]))

(module+ test
  (require rackunit)
  (check-equal? (bytes->u32 (u32->bytes 0)) 0)
  (check-equal? (bytes->u32 (u32->bytes 4294967295)) 4294967295)
  (check-equal? (bytes->u32 (u32->bytes 123456789)) 123456789)
  ;; Round-trip frames through a pipe.
  (define-values (in out) (make-pipe))
  (write-json-frame out frame-ctl (hasheq 'op "hello" 'proto proto-version))
  (write-frame out frame-data #"raw-bytes")
  (close-output-port out)
  (define j (read-json-frame in frame-ctl))
  (check-equal? (hash-ref j 'op) "hello")
  (check-equal? (hash-ref j 'proto) proto-version)
  (define-values (t payload) (read-frame in))
  (check-equal? t frame-data)
  (check-equal? payload #"raw-bytes")
  (check-false (read-json-frame in)))

(provide proto-version
         frame-ctl frame-data frame-resize frame-exit frame-meta frame-ack
         max-frame-size
         write-frame read-frame
         write-json-frame read-json-frame)
