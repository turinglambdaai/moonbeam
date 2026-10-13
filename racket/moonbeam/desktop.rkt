#lang racket/base

;; Desktop-view lane (M2): Apollo/Sunshine + Moonlight integration.
;;
;; Moonbeam never reimplements the video pipeline — it detects, installs
;; (opt-in) and launches the upstream tools, and reports honest status.
;; All probe/install paths are injectable so tests run without the real
;; tools installed.

(require json
         racket/file
         racket/format
         racket/match
         racket/path
         racket/string
         racket/system)

;; ---- detection ----

(define (first-existing paths)
  (for/first ([p (in-list paths)] #:when (and p (file-exists? p)))
    p))

;; Apollo first (virtual display), then Sunshine, then anything on PATH.
(define (detect-sunshine)
  (first-existing
   (case (system-type 'os)
     [(macosx)
      (list "/Applications/Apollo.app/Contents/MacOS/sunshine"
            "/Applications/Sunshine.app/Contents/MacOS/sunshine"
            (find-executable-path "sunshine"))]
     [(unix)
      (list "/usr/bin/sunshine"
            "/usr/local/bin/sunshine"
            (find-executable-path "sunshine"))]
     [else (list)])))

(define (detect-moonlight-qt)
  (first-existing
   (case (system-type 'os)
     [(macosx)
      (list "/Applications/Moonlight.app/Contents/MacOS/moonlight-qt"
            (find-executable-path "moonlight-qt"))]
     [(unix)
      (list "/usr/bin/moonlight-qt"
            "/usr/local/bin/moonlight-qt"
            (find-executable-path "moonlight-qt"))]
     [else (list)])))

(define (detect-moonlight-embedded)
  (case (system-type 'os)
    [(macosx) (find-executable-path "moonlight")]
    [(unix) (find-executable-path "moonlight")]
    [else #f]))

;; ---- launch argument builders (pure, tested) ----

;; moonlight-qt <host> <app> streams the app directly.
(define (moonlight-qt-launch-args binary host-addr [app "Desktop"])
  (list binary host-addr app))

;; moonlight-embedded: moonlight stream -app <app> <host>
(define (embedded-launch-args binary host-addr [app "Desktop"])
  (list binary "stream" "-app" app host-addr))

;; Embedded can also drive pairing from the CLI (PIN is shown in the
;; Sunshine/Apollo web UI).
(define (embedded-pair-args binary host-addr)
  (list binary "pair" host-addr))

;; ---- config verification ----

(define (sunshine-config-dir)
  (case (system-type 'os)
    [(macosx)
     (build-path (find-system-path 'home-dir)
                 "Library" "Application Support" "Sunshine")]
    [(unix)
     (build-path (find-system-path 'home-dir) ".config" "sunshine")]
    [else #f]))

;; Verifies the upstream apps config: parses, lists app names, reports
;; whether a Desktop entry is present. Missing file = first run not done.
(define (verify-apps-config config-dir)
  (define apps-json (build-path config-dir "apps.json"))
  (cond
    [(not (file-exists? apps-json))
     (hasheq 'ok #f 'reason "apps.json-not-found" 'path (path->string apps-json))]
    [else
     (with-handlers ([exn:fail? (lambda (e)
                                  (hasheq 'ok #f 'reason "apps-json-unreadable"
                                          'path (path->string apps-json)))])
       (define conf (call-with-input-file apps-json read-json))
       (define apps (hash-ref conf 'apps (list)))
       (define names
         (for/list ([a apps] #:when (hash? a)) (~a (hash-ref a 'name ""))))
       (hasheq 'ok #t
               'path (path->string apps-json)
               'apps names
               'desktop (and (member "Desktop" names) #t)))]))

;; ---- status (deterministic JSON, agent-friendly) ----

(define (desktop-status)
  (define sun (detect-sunshine))
  (define cfg (and sun (sunshine-config-dir)))
  (hasheq 'sunshine (and sun (path->string sun))
          'moonlight-qt (let ([m (detect-moonlight-qt)])
                          (and m (path->string m)))
          'moonlight-embedded (let ([m (detect-moonlight-embedded)])
                                (and m (path->string m)))
          'config (and cfg
                       (if (file-exists? (build-path cfg "apps.json"))
                           (hasheq 'ok #t 'path (path->string cfg))
                           (hasheq 'ok #f
                                   'reason "apps.json-not-found"
                                   'path (path->string cfg))))))

;; ---- install (opt-in) ----

;; Returns the install command for the platform; the caller decides whether
;; to run it. macOS uses the LizardByte homebrew cask (Sunshine). Apollo is
;; a manual download from its GitHub releases.
(define (install-command)
  (case (system-type 'os)
    [(macosx) (list "brew" "install" "--cask" "sunshine")]
    [(unix) (list "sh" "-c"
                  "sudo apt-get install -y sunshine || flatpak install --user flathub dev.lizardbyte.app.Sunshine")]
    [else #f]))

(define (apollo-download-hint)
  "https://github.com/ClassicOldSong/Apollo/releases")

(module+ test
  (require racket/file
           rackunit)
  ;; first-existing
  (check-false (first-existing (list #f "/no/such/path")))
  (define tmp (make-temporary-file "mb-dt~a" 'directory))
  (define fake (make-temporary-file "fakebin~a"))
  (check-equal? (first-existing (list "/no" (path->string fake))) (path->string fake))

  ;; launch arg builders (pure)
  (check-equal? (moonlight-qt-launch-args "mlqt" "192.168.1.10")
                (list "mlqt" "192.168.1.10" "Desktop"))
  (check-equal? (moonlight-qt-launch-args "mlqt" "host6" "Workbench")
                (list "mlqt" "host6" "Workbench"))
  (check-equal? (embedded-launch-args "moonlight" "192.168.1.10")
                (list "moonlight" "stream" "-app" "Desktop" "192.168.1.10"))
  (check-equal? (embedded-pair-args "moonlight" "192.168.1.10")
                (list "moonlight" "pair" "192.168.1.10"))

  ;; apps.json verification
  (define cfg (build-path tmp "cfg"))
  (make-directory* cfg)
  (define not-there (verify-apps-config cfg))
  (check-false (hash-ref not-there 'ok))
  (call-with-output-file (build-path cfg "apps.json")
    (lambda (fout)
      (write-json (hasheq 'apps
                          (list (hasheq 'name "Desktop" 'cmd "false")
                                (hasheq 'name "Steam Big Picture"))) fout))
    #:exists 'truncate)
  (define ok-res (verify-apps-config cfg))
  (check-true (hash-ref ok-res 'ok))
  (check-true (hash-ref ok-res 'desktop))
  (check-true (pair? (member "Steam Big Picture" (hash-ref ok-res 'apps))))
  (call-with-output-file (build-path cfg "apps.json")
    (lambda (fout) (display "not-json" fout)) #:exists 'truncate)
  (check-false (hash-ref (verify-apps-config cfg) 'ok))

  ;; install command exists on unix/mac
  (unless (eq? (system-type 'os) 'windows)
    (check-true (pair? (install-command)))))

(provide detect-sunshine detect-moonlight-qt detect-moonlight-embedded
         moonlight-qt-launch-args embedded-launch-args embedded-pair-args
         sunshine-config-dir verify-apps-config desktop-status
         install-command apollo-download-hint)
