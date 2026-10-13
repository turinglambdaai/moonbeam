#lang racket/base

;; The pty terminal backend: a real pseudo-terminal via posix_openpt.
;; Loaded on demand (unix/macOS only) so Windows never resolves this FFI.

(require racket/string
         ffi/unsafe
         ffi/unsafe/define
         racket/port)

;; macOS uses a two-level namespace: process-image lookup (#f) fails for
;; libc symbols, so link libSystem explicitly. glibc resolves from #f.
(define libc-lib
  (case (system-type 'os)
    [(macosx) (ffi-lib "libSystem.B.dylib")]
    [else #f]))

(define-ffi-definer define-libc libc-lib)

(define-libc posix_openpt (_fun _int -> _int))
(define-libc grantpt (_fun _int -> _int))
(define-libc unlockpt (_fun _int -> _int))
(define-libc ptsname (_fun _int -> _string/utf-8))
(define-libc c-read (_fun _int _bytes _int -> (n : _int)) #:c-id read)
(define-libc c-write (_fun _int _bytes _int -> (n : _int)) #:c-id write)
(define-libc c-close (_fun _int -> _int) #:c-id close)
(define-cstruct _winsize ([ws-row _ushort]
                          [ws-col _ushort]
                          [ws-x _ushort]
                          [ws-y _ushort]))

(define-libc c-ioctl (_fun _int _uint32 _winsize-pointer -> _int) #:c-id ioctl)

(define TIOCSWINSZ
  (case (system-type 'os)
    [(macosx) #x80087467]
    [(unix) #x5414]
    [else #f]))

;; O_NOCTTY is Darwin 0x20000, Linux 0x100. O_NONBLOCK is applied at
;; posix_openpt time: FFI three-argument fcntl proved unreliable here,
;; while the open-time flag is honored everywhere.
(define O_NOCTTY
  (case (system-type 'os)
    [(macosx) #x20000]
    [else #x100]))
(define O_NONBLOCK
  (case (system-type 'os)
    [(macosx) #x4]
    [else #x800]))

(define (spawn-pty shell-path args cols rows on-output)
  ;; The pump below polls with O_NONBLOCK: a blocking FFI read would freeze
  ;; the single OS thread of the CS runtime and starve every racket thread.
  (define master (posix_openpt (+ 2 O_NOCTTY O_NONBLOCK)))
  (when (< master 0)
    (error 'spawn-pty "posix_openpt failed"))
  (define (fail step)
    (c-close master)
    (error 'spawn-pty "~a failed" step))
  (unless (zero? (grantpt master)) (fail "grantpt"))
  (unless (zero? (unlockpt master)) (fail "unlockpt"))
  (define slave-path (ptsname master))
  (when (or (not slave-path) (string=? slave-path "")) (fail "ptsname"))

  ;; Recent macOS refuses TIOCSWINSZ on the master until the slave side is
  ;; open, so the initial window size is set only after opening the slave.
  ;; open-input-output-file yields two views in Racket 9.x: (input output).
  (define-values (slave-in slave-out)
    (open-input-output-file slave-path #:mode 'binary #:exists 'update))
  (unless (zero? (c-ioctl master TIOCSWINSZ (make-winsize rows cols 0 0)))
    (close-input-port slave-in)
    (close-output-port slave-out)
    (fail "ioctl"))

  ;; subprocess redirects: stdin takes the write view, stdout/stderr the
  ;; read views (Racket 9.3 parameter order: stdin, stdout, stderr).
  (eprintf "pty: slave-in in=?~a out=?~a | slave-out in=?~a out=?~a\n"
           (input-port? slave-in) (output-port? slave-in)
           (input-port? slave-out) (output-port? slave-out))
  (flush-output (current-error-port))
  (eprintf "pty: slave-in=~s slave-out=~s\n" slave-in slave-out)
  (flush-output (current-error-port))
  (define-values (p s-in s-out s-err)
    (with-handlers
        ([exn:fail?
          (lambda (e)
            (eprintf "pty: subprocess FAIL: ~a\n" (exn-message e))
            (flush-output (current-error-port))
            (raise e))])
      (apply subprocess slave-out slave-in slave-out shell-path args)))
  (close-input-port slave-in)
  (close-output-port slave-out)

  ;; Pump master -> on-output (non-blocking, yields to the runtime).
  (thread
   (lambda ()
     (define buf (make-bytes 65536))
     (let loop ()
       (define n (c-read master buf 65536))
       (cond
         [(and (fixnum? n) (> n 0))
          (on-output (subbytes buf 0 n))
          (loop)]
         [(eof-object? n) (void)]
         [else (sleep 0.01) (loop)]))))

  (values (lambda (bstr)
            (let loop ([off 0])
              (define chunk (subbytes bstr off))
              (define n (c-write master chunk (bytes-length chunk)))
              (cond
                [(and (fixnum? n) (> n 0))
                 (define next (+ off n))
                 (unless (= next (bytes-length bstr))
                   (loop next))]
                [else (sleep 0.01) (loop off)])))
          (lambda () (c-close master))
          (lambda ()
            (subprocess-wait p)
            (define st (subprocess-status p))
            (if (fixnum? st) st 0))
          (lambda (cols2 rows2)
            (c-ioctl master TIOCSWINSZ (make-winsize rows2 cols2 0 0)))))

(provide spawn-pty)
