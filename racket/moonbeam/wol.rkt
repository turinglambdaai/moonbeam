#lang racket/base

;; Wake-on-LAN: build and broadcast magic packets.

(require racket/string)

;; Parses "aa:bb:cc:dd:ee:ff", "AA-BB-CC-DD-EE-FF" or "aabbccddeeff" into 6 bytes.
(define (parse-mac s)
  (define hex
    (string-replace
     (string-replace (string-downcase (string-trim s)) ":" "") "-" ""))
  (unless (= 12 (string-length hex))
    (error 'parse-mac "invalid MAC address: ~a" s))
  (define bstr (make-bytes 6))
  (for ([i (in-range 6)])
    (define byte (string->number (substring hex (* 2 i) (+ (* 2 i) 2)) 16))
    (unless byte (error 'parse-mac "invalid hex in MAC address: ~a" s))
    (bytes-set! bstr i byte))
  bstr)

;; 6x 0xFF followed by the target MAC repeated 16 times.
(define (magic-packet mac-bytes)
  (unless (and (bytes? mac-bytes) (= 6 (bytes-length mac-bytes)))
    (error 'magic-packet "expected a 6-byte MAC"))
  (define out (make-bytes 102))
  (for ([i (in-range 6)]) (bytes-set! out i #xFF))
  (for ([i (in-range 16)])
    (bytes-copy! out (+ 6 (* 6 i)) mac-bytes))
  out)

;; Broadcast needs SO_BROADCAST, which Racket's udp module does not set,
;; so the packet goes out through a raw libc UDP socket.

(require ffi/unsafe
         ffi/unsafe/define)

(define-ffi-definer define-libc (case (system-type 'os)
                                  [(macosx) (ffi-lib "libSystem.B.dylib")]
                                  [else #f]))

(define-libc c-socket (_fun _int _int _int -> _int) #:c-id socket)
(define-libc c-setsockopt (_fun _int _int _int _bytes _int -> _int) #:c-id setsockopt)
(define-libc c-sendto (_fun _int _bytes _int _int _pointer _int -> _int) #:c-id sendto)
(define-libc c-inet-addr (_fun _string -> _uint32) #:c-id inet_addr)
(define-libc c-close-fd (_fun _int -> _int) #:c-id close)

(define sol-socket (case (system-type 'os) [(macosx) #xffff] [else 1]))
(define so-broadcast (case (system-type 'os) [(macosx) #x0020] [else 6]))

;; sockaddr_in built by hand: family (native), port (BE), addr (BE), 8 zero.
(define (sockaddr-in addr-u32 port)
  (define b (make-bytes 16 0))
  (bytes-set! b 0 2) ; AF_INET
  (bytes-set! b 2 (arithmetic-shift (bitwise-and port #xFF00) -8))
  (bytes-set! b 3 (bitwise-and port #xFF))
  (bytes-copy! b 4 (integer->integer-bytes addr-u32 4 #f #t))
  b)

(define (send-wol mac
                  #:broadcast [broadcast "255.255.255.255"]
                  #:port [port 9])
  (define packet (magic-packet (if (bytes? mac) mac (parse-mac mac))))
  (define fd (c-socket 2 2 0)) ; AF_INET, SOCK_DGRAM
  (when (< fd 0) (error 'send-wol "socket failed"))
  (dynamic-wind
    (lambda () (void))
    (lambda ()
      (define one (integer->integer-bytes 1 4 #f #f))
      (unless (zero? (c-setsockopt fd sol-socket so-broadcast one 4))
        (error 'send-wol "setsockopt SO_BROADCAST failed"))
      (define sa (sockaddr-in (c-inet-addr broadcast) port))
      (define n (c-sendto fd packet (bytes-length packet) 0 sa 16))
      (unless (= n (bytes-length packet))
        (error 'send-wol "send failed")))
    (lambda ()
      (c-close-fd fd))))

(module+ test
  (require rackunit)
  (check-equal? (parse-mac "00:11:22:33:44:55") (bytes 0 17 34 51 68 85))
  (check-equal? (parse-mac "00-11-22-33-44-55") (bytes 0 17 34 51 68 85))
  (check-equal? (parse-mac "001122334455") (bytes 0 17 34 51 68 85))
  (check-exn exn:fail? (lambda () (parse-mac "nope")))
  (define p (magic-packet (parse-mac "00:11:22:33:44:55")))
  (check-equal? (bytes-length p) 102)
  (check-equal? (subbytes p 0 6) (make-bytes 6 #xFF))
  (check-equal? (subbytes p 6 12) (bytes 0 17 34 51 68 85))
  (check-equal? (subbytes p 96 102) (bytes 0 17 34 51 68 85)))

(provide parse-mac magic-packet send-wol)
