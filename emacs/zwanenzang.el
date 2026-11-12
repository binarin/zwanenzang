;;; zwanenzang.el --- Org client for the zwanenzang tracker  -*- lexical-binding: t; -*-

;; Author: Alexey Lebedeff
;; Version: 0.1.0
;; Package-Requires: ((emacs "31.1") (org-ql "0.9"))
;; Keywords: outlines, tools

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Two-way sync between Org subtrees and zwanenzang trackers.  A heading
;; with a ZWANENZANG property naming a tracker location is a scope root;
;; the ticket headings beneath it sync with that tracker through the
;; `zwanenzang' CLI and its JSON contract.
;;
;; Sync happens through explicit interactive commands.  A global Org blocker
;; hook checks manually entered ZWANENZANG_DEPENDS_ON properties inside scopes;
;; it never calls the CLI.  There is no minor mode or timer.
;;
;; The design is in docs/design/03-org-client.md and the CLI contract in
;; docs/cli-json.md of the zwanenzang repository.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'org-element)
(require 'org-fold)
(require 'org-id)
(require 'org-src)
(require 'subr-x)

(defgroup zwanenzang nil
  "Sync Org subtrees with zwanenzang trackers."
  :group 'org
  :prefix "zwanenzang-")

;; The Nix build replaces this default with the store path of the CLI built
;; from the same flake; keep the form on one line so the substitution finds it.
(defcustom zwanenzang-program "zwanenzang"
  "The zwanenzang CLI: an absolute file name, or a name looked up on `exec-path'."
  :type 'string)

(defcustom zwanenzang-org-files 'agenda
  "Org files scanned for scope roots by commands acting on every scope.
The symbol `agenda' means the files of `org-agenda-files'."
  :type '(choice (const :tag "Same as `org-agenda-files'" agenda)
                 (repeat :tag "These files" file)))

(defcustom zwanenzang-redirect-org-notes t
  "Redirect `org-add-note' on tracker tickets to `zwanenzang-comment'.
A prefix argument always bypasses redirection.  State-change logging
is unaffected.  Outside ticket headings in scopes, Org behaves normally."
  :type 'boolean)

(defun zwanenzang--org-files ()
  "The files `zwanenzang-org-files' names, as absolute file names."
  (if (eq zwanenzang-org-files 'agenda)
      (org-agenda-files t)
    (mapcar #'expand-file-name zwanenzang-org-files)))

;;;; Calling the CLI

;; JSON null and false stay distinct from nil, which is the empty object or
;; list: a null cursor and an absent one mean different things to the CLI.
;; The converse does not hold: a parsed empty array or object is nil too,
;; so a parsed value must not be sent back in a request as it stands.

(defun zwanenzang--json-parse ()
  "Parse the JSON value in the current buffer."
  (goto-char (point-min))
  (json-parse-buffer :object-type 'alist :array-type 'list
                     :null-object :null :false-object :false))

(defun zwanenzang--json-encode (value)
  "Encode VALUE, built like the output of `zwanenzang--json-parse', as JSON.
A value that has no JSON form, such as a string holding raw bytes,
signals `user-error'."
  (condition-case err
      (json-serialize value :null-object :null :false-object :false)
    ((wrong-type-argument json-error)
     (user-error "zwanenzang: cannot encode the request as JSON: %s"
                 (error-message-string err)))))

(defun zwanenzang--run (directory args &optional input)
  "Run `zwanenzang-program' on the tracker at or above DIRECTORY with ARGS.
INPUT, when non-nil, is encoded as JSON and given on stdin.  Return a
plist with :exit (the exit status), :parsed (whether stdout is one JSON
value), :json (that value) and :stderr.  This signals only when the
program cannot be run or INPUT cannot be encoded; a failed command is
for `zwanenzang-call' to judge."
  (let* ((default-directory (file-name-as-directory (expand-file-name directory)))
         (stdin (if input (zwanenzang--json-encode input) ""))
         (stderr-file (make-temp-file "zwanenzang-stderr-"))
         (coding-system-for-read 'utf-8)
         (coding-system-for-write 'utf-8))
    (unwind-protect
        (with-temp-buffer
          (let* ((exit (condition-case err
                           (apply #'call-process-region stdin nil zwanenzang-program
                                  nil (list t stderr-file) nil
                                  "-C" (file-local-name default-directory) args)
                         (file-error
                          (user-error "zwanenzang: cannot run %s (%s); see `zwanenzang-program'"
                                      zwanenzang-program (error-message-string err)))))
                 (parsed t)
                 (json (and (> (buffer-size) 0)
                            (condition-case nil (zwanenzang--json-parse)
                              (json-error (setq parsed nil))))))
            (list :exit exit
                  :parsed (and parsed (> (buffer-size) 0))
                  :json json
                  :stderr (with-temp-buffer
                            (insert-file-contents stderr-file)
                            (string-trim (buffer-string))))))
      (delete-file stderr-file))))

