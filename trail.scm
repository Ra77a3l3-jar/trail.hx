(require "helix/editor.scm")
(require "helix/misc.scm")
(require "helix/components.scm")
(require "helix/static.scm")
(require (prefix-in helix. "helix/commands.scm"))

(provide trail-open)

(define *trail-max-recent* 30)

(define *trail-ignore-set*
  (hashset ".git" "node_modules" "target" ".direnv" "__pycache__" ".hg" ".venv" "dist" "build"))

;; steel has no getenv, parse /proc/self/environ
(define (trail-env-var name)
  (with-handler
    (lambda (_) "")
    (let* ([p (open-input-file "/proc/self/environ")]
           [raw (read-port-to-string p)])
      (close-input-port p)
      (let* ([key (string-append name "=")]
             [klen (string-length key)]
             [rlen (string-length raw)])
        (let outer ([i 0])
          (cond
            [(> (+ i klen) rlen) ""]
            [(let inner ([j 0])
               (cond [(= j klen) #true]
                     [(char=? (string-ref raw (+ i j)) (string-ref key j)) (inner (+ j 1))]
                     [else #false]))
             (let* ([start (+ i klen)]
                    [end (let scan ([k start])
                           (if (or (>= k rlen) (char=? (string-ref raw k) (integer->char 0)))
                               k (scan (+ k 1))))])
               (substring raw start end))]
            [else (outer (+ i 1))]))))))

(define *trail-home* (trail-env-var "HOME"))

;; falls back to the XDG data dir if $STEEL_HOME isn't set
(define *trail-steel-home*
  (let ([v (trail-env-var "STEEL_HOME")])
    (if (equal? v "") (string-append *trail-home* "/.local/share/steel") v)))

(define (trail-data-dir) (string-append *trail-steel-home* "/cogs/trail"))
(define (trail-data-file) (string-append (trail-data-dir) "/recent"))

(define (trail-mkdir-p! path)
  (let ([proc (~> (command "mkdir" (list "-p" path))
                  with-stdout-piped
                  with-stderr-piped
                  spawn-process)])
    (when (Ok? proc)
      (read-port-to-string (child-stdout (Ok->value proc))))))

(define (trail-take lst n)
  (if (or (null? lst) (<= n 0)) '() (cons (car lst) (trail-take (cdr lst) (- n 1)))))

(define (trail-drop lst n)
  (if (or (null? lst) (<= n 0)) lst (trail-drop (cdr lst) (- n 1))))

(define (trail-truncate s max-w)
  (if (<= (string-length s) max-w)
      s
      (string-append (substring s 0 (max 0 (- max-w 1))) "…")))

(define *trail-recent* '())

(define (trail-save!)
  (trail-mkdir-p! (trail-data-dir))
  (with-handler
    (lambda (_e) (set-error! "trail: failed to save recent projects"))
    (begin
      ;; clear old file before rewriting
      (with-handler (lambda (_) #false) (delete-file! (trail-data-file)))
      (let ([p (open-output-file (trail-data-file))])
        (for-each (lambda (path) (display (string-append path "\n") p)) *trail-recent*)
        (close-output-port p)))))

(define (trail-load!)
  (define content
    (with-handler
      (lambda (_) "")
      (let* ([p (open-input-file (trail-data-file))]
             [out (read-port-to-string p)])
        (close-input-port p)
        out)))
  (define loaded
    (filter (lambda (s) (> (string-length s) 0))
            (map trim (split-many content "\n"))))
  ;; drop entries whose directory no longer exists, or that are unsafe to
  ;; ever scan like $HOME, and persist the prune
  (define alive (filter (lambda (p) (and (is-dir? p) (not (trail-untrackable? p)))) loaded))
  (set! *trail-recent* alive)
  (when (< (length alive) (length loaded))
    (trail-save!)))

;; canonicalize-path may add a trailing separator
;; breaking equal? comparison against *trail-home* below
(define (trail-strip-trailing-sep p)
  (if (and (> (string-length p) 1) (ends-with? p (path-separator)))
      (trim-end-matches p (path-separator))
      p))

;; directories that should never be recorded as a project
;; if when recursively scanned and no .git is found, they can walk the
;; entire home directory and hang the editor.
(define (trail-untrackable? path)
  (define p (trail-strip-trailing-sep path))
  (or (equal? p *trail-home*) (equal? p "/") (equal? p "")))

(define (trail-track! path)
  (define canonical (trail-strip-trailing-sep (with-handler (lambda (_) path) (canonicalize-path path))))
  (unless (trail-untrackable? canonical)
    ;; remove existing entry and prepend as most recent
    (set! *trail-recent*
          (cons canonical (filter (lambda (p) (not (equal? p canonical))) *trail-recent*)))
    (when (> (length *trail-recent*) *trail-max-recent*)
      (set! *trail-recent* (trail-take *trail-recent* *trail-max-recent*)))
    (trail-save!)))

(define (trail-scan-files root)
  (define root-prefix (string-append root (path-separator)))
  (define acc '())
  (define (walk dir)
    (for-each
     (lambda (p)
       (define name (file-name p))
       (unless (hashset-contains? *trail-ignore-set* name)
         (if (is-dir? p)
             (walk p)
             (set! acc (cons p acc)))))
     (with-handler (lambda (_) '()) (read-dir dir))))
  (walk root)
  (sort (map (lambda (p) (substring p (string-length root-prefix) (string-length p))) acc)
        string<?))

(define *trail-active* #f)
(define *trail-focus* 'projects)

(define *trail-proj-query* "")
(define *trail-proj-filtered* '())
(define *trail-proj-cursor* 0)
(define *trail-proj-window-start* 0)

(define *trail-current-project* #f)
(define *trail-files* '())
(define *trail-file-query* "")
(define *trail-file-filtered* '())
(define *trail-file-cursor* 0)
(define *trail-file-window-start* 0)

(define *trail-visible-height* 10)

(define (trail-refresh-projects!)
  (set! *trail-proj-filtered*
        (if (equal? *trail-proj-query* "")
            *trail-recent*
            (fuzzy-match *trail-proj-query* *trail-recent*))))

(define (trail-refresh-files-for-project! path)
  (set! *trail-current-project* path)
  (set! *trail-files* (if (and path (is-dir? path)) (trail-scan-files path) '()))
  (set! *trail-file-query* "")
  (set! *trail-file-filtered* *trail-files*)
  (set! *trail-file-cursor* 0)
  (set! *trail-file-window-start* 0))

(define (trail-refresh-files-for-highlighted-project!)
  (if (null? *trail-proj-filtered*)
      (trail-refresh-files-for-project! #f)
      (trail-refresh-files-for-project!
       (list-ref *trail-proj-filtered* *trail-proj-cursor*))))

(define (trail-ensure-visible cursor window-start visible-h)
  (cond
    ;; clamp cursor to keep it inside the visible window
    [(< cursor window-start) cursor]
    [(>= cursor (+ window-start visible-h)) (max 0 (- cursor (- visible-h 1)))]
    [else window-start]))

(define (trail-move! delta)
  (cond
    [(equal? *trail-focus* 'projects)
     (define n (length *trail-proj-filtered*))
     (when (> n 0)
       (set! *trail-proj-cursor* (modulo (+ *trail-proj-cursor* delta n) n))
       (set! *trail-proj-window-start*
             (trail-ensure-visible *trail-proj-cursor* *trail-proj-window-start* *trail-visible-height*))
       (trail-refresh-files-for-highlighted-project!))]
    [else
     (define n (length *trail-file-filtered*))
     (when (> n 0)
       (set! *trail-file-cursor* (modulo (+ *trail-file-cursor* delta n) n))
       (set! *trail-file-window-start*
             (trail-ensure-visible *trail-file-cursor* *trail-file-window-start* *trail-visible-height*)))]))

(define (trail-type! ch)
  (cond
    [(equal? *trail-focus* 'projects)
     (set! *trail-proj-query* (string-append *trail-proj-query* (string ch)))
     (trail-refresh-projects!)
     (set! *trail-proj-cursor* 0)
     (set! *trail-proj-window-start* 0)
     (trail-refresh-files-for-highlighted-project!)]
    [else
     (set! *trail-file-query* (string-append *trail-file-query* (string ch)))
     (set! *trail-file-filtered*
           (if (equal? *trail-file-query* "")
               *trail-files*
               (fuzzy-match *trail-file-query* *trail-files*)))
     (set! *trail-file-cursor* 0)
     (set! *trail-file-window-start* 0)]))

(define (trail-backspace!)
  (define (chop s) (if (equal? s "") s (substring s 0 (- (string-length s) 1))))
  (cond
    [(equal? *trail-focus* 'projects)
     (set! *trail-proj-query* (chop *trail-proj-query*))
     (trail-refresh-projects!)
     (set! *trail-proj-cursor* 0)
     (set! *trail-proj-window-start* 0)
     (trail-refresh-files-for-highlighted-project!)]
    [else
     (set! *trail-file-query* (chop *trail-file-query*))
     (set! *trail-file-filtered*
           (if (equal? *trail-file-query* "")
               *trail-files*
               (fuzzy-match *trail-file-query* *trail-files*)))
     (set! *trail-file-cursor* 0)
     (set! *trail-file-window-start* 0)]))

(define (trail-current-file-path)
  (and *trail-current-project*
       (not (null? *trail-file-filtered*))
       (string-append *trail-current-project* (path-separator)
                       (list-ref *trail-file-filtered* *trail-file-cursor*))))

(define (trail-remove-current-project!)
  (when (and *trail-active* (equal? *trail-focus* 'projects) (not (null? *trail-proj-filtered*)))
    (define path (list-ref *trail-proj-filtered* *trail-proj-cursor*))
    (set! *trail-recent* (filter (lambda (p) (not (equal? p path))) *trail-recent*))
    (trail-save!)
    (trail-refresh-projects!)
    (set! *trail-proj-cursor* (min *trail-proj-cursor* (max 0 (- (length *trail-proj-filtered*) 1))))
    (set! *trail-proj-window-start* 0)
    (trail-refresh-files-for-highlighted-project!)
    (set-status! (string-append "trail: removed " (file-name path)))))

(define (trail-activate!)
  (cond
    [(equal? *trail-focus* 'projects)
     (define path *trail-current-project*)
     (when path
       (helix.change-current-directory path)
       (set-status! (string-append "trail: switched to " path)))
     (set! *trail-focus* 'files)
     event-result/consume]
    [else
     (define target (trail-current-file-path))
     (if target
         (begin
           (when *trail-current-project*
             (helix.change-current-directory *trail-current-project*))
           (set! *trail-active* #f)
           (enqueue-thread-local-callback (lambda () (helix.open target)))
           event-result/close)
         event-result/consume)]))

;; size picker as percentage of terminal, centered
(define (trail-box-metrics rect)
  (define tw (area-width rect))
  (define th (area-height rect))
  (define w (max 40 (quotient (* tw 9) 10)))
  (define h (max 10 (quotient (* th 8) 10)))
  (define x (quotient (- tw w) 2))
  (define y (max 0 (quotient (- th h) 3)))
  (define left-w (quotient w 2))
  (define right-x (+ x left-w))
  (define right-w (- w left-w))
  (list x y w h left-w right-x right-w))

(define (trail-draw-pane frame x y w h label query filtered-items total-n cursor window-start visible-h styles)
  (define bg (list-ref styles 0))
  (define border (list-ref styles 1))
  (define text-style (list-ref styles 2))
  (define sel-style (list-ref styles 3))
  (define dim-style (list-ref styles 4))

  (define content-x (+ x 1))
  (define content-w (- w 2))

  (define pane-area (area x y w h))
  (buffer/clear-with frame pane-area bg)
  (block/render frame pane-area (make-block bg border "all" "plain"))

  (define frac (string-append (number->string (length filtered-items)) "/" (number->string total-n)))
  (define counter (if label (string-append label "  " frac) frac))
  (frame-set-string! frame content-x (+ y 1)
                     (trail-truncate query (max 0 (- content-w (string-length counter) 1)))
                     text-style)
  (frame-set-string! frame (max content-x (- (+ x w) 1 (string-length counter))) (+ y 1)
                     counter dim-style)
  (frame-set-string! frame content-x (+ y 2) (make-string content-w #\─) dim-style)

  ;; extract window-sized slice of items to render
  (define visible (trail-take (trail-drop filtered-items window-start) visible-h))
  (let loop ([lst visible] [row 0])
    (unless (or (null? lst) (>= row visible-h))
      (define idx (+ window-start row))
      (define item (car lst))
      (define hl? (= idx cursor))
      (define y-row (+ y 3 row))
      (define marker (if hl? "> " "  "))
      (when hl?
        (frame-set-string! frame content-x y-row (make-string content-w #\space) sel-style))
      (frame-set-string! frame content-x y-row
                         (trail-truncate (string-append marker item) content-w)
                         (if hl? sel-style text-style))
      (loop (cdr lst) (+ row 1))))

  (when (null? filtered-items)
    (frame-set-string! frame content-x (+ y 3) "  (no matches)" dim-style)))

(define (trail-render _state rect frame)
  (define metrics (trail-box-metrics rect))
  (define x (list-ref metrics 0))
  (define y (list-ref metrics 1))
  (define w (list-ref metrics 2))
  (define h (list-ref metrics 3))
  (define left-w (list-ref metrics 4))
  (define right-x (list-ref metrics 5))
  (define right-w (list-ref metrics 6))

  (set! *trail-visible-height* (max 1 (- h 4)))

  (define bg (theme-scope-ref "ui.background"))
  (define border-style (theme-scope-ref "ui.text"))
  (define text-style (theme-scope-ref "ui.text"))
  (define sel-style (theme-scope-ref "ui.menu.selected"))
  (define dim-style (style-with-dim (theme-scope-ref "ui.text")))

  (define styles (list bg border-style text-style sel-style dim-style))

  (define proj-labels (map file-name *trail-proj-filtered*))
  (trail-draw-pane frame x y left-w h
                   #f *trail-proj-query* proj-labels (length *trail-recent*)
                   *trail-proj-cursor* *trail-proj-window-start* *trail-visible-height*
                   styles)

  (trail-draw-pane frame right-x y right-w h
                   (and *trail-current-project* (file-name *trail-current-project*))
                   *trail-file-query* *trail-file-filtered* (length *trail-files*)
                   *trail-file-cursor* *trail-file-window-start* *trail-visible-height*
                   styles))

(define (trail-cursor-fn _state rect)
  (define metrics (trail-box-metrics rect))
  (define x (list-ref metrics 0))
  (define y (list-ref metrics 1))
  (define right-x (list-ref metrics 5))
  ;; position cursor in the focused pane
  (if (equal? *trail-focus* 'projects)
      (position (+ y 1) (+ x 1 (string-length *trail-proj-query*)))
      (position (+ y 1) (+ right-x 1 (string-length *trail-file-query*)))))

(define (trail-handle-event _state event)
  (define ch (key-event-char event))
  (cond
    [(key-event-escape? event)
     (set! *trail-active* #f)
     event-result/close]
    [(key-event-tab? event)
     (set! *trail-focus* (if (equal? *trail-focus* 'projects) 'files 'projects))
     event-result/consume]
    [(or (key-event-down? event) (and (char? ch) (char=? ch #\j)))
     (trail-move! 1)
     event-result/consume]
    [(or (key-event-up? event) (and (char? ch) (char=? ch #\k)))
     (trail-move! -1)
     event-result/consume]
    [(key-event-enter? event) (trail-activate!)]
    [(key-event-backspace? event)
     (trail-backspace!)
     event-result/consume]
    [(and (char? ch) (char=? ch #\x) (equal? (key-event-modifier event) key-modifier-ctrl))
     (trail-remove-current-project!)
     event-result/consume]
    [(char? ch)
     (trail-type! ch)
     event-result/consume]
    [else event-result/consume]))

(struct TrailState ())

(define (trail-make-component)
  (new-component! "trail-popup"
                  (TrailState)
                  trail-render
                  (hash "handle_event" trail-handle-event
                        "cursor" trail-cursor-fn)))

;;@doc
;; Open the recent-projects picker
(define (trail-open)
  (unless *trail-active*
    (set! *trail-active* #t)
    (set! *trail-focus* 'projects)
    (set! *trail-proj-query* "")
    (set! *trail-proj-cursor* 0)
    (set! *trail-proj-window-start* 0)
    (trail-refresh-projects!)
    (trail-refresh-files-for-highlighted-project!)
    (push-component! (trail-make-component))))

(trail-load!)
(trail-track! (helix-find-workspace))