(defun zwanenzang--error-object (json)
  "The error object in JSON, a parsed CLI output, or nil."
  (let ((err (and (consp json) (alist-get 'error json))))
    (and (consp err) err)))

(defun zwanenzang--command-name (args)
  "The subcommand in ARGS, skipping global options and their values."
  (let (name)
    (while (and args (not name))
      (let ((a (pop args)))
        (cond ((member a '("-C" "--tracker" "--actor-name")) (pop args))
              ((string-prefix-p "-" a))
              (t (setq name a)))))
    (or name "zwanenzang")))

(defvar zwanenzang--call #'zwanenzang-call
  "Function the commands run the CLI with, called like `zwanenzang-call'.
Not an option: the test suite binds it to a wrapper that checks every
tracker it touches is disposable.")

(define-error 'zwanenzang-stale-doc-base "Stale document base" 'user-error)

(defun zwanenzang-call (directory args &optional input)
  "Run the CLI on the tracker at or above DIRECTORY with ARGS; return its JSON.
INPUT, when non-nil, is encoded as JSON on stdin.  A failed command
signals `user-error' naming the error code and message: a JSON error
object, a usage error (exit status 2), or a non-zero exit with no JSON.
The code `stale-doc-base' is the subtype `zwanenzang-stale-doc-base', which
a caller can retry.
Any other JSON is returned whatever the exit status, because some
commands exit 1 with a full result: `sync' when publication failed,
`lint' when it found issues.  Callers judge those from the JSON."
  (let* ((result (zwanenzang--run directory args input))
         (exit (plist-get result :exit))
         (json (plist-get result :json))
         (err (zwanenzang--error-object json))
         (command (zwanenzang--command-name args)))
    (cond
     (err
      (signal (if (equal (alist-get 'code err) "stale-doc-base")
                  'zwanenzang-stale-doc-base
                'user-error)
              (list (format "zwanenzang: %s: %s"
                            (alist-get 'code err) (alist-get 'message err)))))
     ((eql exit 2)
      (user-error "zwanenzang: usage: %s" (plist-get result :stderr)))
     ((plist-get result :parsed) json)
     ((eql exit 0)
      (user-error "zwanenzang: %s printed no JSON" command))
     (t
      (user-error "zwanenzang: %s exited with %s: %s"
                  command exit (plist-get result :stderr))))))

;;;; Reports

(defconst zwanenzang-report-buffer "*zwanenzang*"
  "Buffer collecting readable reports of publication errors and skips.")

(defun zwanenzang-report (summary &optional details info)
  "Echo SUMMARY and append it with DETAILS and INFO to the `*zwanenzang*' buffer.
Each is a list of strings, one line each.  DETAILS is for outcomes that
are not failures but need a look, such as a sync that could not publish;
the echo points at the report then.  INFO is what happened, kept in the
report without pointing at it, so a clean run is one line in the echo."
  (with-current-buffer (get-buffer-create zwanenzang-report-buffer)
    (unless (derived-mode-p 'special-mode)
      (special-mode))
    (let ((inhibit-read-only t))
      (save-excursion
        (goto-char (point-max))
        (unless (bobp) (insert "\n"))
        (insert (format-time-string "[%F %T] ") summary "\n")
        (dolist (line (append details info))
          (insert "  " line "\n")))))
  (message "%s%s" summary
           (if details (format " (see %s)" zwanenzang-report-buffer) "")))

;;;; Text in Org

;; Tracker prose is Org, written into Org bodies as it stands.  Only what
;; would break the outline or the body's structure gets a leading comma, as
;; Org escapes such lines in blocks: a heading line, and any drawer-like
;; line, whatever follows it, since a human may add a drawer below it later.
;; Reading strips that one comma again, along with the comma of any `#+'
;; line an earlier version of the client escaped, so the two are inverse.

(defconst zwanenzang--heading-line-re "\\`\\*+\\(?:[ \t]\\|\\'\\)"
  "A line Org would read as a heading.")

(defconst zwanenzang--drawer-line-re "\\`[ \t]*:\\(?:\\w\\|[-_]\\)+:[ \t]*\\'"
  "A line Org could read as a drawer boundary.")

(defconst zwanenzang--end-line-re "\\`[ \t]*:end:[ \t]*\\'"
  "A line that closes a drawer; match it ignoring case.")

(defconst zwanenzang--client-drawer-re "\\`[ \t]*:ZWANENZANG_[-_[:alnum:]]*:[ \t]*\\'"
  "The opening line of a drawer the client owns.")

(defconst zwanenzang--escaped-line-re
  (concat "\\`,+\\(?:\\*+\\(?:[ \t]\\|\\'\\)\\|#\\+"
          "\\|[ \t]*:\\(?:\\w\\|[-_]\\)+:[ \t]*\\'\\)")
  "A line whose first comma reading strips.
Writing adds one to such a line too, so it survives the round trip.")

(defun zwanenzang--map-lines (fn text)
  "Apply FN to each line of TEXT and join the results again."
  (mapconcat fn (split-string text "\n") "\n"))

(defun zwanenzang--escape-text (text)
  "TEXT with every line that would break the Org body escaped by a comma."
  (zwanenzang--map-lines
   (lambda (line)
     (if (or (string-match-p zwanenzang--heading-line-re line)
             (string-match-p zwanenzang--drawer-line-re line)
             (string-match-p zwanenzang--escaped-line-re line))
         (concat "," line)
       line))
   text))

(defun zwanenzang--unescape-text (text)
  "TEXT with the comma `zwanenzang--escape-text' added removed."
  (zwanenzang--map-lines
   (lambda (line)
     (if (string-match-p zwanenzang--escaped-line-re line) (substring line 1) line))
   text))

(defun zwanenzang--comment-text (text)
  "TEXT of a comment as Org text for the comments drawer, ending in a newline.
Comments are never read back, so only heading lines and what would close
the drawer are escaped."
  (let ((s (string-trim-right text))
        (case-fold-search t))
    (if (string-empty-p s)
        ""
      (concat (zwanenzang--map-lines
               (lambda (line)
                 (if (or (string-match-p zwanenzang--heading-line-re line)
                         (string-match-p zwanenzang--end-line-re line))
                     (concat "," line)
                   line))
               s)
              "\n"))))

(defun zwanenzang--normalize-text (text)
  "TEXT without leading blank lines or trailing whitespace.
Non-empty text ends in one newline.  Prose is compared and hashed in
this form, so Org's blank lines around a body are not edits."
  (let ((s (string-trim-right
            (replace-regexp-in-string "\\`\\(?:[ \t]*\n\\)+" "" text))))
    (if (string-empty-p s) "" (concat s "\n"))))

(defun zwanenzang--hash (text)
  "A short hash of TEXT, for sync state."
  (substring (secure-hash 'sha256 (encode-coding-string text 'utf-8 t)) 0 16))

(defun zwanenzang--fixed-width (text indent)
  "TEXT as Org fixed-width lines (`: line'), each starting with INDENT.
Nothing in such a line is markup, so any text is safe in a drawer."
  (let ((s (string-trim-right text)))
    (if (string-empty-p s)
        ""
      (concat (zwanenzang--map-lines
               (lambda (line) (concat indent (if (string-empty-p line) ":" (concat ": " line))))
               s)
              "\n"))))

;;;; Entry bodies

;; The body of an entry is everything after its heading line up to the
;; next heading.  Planning lines come first, then drawers (the property
;; drawer among them) and text, which may be interleaved.  The
;; description is the text, without drawers or planning lines.  The
;; client writes its comments and hidden drawers last, after the text.

(defconst zwanenzang--tail-drawers '("ZWANENZANG_COMMENTS" "ZWANENZANG_HIDDEN")
  "Drawers kept at the end of a ticket's body, in this order.")

(defun zwanenzang--drawer-end (lines start)
  "The index in the vector LINES of what closes the drawer opened at START.
Nil when nothing does.  Drawers do not nest, so a drawer-like line with
another one before its :END: is text.  Files written by earlier versions
can hold such lines unescaped in a description, and reading them as a
drawer running on through a human's drawer below would cut the description
short.  Only the drawers known to hold such lines are exempt: the
property drawer (an empty property looks like one), the logbook and the
client's own."
  (let ((case-fold-search t)
        (container (or (string-match-p zwanenzang--client-drawer-re (aref lines start))
                       (string-match-p "\\`[ \t]*:\\(?:PROPERTIES\\|LOGBOOK\\):[ \t]*\\'"
                                       (aref lines start)))))
    (cl-loop for j from (1+ start) below (length lines)
             for line = (aref lines j)
             when (string-match-p zwanenzang--end-line-re line) return j
             when (and (not container) (string-match-p zwanenzang--drawer-line-re line))
             return nil)))

(defun zwanenzang--body-segments (body)
  "Split BODY, the text after a heading line, into a list of segments.
Each is (planning LINE), (drawer TEXT NAME) or (text LINE); every LINE
and TEXT ends in a newline.  A drawer without its :END: line is text."
  (let* ((lines (vconcat (split-string (string-remove-suffix "\n" body) "\n")))
         (n (if (string-empty-p body) 0 (length lines)))
         (i 0) (start t) segments)
    (while (< i n)
      (let ((line (aref lines i)) end)
        (cond
         ((and start (let ((case-fold-search nil))
                       (string-match-p org-planning-line-re line)))
          (push (list 'planning (concat line "\n")) segments)
          (cl-incf i))
         ((and (string-match org-drawer-regexp line)
               (not (string-equal-ignore-case (match-string 1 line) "END"))
               ;; Org ends a drawer at :END: in any case.
               (setq end (zwanenzang--drawer-end lines i)))
          (push (list 'drawer
                      (mapconcat (lambda (l) (concat l "\n"))
                                 (cl-subseq lines i (1+ end)) "")
                      (match-string 1 line))
                segments)
          (setq i (1+ end) start nil))
         (t
          (push (list 'text (concat line "\n")) segments)
          (setq i (1+ i) start nil)))))
    (nreverse segments)))

(defun zwanenzang--segments-text (segments)
  "The raw text segments of SEGMENTS, joined."
  (mapconcat #'cadr (seq-filter (lambda (s) (eq (car s) 'text)) segments) ""))

(defun zwanenzang--body-description (body)
  "The description in BODY: its text, unescaped and normalized."
  (zwanenzang--normalize-text
   (zwanenzang--unescape-text (zwanenzang--segments-text (zwanenzang--body-segments body)))))

(defconst zwanenzang--document-format "org-src-v1"
  "Named-document body codec, independent of the description codec.")

(defconst zwanenzang--document-header
  "#+begin_src org -i :eval never :exports code :noweb no\n"
  "Literal, indentation-preserving source wrapper; never evaluate prose.")

(defun zwanenzang--document-parts ()
  "Return (HOST-BODY . TEXT) for the named document at point.
Without a format property, read the legacy escaped body.  A marked body
must contain exactly one canonical source block and only host drawers or
planning lines outside it.  Fail closed on damaged or unknown wrappers.
Org's parsed source value is already unescaped: never decode it twice."
  (let ((body (zwanenzang--body))
        (format (org-entry-get nil "ZWANENZANG_DOC_FORMAT")))
    (if (not format)
        (cons body (zwanenzang--body-description body))
      (unless (equal format zwanenzang--document-format)
        (user-error "zwanenzang: unknown named-document format %s" format))
      (with-temp-buffer
        (insert body)
        (org-mode)
        (let* ((blocks (org-element-map (org-element-parse-buffer) 'src-block
                                        (lambda (block)
                                          (when (eq (org-element-type (org-element-parent block)) 'section)
                                            block))))
               (block (car blocks))
               (begin (and block (org-element-begin block)))
               (end (and block (org-element-end block)))
               (host (and begin (concat (buffer-substring-no-properties (point-min) begin)
                                        (buffer-substring-no-properties end (point-max))))))
          (unless (and (= (length blocks) 1)
                       (save-excursion
                         (goto-char begin)
                         (looking-at-p (regexp-quote zwanenzang--document-header)))
                       (string-empty-p
                        (string-trim (buffer-substring-no-properties end (point-max))))
                       (string-empty-p
                        (string-trim (zwanenzang--segments-text
                                      (zwanenzang--body-segments host)))))
            (user-error "zwanenzang: malformed named-document source block; repair it before syncing"))
          (cons host (zwanenzang--normalize-text (org-element-property :value block))))))))

(defun zwanenzang--document-text ()
  "The named document at point as normalized decoded prose."
  (cdr (zwanenzang--document-parts)))

(defun zwanenzang--entry-text ()
  "Normalized prose of the ticket or direct named document at point."
  (if (org-entry-get nil "ZWANENZANG_DOC")
      (zwanenzang--document-text)
    (zwanenzang--body-description (zwanenzang--body))))

(defun zwanenzang--compose-document (drawers &optional text)
  "The document body at point with DRAWERS replaced and optional new TEXT.
Keep host drawers separate from the literal source payload."
  (pcase-let ((`(,host . ,local) (zwanenzang--document-parts)))
    (concat (zwanenzang--compose-body host drawers "")
            zwanenzang--document-header
            (org-escape-code-in-string
             (zwanenzang--normalize-text (or text local)))
            "#+end_src\n")))

(defun zwanenzang--write-document (text)
  "Write TEXT in the named document at point, migrating legacy bodies."
  (zwanenzang--write-body (zwanenzang--compose-document nil text))
  (zwanenzang--put "ZWANENZANG_DOC_FORMAT" zwanenzang--document-format))

(defun zwanenzang--check-source-edit ()
  "Refuse a client operation while this host buffer has a source editor.
The editor may contain unsaved prose; syncing or moving its host would
read stale text or invalidate its markers.  Finish or abort it first."
  (let ((host (current-buffer)))
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (when (and (bound-and-true-p org-src-mode)
                   (eq (org-src-source-buffer) host))
          (user-error "zwanenzang: finish or abort the source editor %s first"
                      (buffer-name buffer)))))))

(defun zwanenzang--render-drawer (name content)
  "A drawer NAME holding CONTENT, or nil when CONTENT is nil or empty."
  (and content (not (string-empty-p content))
       (concat ":" name ":\n" content ":END:\n")))

(defun zwanenzang--compose-body (body drawers &optional description)
  "BODY with the client's DRAWERS and, unless nil, a new DESCRIPTION.
DRAWERS maps drawer names to their new content: any drawer of such a
name is dropped, and one with non-empty content is written in its place
in the order below.  The order is planning lines and other drawers as
they stand, then the named drawers other than `zwanenzang--tail-drawers',
then the text, then the tail drawers, wherever they were before.  Without
DESCRIPTION the text is kept exactly as it stands; with it the text is
replaced by DESCRIPTION, escaped."
  (let* ((segments (zwanenzang--body-segments body))
         (named (lambda (s names) (and (eq (car s) 'drawer) (member (nth 2 s) names))))
         (kept (seq-remove (lambda (s)
                             (or (eq (car s) 'text)
                                 (funcall named s zwanenzang--tail-drawers)
                                 (funcall named s (mapcar #'car drawers))))
                           segments)))
    (concat (mapconcat #'cadr kept "")
            (mapconcat (lambda (d)
                         (or (and (not (member (car d) zwanenzang--tail-drawers))
                                  (zwanenzang--render-drawer (car d) (cdr d)))
                             ""))
                       drawers "")
            (if description
                (zwanenzang--escape-text (zwanenzang--normalize-text description))
              (zwanenzang--segments-text segments))
            (mapconcat (lambda (name)
                         (let ((new (assoc name drawers)))
                           (if new
                               (or (zwanenzang--render-drawer name (cdr new)) "")
                             (mapconcat #'cadr
                                        (seq-filter (lambda (s) (funcall named s (list name)))
                                                    segments)
                                        ""))))
                       zwanenzang--tail-drawers ""))))

(defun zwanenzang--body-bounds ()
  "Start and end of the body of the heading at point."
  (save-excursion
    (org-back-to-heading t)
    (let ((end (save-excursion (outline-next-heading) (point))))
      (cons (min end (line-beginning-position 2)) end))))

(defun zwanenzang--body ()
  "The body of the heading at point."
  (pcase-let ((`(,start . ,end) (zwanenzang--body-bounds)))
    (buffer-substring-no-properties start end)))

(defun zwanenzang--drawer-text (element)
  "Return drawer ELEMENT's text, excluding post-blank lines."
  (buffer-substring-no-properties
   (org-element-begin element)
   (save-excursion
     (goto-char (org-element-end element))
     (skip-chars-backward " \t\n\r")
     (line-end-position))))

(defun zwanenzang--drawer-visibility ()
  "Return (NAME TEXT FOLDED) for each drawer in the current entry."
  (save-excursion
    (pcase-let ((`(,start . ,end) (zwanenzang--body-bounds)))
      (goto-char start)
      (let (drawers)
        (while (re-search-forward org-drawer-regexp end t)
          (beginning-of-line)
          (let ((name (match-string-no-properties 1))
                (element (org-element-at-point)))
            (if (memq (org-element-type element) '(drawer property-drawer))
                (let ((finish (org-element-end element)))
                  (push (list name
                              (zwanenzang--drawer-text element)
                              (org-fold-folded-p (line-end-position) 'drawer))
                        drawers)
                  (goto-char finish))
              (forward-line 1))))
        (nreverse drawers)))))

(defun zwanenzang--restore-drawers (before)
  "Restore unchanged drawers from BEFORE; always close property drawers.
New or changed drawers are opened, but unchanged drawers retain their fold."
  (save-excursion
    (pcase-let ((`(,start . ,end) (zwanenzang--body-bounds)))
      (goto-char start)
      (while (re-search-forward org-drawer-regexp end t)
        (beginning-of-line)
        (let* ((name (match-string-no-properties 1))
               (element (org-element-at-point)))
          (if (memq (org-element-type element) '(drawer property-drawer))
              (let* ((finish (org-element-end element))
                     (old (assoc name before))
                     (same (equal (cadr old) (zwanenzang--drawer-text element))))
                (org-fold-hide-drawer-toggle
                 (if (or (equal name "PROPERTIES") (and same (nth 2 old))) t 'off)
                 nil element)
                (goto-char finish))
            (forward-line 1)))))))

(defun zwanenzang--write-body (new)
  "Replace the body with NEW, preserving unchanged drawers' visibility."
  (zwanenzang--check-source-edit)
  (let ((before (zwanenzang--drawer-visibility))
        (outline (save-excursion
                   (org-back-to-heading t)
                   (org-fold-core-get-region-at-point 'outline (line-end-position)))))
    (unless (equal new (zwanenzang--body))
      (save-excursion
        (org-back-to-heading t)
        (end-of-line)
        (when (eobp) (insert "\n"))
        (pcase-let* ((`(,start . ,end) (zwanenzang--body-bounds))
                     (fold-start (and outline (copy-marker (car outline))))
                     (fold-end (and outline (copy-marker (max end (cdr outline)) t)))
                     ;; An entry fold can end on the newline before the next
                     ;; heading.  Anchor outside deletion, retaining that offset.
                     (fold-end-offset (and outline (min 0 (- (cdr outline) end)))))
          (unwind-protect
              (progn
                (goto-char start)
                (delete-region start end)
                (insert new)
                ;; Re-fold the original enclosing extent, not an interior body
                ;; range: splitting an ancestor overlay breaks later reveals.
                (when outline
                  (let ((finish (+ fold-end fold-end-offset)))
                    (if (< fold-start finish)
                        (org-fold-region fold-start finish t 'outline)
                      ;; An empty entry must not hide its child's separator.
                      (org-fold-region fold-start fold-end nil 'outline)))))
            (when fold-start (set-marker fold-start nil))
            (when fold-end (set-marker fold-end nil))))))
    (zwanenzang--restore-drawers before)))

(defun zwanenzang--put (property value)
  "Set PROPERTY of the entry at point to VALUE, or remove it when nil.
Text is unchanged when it already has that value; properties stay folded."
  (unless (equal (org-entry-get nil property) value)
    (if value
        (org-entry-put nil property value)
      (org-entry-delete nil property)))
  (zwanenzang--restore-drawers (zwanenzang--drawer-visibility)))

(defun zwanenzang--ensure-org-id ()
  "Give the ticket at point an Org ID without using the global ID registry.
Keep any existing ID; tracker identity remains ZWANENZANG_ID."
  (unless (org-entry-get nil "ID")
    (zwanenzang--put "ID" (org-id-new))))

;;;; Headings

(defconst zwanenzang-conflict-tag "zz_conflict"
  "Tag on a ticket heading whose last pull could not apply something.
The client sets and clears it; it is never a tracker tag.")

(defun zwanenzang--tracker-tags (tags)
  "TAGS without the conflict tag and Org's archive tag."
  (seq-remove (lambda (tag) (member tag (list zwanenzang-conflict-tag org-archive-tag)))
              tags))

(defun zwanenzang--heading ()
  "Keyword, title and local tags of the heading at point, as a plist."
  (save-excursion
    (org-back-to-heading t)
    (let ((case-fold-search nil))
      (list :keyword (org-get-todo-state)
            :priority (nth 3 (org-heading-components))
            :title (string-trim (substring-no-properties (org-get-heading t t t t)))
            :tags (mapcar #'substring-no-properties (org-get-tags nil t))))))

(defun zwanenzang--set-heading (keyword title tags &rest priority)
  "Give the heading at point KEYWORD, TITLE and TAGS.
An optional PRIORITY value sets the native cookie; nil clears it.
Without that argument the cookie stays.  Level and COMMENT marker stay."
  (save-excursion
    (org-back-to-heading t)
    (let ((case-fold-search nil)
          (old (zwanenzang--heading)))
      (unless (and (equal keyword (plist-get old :keyword))
                   (equal title (plist-get old :title))
                   (equal tags (plist-get old :tags))
                   (or (null priority) (equal (car priority) (plist-get old :priority))))
        (let* ((parts (org-heading-components))
               (priority (if priority (car priority) (nth 3 parts)))
               (headline (or (nth 4 parts) ""))
               ;; The stars stay, and with them markers at the heading.
               (line (concat (and keyword (concat " " keyword))
                             (and priority (format " [#%s]" (org-priority-to-string priority)))
                             (and (string-prefix-p (concat org-comment-string " ") headline)
                                  (concat " " org-comment-string))
                             " " title
                             (and tags (concat " :" (string-join tags ":") ":")))))
          (skip-chars-forward "*")
          (delete-region (point) (line-end-position))
          (insert line)
          (when tags (org-align-tags)))))))

(defun zwanenzang--heading-marker ()
  "A marker at the heading at point that stays there as the buffer changes.
It advances over text inserted at its position, which is the end of the
entry before it, so that entry's body can be rewritten."
  (copy-marker (line-beginning-position) t))

(defun zwanenzang--doc-headings ()
  "Alist of (NAME . MARKER) for the document subheadings at point.
Those are its direct children with a ZWANENZANG_DOC property."
  (save-excursion
    (org-back-to-heading t)
    (let ((level (org-current-level))
          (end (save-excursion (org-end-of-subtree t t) (point)))
          docs)
      (while (and (outline-next-heading) (< (point) end))
        (when (= (org-current-level) (1+ level))
          (let ((name (org-entry-get nil "ZWANENZANG_DOC")))
            (when name (push (cons name (zwanenzang--heading-marker)) docs)))))
      (nreverse docs))))

(defun zwanenzang--insert-heading (pos level title properties)
  "Insert a heading of LEVEL with TITLE and PROPERTIES at POS; return a marker.
POS is the beginning of a line or the end of the buffer.  PROPERTIES is
an alist of property names and values."
  (save-excursion
    (goto-char pos)
    (unless (bolp) (insert "\n"))
    (let ((start (point-marker)))
      (insert (make-string level ?*) " " title "\n:PROPERTIES:\n"
              (mapconcat (lambda (p) (format ":%s: %s\n" (car p) (cdr p))) properties "")
              ":END:\n")
      (goto-char start)
      (zwanenzang--restore-drawers nil)
      (set-marker-insertion-type start t)
      start)))

(defun zwanenzang--relevel (text delta)
  "TEXT, a subtree, with every heading DELTA levels deeper."
  (replace-regexp-in-string
   "^\\(\\*+\\)\\([ \t]\\|$\\)"
   (lambda (m)
     (concat (make-string (max 1 (+ delta (length (match-string 1 m)))) ?*)
             (match-string 2 m)))
   text t t))

(defun zwanenzang--subtree-end (pos)
  "Where the subtree of the heading at POS ends.
That is the next heading after it, or the end of the buffer."
  (save-excursion (goto-char pos) (org-end-of-subtree t t) (point)))

(defun zwanenzang--move-subtree (from to)
  "Move the subtree at FROM to be the last child of the heading at TO."
  (zwanenzang--check-source-edit)
  (let* ((end (zwanenzang--subtree-end from))
         (from-level (save-excursion (goto-char from) (org-current-level)))
         (text (buffer-substring-no-properties from end))
         (drawers (save-excursion
                    (goto-char from)
                    (let (states)
                      (while (< (point) end)
                        (push (list (zwanenzang--drawer-visibility)
                                    (org-fold-folded-p (line-beginning-position) 'outline)
                                    (org-fold-folded-p (line-end-position) 'outline))
                              states)
                        (outline-next-heading))
                      (nreverse states)))))
    (unless (string-suffix-p "\n" text) (setq text (concat text "\n")))
    (delete-region from end)
    (save-excursion
      (goto-char to)
      (let ((delta (- (1+ (org-current-level)) from-level))
            (destination-hidden (org-fold-folded-p (line-end-position) 'outline)))
        (goto-char (zwanenzang--subtree-end to))
        (unless (bolp) (insert "\n"))
        (let ((start (point)))
          (insert (zwanenzang--relevel text delta))
          (when destination-hidden
            (org-fold-region start (point) t 'outline))
          (goto-char start)
          (dolist (state drawers)
            (zwanenzang--restore-drawers (car state))
            (when (nth 1 state)
              (org-fold-region (line-beginning-position) (line-end-position) t 'outline))
            (when (nth 2 state)
              (org-fold-region (line-end-position) (cdr (zwanenzang--body-bounds))
                               t 'outline))
            (outline-next-heading)))))))

(defmacro zwanenzang--one-undo-step (&rest body)
  "Run BODY so that its buffer changes undo as one step.
If BODY exits non-locally, every change it made is undone."
  (declare (indent 0) (debug t))
  (let ((handle (make-symbol "handle"))
        (done (make-symbol "done")))
    `(let ((,handle (prepare-change-group))
           (undo-outer-limit nil)
           (,done nil))
       (unwind-protect
           (progn
             (activate-change-group ,handle)
             (prog1 (progn ,@body) (setq ,done t)))
         (if ,done
             (progn (undo-amalgamate-change-group ,handle)
                    (accept-change-group ,handle))
           (cancel-change-group ,handle))))))

;;;; Scopes

(defun zwanenzang--scope-root ()
  "A marker at the scope root containing point.
That is the nearest heading at or above point with a ZWANENZANG property."
  (when (bound-and-true-p org-src-mode)
    (user-error "zwanenzang: source editors are prose, not tracker scopes"))
  (zwanenzang--check-source-edit)
  (org-with-wide-buffer
   (when (org-before-first-heading-p)
     (user-error "zwanenzang: point is not inside a scope"))
   (org-back-to-heading t)
   (let (root)
     (while (and (not (setq root (and (org-entry-get nil "ZWANENZANG")
                                      (zwanenzang--heading-marker))))
                 (org-up-heading-safe)))
     (or root
         (user-error "zwanenzang: point is not inside a scope (%s)"
                     "no heading above it has a ZWANENZANG property")))))

(defun zwanenzang--scope-directory (root)
  "The tracker directory the scope root at ROOT names."
  (let* ((location (org-entry-get root "ZWANENZANG"))
         (dir (expand-file-name location (if buffer-file-name
                                             (file-name-directory buffer-file-name)
                                           default-directory))))
    (when (file-remote-p dir)
      (user-error "zwanenzang: remote scope locations are not supported yet: %s" location))
    (unless (file-directory-p dir)
      (user-error "zwanenzang: scope location is not a directory: %s" location))
    dir))

(defun zwanenzang--scan-all (root)
  "The headings the scope at ROOT syncs, in buffer order, and its inbox.
Return a plist with :headings and :inbox.  Each heading is a plist with
:marker, then :id for a ticket heading, or nil for a new ticket: a heading
with a TODO keyword and no identity, which is not the inbox or a document.
:nest is the id of the nearest ticket heading above it in the scope, or
nil; :up is the same but also counts a new ticket above it, as its marker.
Other headings are the human's structure, and are transparent.  INBOX is
a marker at the root's child with ZWANENZANG_INBOX: t, or nil.  The subtree
of a scope root nested inside is another scope and is skipped."
  (save-excursion
    (goto-char root)
    (let ((root-level (org-current-level))
          (end (zwanenzang--subtree-end root))
          stack headings inbox)
      (outline-next-heading)
      (while (< (point) end)
        ;; Validate before collecting ANY creates, including under blocked
        ;; owners.  A damaged source fence must never expose fake tickets.
        (when (org-entry-get nil "ZWANENZANG_DOC_FORMAT")
          (zwanenzang--document-text))
        (let ((level (org-current-level)))
          (if (org-entry-get nil "ZWANENZANG")
              (org-end-of-subtree t t)
            (while (and stack (>= (car (car stack)) level)) (pop stack))
            (let* ((id (org-entry-get nil "ZWANENZANG_ID"))
                   (is-inbox (equal (org-entry-get nil "ZWANENZANG_INBOX") "t"))
                   (new (and (not id) (not is-inbox)
                             (not (org-entry-get nil "ZWANENZANG_DOC"))
                             (org-get-todo-state)))
                   (marker (and (or id new) (zwanenzang--heading-marker))))
              (when (and (not inbox) is-inbox (= level (1+ root-level)))
                (setq inbox (zwanenzang--heading-marker)))
              (when marker
                (push (list :id id :marker marker
                            :nest (nth 1 (seq-find #'cadr stack))
                            :up (nth 2 (seq-find #'caddr stack)))
                      headings))
              (push (list level id (or id marker)) stack))
            (outline-next-heading))))
      (list :headings (nreverse headings) :inbox inbox))))

(defun zwanenzang--scan (root)
  "The ticket headings in the scope at ROOT and its inbox, as (TICKETS . INBOX).
See `zwanenzang--scan-all'."
  (let ((scan (zwanenzang--scan-all root)))
    (cons (seq-filter (lambda (h) (plist-get h :id)) (plist-get scan :headings))
          (plist-get scan :inbox))))

(defun zwanenzang--ensure-inbox (root)
  "A marker at the inbox of the scope at ROOT, creating it if needed."
  (or (cdr (zwanenzang--scan root))
      (zwanenzang--insert-heading (zwanenzang--subtree-end root)
                                  (1+ (save-excursion (goto-char root) (org-current-level)))
                                  "Inbox" '(("ZWANENZANG_INBOX" . "t")))))

;;;; Keyword map

(defun zwanenzang--keyword-map (spec statuses keywords)
  "Parse the keyword map SPEC against the tracker STATUSES and Org KEYWORDS.
SPEC is the ZWANENZANG_KEYWORDS value or nil.  Return (MAP . PROBLEMS):
MAP is an alist from status to the keyword it is shown with, PROBLEMS
a list of readable lines.  An entry naming a keyword Org does not know
in this buffer, or a status outside the vocabulary, is left out."
  (let (map problems)
    (if (null spec)
        (dolist (kw keywords)
          (let ((status (seq-find (lambda (s) (string-equal-ignore-case s kw)) statuses)))
            (when (and status (not (assoc status map)))
              (push (cons status kw) map))))
      (dolist (entry (split-string spec))
        (if (not (string-match "\\`\\([^=]+\\)=\\(.+\\)\\'" entry))
            (push (format "keyword map: malformed entry %s" entry) problems)
          (let ((kw (match-string 1 entry))
                (listed (split-string (match-string 2 entry) "," t)))
            (if (not (member kw keywords))
                (push (format "keyword map: %s is not a TODO keyword in this buffer" kw) problems)
              (dolist (status listed)
                (cond
                 ((not (member status statuses))
                  (push (format "keyword map: %s is not a tracker status" status) problems))
                 ((assoc status map)
                  (push (format "keyword map: status %s has two keywords, %s and %s"
                                status (cdr (assoc status map)) kw)
                        problems))
                 (t (push (cons status kw) map)))))))))
    (dolist (status statuses)
      (unless (assoc status map)
        (push (format "keyword map: status %s has no keyword" status) problems)))
    (cons (nreverse map) (nreverse problems))))

;;;; Dependencies

(defun zwanenzang--dependency-refs ()
  "The entry's prerequisite numbers, normalized as a set."
  (sort (delete-dups (split-string (upcase (or (org-entry-get nil "ZWANENZANG_DEPENDS_ON") ""))))
        #'string<))

(defun zwanenzang--dependency-displays (ticket known)
  "Resolve TICKET's dependency identities through KNOWN to published numbers.
An unpublished prerequisite cannot be represented in the manual property."
  (sort (mapcar (lambda (id)
                  (let ((target (and known (gethash id known))))
                    (unless (integerp (alist-get 'number target))
                      (user-error "prerequisite %s has no published ticket number" id))
                    (alist-get 'display target)))
                (alist-get 'depends_on ticket))
        #'string<))

(defvar-local zwanenzang--dependency-snapshots nil
  "In-memory tracker snapshots for dependency checks in this buffer.
Each plist holds a scope :root marker, :location, :tracker identity,
:tickets (all summaries), :statuses and refresh :time.  Nothing is persisted.")

(defun zwanenzang--dependency-snapshot (root)
  "The usable dependency snapshot for ROOT, or nil after a scope change."
  (seq-find
   (lambda (snapshot)
     (let ((marker (plist-get snapshot :root)))
       (and (eq (marker-buffer marker) (current-buffer))
            (= marker root)
            (equal (plist-get snapshot :location) (org-entry-get root "ZWANENZANG"))
            (equal (plist-get snapshot :tracker) (org-entry-get root "ZWANENZANG_TRACKER")))))
   zwanenzang--dependency-snapshots))

(defun zwanenzang--dependency-reasons (root refs)
  "Explain why prerequisite ticket REFS in ROOT are not known to be done.
REFS are human-facing numbers such as ZZ-0042, not internal ULIDs.
Local Org keywords take precedence over snapshot statuses.  Missing,
duplicate, tombstoned and unmapped prerequisites are not satisfied."
  (let* ((snapshot (zwanenzang--dependency-snapshot root))
         (known (plist-get snapshot :tickets))
         (map (car (zwanenzang--keyword-map
                    (org-entry-get root "ZWANENZANG_KEYWORDS")
                    (plist-get snapshot :statuses) org-todo-keywords-1)))
         (local (make-hash-table :test #'equal))
         (local-numbers (make-hash-table :test #'equal))
         (summaries (make-hash-table :test #'equal))
         (headings (car (zwanenzang--scan root)))
         reasons)
    (when known
      (maphash (lambda (_id summary)
                 (puthash (alist-get 'display summary) summary summaries))
               known))
    (dolist (heading headings)
      (push (plist-get heading :marker) (gethash (plist-get heading :id) local)))
    (dolist (heading headings)
      (let ((number (org-entry-get (plist-get heading :marker) "ZWANENZANG_NUMBER")))
        (when number
          (puthash number (seq-union (gethash number local-numbers)
                                    (gethash (plist-get heading :id) local) #'eq)
                   local-numbers))))
    (dolist (ref (delete-dups refs))
      (let* ((number-p (string-match-p "\\`[^ \t\n]+-[0-9]+\\'" ref))
             (summary (and number-p (gethash ref summaries)))
             ;; Resolve through the snapshot's canonical number when possible,
             ;; then match Org by stable identity, even if its number is stale.
             (headings (and number-p
                            (if summary (gethash (alist-get 'id summary) local)
                              (gethash ref local-numbers))))
             (keyword (and (= (length headings) 1)
                           (save-excursion
                             (goto-char (car headings))
                             (org-get-todo-state))))
             (status (alist-get 'status summary))
             (label (if headings
                        (save-excursion
                          (goto-char (car headings))
                          (format "%s %s" ref (org-get-heading t t t t)))
                      (if summary (zwanenzang--label summary) ref)))
             (reason
              (cond
               ((not number-p) "expected a ticket ID such as ZZ-0042")
               ((> (length headings) 1) "duplicate headings")
               ((and snapshot (not summary)) "unknown ticket in this tracker")
               ((eq (alist-get 'tombstoned summary) t) "tombstoned")
               (headings
                (cond ((member keyword org-done-keywords) nil)
                      (keyword (format "unfinished (%s, local Org)" keyword))
                      (t "unknown local TODO state")))
               ((not snapshot) "unknown; sync this scope first")
               ((not (cdr (assoc status map))) (format "unmapped status %s" status))
               ((member (cdr (assoc status map)) org-done-keywords) nil)
               (t (format "unfinished (%s)" status)))))
        (when reason (push (format "%s: %s" label reason) reasons))))
    (nreverse reasons)))

(defun zwanenzang--block-dependencies (change)
  "Block local completion in CHANGE when explicit prerequisites are unfinished.
Only headings with inherited ZWANENZANG and their own DEPENDS_ON property
participate.  Org's ordinary force-TODO and NOBLOCKING overrides apply.
Pull rewrites headings directly and therefore never runs this hook."
  (if (or (not (eq (plist-get change :type) 'todo-state-change))
          (member (plist-get change :from) org-done-keywords)
          (not (member (plist-get change :to) org-done-keywords)))
      t
    (org-with-point-at (plist-get change :position)
      (org-with-wide-buffer
       (let ((ids (and (derived-mode-p 'org-mode)
                       (not (org-before-first-heading-p))
                       (org-entry-get nil "ZWANENZANG" t)
                       (split-string (or (org-entry-get nil "ZWANENZANG_DEPENDS_ON") "")))))
         (if (not ids) t
           (let* ((root (zwanenzang--scope-root))
                  (reasons (zwanenzang--dependency-reasons root ids))
                  (snapshot (zwanenzang--dependency-snapshot root)))
             (if (not reasons) t
               (setq org-block-entry-blocking
                     (format "%s [%s; C-u C-u C-u C-c C-t overrides]"
                             (string-join reasons "; ")
                             (if snapshot
                                 (format "snapshot %s old"
                                         (format-seconds "%h h %m min %s s"
                                                         (max 0 (- (float-time)
                                                                   (plist-get snapshot :time)))))
                               "no tracker snapshot")))
               nil))))))))

;;;; Sync state

;; ZWANENZANG_SYNC holds the fields as last synced: the tracker status,
;; hashes of title and tags, the tracker parent and the nesting the
;; heading had then (they differ when the parent has no heading in scope).
;; "-" is none; a missing key is unknown.

(defconst zwanenzang--sync-keys '(status title priority tags depends parent nest))

(defun zwanenzang--parse-sync (value)
  "Parse a ZWANENZANG_SYNC VALUE into an alist; \"-\" becomes nil."
  (let (alist)
    (dolist (pair (and value (split-string value)))
      (when (string-match "\\`\\([a-z]+\\)=\\(.*\\)\\'" pair)
        (let ((v (match-string 2 pair)))
          (push (cons (intern (match-string 1 pair)) (unless (equal v "-") v)) alist))))
    (nreverse alist)))

(defun zwanenzang--format-sync (alist)
  "Format ALIST, as `zwanenzang--parse-sync' returns it, as a property value."
  (string-join
   (delq nil (mapcar (lambda (key)
                       (let ((cell (assq key alist)))
                         (and cell (format "%s=%s" key (or (cdr cell) "-")))))
                     zwanenzang--sync-keys))
   " "))

(defun zwanenzang--sync-get (alist key)
  "KEY's value in the sync ALIST, or `:unknown' when it was never recorded."
  (let ((cell (assq key alist)))
    (if cell (cdr cell) :unknown)))

(defun zwanenzang--merge (local base remote)
  "Reconcile one field: LOCAL in Org, BASE as last synced, REMOTE in the tracker.
BASE is `:unknown' when nothing was recorded.  Return `same' when Org
already shows REMOTE, `apply' when only the tracker changed, `keep' when
only Org changed and `conflict' when both did, or BASE is unknown."
  (cond ((equal local remote) 'same)
        ((eq base :unknown) 'conflict)
        ((equal local base) 'apply)
        ((equal remote base) 'keep)
        (t 'conflict)))

(defun zwanenzang--merge-parent (nest base-nest remote base-parent expected)
  "Reconcile the parent of a ticket heading.
NEST is its nesting now and BASE-NEST at the last sync; REMOTE is the
tracker parent and BASE-PARENT the one last synced.  EXPECTED is the
nesting REMOTE asks for: REMOTE when it has a heading in scope, else nil.
Return `same', `move' (only the tracker changed), `keep' (only the
nesting changed) or `conflict'."
  (let ((local-changed (not (equal nest base-nest)))
        (remote-changed (not (equal remote base-parent))))
    (cond
     ((or (eq base-nest :unknown) (eq base-parent :unknown))
      (if (equal nest expected) 'same 'conflict))
     ((not remote-changed) (if local-changed 'keep 'same))
     ((not local-changed) (if (equal nest expected) 'same 'move))
     ((equal nest expected) 'same)
     (t 'conflict))))

;;;; Pull

(cl-defstruct (zwanenzang--pull (:constructor zwanenzang--pull-create)
                                (:copier nil))
  "What one scope's pull works with and collects."
  root dir tracker-dir map hidden actors
  known statuses tracker                ; last successful read, for dependency checks
  (ids (make-hash-table :test #'equal)) ; id -> marker, unique headings only
  moves
  lines                                 ; what needs a look, newest first
  info                                  ; what happened, newest first
  pulled                                ; ids whose shown state changed
  (new 0) (moved 0)
  conflicted                            ; ids, each counted once
  (blocked 0)
  refused)                              ; why the whole scope was skipped

(defun zwanenzang--pull-line (pull format &rest args)
  "Add a line to PULL's report, formatted from FORMAT and ARGS."
  (push (apply #'format format args) (zwanenzang--pull-lines pull)))

(defun zwanenzang--pull-note (pull format &rest args)
  "Add a line about what happened to PULL's report, from FORMAT and ARGS."
  (push (apply #'format format args) (zwanenzang--pull-info pull)))

(defun zwanenzang--label (ticket)
  "How the report names TICKET: its display form and title."
  (format "%s %s" (alist-get 'display ticket) (alist-get 'title ticket)))

(defun zwanenzang--null (value)
  "VALUE, or nil when it is JSON null."
  (unless (eq value :null) value))

(defun zwanenzang--actor-name (pull actor)
  "The display name of ACTOR in PULL's tracker, or its short id."
  (or (alist-get (intern actor) (zwanenzang--pull-actors pull))
      (substring actor 0 (min 10 (length actor)))))

(defun zwanenzang--comments-content (pull ticket)
  "The :ZWANENZANG_COMMENTS: drawer content for TICKET, newest first.
Reverse replay order, not wall-clock timestamps; leave TICKET unchanged."
  (mapconcat
   (lambda (c)
     (let ((link (zwanenzang--null (alist-get 'link c))))
       (concat (format "[%s] %s:\n" (alist-get 'ts c)
                       (zwanenzang--actor-name pull (alist-get 'actor c)))
               (zwanenzang--comment-text (alist-get 'text c))
               (and link
                    (concat (org-link-make-string
                             (if (string-match-p "\\`[a-zA-Z][a-zA-Z0-9+.-]*:" link)
                                 link
                               (concat "file:" (expand-file-name
                                                link (zwanenzang--pull-tracker-dir pull)))))
                            "\n")))))
   (reverse (alist-get 'comments ticket)) ""))

(defun zwanenzang--hidden-content (pull ticket)
  "The :ZWANENZANG_HIDDEN: drawer content for TICKET.
One link for each hidden document it has."
  (mapconcat
   (lambda (name)
     (let ((doc (alist-get (intern name) (alist-get 'documents ticket))))
       (if (and doc (zwanenzang--null (alist-get 'current doc)))
           (concat (org-link-make-string
                    (format "zwanenzang:%s/%s" (alist-get 'id ticket) name)
                    (format "%s (hidden)" name))
                   "\n")
         "")))
   (zwanenzang--pull-hidden pull) ""))

(defun zwanenzang--conflict-content (conflicts)
  "The :ZWANENZANG_CONFLICT: drawer content for CONFLICTS.
Each conflict is (FIELD NOTE VALUE), VALUE the skipped remote value
or nil."
  (mapconcat (lambda (c)
               (concat (format "- %s: %s\n" (nth 0 c) (nth 1 c))
                       (if (nth 2 c) (zwanenzang--fixed-width (nth 2 c) "  ") "")))
             conflicts ""))

(defun zwanenzang--write-blocked (conflicts)
  "Mark the heading at point as blocked by CONFLICTS and change nothing else."
  (zwanenzang--write-body
   (zwanenzang--compose-body (zwanenzang--body)
                             `(("ZWANENZANG_CONFLICT"
                                . ,(zwanenzang--conflict-content conflicts)))))
  (let ((h (zwanenzang--heading)))
    (zwanenzang--set-heading (plist-get h :keyword) (plist-get h :title)
                             (append (remove zwanenzang-conflict-tag (plist-get h :tags))
                                     (list zwanenzang-conflict-tag)))))

(defun zwanenzang--add-conflict (conflict)
  "Add CONFLICT to the conflict drawer of the heading at point and tag it."
  (let* ((body (zwanenzang--body))
         (drawer (seq-find (lambda (s) (and (eq (car s) 'drawer)
                                            (equal (nth 2 s) "ZWANENZANG_CONFLICT")))
                           (zwanenzang--body-segments body)))
         (old (if drawer
                  (replace-regexp-in-string "\\`.*\n\\|.*\n\\'" "" (cadr drawer))
                "")))
    (zwanenzang--write-body
     (zwanenzang--compose-body
      body `(("ZWANENZANG_CONFLICT" . ,(concat old (zwanenzang--conflict-content
                                                     (list conflict)))))))
    (let ((h (zwanenzang--heading)))
      (zwanenzang--set-heading (plist-get h :keyword) (plist-get h :title)
                               (append (remove zwanenzang-conflict-tag (plist-get h :tags))
                                       (list zwanenzang-conflict-tag))))))

(defun zwanenzang--merge-prose (remote fresh hash-property)
  "Reconcile the body text at point with REMOTE, normalized tracker text.
HASH-PROPERTY holds the hash of the text as last synced; FRESH means
the heading is new, so its text counts as synced.  Return a decision
as `zwanenzang--merge' does."
  (let ((local (zwanenzang--hash (zwanenzang--entry-text))))
    (zwanenzang--merge local
                       (if fresh local (or (org-entry-get nil hash-property) :unknown))
                       (zwanenzang--hash remote))))

(defun zwanenzang--remote-text (texts name)
  "The normalized current text of document NAME, a symbol, in TEXTS."
  (zwanenzang--normalize-text (or (alist-get name texts) "")))

(defun zwanenzang--pull-docs (pull ticket texts)
  "Pull the named documents of TICKET into subheadings at point.
TEXTS maps document names to their current text.  A document without
a subheading gets one.  Return the conflicts."
  (let ((docs (zwanenzang--doc-headings))
        conflicts)
    (dolist (doc (alist-get 'documents ticket))
      (let ((name (symbol-name (car doc)))
            (version (zwanenzang--null (alist-get 'current (cdr doc))))
            (remote (zwanenzang--remote-text texts (car doc))))
        (unless (or (equal name "description") (null version)
                    (member name (zwanenzang--pull-hidden pull)))
          (let* ((marker (cdr (assoc name docs)))
                 (fresh (null marker)))
            (unless marker
              (setq marker (zwanenzang--insert-heading
                            (if docs
                                (zwanenzang--subtree-end (cdar (last docs)))
                              (cdr (zwanenzang--body-bounds)))
                            (1+ (org-current-level)) name `(("ZWANENZANG_DOC" . ,name))))
              (setq docs (append docs (list (cons name marker)))))
            (save-excursion
              (goto-char marker)
              (let ((local (zwanenzang--document-text)))
                (zwanenzang--write-document local))
              (pcase (zwanenzang--merge-prose remote fresh "ZWANENZANG_HASH")
                ('conflict
                 (push (list (format "document %s" name)
                             (format "tracker version %s skipped; Org text kept" version)
                             remote)
                       conflicts))
                (decision
                 (when (eq decision 'apply)
                   (zwanenzang--write-document remote))
                 (zwanenzang--put "ZWANENZANG_VERSION" version)
                 (zwanenzang--put "ZWANENZANG_HASH" (zwanenzang--hash remote)))))))))
    (nreverse conflicts)))

(defun zwanenzang--tags-hash (tags)
  "The hash of TAGS, ignoring their order."
  (zwanenzang--hash (string-join (sort (copy-sequence tags) #'string<) " ")))

(defun zwanenzang--fresh-sync (pull heading nest ticket)
  "Sync state for a heading just inserted: its HEADING and NEST as they are.
Every field then counts as unchanged in Org, so TICKET's values apply."
  `((status . ,(car (rassoc (plist-get heading :keyword) (zwanenzang--pull-map pull))))
    (title . ,(zwanenzang--hash (plist-get heading :title)))
    (priority . ,(number-to-string (or (plist-get heading :priority) -1)))
    (tags . ,(zwanenzang--tags-hash (zwanenzang--tracker-tags (plist-get heading :tags))))
    (parent . ,(zwanenzang--null (alist-get 'parent ticket)))
    (nest . ,nest)))

(defun zwanenzang--pull-parent (pull ticket nest sync)
  "Reconcile the nesting of the heading at point with TICKET's parent.
NEST is the ticket heading it is nested under and SYNC its sync state.
A parent change the nesting does not yet show is queued as a move in
PULL.  Return (CONFLICT PARENT NEST): the conflict or nil, and the
parent and nesting to record."
  (let* ((remote (zwanenzang--null (alist-get 'parent ticket)))
         (target (and remote (gethash remote (zwanenzang--pull-ids pull))))
         (expected (and target remote))
         (decision (zwanenzang--merge-parent nest (zwanenzang--sync-get sync 'nest)
                                             remote (zwanenzang--sync-get sync 'parent)
                                             expected))
         (keep (list nil (alist-get 'parent sync) (alist-get 'nest sync))))
    (cond
     ((eq decision 'conflict)
      (cons (list "parent" (format "tracker parent is %s; Org nesting kept" (or remote "none"))
                  nil)
            (cdr keep)))
     ((eq decision 'keep) keep)
     ((and (eq decision 'move) target
           (<= (point) target) (< target (zwanenzang--subtree-end (point))))
      (cons (list "parent" (format "tracker parent %s is nested inside this heading; %s"
                                   remote "Org nesting kept")
                  nil)
            (cdr keep)))
     ((eq decision 'move)
      (push (list (alist-get 'id ticket) (or expected :inbox) remote
                  (assq 'parent sync) (assq 'nest sync))
            (zwanenzang--pull-moves pull))
      (list nil remote expected))
     (t (list nil remote nest)))))

(defun zwanenzang--pull-ticket (pull entry nest &optional fresh)
  "Pull ENTRY, one ticket of a read result, into the ticket heading at point.
NEST is the id of the ticket heading the heading is nested under, or
nil.  FRESH means the heading was just inserted, so everything in it
counts as unchanged since the last sync.  Each field the tracker changed
is applied when Org did not change it too; otherwise Org's value stays
and the remote one goes in the conflict drawer.  Return the list of
conflicting fields, or `blocked' when the tracker status has no keyword."
  (let* ((ticket (alist-get 'ticket entry))
         (texts (alist-get 'documents entry))
         (status (alist-get 'status ticket))
         (map (zwanenzang--pull-map pull))
         (heading (zwanenzang--heading))
         (sync (if fresh
                   (zwanenzang--fresh-sync pull heading nest ticket)
                 (zwanenzang--parse-sync (org-entry-get nil "ZWANENZANG_SYNC"))))
         (new-sync (copy-alist sync))
         (keyword (plist-get heading :keyword))
         (title (plist-get heading :title))
         (priority (plist-get heading :priority))
         (tags (zwanenzang--tracker-tags (plist-get heading :tags)))
         conflicts description desc-state)
    (cl-flet ((settle (field decision note value key synced)
                ;; Record DECISION for FIELD; non-nil when the remote value applies.
                (if (eq decision 'conflict)
                    (progn (push (list field note value) conflicts) nil)
                  (setf (alist-get key new-sync) synced)
                  (eq decision 'apply))))
      (if (not (assoc status map))
          (progn
            (zwanenzang--write-blocked
             `(("status" ,(format "tracker status %s has no keyword in the keyword map; %s"
                                  status "nothing pulled")
                nil)))
            'blocked)
        (zwanenzang--ensure-org-id)
        ;; Status is compared as keywords: a draft shown as TODO stays
        ;; draft until the keyword changes.
        (let* ((remote (cdr (assoc status map)))
               (base (zwanenzang--sync-get sync 'status))
               ;; A synced status the map no longer shows says nothing
               ;; about which keyword Org had then.
               (base-kw (if fresh keyword (or (cdr (assoc base map)) :unknown)))
               (decision (zwanenzang--merge keyword base-kw remote)))
          (when (settle "status" decision (format "tracker has %s (%s); Org keyword kept"
                                                  status remote)
                        nil 'status status)
            (setq keyword remote)))
        (let ((remote (string-trim (alist-get 'title ticket))))
          (when (settle "title" (zwanenzang--merge (zwanenzang--hash title)
                                                   (zwanenzang--sync-get sync 'title)
                                                   (zwanenzang--hash remote))
                        "tracker title skipped; Org title kept" remote
                        'title (zwanenzang--hash remote))
            (setq title remote)))
        (let* ((remote (zwanenzang--null (alist-get 'priority ticket)))
               (remote-key (number-to-string (or remote -1)))
               ;; Upgrade old clients: missing baseline means no cookie.
               (base (or (alist-get 'priority sync) "-1")))
          (when (settle "priority"
                        (zwanenzang--merge (number-to-string (or priority -1)) base remote-key)
                        "tracker priority skipped; Org cookie kept" remote-key
                        'priority remote-key)
            (setq priority remote)))
        (let ((remote (alist-get 'tags ticket)))
          (when (settle "tags" (zwanenzang--merge (zwanenzang--tags-hash tags)
                                                  (zwanenzang--sync-get sync 'tags)
                                                  (zwanenzang--tags-hash remote))
                        "tracker tags skipped; Org tags kept"
                        (if remote (string-join remote " ") "(none)")
                        'tags (zwanenzang--tags-hash remote))
            (setq tags remote)))
        (condition-case err
            (let* ((local (zwanenzang--dependency-refs))
                   (remote (zwanenzang--dependency-displays ticket (zwanenzang--pull-known pull)))
                   ;; Upgrade old Org-only properties without discarding them.
                   (base (if fresh (zwanenzang--tags-hash local)
                           (or (alist-get 'depends sync) (zwanenzang--tags-hash nil)))))
              (when (settle "dependencies"
                            (zwanenzang--merge (zwanenzang--tags-hash local) base
                                              (zwanenzang--tags-hash remote))
                            "tracker prerequisites skipped; Org dependencies kept"
                            (string-join remote " ") 'depends (zwanenzang--tags-hash remote))
                (zwanenzang--put "ZWANENZANG_DEPENDS_ON"
                                 (and remote (string-join remote " ")))))
          (user-error
           (push (list "dependencies" (error-message-string err) nil) conflicts)))
        (pcase-let ((`(,conflict ,parent ,nested) (zwanenzang--pull-parent pull ticket nest sync)))
          (if conflict
              (push conflict conflicts)
            (setf (alist-get 'parent new-sync) parent
                  (alist-get 'nest new-sync) nested)))
        (let ((remote (zwanenzang--remote-text texts 'description))
              (version (alist-get 'current (alist-get 'description (alist-get 'documents ticket)))))
          (pcase (zwanenzang--merge-prose remote fresh "ZWANENZANG_DESC_HASH")
            ('conflict
             (push (list "description" "tracker description skipped; Org text kept" remote)
                   conflicts))
            (decision
             (when (eq decision 'apply) (setq description remote))
             (setq desc-state (list (zwanenzang--null version) (zwanenzang--hash remote))))))
        (when (eq (alist-get 'tombstoned ticket) t)
          (push (list "tombstoned"
                      "the ticket is tombstoned in the tracker; writes to it would be refused"
                      nil)
                conflicts))
        ;; Push skips such a heading; the note lasts as long as the keyword.
        (unless (rassoc keyword map)
          (push (list "keyword"
                      (if keyword
                          (format "Org keyword %s has no status in the keyword map; not pushed"
                                  keyword)
                        "the heading has no TODO keyword; not pushed")
                      nil)
                conflicts))
        (setq conflicts (append (nreverse conflicts) (zwanenzang--pull-docs pull ticket texts)))
        (zwanenzang--write-body
         (zwanenzang--compose-body
          (zwanenzang--body)
          `(("ZWANENZANG_COMMENTS" . ,(zwanenzang--comments-content pull ticket))
            ("ZWANENZANG_HIDDEN" . ,(zwanenzang--hidden-content pull ticket))
            ("ZWANENZANG_CONFLICT" . ,(zwanenzang--conflict-content conflicts)))
          description))
        (when (integerp (alist-get 'number ticket))
          (zwanenzang--put "ZWANENZANG_NUMBER" (alist-get 'display ticket)))
        (zwanenzang--put "ZWANENZANG_ACTIVITY" (alist-get 'ts (alist-get 'activity ticket)))
        (zwanenzang--put "ZWANENZANG_TAG_SINCE"
                         (and (alist-get 'tag_since ticket)
                              (zwanenzang--json-encode (alist-get 'tag_since ticket))))
        (unless (and (org-entry-get nil "ZWANENZANG_READ_AT")
                     (equal (org-entry-get nil "ZWANENZANG_CURSOR")
                            (zwanenzang--null (alist-get 'cursor entry))))
          (zwanenzang--put "ZWANENZANG_READ_AT" (format-time-string "%FT%TZ" nil t)))
        (zwanenzang--put "ZWANENZANG_INACTIVE"
                         (and (or (eq (alist-get 'archived ticket) t)
                                  (eq (alist-get 'tombstoned ticket) t)) "t"))
        (zwanenzang--put "ZWANENZANG_CURSOR" (zwanenzang--null (alist-get 'cursor entry)))
        (zwanenzang--put "ZWANENZANG_SYNC" (zwanenzang--format-sync new-sync))
        (when desc-state
          (zwanenzang--put "ZWANENZANG_DESC_VERSION" (nth 0 desc-state))
          (zwanenzang--put "ZWANENZANG_DESC_HASH" (nth 1 desc-state)))
        (zwanenzang--set-heading
         keyword title
         (append tags
                 (and (member org-archive-tag (plist-get heading :tags)) (list org-archive-tag))
                 (and conflicts (list zwanenzang-conflict-tag)))
         priority)
        (mapcar #'car conflicts)))))

(defun zwanenzang--conflict-label (ticket)
  "How the report names TICKET, at point, in a conflict: both titles."
  (format "%s Org \"%s\", tracker \"%s\"" (alist-get 'display ticket)
          (plist-get (zwanenzang--heading) :title) (alist-get 'title ticket)))

(defun zwanenzang--note-conflict (pull ticket what)
  "Report in PULL a conflict in WHAT on TICKET, at point; count the ticket once."
  (cl-pushnew (alist-get 'id ticket) (zwanenzang--pull-conflicted pull) :test #'equal)
  (zwanenzang--pull-line pull "%s: conflict in %s" (zwanenzang--conflict-label ticket) what))

(defun zwanenzang--note-result (pull ticket result)
  "Count RESULT of pulling TICKET, at point, in PULL and report it."
  (cond
   ((eq result 'blocked)
    (cl-incf (zwanenzang--pull-blocked pull))
    (zwanenzang--pull-line pull "%s: blocked, tracker status %s has no keyword"
                           (zwanenzang--label ticket) (alist-get 'status ticket)))
   (result
    (zwanenzang--note-conflict pull ticket (string-join result ", "))))
  (when (eq (alist-get 'archived ticket) t)
    (zwanenzang--pull-note pull "%s: archived in the tracker" (zwanenzang--label ticket))))

(defun zwanenzang--shown-state ()
  "What the human sees of the ticket at point, to tell whether a pull changed it.
Sync state and conflict notes are left out."
  (let ((heading (zwanenzang--heading))
        (segments (zwanenzang--body-segments (zwanenzang--body))))
    (list (plist-get heading :keyword)
          (plist-get heading :title)
          (plist-get heading :priority)
          (zwanenzang--dependency-refs)
          (zwanenzang--tracker-tags (plist-get heading :tags))
          (zwanenzang--segments-text segments)
          (seq-filter (lambda (s) (member (nth 2 s) zwanenzang--tail-drawers)) segments)
          (mapcar (lambda (doc)
                    (save-excursion
                      (goto-char (cdr doc))
                      (zwanenzang--document-text)))
                  (zwanenzang--doc-headings)))))

(defun zwanenzang--pull-existing (pull entry nest)
  "Pull ENTRY into the ticket heading at point, reporting in PULL what changed.
NEST is as in `zwanenzang--pull-ticket'."
  (let* ((ticket (alist-get 'ticket entry))
         (before (zwanenzang--shown-state))
         (result (zwanenzang--pull-ticket pull entry nest)))
    (zwanenzang--note-result pull ticket result)
    (unless (equal before (zwanenzang--shown-state))
      (push (alist-get 'id ticket) (zwanenzang--pull-pulled pull))
      (zwanenzang--pull-note pull "pulled %s" (zwanenzang--label ticket)))))

(defun zwanenzang--rescan (pull)
  "Refresh the markers of PULL's unique tickets after subtrees moved."
  (let ((ids (zwanenzang--pull-ids pull)))
    (dolist (tk (car (zwanenzang--scan (zwanenzang--pull-root pull))))
      (when (gethash (plist-get tk :id) ids)
        (puthash (plist-get tk :id) (plist-get tk :marker) ids)))))

(defun zwanenzang--discover (pull entries)
  "Insert a heading for each of ENTRIES, tickets absent from PULL's scope.
A ticket goes under its parent's heading when the parent is in scope,
parents first, and otherwise under the inbox.  A ticket whose status has
no keyword is not inserted.  Return nil if any was left out."
  (let* ((map (zwanenzang--pull-map pull))
         (root (zwanenzang--pull-root pull))
         (ids (zwanenzang--pull-ids pull))
         (complete t)
         (pending
          (seq-remove
           (lambda (e)
             (let ((ticket (alist-get 'ticket e)))
               (unless (assoc (alist-get 'status ticket) map)
                 (zwanenzang--pull-line pull "%s: not inserted, tracker status %s has no keyword"
                                        (zwanenzang--label ticket) (alist-get 'status ticket))
                 (cl-incf (zwanenzang--pull-blocked pull))
                 (setq complete nil)
                 t)))
           entries)))
    (cl-flet ((parent (e) (zwanenzang--null (alist-get 'parent (alist-get 'ticket e))))
              (id (e) (alist-get 'id (alist-get 'ticket e))))
      (while pending
        (let ((ready (or (seq-remove (lambda (e)
                                       (seq-find (lambda (o) (equal (id o) (parent e))) pending))
                                     pending)
                         pending)))
          (dolist (e ready)
            (let* ((ticket (alist-get 'ticket e))
                   (under (and (parent e) (gethash (parent e) ids)))
                   (target (or under (zwanenzang--ensure-inbox root)))
                   (marker (zwanenzang--insert-heading
                            (zwanenzang--subtree-end target)
                            (1+ (save-excursion (goto-char target) (org-current-level)))
                            (string-trim (alist-get 'title ticket))
                            `(("ZWANENZANG_ID" . ,(id e))))))
              (puthash (id e) marker ids)
              (save-excursion
                (goto-char marker)
                (zwanenzang--note-result
                 pull ticket (zwanenzang--pull-ticket pull e (and under (parent e)) t)))
              (cl-incf (zwanenzang--pull-new pull))
              (zwanenzang--pull-note pull "new %s" (zwanenzang--label ticket))))
          (setq pending (seq-difference pending ready #'eq)))))
    complete))

(defun zwanenzang--apply-read (pull result blocked tickets)
  "Apply RESULT, the scope read, to PULL's scope.
BLOCKED pairs scanned TICKETS that must not be pulled with the note
saying why.  Headings in scope are pulled in place, then moved where the
tracker moved their parent, then absent tickets are inserted.  The root
records the tracker and, unless a ticket was left out, the new scope
cursor."
  (let ((entries (make-hash-table :test #'equal))
        (present (make-hash-table :test #'equal))
        (root (zwanenzang--pull-root pull))
        (ids (zwanenzang--pull-ids pull)))
    (dolist (e (alist-get 'tickets result))
      (puthash (alist-get 'id (alist-get 'ticket e)) e entries))
    (dolist (tk tickets) (puthash (plist-get tk :id) t present))
    (dolist (b blocked)
      (save-excursion
        (goto-char (plist-get (car b) :marker))
        (zwanenzang--write-blocked (list (list "id" (cdr b) nil))))
      (cl-incf (zwanenzang--pull-blocked pull)))
    (dolist (tk tickets)
      (let ((entry (gethash (plist-get tk :id) entries)))
        (when (and entry (gethash (plist-get tk :id) ids))
          (save-excursion
            (goto-char (plist-get tk :marker))
            (zwanenzang--pull-existing pull entry (plist-get tk :nest))))))
    (pcase-dolist (`(,id ,target ,parent ,old-parent ,old-nest)
                   (reverse (zwanenzang--pull-moves pull)))
      (zwanenzang--rescan pull)
      (let ((from (gethash id ids))
            (to (if (eq target :inbox)
                    (zwanenzang--ensure-inbox root)
                  (gethash target ids)))
            (ticket (alist-get 'ticket (gethash id entries))))
        (if (not (and (<= from to) (< to (zwanenzang--subtree-end from))))
            (progn (zwanenzang--move-subtree from to)
                   (cl-incf (zwanenzang--pull-moved pull))
                   (zwanenzang--pull-note pull "moved %s" (zwanenzang--label ticket)))
          ;; An earlier move put the new parent inside this subtree.  The
          ;; heading stays, and so does the sync state of its nesting.
          (save-excursion
            (goto-char from)
            (zwanenzang--put "ZWANENZANG_SYNC"
                             (zwanenzang--format-sync
                              (append (list old-parent old-nest)
                                      (seq-remove (lambda (cell) (memq (car cell) '(parent nest)))
                                                  (zwanenzang--parse-sync
                                                   (org-entry-get nil "ZWANENZANG_SYNC"))))))
            (zwanenzang--add-conflict
             (list "parent" (format "tracker parent %s is nested inside this heading; %s"
                                    parent "Org nesting kept")
                   nil))
            (zwanenzang--note-conflict
             pull ticket "parent (not moved, the new parent is nested inside it)")))))
    (zwanenzang--rescan pull)
    (let ((complete (zwanenzang--discover
                     pull (seq-remove (lambda (e)
                                        (gethash (alist-get 'id (alist-get 'ticket e)) present))
                                      (alist-get 'tickets result)))))
      (save-excursion
        (goto-char root)
        (zwanenzang--put "ZWANENZANG_TRACKER" (alist-get 'id (alist-get 'tracker result)))
        (when complete
          (zwanenzang--put "ZWANENZANG_CURSOR" (zwanenzang--null (alist-get 'cursor result))))))))

(defun zwanenzang--known-tickets (dir)
  "Every ticket the tracker at DIR knows, as a hash table from id to summary."
  (let ((known (make-hash-table :test #'equal)))
    (dolist (summary (alist-get 'tickets (funcall zwanenzang--call dir '("list" "--all"))))
      (puthash (alist-get 'id summary) summary known))
    known))

(defun zwanenzang--blocked-headings (tickets known)
  "The scanned TICKETS that must not sync: foreign or duplicate ids.
KNOWN is from `zwanenzang--known-tickets'.  Return an alist of each such
ticket and a note saying why."
  (let ((counts (make-hash-table :test #'equal))
        blocked)
    (dolist (tk tickets)
      (cl-incf (gethash (plist-get tk :id) counts 0)))
    (dolist (tk tickets)
      (let* ((id (plist-get tk :id))
             (note
              (cond
               ((> (gethash id counts) 1)
                ;; No line numbers here: the note goes in the buffer and
                ;; would move them.  The report gives each heading's line.
                (format "duplicate: ZWANENZANG_ID %s is on %d headings in this scope"
                        id (gethash id counts)))
               ((not (gethash id known))
                (format "foreign: the tracker has no ticket %s" id)))))
        (when note (push (cons tk note) blocked))))
    (nreverse blocked)))

(defun zwanenzang--read-scope (root dir tickets blocked)
  "Read the scope at ROOT from the tracker at DIR, for TICKETS except BLOCKED."
  (funcall zwanenzang--call dir '("read")
           `((cursors . ,(delq nil
                               (mapcar (lambda (tk)
                                         (unless (assq tk blocked)
                                           (cons (intern (plist-get tk :id))
                                                 (or (org-entry-get (plist-get tk :marker)
                                                                    "ZWANENZANG_CURSOR")
                                                     :null))))
                                       tickets)))
             (since . ,(or (org-entry-get root "ZWANENZANG_CURSOR") :null)))))

(defun zwanenzang--scope-name (root)
  "The title of the scope root at ROOT, for reports."
  (substring-no-properties (save-excursion (goto-char root) (org-get-heading t t t t))))

(defun zwanenzang--tracker-mismatch (what root dir result)
  "Why the scope at ROOT must not WHAT with the tracker at DIR, or nil.
RESULT is the read of that tracker; the scope is bound to the first one."
  (let ((stored (org-entry-get root "ZWANENZANG_TRACKER"))
        (id (alist-get 'id (alist-get 'tracker result)))
        (priority (alist-get 'priority (alist-get 'tracker result))))
    (cond
     ((and stored (not (equal stored id)))
      (format "zwanenzang: %s of %s blocked: it is bound to tracker %s, %s is %s"
              what (zwanenzang--scope-name root) stored dir id))
     ((and priority
           (not (equal priority `((highest . ,org-priority-highest)
                                  (lowest . ,org-priority-lowest)
                                  (default . ,org-priority-default)))))
      ;; Compare by key, not JSON object order.
      (unless (and (= (alist-get 'highest priority) org-priority-highest)
                   (= (alist-get 'lowest priority) org-priority-lowest)
                   (= (alist-get 'default priority) org-priority-default))
        (let ((file (expand-file-name "zwanenzang.toml" dir))
              (snippet (format "# 0..64 are numeric priorities; 65..90 are character codes A..Z.\n[priority]\nhighest = %d\nlowest = %d\ndefault = %d\n"
                               org-priority-highest org-priority-lowest
                               org-priority-default)))
          (propertize
           (format "zwanenzang: %s blocked: align Org PRIORITIES / org-priority-{highest,lowest,default} with [priority] in %s (tracker: highest=%d, lowest=%d, default=%d); no settings were overwritten. Either align Org to the tracker values above, or replace the existing [priority] section with these active Org values. Changing TOML changes the range/default for every user of the tracker: save, commit and push in the tracker clone, then retry.\n%s"
                   what file (alist-get 'highest priority)
                   (alist-get 'lowest priority) (alist-get 'default priority) snippet)
           'zwanenzang-priority-remedy (cons file snippet))))))))

(defun zwanenzang--offer-priority-remedy (refusal)
  "Copy the Org settings in REFUSAL and offer to visit its TOML file.
Only priority refusals carry this metadata.  Never edit or save the file."
  (when-let* ((remedy (get-text-property 0 'zwanenzang-priority-remedy refusal)))
    (kill-new (cdr remedy))
    (when (and (not noninteractive)
               (y-or-n-p (format "zwanenzang: priority settings differ; [priority] snippet copied to kill-ring. Open %s? " (car remedy))))
      (find-file-other-window (car remedy)))
    (message "zwanenzang: [priority] snippet copied to kill-ring (see *zwanenzang*); align Org to tracker values, or replace the TOML section tracker-wide, save, commit and push, then retry")))

(defun zwanenzang--hide-docs (root)
  "The names in the ZWANENZANG_HIDE_DOCS of the scope at ROOT."
  (split-string (or (org-entry-get root "ZWANENZANG_HIDE_DOCS") "")))

(defun zwanenzang--pull-scope (root)
  "Pull the scope at ROOT, a marker at its root heading; return the pull.
The CLI is only read from.  All changes to the buffer are one undo step
and the buffer is not saved."
  (with-current-buffer (marker-buffer root)
    (zwanenzang--check-source-edit)
    (org-with-wide-buffer
     (let* ((case-fold-search nil)
            (dir (zwanenzang--scope-directory root))
            (tickets (car (zwanenzang--scan root)))
            (known (zwanenzang--known-tickets dir))
            (blocked (zwanenzang--blocked-headings tickets known))
            (pull (zwanenzang--pull-create :root root :dir dir)))
       ;; Duplicate and foreign ids block only their headings, and are
       ;; never sent to read.
       (dolist (tk tickets)
         (let ((note (cdr (assq tk blocked))))
           (if note
               (zwanenzang--pull-line pull "line %d: %s"
                                      (line-number-at-pos (plist-get tk :marker) t) note)
             (puthash (plist-get tk :id) (plist-get tk :marker) (zwanenzang--pull-ids pull)))))
       (let* ((result (zwanenzang--read-scope root dir tickets blocked))
              (tracker (alist-get 'tracker result))
              (refused (zwanenzang--tracker-mismatch "pull" root dir result)))
         (if refused
             (setf (zwanenzang--pull-refused pull) refused)
           (let ((km (zwanenzang--keyword-map (org-entry-get root "ZWANENZANG_KEYWORDS")
                                              (alist-get 'statuses tracker)
                                              org-todo-keywords-1))
                 (hide (zwanenzang--hide-docs root)))
             (setf (zwanenzang--pull-map pull) (car km)
                   (zwanenzang--pull-hidden pull) (remove "description" hide)
                   (zwanenzang--pull-actors pull) (alist-get 'actors tracker)
                   (zwanenzang--pull-tracker-dir pull) dir)
             (dolist (p (cdr km)) (zwanenzang--pull-line pull "%s" p))
             (when (member "description" hide)
               (zwanenzang--pull-line
                pull "ZWANENZANG_HIDE_DOCS: the description cannot be hidden; ignored")))
           (when (eq (alist-get 'reset result) t)
             (zwanenzang--pull-line
              pull "history changed under the scope cursor: compared in full"))
           ;; Read and list are separate local loads.  Prefer read's newer
           ;; state where available; absent unchanged tickets stay in KNOWN.
           ;; Relationship display needs this map before editing headings.
           (dolist (entry (alist-get 'tickets result))
             (let ((ticket (alist-get 'ticket entry)))
               (puthash (alist-get 'id ticket) ticket known)))
           (setf (zwanenzang--pull-known pull) known)
           (zwanenzang--one-undo-step
             (zwanenzang--apply-read pull result blocked tickets))
           (setf (zwanenzang--pull-statuses pull) (alist-get 'statuses tracker)
                 (zwanenzang--pull-tracker pull) (alist-get 'id tracker))))
       pull))))

;;;; Reports of a whole command

(cl-defstruct (zwanenzang--outcome (:constructor zwanenzang--outcome-create)
                                   (:copier nil))
  "What one command collected on one scope, for its report."
  pull                                  ; the last pull: its conflicts still stand
  problems info                         ; lines, newest first
  pulled (new 0) (moved 0) (created 0) (pushed 0)
  saved                                 ; the file was saved for new identities
  refused)

(defun zwanenzang--pull-into (outcome root)
  "Pull the scope at ROOT and add the result to OUTCOME."
  (let ((pull (zwanenzang--pull-scope root)))
    (setf (zwanenzang--outcome-pull outcome) pull
          (zwanenzang--outcome-refused outcome) (zwanenzang--pull-refused pull)
          (zwanenzang--outcome-info outcome) (append (zwanenzang--pull-info pull)
                                                     (zwanenzang--outcome-info outcome))
          (zwanenzang--outcome-pulled outcome) (seq-union (zwanenzang--outcome-pulled outcome)
                                                          (zwanenzang--pull-pulled pull))
          (zwanenzang--outcome-new outcome) (+ (zwanenzang--outcome-new outcome)
                                               (zwanenzang--pull-new pull))
          (zwanenzang--outcome-moved outcome) (+ (zwanenzang--outcome-moved outcome)
                                                 (zwanenzang--pull-moved pull)))))

(defun zwanenzang--note-sync (outcome sync)
  "Add SYNC, a sync object or JSON null, to OUTCOME's report.
Publication errors and skipped checkouts are not failures, but need a look."
  (when (consp sync)
    (let ((err (zwanenzang--null (alist-get 'error sync)))
          (checkouts (alist-get 'checkouts sync)))
      (when err
        (push (format "not published: %s: %s" (alist-get 'code err) (alist-get 'message err))
              (zwanenzang--outcome-problems outcome)))
      (dolist (n (alist-get 'numbered sync))
        (push (format "numbered %s" (alist-get 'display n))
              (zwanenzang--outcome-info outcome)))
      (let ((err (zwanenzang--null (alist-get 'error checkouts))))
        (when err
          (push (format "checkouts: %s: %s" (alist-get 'code err) (alist-get 'message err))
                (zwanenzang--outcome-problems outcome))))
      (dolist (c (alist-get 'results checkouts))
        (if (equal (alist-get 'status c) "skipped")
            (push (format "checkout %s: skipped, %s: %s" (alist-get 'path c)
                          (alist-get 'reason c) (alist-get 'message c))
                  (zwanenzang--outcome-problems outcome))
          (push (format "checkout %s: %s" (alist-get 'path c) (alist-get 'status c))
                (zwanenzang--outcome-info outcome)))))))

(defun zwanenzang--report-outcome (verb root outcome)
  "Report OUTCOME of a command on the scope at ROOT, saying it VERB the scope."
  (with-current-buffer (marker-buffer root)
    (if (zwanenzang--outcome-refused outcome)
        (let ((refusal (zwanenzang--outcome-refused outcome)))
          (prog1 (zwanenzang-report refusal)
            (zwanenzang--offer-priority-remedy refusal)))
      (let* ((pull (zwanenzang--outcome-pull outcome))
             (parts (append
                     (delq nil
                           (cl-mapcar
                            (lambda (n label) (and (> n 0) (format "%d %s" n label)))
                            (list (length (zwanenzang--outcome-pulled outcome))
                                  (zwanenzang--outcome-new outcome)
                                  (zwanenzang--outcome-moved outcome)
                                  (zwanenzang--outcome-created outcome)
                                  (zwanenzang--outcome-pushed outcome)
                                  (length (zwanenzang--pull-conflicted pull))
                                  (zwanenzang--pull-blocked pull))
                            '("pulled" "new" "moved" "created" "pushed"
                              "with conflicts" "blocked")))
                     (and (zwanenzang--outcome-saved outcome) '("file saved")))))
        (zwanenzang-report
         (format "zwanenzang: %s %s: %s" verb
                 (org-with-wide-buffer (zwanenzang--scope-name root))
                 (if parts (string-join parts ", ") "nothing changed"))
         (append (reverse (zwanenzang--outcome-problems outcome))
                 (reverse (zwanenzang--pull-lines pull)))
         (reverse (zwanenzang--outcome-info outcome)))))))

(defun zwanenzang--root-at-point ()
  "The scope root containing point, in an Org buffer."
  (unless (derived-mode-p 'org-mode)
    (user-error "zwanenzang: not an Org buffer"))
  (zwanenzang--scope-root))

;;;###autoload
(defun zwanenzang-pull ()
  "Pull the tracker's state into the scope containing point.
Only the buffer changes: the tracker is read, not written, and nothing
is saved.  The changes undo as one step.  A summary is echoed and a
report appended to the `*zwanenzang*' buffer."
  (interactive)
  (let ((root (zwanenzang--root-at-point))
        (outcome (zwanenzang--outcome-create)))
    (zwanenzang--pull-into outcome root)
    (zwanenzang--report-outcome "pulled" root outcome)))

;;;; Comments

(defvar-local zwanenzang--comment-target nil
  "Compose target: heading marker, scope marker, ticket id and directory.")

(defvar-local zwanenzang--comment-window-configuration nil
  "Window configuration before displaying this compose buffer.")

(defvar-local zwanenzang--comment-return-to nil
  "Source point before composing, which window configurations do not save.")

(defvar zwanenzang-comment-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'zwanenzang-comment-send)
    (define-key map (kbd "C-c C-k") #'zwanenzang-comment-abort)
    map))

(define-derived-mode zwanenzang-comment-mode org-mode "ZW-Comment"
  "Compose an append-only tracker comment.
C-c C-c sends; C-c C-k aborts.  The buffer contains only comment text.")

(defun zwanenzang--comment-heading ()
  "The ticket heading for a note at point, or nil.
A named document belongs to its direct parent ticket, not an inherited ID.
Structural headings and nested scopes never borrow an ancestor's ticket."
  (when (derived-mode-p 'org-mode)
    (org-with-wide-buffer
     (unless (org-before-first-heading-p)
       (org-back-to-heading t)
       (when (org-entry-get nil "ZWANENZANG" t)
         (when (and (org-entry-get nil "ZWANENZANG_DOC")
                    (not (org-entry-get nil "ZWANENZANG_ID"))
                    (not (org-entry-get nil "ZWANENZANG")))
           (org-up-heading-safe))
         (when (or (org-entry-get nil "ZWANENZANG_ID")
                   (and (org-get-todo-state)
                        (not (org-entry-get nil "ZWANENZANG"))
                        (not (org-entry-get nil "ZWANENZANG_DOC"))
                        (not (org-entry-get nil "ZWANENZANG_INBOX"))))
           (zwanenzang--heading-marker)))))))

;;;###autoload
(defun zwanenzang-comment ()
  "Compose a tracker comment for the ticket or its named document at point.
Sending appends one comment and pulls the scope, without pushing Org edits.
The optional CLI link field is not exposed by this command."
  (interactive)
  (let* ((root (zwanenzang--root-at-point))
         (heading (or (zwanenzang--comment-heading)
                      (user-error "zwanenzang: point is not on a ticket or its named document")))
         (id (org-entry-get heading "ZWANENZANG_ID"))
         (dir (zwanenzang--scope-directory root)))
    (unless id
      (user-error "zwanenzang: push this ticket before adding a comment"))
    (let ((buffer (generate-new-buffer "*zwanenzang comment*"))
          (windows (current-window-configuration))
          (return-to (point-marker)))
      (pop-to-buffer buffer)
      (zwanenzang-comment-mode)
      (setq zwanenzang--comment-target (list heading root id dir)
            zwanenzang--comment-window-configuration windows
            zwanenzang--comment-return-to return-to)
      (setq header-line-format "Comment: C-c C-c send, C-c C-k abort"))))

(defun zwanenzang--comment-close ()
  "Close the current draft and restore its pre-compose windows and point."
  (let ((windows zwanenzang--comment-window-configuration)
        (return-to zwanenzang--comment-return-to))
    (set-buffer-modified-p nil)
    (kill-buffer (current-buffer))
    (set-window-configuration windows)
    (when (marker-buffer return-to)
      (with-current-buffer (marker-buffer return-to)
        (goto-char return-to)))
    (set-marker return-to nil)))

(defun zwanenzang-comment-abort ()
  "Discard this compose buffer without writing a comment."
  (interactive)
  (unless zwanenzang--comment-target
    (user-error "zwanenzang: not a comment compose buffer"))
  (zwanenzang--comment-close))

(defun zwanenzang-comment-send ()
  "Send this comment once, then pull its source scope.
A refused write retains the draft.  Once accepted locally, the draft is
closed even if publication or the subsequent pull fails, to avoid resend."
  (interactive)
  (unless zwanenzang--comment-target
    (user-error "zwanenzang: not a comment compose buffer"))
  (pcase-let* ((`(,heading ,root ,id ,dir) zwanenzang--comment-target)
               (draft (current-buffer))
               (text (buffer-substring-no-properties (point-min) (point-max))))
    (when (string-empty-p (string-trim text))
      (user-error "zwanenzang: comment is empty"))
    (unless (and (marker-buffer heading) (marker-buffer root))
      (user-error "zwanenzang: comment source buffer was killed"))
    (with-current-buffer (marker-buffer heading)
      (org-with-wide-buffer
       (goto-char heading)
       (unless (and (org-at-heading-p)
                    (equal id (org-entry-get nil "ZWANENZANG_ID"))
                    (= root (zwanenzang--scope-root))
                    (equal dir (zwanenzang--scope-directory root)))
         (user-error "zwanenzang: comment target changed; draft retained"))
       (let* ((tickets (car (zwanenzang--scan root)))
              (known (zwanenzang--known-tickets dir))
              (blocked (zwanenzang--blocked-headings tickets known))
              (target (seq-find (lambda (tk) (equal id (plist-get tk :id))) tickets))
              (read (funcall zwanenzang--call dir '("read")
                             '((cursors . nil) (since . :null))))
              (refusal (zwanenzang--tracker-mismatch "comment" root dir read)))
         (when refusal (user-error "%s" refusal))
         (unless (and target (not (assq target blocked)))
           (user-error "zwanenzang: foreign or duplicate comment target; draft retained"))
         (let* ((result (funcall zwanenzang--call dir '("apply")
                                 `((changes . [((op . "comment") (ticket . ,id)
                                               (data . ((text . ,text))))]))))
                (outcome (zwanenzang--outcome-create)))
           ;; Acceptance is the boundary: never offer to resend after this.
           (with-current-buffer draft
             (zwanenzang--comment-close))
           (zwanenzang--note-sync outcome (alist-get 'sync result))
           (condition-case err
               (zwanenzang--pull-into outcome root)
             (error
              (push (format "Comment saved locally; pull failed: %s. Pull again; do not resend."
                            (error-message-string err))
                    (zwanenzang--outcome-problems outcome))
              (setf (zwanenzang--outcome-pull outcome) (zwanenzang--pull-create))))
           (zwanenzang--report-outcome "comment saved in" root outcome)))))))

(defun zwanenzang--org-add-note (original &rest args)
  "Redirect ORIGINAL with ARGS on tickets and their named documents."
  (if (and zwanenzang-redirect-org-notes (not current-prefix-arg)
           (zwanenzang--comment-heading))
      (zwanenzang-comment)
    (apply original args)))

(advice-add 'org-add-note :around #'zwanenzang--org-add-note)

;;;; Showing branches

(defcustom zwanenzang-show-branches-to-tickets t
  "Make `org-fold-show-branches' stop at ticket headings in scopes.
That is what \\[org-kill-note-or-show-branches] uses.  It then shows the
human's structure and the ticket headings in it, child tickets included,
but not the rest of what a ticket nests: named documents and the human's
own subheadings stay folded.  Outside scopes Org behaves normally."
  :type 'boolean)

(defun zwanenzang--branch-ticket-p (in-scope)
  "Whether the heading at point is a ticket heading, IN-SCOPE or not.
As in `zwanenzang--scan-all', a heading with a TODO keyword and no
identity is a new ticket unless it is the inbox or a document."
  (and in-scope
       (not (org-entry-get nil "ZWANENZANG"))
       (or (org-entry-get nil "ZWANENZANG_ID")
           (and (org-get-todo-state)
                (not (org-entry-get nil "ZWANENZANG_DOC"))
                (not (equal (org-entry-get nil "ZWANENZANG_INBOX") "t"))))
       t))

(defun zwanenzang--show-branches-to-tickets ()
  "Show the subheadings of this heading down to ticket headings.
Below a ticket heading only its child tickets are shown.  A heading that
stays hidden hides its whole subtree.  Nothing is folded here: like
`org-fold-show-branches', this only reveals heading lines."
  (save-excursion
    (org-with-limited-levels
     (org-back-to-heading t)
     (let* ((in-scope (and (org-entry-get nil "ZWANENZANG" t) t))
            (end (save-excursion (org-end-of-subtree t t)))
            ;; (LEVEL IN-SCOPE TICKET) for the shown headings above point.
            (stack (list (list (org-current-level) in-scope
                               (zwanenzang--branch-ticket-p in-scope)))))
       (org-fold-heading nil)
       (outline-next-heading)
       (while (< (point) end)
         (let ((level (org-current-level)))
           (while (>= (car (car stack)) level) (pop stack))
           (let* ((above (car stack))
                  (scope (or (nth 1 above)
                             (and (org-entry-get nil "ZWANENZANG") t)))
                  (ticket (zwanenzang--branch-ticket-p scope)))
             (if (and (nth 2 above) (not ticket))
                 (org-end-of-subtree t t)
               (org-fold-heading nil)
               (push (list level scope ticket) stack)
               (outline-next-heading)))))))))

(defun zwanenzang--show-branches-scoped-p ()
  "Whether the subtree at point is in a scope or contains a scope root."
  (save-excursion
    (org-back-to-heading t)
    (or (org-entry-get nil "ZWANENZANG" t)
        (let ((end (save-excursion (org-end-of-subtree t t))))
          (re-search-forward "^[ \t]*:ZWANENZANG:" end t)))))

(defun zwanenzang--org-show-branches (original &rest args)
  "Call ORIGINAL with ARGS, unless the heading at point has tickets below it.
See `zwanenzang-show-branches-to-tickets'."
  (if (and zwanenzang-show-branches-to-tickets
           (derived-mode-p 'org-mode)
           (not (org-before-first-heading-p))
           (zwanenzang--show-branches-scoped-p))
      (zwanenzang--show-branches-to-tickets)
    (apply original args)))

(advice-add 'org-fold-show-branches :around #'zwanenzang--org-show-branches)

;;;; Push

;; A push compares each heading with its sync state and sends Org's value
;; for what differs, whatever the tracker has now: the human wins, and the
;; agent's value stays in history.  Field conflicts are therefore pushed
;; like any edit, and the pull that ends the push clears their notes.
;; Blocked headings send nothing; that pull is also what reports them.

(cl-defstruct (zwanenzang--plan (:constructor zwanenzang--plan-create)
                                (:copier nil))
  "The changes one scope's push will send."
  changes                               ; newest first
  news                                  ; (MARKER . CHANGE INDEX) of creates
  revived                               ; markers of headings being unarchived
  lines)                                ; report lines, newest first

(defun zwanenzang--plan-add (plan op ref data)
  "Add a change to PLAN: OP on the ticket REF, nil for a create, with DATA."
  (push `((op . ,op) ,@(and ref `((ticket . ,ref))) (data . ,data))
        (zwanenzang--plan-changes plan)))

(defun zwanenzang--plan-line (plan format &rest args)
  "Add a line to PLAN's report, formatted from FORMAT and ARGS."
  (push (apply #'format format args) (zwanenzang--plan-lines plan)))

(defun zwanenzang--edited-p (hash base empty)
  "Whether a value hashing to HASH differs from BASE, its hash as last synced.
BASE is `:unknown' when nothing was recorded; then any value counts as
edited unless EMPTY, so a heading with no sync state cannot wipe a field."
  (if (eq base :unknown) (not empty) (not (equal hash base))))

(defun zwanenzang--plan-up-blocked-p (plan up targets)
  "Whether UP, the :up of a scanned heading, cannot be a parent.
It is a new ticket PLAN does not create, or an id in the hash set TARGETS."
  (if (markerp up)
      (not (assq up (zwanenzang--plan-news plan)))
    (and up (gethash up targets))))

(defun zwanenzang--plan-ref (plan up)
  "The reference to UP, the :up of a scanned heading, in PLAN's request."
  (if (markerp up)
      `((created . ,(cdr (assq up (zwanenzang--plan-news plan)))))
    up))

(defun zwanenzang--heading-label ()
  "How the report names the heading at point, which may have no number yet."
  (string-join (delq nil (list (or (org-entry-get nil "ZWANENZANG_NUMBER")
                                   (org-entry-get nil "ZWANENZANG_ID"))
                               (plist-get (zwanenzang--heading) :title)))
               " "))

(defun zwanenzang--plan-doc (plan ref name ticket texts)
  "Add to PLAN the document NAME of ticket REF, the heading at point's text.
TICKET and TEXTS are the ticket's state and document text, nil when new.
The base is the current version, so a stale one cannot refuse the batch."
  (let* ((local (zwanenzang--entry-text))
         (symbol (intern name))
         (version (zwanenzang--null (alist-get 'current (alist-get symbol (alist-get 'documents ticket)))))
         (base (or (org-entry-get nil (if (equal name "description")
                                          "ZWANENZANG_DESC_HASH"
                                        "ZWANENZANG_HASH"))
                   :unknown)))
    (when (and (zwanenzang--edited-p (zwanenzang--hash local) base (string-empty-p local))
               (not (equal local (zwanenzang--remote-text texts symbol))))
      (zwanenzang--plan-add plan "doc" ref
                            `((name . ,name) (text . ,local) (base . ,(or version :null)))))))

(defun zwanenzang--plan-docs (plan ref ticket texts hidden)
  "Add to PLAN the named documents of ticket REF, the heading at point.
TICKET and TEXTS are as in `zwanenzang--plan-doc'; HIDDEN lists the
names that are never pushed."
  (let (seen)
    (dolist (doc (zwanenzang--doc-headings))
      (let ((name (car doc)))
        (cond
         ((equal name "description")
          (zwanenzang--plan-line plan "%s: document heading \"description\" not pushed: %s"
                                 (zwanenzang--heading-label)
                                 "the description is the ticket's body"))
         ((member name hidden)
          (zwanenzang--plan-line plan "%s: document %s not pushed: it is in ZWANENZANG_HIDE_DOCS"
                                 (zwanenzang--heading-label) name))
         ((member name seen)
          (zwanenzang--plan-line plan "%s: second heading for document %s not pushed"
                                 (zwanenzang--heading-label) name))
         (t
          (push name seen)
          (save-excursion
            (goto-char (cdr doc))
            (zwanenzang--plan-doc plan ref name ticket texts))))))))

(defun zwanenzang--plan-fields (plan heading ref entry map hidden targets &optional known)
  "Add to PLAN what differs from sync state on HEADING, a scanned heading at point.
REF names its ticket in the request.  ENTRY is its read result, nil for a
new ticket.  MAP is the keyword map, HIDDEN the hidden documents and
TARGETS the ids that cannot be parents.  KNOWN maps all tracker ids to
summaries for resolving dependency numbers, including absent prerequisites."
  (let* ((ticket (alist-get 'ticket entry))
         (shown (zwanenzang--heading))
         (keyword (plist-get shown :keyword))
         (title (plist-get shown :title))
         (tags (zwanenzang--tracker-tags (plist-get shown :tags)))
         (sync (zwanenzang--parse-sync (org-entry-get nil "ZWANENZANG_SYNC")))
         (up (plist-get heading :up)))
    (when ticket
      (when (and (eq (alist-get 'archived ticket) t) (org-entry-get nil "ARCHIVE_TIME"))
        (zwanenzang--plan-add plan "unarchive" ref nil)
        (push (plist-get heading :marker) (zwanenzang--plan-revived plan)))
      ;; Status goes by keyword: a draft shown as TODO stays draft until
      ;; the keyword changes, and two statuses of one keyword agree.
      (let ((base (cdr (assoc (zwanenzang--sync-get sync 'status) map)))
            (remote (cdr (assoc (alist-get 'status ticket) map))))
        (unless (or (equal keyword base) (equal keyword remote))
          (zwanenzang--plan-add plan "status" ref `((to . ,(car (rassoc keyword map)))))))
      (when (and (zwanenzang--edited-p (zwanenzang--hash title)
                                       (zwanenzang--sync-get sync 'title) nil)
                 (not (equal title (string-trim (alist-get 'title ticket)))))
        (zwanenzang--plan-add plan "title" ref `((to . ,title)))))
    (let* ((priority (plist-get shown :priority))
           (key (number-to-string (or priority -1)))
           (base (or (alist-get 'priority sync) "-1")))
      (when (and (not (equal key base))
                 (not (equal priority (zwanenzang--null (alist-get 'priority ticket)))))
        (zwanenzang--plan-add plan "priority" ref `((to . ,(or priority :null))))))
    (when (zwanenzang--edited-p (zwanenzang--tags-hash tags)
                                (zwanenzang--sync-get sync 'tags) (null tags))
      (let ((remote (alist-get 'tags ticket)))
        (dolist (tag (seq-difference tags remote))
          (zwanenzang--plan-add plan "tag" ref `((tag . ,tag))))
        (dolist (tag (seq-difference remote tags))
          (zwanenzang--plan-add plan "untag" ref `((tag . ,tag))))))
    (let* ((refs (zwanenzang--dependency-refs))
           (base (zwanenzang--sync-get sync 'depends)))
      (when (zwanenzang--edited-p (zwanenzang--tags-hash refs) base (null refs))
        (let (local)
          ;; Never silently drop malformed/unknown references from a push.
          ;; Refuse before apply, so no other field is partially written.
          (dolist (number refs)
            (let (matches)
              (when known
                (maphash (lambda (id summary)
                           (when (and (integerp (alist-get 'number summary))
                                      (equal number (alist-get 'display summary)))
                             (push id matches)))
                         known))
              (unless (= (length matches) 1)
                (user-error "zwanenzang: %s: unknown or ambiguous prerequisite %s"
                            (zwanenzang--heading-label) number))
              (push (car matches) local)))
          (let ((remote (alist-get 'depends_on ticket)))
            (dolist (id (seq-difference remote local #'equal))
              (zwanenzang--plan-add plan "undepend" ref `((to . ,id))))
            (dolist (id (seq-difference local remote #'equal))
              (zwanenzang--plan-add plan "depend" ref `((to . ,id))))))))
    ;; Parent goes by nesting, and only a change in nesting sends it: a
    ;; ticket parked in the inbox keeps its tracker parent.
    (let ((base (zwanenzang--sync-get sync 'nest))
          (remote (zwanenzang--null (alist-get 'parent ticket))))
      (when (and (if (eq base :unknown) up (not (equal up base)))
                 (not (equal up remote)))
        (if (zwanenzang--plan-up-blocked-p plan up targets)
            (zwanenzang--plan-line plan "%s: parent not pushed: the ticket heading above it is blocked"
                                   (zwanenzang--heading-label))
          (zwanenzang--plan-add plan "parent" ref
                                `((to . ,(or (zwanenzang--plan-ref plan up) :null)))))))
    (zwanenzang--plan-doc plan ref "description" ticket (alist-get 'documents entry))
    (zwanenzang--plan-docs plan ref ticket (alist-get 'documents entry) hidden)))

(defun zwanenzang--plan-create-ticket (plan heading map targets)
  "Add to PLAN the create for HEADING, a scanned new ticket at point.
Unless something blocks it, which is reported.  MAP and TARGETS are as in
`zwanenzang--plan-fields'."
  (let* ((shown (zwanenzang--heading))
         (keyword (plist-get shown :keyword))
         (title (plist-get shown :title))
         (status (car (rassoc keyword map)))
         (line (line-number-at-pos (point) t)))
    (cond
     ((not status)
      (zwanenzang--plan-line plan "line %d: \"%s\" not created: keyword %s has no status"
                             line title keyword))
     ((string-empty-p title)
      (zwanenzang--plan-line plan "line %d: not created: the heading has no title" line))
     ((zwanenzang--plan-up-blocked-p plan (plist-get heading :up) targets)
      (zwanenzang--plan-line plan "line %d: \"%s\" not created: the ticket heading above it is blocked"
                             line title))
     (t
      (push (cons (plist-get heading :marker) (length (zwanenzang--plan-changes plan)))
            (zwanenzang--plan-news plan))
      (zwanenzang--plan-add plan "create" nil `((title . ,title) (status . ,status)))))))

(defun zwanenzang--plan-label (change)
  "What the report calls the field CHANGE touches."
  (pcase (alist-get 'op change)
    ((or "tag" "untag") "tags")
    ((or "depend" "undepend") "dependencies")
    ("doc" (let ((name (alist-get 'name (alist-get 'data change))))
             (if (equal name "description") name (format "document %s" name))))
    (op op)))

(defun zwanenzang--plan-push (headings blocked entries map hidden &optional known)
  "The plan of one push, comparing Org with a read; the buffer is not changed.
HEADINGS is from `zwanenzang--scan-all', BLOCKED from
`zwanenzang--blocked-headings', ENTRIES the tickets of the read, MAP the
keyword map and HIDDEN the hidden documents.  Creates come first, so later
changes can refer to them.  The rest go in buffer order, ancestors first,
so a reshuffled nesting has no moment with a parent cycle.  KNOWN maps all
tracker ids to summaries for resolving dependency numbers."
  (let ((plan (zwanenzang--plan-create))
        (read (make-hash-table :test #'equal))
        (targets (make-hash-table :test #'equal)))
    (dolist (b blocked)
      (puthash (plist-get (car b) :id) t targets))
    (dolist (entry entries)
      (let ((ticket (alist-get 'ticket entry)))
        (puthash (alist-get 'id ticket) entry read)
        (when (eq (alist-get 'tombstoned ticket) t)
          (puthash (alist-get 'id ticket) t targets))))
    (dolist (h headings)
      (unless (plist-get h :id)
        (save-excursion
          (goto-char (plist-get h :marker))
          (zwanenzang--plan-create-ticket plan h map targets))))
    (dolist (h headings)
      (save-excursion
        (goto-char (plist-get h :marker))
        (let* ((id (plist-get h :id))
               (entry (and id (gethash id read)))
               (new (assq (plist-get h :marker) (zwanenzang--plan-news plan)))
               (shown (zwanenzang--heading)))
          (cond
           (new
            (zwanenzang--plan-fields plan h `((created . ,(cdr new))) nil map hidden targets known))
           ((or (not id) (gethash id targets)))
           ((not (and (rassoc (plist-get shown :keyword) map)
                      (assoc (alist-get 'status (alist-get 'ticket entry)) map))))
           ((string-empty-p (plist-get shown :title))
            (zwanenzang--plan-line plan "%s: not pushed: the heading has no title" id))
           (t
            (zwanenzang--plan-fields plan h id entry map hidden targets known))))))
    ;; Remove old edges before adding replacements, avoiding transient cycles.
    ;; Creates remain first and in order: their change-index references stay valid.
    (setf (zwanenzang--plan-changes plan)
          (reverse (cl-stable-sort (reverse (zwanenzang--plan-changes plan)) #'<
                                  :key (lambda (change)
                                         (pcase (alist-get 'op change)
                                           ("create" 0) ("undepend" 1) (_ 2))))))
    plan))

(defun zwanenzang--written-fields (changes results)
  "What `apply' changed on existing tickets, as an alist of id and field labels.
CHANGES is the request's list and RESULTS the result's, position by
position.  A change the tracker took as a no-op is left out, and so are
new tickets, which the report names as created."
  (let (fields)
    (cl-mapc (lambda (change result)
               (let ((id (alist-get 'ticket change)))
                 (when (and (stringp id) (eq (alist-get 'written result) t))
                   (let ((label (zwanenzang--plan-label change))
                         (cell (assoc id fields)))
                     (cond ((null cell) (push (list id label) fields))
                           ((not (member label (cdr cell)))
                            (setcdr cell (append (cdr cell) (list label)))))))))
             changes results)
    (nreverse fields)))

(defun zwanenzang--drop-archive-properties ()
  "Remove what `org-archive-subtree' left on the entry at point."
  (dolist (property (org-entry-properties nil 'standard))
    (when (string-prefix-p "ARCHIVE_" (car property))
      (org-entry-delete nil (car property)))))

(defun zwanenzang--write-back (plan created outcome)
  "Write what `apply' returned for PLAN to the buffer, saving it if it must.
CREATED is the result's map of create positions to ids.  The identity of
a new ticket lives only in the buffer until saved, and without it the next
push would create the ticket again, so a push that created one saves the
file; nothing else does."
  (pcase-dolist (`(,marker . ,index) (reverse (zwanenzang--plan-news plan)))
    (org-entry-put marker "ZWANENZANG_ID"
                   (alist-get (intern (number-to-string index)) created))
    (save-excursion
      (goto-char marker)
      (zwanenzang--ensure-org-id)))
  (dolist (marker (zwanenzang--plan-revived plan))
    (save-excursion
      (goto-char marker)
      (zwanenzang--drop-archive-properties)))
  (when (zwanenzang--plan-news plan)
    (if buffer-file-name
        (progn
          (save-buffer)
          (setf (zwanenzang--outcome-saved outcome) t)
          (push (format "saved %s: it holds the ids of the new tickets" buffer-file-name)
                (zwanenzang--outcome-info outcome)))
      (push "not saved: the buffer visits no file, and the new tickets' ids are only in it"
            (zwanenzang--outcome-problems outcome)))))

(defun zwanenzang--send-plan (plan dir outcome)
  "Send PLAN to the tracker at DIR and write back what it returns to Org.
An empty plan sends nothing.  A read-only buffer is refused first, so
identities cannot fail to land for that reason.  If writing back fails
anyway, the tickets exist, so the error lists them for the human to
recover.  OUTCOME collects the report."
  (let ((changes (reverse (zwanenzang--plan-changes plan))))
    (when changes
      (when buffer-read-only
        (user-error "zwanenzang: %s is read-only; nothing was sent" (buffer-name)))
      (let* ((result (funcall zwanenzang--call dir '("apply")
                              `((changes . ,(vconcat changes)))))
             (created (alist-get 'created result))
             (labels (mapcar (lambda (ticket) (cons (alist-get 'id ticket)
                                                    (zwanenzang--label ticket)))
                             (alist-get 'tickets result)))
             (new-ids (mapcar (lambda (news)
                                (alist-get (intern (number-to-string (cdr news))) created))
                              (reverse (zwanenzang--plan-news plan)))))
        (condition-case err
            (zwanenzang--write-back plan created outcome)
          (error
           (user-error "zwanenzang: the tracker took the push, but writing it to Org failed: %s; %s"
                       (error-message-string err)
                       (if new-ids
                           (format "created %s"
                                   (mapconcat (lambda (id)
                                                (format "%s (%s)" (cdr (assoc id labels)) id))
                                              new-ids ", "))
                         "no tickets were created"))))
        (dolist (id new-ids)
          (cl-incf (zwanenzang--outcome-created outcome))
          (push (format "created %s" (cdr (assoc id labels)))
                (zwanenzang--outcome-info outcome)))
        (pcase-dolist (`(,id . ,what)
                       (zwanenzang--written-fields changes (alist-get 'results result)))
          (cl-incf (zwanenzang--outcome-pushed outcome))
          (push (format "pushed %s: %s" (cdr (assoc id labels)) (string-join what ", "))
                (zwanenzang--outcome-info outcome)))
        (zwanenzang--note-sync outcome (alist-get 'sync result))))))

(defun zwanenzang--push-attempt (root dir outcome)
  "Read the scope at ROOT from the tracker at DIR, and apply what differs.
Refusing the scope, or failing, adds nothing to OUTCOME's lines."
  (let* ((headings (plist-get (zwanenzang--scan-all root) :headings))
         (tickets (seq-filter (lambda (h) (plist-get h :id)) headings))
         (known (zwanenzang--known-tickets dir))
         (blocked (zwanenzang--blocked-headings tickets known))
         (result (zwanenzang--read-scope root dir tickets blocked))
         (refused (zwanenzang--tracker-mismatch "push" root dir result)))
    (if refused
        (setf (zwanenzang--outcome-refused outcome) refused)
      (let ((plan (zwanenzang--plan-push
                   headings blocked (alist-get 'tickets result)
                   (car (zwanenzang--keyword-map (org-entry-get root "ZWANENZANG_KEYWORDS")
                                                 (alist-get 'statuses (alist-get 'tracker result))
                                                 org-todo-keywords-1))
                   (remove "description" (zwanenzang--hide-docs root)) known)))
        (zwanenzang--send-plan plan dir outcome)
        (setf (zwanenzang--outcome-problems outcome)
              (append (zwanenzang--plan-lines plan) (zwanenzang--outcome-problems outcome)))))))

(defun zwanenzang--push-scope (root outcome)
  "Push the scope at ROOT and pull again, adding the result to OUTCOME.
A failed apply signals, having written nothing to the tracker or the
buffer.  A document version landing between the read and the apply, which
only another writer in this clone can cause, gets one more try."
  (with-current-buffer (marker-buffer root)
    (zwanenzang--check-source-edit)
    (org-with-wide-buffer
     (let ((case-fold-search nil)
           (dir (zwanenzang--scope-directory root)))
       (condition-case nil
           (zwanenzang--push-attempt root dir outcome)
         (zwanenzang-stale-doc-base
          (zwanenzang--push-attempt root dir outcome)))
       (unless (zwanenzang--outcome-refused outcome)
         (zwanenzang--pull-into outcome root))))))

;;;###autoload
(defun zwanenzang-push ()
  "Push the human's edits in the scope containing point to the tracker.
Whatever differs from the last sync is sent, new tickets included, and
Org's value wins.  A pull follows, so numbers and cursors land.  The
buffer is saved only when new tickets were created, right after their ids
are written, since losing those would create them again.  A report goes
to the `*zwanenzang*' buffer."
  (interactive)
  (let ((root (zwanenzang--root-at-point))
        (outcome (zwanenzang--outcome-create)))
    (zwanenzang--push-scope root outcome)
    (zwanenzang--report-outcome "pushed" root outcome)))

(defun zwanenzang--remember-dependencies (pull)
  "Retain PULL's successful local read for interactive dependency checks."
  (let ((root (zwanenzang--pull-root pull)))
    (with-current-buffer (marker-buffer root)
      (setq zwanenzang--dependency-snapshots
            (cons (list :root (copy-marker root)
                        :location (org-entry-get root "ZWANENZANG")
                        :tracker (zwanenzang--pull-tracker pull)
                        :tickets (zwanenzang--pull-known pull)
                        :statuses (zwanenzang--pull-statuses pull)
                        :time (float-time))
                  (seq-remove
                   (lambda (snapshot)
                     (let ((marker (plist-get snapshot :root)))
                       (or (not (marker-buffer marker)) (= marker root))))
                   zwanenzang--dependency-snapshots))))))

(defun zwanenzang--sync-scope (root)
  "Run the CLI's sync, a pull and a push on the scope at ROOT; report the result."
  (let ((outcome (zwanenzang--outcome-create))
        (dir (with-current-buffer (marker-buffer root) (zwanenzang--scope-directory root))))
    (let ((sync (alist-get 'sync (funcall zwanenzang--call dir '("sync")))))
      (zwanenzang--note-sync outcome sync)
      (zwanenzang--pull-into outcome root)
      (unless (zwanenzang--outcome-refused outcome)
        (zwanenzang--push-scope root outcome)
        (when (and (not (zwanenzang--outcome-refused outcome))
                   (not (zwanenzang--null (alist-get 'error sync)))
                   (null (zwanenzang--outcome-problems outcome)))
          (zwanenzang--remember-dependencies (zwanenzang--outcome-pull outcome)))))
    (zwanenzang--report-outcome "synced" root outcome)))

;;;###autoload
(defun zwanenzang-sync ()
  "Sync the scope containing point: CLI sync, then pull, then push.
Failing to reach the remote is reported, not an error: work continues
against the local clone."
  (interactive)
  (zwanenzang--sync-scope (zwanenzang--root-at-point)))

(defun zwanenzang--scope-roots ()
  "Markers at every scope root in the current buffer, in buffer order."
  (org-with-wide-buffer
   (goto-char (point-min))
   (let ((case-fold-search t)
         roots)
     (while (re-search-forward "^[ \t]*:ZWANENZANG:[ \t]" nil t)
       (unless (org-before-first-heading-p)
         (save-excursion
           (org-back-to-heading t)
           (when (org-entry-get nil "ZWANENZANG")
             (push (zwanenzang--heading-marker) roots)))))
     (nreverse roots))))

;;;###autoload
(defun zwanenzang-sync-all ()
  "Sync every scope in `zwanenzang-org-files', each like `zwanenzang-sync'.
A scope or file that fails, in any way, is reported and the others run."
  (interactive)
  (let ((done 0) failures)
    (dolist (file (zwanenzang--org-files))
      (condition-case err
          (if (not (file-exists-p file))
              (push (format "%s: no such file" file) failures)
            (with-current-buffer (find-file-noselect file)
              (dolist (root (zwanenzang--scope-roots))
                (condition-case err
                    (progn (zwanenzang--sync-scope root)
                           (cl-incf done))
                  (error
                   (push (format "%s: %s: %s" file
                                 (org-with-wide-buffer (zwanenzang--scope-name root))
                                 (error-message-string err))
                         failures))))))
        (error
         (push (format "%s: %s" file (error-message-string err)) failures))))
    (zwanenzang-report (format "zwanenzang: synced %d scopes, %d failed" done (length failures))
                       (reverse failures))))

;;;; Resolve duplicate tickets

(defun zwanenzang--prose-synced-p (marker)
  "Whether MARKER's description and all present documents match saved hashes.
Missing state is not evidence that a copy is unchanged."
  (save-excursion
    (goto-char marker)
    (and (equal (org-entry-get nil "ZWANENZANG_DESC_HASH")
                (zwanenzang--hash
                 (zwanenzang--body-description (zwanenzang--body))))
         (seq-every-p
          (lambda (doc)
            (save-excursion
              (goto-char (cdr doc))
              (equal (org-entry-get nil "ZWANENZANG_HASH")
                     (zwanenzang--hash
                      (zwanenzang--document-text)))))
          (zwanenzang--doc-headings)))))

(defun zwanenzang--detach-entry ()
  "Turn the entry at point into untracked Org without deleting its text.
Remove the keyword too, so push cannot create a replacement ticket."
  (let ((body (if (org-entry-get nil "ZWANENZANG_DOC_FORMAT")
                  (zwanenzang--compose-document '(("ZWANENZANG_CONFLICT")))
                (zwanenzang--compose-body (zwanenzang--body) '(("ZWANENZANG_CONFLICT"))))))
    (zwanenzang--write-body body))
  (dolist (property (org-entry-properties nil 'standard))
    (when (string-prefix-p "ZWANENZANG" (car property))
      (org-entry-delete nil (car property))))
  (let ((heading (zwanenzang--heading)))
    (zwanenzang--set-heading
     nil (plist-get heading :title)
     (remove "zz_conflict" (plist-get heading :tags)))))

;;;###autoload
(defun zwanenzang-resolve-duplicate ()
  "Choose which duplicate at or above point keeps its tracker identity.
Offer the sole copy matching saved prose hashes as a default, otherwise
require an explicit choice.  After confirmation detach all other copies
in this scope, retaining their text.  Refuse if a copy to detach contains
ticket headings: move those children first.  No CLI calls or file saves
are made; the entire edit is undoable."
  (interactive)
  (let ((root (zwanenzang--root-at-point)))
    (org-with-wide-buffer
     (when buffer-read-only (user-error "zwanenzang: buffer is read-only"))
     (let* ((start (zwanenzang--ticket-heading-at-point root))
            (id (org-entry-get start "ZWANENZANG_ID"))
            (copies (seq-filter
                     (lambda (h) (equal id (plist-get h :id)))
                     (car (zwanenzang--scan root))))
            (choices (mapcar
                      (lambda (h)
                        (let ((marker (plist-get h :marker)))
                          (cons (save-excursion
                                  (goto-char marker)
                                  (format "Line %d: %s" (line-number-at-pos)
                                          (org-get-heading t t t t)))
                                marker)))
                      copies))
            (unchanged (seq-filter
                        (lambda (choice) (zwanenzang--prose-synced-p (cdr choice)))
                        choices)))
       (unless (> (length choices) 1)
         (user-error "zwanenzang: this ticket has no duplicate in this scope"))
       (let* ((default (and (= (length unchanged) 1) (caar unchanged)))
              (choice (completing-read
                       "Keep tracker identity on: " choices nil t nil nil default))
              (keep (cdr (assoc choice choices))))
         (unless keep (user-error "zwanenzang: choose a heading explicitly"))
         ;; Check every copy before editing any: detaching an ancestor would
         ;; otherwise silently change its children's parent on the next push.
         (let ((headings (plist-get (zwanenzang--scan-all root) :headings)))
           (dolist (copy choices)
             (unless (eq (cdr copy) keep)
               (let ((end (zwanenzang--subtree-end (cdr copy))))
                 (when (seq-some
                        (lambda (h)
                          (let ((marker (plist-get h :marker)))
                            (and (> marker (cdr copy)) (< marker end))))
                        headings)
                   (user-error
                    "zwanenzang: %s contains ticket headings; move them first"
                    (car copy)))))))
         (when (yes-or-no-p
                (format "Keep %s; turn %d other copies into plain Org? "
                        choice (1- (length copies))))
           (zwanenzang--one-undo-step
             (dolist (copy choices)
               (unless (eq (cdr copy) keep)
                 (goto-char (cdr copy))
                 (let ((docs (zwanenzang--doc-headings)))
                   (zwanenzang--detach-entry)
                   (dolist (doc docs)
                     (goto-char (cdr doc))
                     (zwanenzang--detach-entry))))))
           (goto-char keep)
           (message "zwanenzang: duplicate resolved; buffer not saved")))))))

;;;; Adopt foreign tickets

(defun zwanenzang--clear-foreign-state (&optional document)
  "Remove tracker state on this entry, keeping DOCUMENT's name when non-nil.
Human properties, Org IDs and body text are retained."
  (dolist (property (org-entry-properties nil 'standard))
    (when (and (string-prefix-p "ZWANENZANG" (car property))
               (not (and document (member (car property)
                                          '("ZWANENZANG_DOC" "ZWANENZANG_DOC_FORMAT")))))
      (org-entry-delete nil (car property))))
  (zwanenzang--drop-archive-properties)
  (when (member "zz_conflict" (org-get-tags nil t))
    (org-set-tags (remove "zz_conflict" (org-get-tags nil t))))
  (let ((drawers '(("ZWANENZANG_CONFLICT") ("ZWANENZANG_COMMENTS") ("ZWANENZANG_HIDDEN"))))
    (zwanenzang--write-body
     (if document
         (zwanenzang--compose-document drawers)
       (zwanenzang--compose-body (zwanenzang--body) drawers)))
    (when document
      (zwanenzang--put "ZWANENZANG_DOC_FORMAT" zwanenzang--document-format))))

;;;###autoload
(defun zwanenzang-adopt-foreign ()
  "Create the foreign ticket at point in this scope's tracker.
Keep its old tracker id as description text, not as identity.  Named
documents become new versions; child tickets are not adopted.  Like
create-on-push, save the file as soon as the new identity lands."
  (interactive)
  (let ((root (zwanenzang--root-at-point))
        (outcome (zwanenzang--outcome-create)))
    (org-with-wide-buffer
     (let* ((case-fold-search nil)
            (start (zwanenzang--ticket-heading-at-point root))
            (dir (zwanenzang--scope-directory root))
            (id (org-entry-get start "ZWANENZANG_ID"))
            (tickets (car (zwanenzang--scan root)))
            (known
             (progn
               (let* ((sync (alist-get 'sync (funcall zwanenzang--call dir '("sync"))))
                      (error (zwanenzang--null (alist-get 'error sync))))
                 (when error
                   (user-error "zwanenzang: cannot adopt without successful sync: %s"
                               error))
                 (zwanenzang--note-sync outcome sync))
               (zwanenzang--known-tickets dir)))
            (blocked (zwanenzang--blocked-headings tickets known))
            (result (zwanenzang--read-scope root dir tickets blocked))
            (refused (zwanenzang--tracker-mismatch "adopt" root dir result)))
       (when buffer-read-only
         (user-error "zwanenzang: buffer is read-only"))
       (when refused (user-error "%s" refused))
       (when (gethash id known)
         (user-error "zwanenzang: this ticket is known here, not foreign"))
       (goto-char start)
       (unless (org-get-todo-state)
         (user-error "zwanenzang: cannot adopt: the heading has no TODO keyword"))
       (let ((docs (zwanenzang--doc-headings))
             write-back-error
             (map (car (zwanenzang--keyword-map
                        (org-entry-get root "ZWANENZANG_KEYWORDS")
                        (alist-get 'statuses (alist-get 'tracker result))
                        org-todo-keywords-1))))
         (atomic-change-group
           (zwanenzang--clear-foreign-state)
           (zwanenzang--write-body
            (zwanenzang--compose-body
             (zwanenzang--body) nil
             (concat (string-trim-right
                      (zwanenzang--body-description (zwanenzang--body)))
                     "\n\nFormer tracker id: " id "\n")))
           (dolist (doc docs)
             (save-excursion
               (goto-char (cdr doc))
               (zwanenzang--clear-foreign-state t)))
           (let* ((headings (plist-get (zwanenzang--scan-all root) :headings))
                  (heading (seq-find (lambda (h) (= start (plist-get h :marker))) headings))
                  (plan (zwanenzang--plan-push
                         (list heading) blocked (alist-get 'tickets result) map
                         (remove "description" (zwanenzang--hide-docs root)) known)))
             (unless (zwanenzang--plan-news plan)
               (user-error "zwanenzang: cannot adopt: %s"
                           (string-join (zwanenzang--plan-lines plan) "; ")))
             (setf (zwanenzang--outcome-problems outcome)
                   (append (zwanenzang--plan-lines plan)
                           (zwanenzang--outcome-problems outcome)))
             ;; Roll back preparation only while the tracker has not taken
             ;; the create.  A save/write-back failure must retain any new id.
             (let* ((real zwanenzang--call)
                    applied
                    (zwanenzang--call
                     (lambda (directory args &optional input)
                       (prog1 (funcall real directory args input)
                         (when (equal args '("apply")) (setq applied t))))))
               (condition-case err
                   (zwanenzang--send-plan plan dir outcome)
                 (error (if applied (setq write-back-error err)
                          (signal (car err) (cdr err))))))))
         (when write-back-error
           (signal (car write-back-error) (cdr write-back-error))))
       (zwanenzang--pull-into outcome root)))
    (zwanenzang--report-outcome "adopted in" root outcome)))

;;;; Archive

(defun zwanenzang--archive-status (ticket map)
  "The closing status to send for TICKET at point, or nil to keep it.
MAP maps statuses to keywords.  Preserve remote done statuses unless the
human explicitly changed to a different done keyword since the last sync."
  (let* ((keyword (org-get-todo-state))
         (sync (zwanenzang--parse-sync (org-entry-get nil "ZWANENZANG_SYNC")))
         (base (cdr (assoc (zwanenzang--sync-get sync 'status) map)))
         (status (alist-get 'status ticket))
         (remote (cdr (assoc status map)))
         (local-done (member keyword org-done-keywords)))
    (unless (and (member remote org-done-keywords)
                 (not (and local-done
                           (not (equal keyword base))
                           (not (equal keyword remote)))))
      (let ((closing (car (rassoc (if local-done keyword (car org-done-keywords)) map))))
        (unless closing
          (user-error "zwanenzang: no mapped done keyword for archiving %s"
                      (alist-get 'id ticket)))
        (unless (equal closing status) closing)))))

(defun zwanenzang--archive-unpushed (heading)
  "Names of locally edited non-status fields on HEADING at point.
Compare with saved sync hashes, without compiling or sending a push."
  (let* ((shown (zwanenzang--heading))
         (sync (zwanenzang--parse-sync (org-entry-get nil "ZWANENZANG_SYNC")))
         (title (plist-get shown :title))
         (tags (zwanenzang--tracker-tags (plist-get shown :tags)))
         (depends (zwanenzang--dependency-refs))
         fields)
    (dolist (field `((title ,(zwanenzang--hash title) ,(string-empty-p title))
                     (tags ,(zwanenzang--tags-hash tags) ,(null tags))
                     (depends ,(zwanenzang--tags-hash depends) ,(null depends))))
      (when (zwanenzang--edited-p (nth 1 field)
                                 (zwanenzang--sync-get sync (car field))
                                 (nth 2 field))
        (push (symbol-name (car field)) fields)))
    (unless (equal (number-to-string (or (plist-get shown :priority) -1))
                   (or (alist-get 'priority sync) "-1"))
      (push "priority" fields))
    (let ((base (zwanenzang--sync-get sync 'nest))
          (nest (plist-get heading :nest)))
      (when (if (eq base :unknown) nest (not (equal base nest)))
        (push "parent" fields)))
    (cl-labels ((edited-text (property)
                 (let ((text (zwanenzang--entry-text)))
                   (zwanenzang--edited-p (zwanenzang--hash text)
                                        (or (org-entry-get nil property) :unknown)
                                        (string-empty-p text)))))
      (when (edited-text "ZWANENZANG_DESC_HASH") (push "description" fields))
      (dolist (doc (zwanenzang--doc-headings))
        (save-excursion
          (goto-char (cdr doc))
          (when (edited-text "ZWANENZANG_HASH")
            (push (format "document %s" (car doc)) fields)))))
    (nreverse fields)))

(defun zwanenzang--archive-subtree (root start end)
  "Close and archive known tickets between START and END in scope ROOT.
Only status and archive operations are sent; Org text is never rewritten."
  (zwanenzang--check-source-edit)
  (when (<= start root)
    (user-error "zwanenzang: archiving a scope root is not supported"))
  (save-excursion
    (goto-char start)
    (outline-next-heading)
    (while (< (point) end)
      (when (org-entry-get nil "ZWANENZANG")
        (user-error "zwanenzang: archived subtree contains a nested scope"))
      (outline-next-heading)))
  (let* ((tickets (car (zwanenzang--scan root)))
         (selected (seq-filter (lambda (tk)
                                 (let ((pos (plist-get tk :marker)))
                                   (and (<= start pos) (< pos end))))
                               tickets)))
    (when selected
      (let* ((dir (zwanenzang--scope-directory root))
             (known (zwanenzang--known-tickets dir))
             (blocked (zwanenzang--blocked-headings tickets known))
             (result (zwanenzang--read-scope root dir selected blocked))
             (refused (zwanenzang--tracker-mismatch "archive" root dir result))
             (mapping (zwanenzang--keyword-map
                       (org-entry-get root "ZWANENZANG_KEYWORDS")
                       (alist-get 'statuses (alist-get 'tracker result))
                       org-todo-keywords-1))
             (map (car mapping))
             (plan (zwanenzang--plan-create))
             (outcome (zwanenzang--outcome-create
                       :pull (zwanenzang--pull-create :root root :dir dir))))
        (when refused (user-error "%s" refused))
        (when (cdr mapping)
          (user-error "zwanenzang: %s" (string-join (cdr mapping) "; ")))
        (dolist (tk selected)
          (when (assq tk blocked)
            (user-error "zwanenzang: %s" (cdr (assq tk blocked)))))
        (dolist (tk selected)
          (save-excursion
            (goto-char (plist-get tk :marker))
            (let* ((id (plist-get tk :id))
                   (entry (seq-find (lambda (e)
                                      (equal id (alist-get 'id (alist-get 'ticket e))))
                                    (alist-get 'tickets result)))
                   (ticket (alist-get 'ticket entry))
                   (status (zwanenzang--archive-status ticket map))
                   (unpushed (zwanenzang--archive-unpushed tk)))
              (when (eq (alist-get 'tombstoned ticket) t)
                (user-error "zwanenzang: cannot archive tombstoned ticket %s" id))
              (when status
                (zwanenzang--plan-add plan "status" id `((to . ,status))))
              (zwanenzang--plan-add plan "archive" id nil)
              (when unpushed
                (push (format "%s: not pushed: %s; edits remain only in the Org archive. Push before archiving to send them to the tracker."
                              (zwanenzang--heading-label) (string-join unpushed ", "))
                      (zwanenzang--outcome-problems outcome))))))
        (zwanenzang--send-plan plan dir outcome)
        (zwanenzang--report-outcome "archived in" root outcome)))))

(defun zwanenzang--archive-hook ()
  "Record Org subtree archival, without interfering with Org's move.
Org runs this hook in the original subtree after copying it but before
removing it.  Failures must not abort removal and leave duplicate copies."
  (when (derived-mode-p 'org-mode)
    (org-with-wide-buffer
     (let ((root (ignore-errors (zwanenzang--scope-root))))
       (when root
         (condition-case err
             (save-excursion
               (org-back-to-heading t)
               (zwanenzang--archive-subtree root (point)
                                           (zwanenzang--subtree-end (point))))
           ((error quit)
            (display-warning
             'zwanenzang
             (format "Org archive continues; tracker archive failed or was interrupted: %s. Check tracker state, set a closing status and run `zwanenzang archive' manually if needed after correcting the problem."
                     (error-message-string err))
             :warning))))))))

;;;; Unarchive

(defun zwanenzang--ticket-heading-at-point (root)
  "A marker at the ticket heading at or above point in the scope at ROOT."
  (save-excursion
    (org-back-to-heading t)
    (while (and (not (org-entry-get nil "ZWANENZANG_ID"))
                (not (= (point) root))
                (org-up-heading-safe)))
    (unless (and (org-entry-get nil "ZWANENZANG_ID") (not (= (point) root)))
      (user-error "zwanenzang: point is not on a ticket heading"))
    (zwanenzang--heading-marker)))

;;;###autoload
(defun zwanenzang-unarchive (&optional subtree)
  "Put the ticket heading at point back in the tracker's active set.
With a prefix argument SUBTREE, also every archived ticket heading below
it.  Leaves status alone, removes the heading's ARCHIVE_ properties and
pulls the scope."
  (interactive "P")
  (let ((root (zwanenzang--root-at-point))
        (outcome (zwanenzang--outcome-create)))
    (org-with-wide-buffer
     (let* ((case-fold-search nil)
            (dir (zwanenzang--scope-directory root))
            (start (zwanenzang--ticket-heading-at-point root))
            (end (if subtree (zwanenzang--subtree-end start) (1+ start)))
            (tickets (car (zwanenzang--scan root)))
            (known (zwanenzang--known-tickets dir))
            (blocked (zwanenzang--blocked-headings tickets known))
            (plan (zwanenzang--plan-create)))
       (dolist (tk tickets)
         (let* ((marker (plist-get tk :marker))
                (id (plist-get tk :id))
                (summary (gethash id known)))
           (when (and (<= start marker) (< marker end)
                      (not (assq tk blocked))
                      (eq (alist-get 'archived summary) t)
                      (not (eq (alist-get 'tombstoned summary) t)))
             (zwanenzang--plan-add plan "unarchive" id nil)
             (push marker (zwanenzang--plan-revived plan)))))
       (unless (zwanenzang--plan-changes plan)
         (push "no archived ticket here" (zwanenzang--outcome-problems outcome)))
       (zwanenzang--send-plan plan dir outcome)
       (zwanenzang--pull-into outcome root)))
    (zwanenzang--report-outcome "unarchived in" root outcome)))

;;;; Hidden documents

(defun zwanenzang--link-follow (path _arg)
  "Open PATH, `<ticket id>/<name>', the target of a zwanenzang: link."
  (zwanenzang-open path))

(org-link-set-parameters "zwanenzang" :follow #'zwanenzang--link-follow)

(defun zwanenzang-open (&optional path)
  "Show the document a zwanenzang: link names, read-only.
PATH is `<ticket id>/<document name>'; interactively, the link at point.
The tracker is the one of the scope containing point."
  (interactive)
  (unless path
    (let ((context (org-element-context)))
      (unless (and (eq (org-element-type context) 'link)
                   (equal (org-element-property :type context) "zwanenzang"))
        (user-error "zwanenzang: no zwanenzang: link at point"))
      (setq path (org-element-property :path context))))
  (unless (string-match "\\`\\([^/]+\\)/\\(.+\\)\\'" path)
    (user-error "zwanenzang: malformed link zwanenzang:%s" path))
  (let* ((id (match-string 1 path))
         (name (match-string 2 path))
         (doc (funcall zwanenzang--call (zwanenzang--scope-directory (zwanenzang--scope-root))
                       (list "doc" "get" id name)))
         (buffer (get-buffer-create (format "*zwanenzang %s %s*" (alist-get 'display doc) name))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (alist-get 'text doc))
        (goto-char (point-min))
        (org-mode))
      (setq buffer-read-only t))
    (pop-to-buffer buffer)
    buffer))

(add-hook 'org-blocker-hook #'zwanenzang--block-dependencies)
(add-hook 'org-archive-hook #'zwanenzang--archive-hook)

(autoload 'zwanenzang-queue "zwanenzang-queue" nil t)

(provide 'zwanenzang)
;;; zwanenzang.el ends here
