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
;; docs/agent-hooks/cli-json.md of the zwanenzang repository.

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
  "Local CLI: an absolute file name, or a name looked up on `exec-path'.
Remote scopes use `zwanenzang' from the remote PATH instead."
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
  "Run the CLI on the tracker at or above DIRECTORY with ARGS.
Use `zwanenzang-program' locally, or remote `zwanenzang' through TRAMP.
INPUT, when non-nil, is encoded as JSON and given on stdin.  Return a
plist with :exit (the exit status), :parsed (whether stdout is one JSON
value), :json (that value) and :stderr.  This signals only when the
program cannot be run or INPUT cannot be encoded; a failed command is
for `zwanenzang-call' to judge."
  (let* ((default-directory (file-name-as-directory (expand-file-name directory)))
         (stdin (if input (zwanenzang--json-encode input) ""))
         (remote (file-remote-p default-directory))
         (program (if remote "zwanenzang" zwanenzang-program))
         stderr-file stdin-file
         (coding-system-for-read 'utf-8)
         (coding-system-for-write 'utf-8))
    (unwind-protect
        (with-temp-buffer
          (setq stderr-file (make-temp-file "zwanenzang-stderr-"))
          (when (and remote input)
            (setq stdin-file (make-temp-file "zwanenzang-stdin-"))
            (with-temp-file stdin-file
              (insert stdin)))
          (let* ((exit (condition-case err
                           (if remote
                               (apply #'process-file program stdin-file
                                      (list t stderr-file) nil
                                      "-C" (file-local-name default-directory) args)
                             (apply #'call-process-region stdin nil program
                                    nil (list t stderr-file) nil
                                    "-C" (file-local-name default-directory) args))
                         (file-error
                          (user-error "zwanenzang: cannot run %s (%s); check %s"
                                      program (error-message-string err)
                                      (if remote "the remote PATH" "`zwanenzang-program'")))))
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
      (when stdin-file (delete-file stdin-file))
      (when stderr-file (delete-file stderr-file)))))

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
;; client writes its comments, documents, relations and code drawers last,
;; after the text.

(defconst zwanenzang--tail-drawers
  '("ZWANENZANG_COMMENTS" "ZWANENZANG_DOCUMENTS" "ZWANENZANG_RELATIONS" "ZWANENZANG_CODE")
  "Drawers kept at the end of a ticket's body, in this order.")

(defconst zwanenzang--legacy-drawers '("ZWANENZANG_HIDDEN")
  "Generated drawers earlier versions wrote, which pulls now remove.")

(defconst zwanenzang--link-drawers '("ZWANENZANG_RELATIONS" "ZWANENZANG_CODE")
  "Tail drawers of references only, rewritten from tracker state by every pull.
A change confined to them does not count as pulling the ticket.")

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

(defcustom zwanenzang-heading-number-prefix t
  "Show the ticket number as a prefix of each synced ticket heading.
Pull writes it after the keyword and priority cookie, as in
\"* TODO [#A] [ZZ-42] Title\", once the ticket has a number.  It is
real heading text, so agenda, search, org-ql and exports see it, but
the client owns it: it is stripped before the title is compared, hashed
or pushed, and an edited or removed prefix is restored by the next pull.
With nil, pull removes the prefixes instead, except where the title
itself starts with something that would read as one."
  :type 'boolean)

(defun zwanenzang--number-prefix-re (number)
  "Regexp matching a heading prefix for NUMBER's tracker, or nil.
NUMBER is a display form such as ZZ-42.  Any bracketed token starting
with the same tracker prefix matches, stale and padded ones included,
along with the blanks after it."
  (when (and number (string-match "\\`\\(.+\\)-[0-9]+\\'" number))
    (concat "\\`\\[" (regexp-quote (match-string 1 number))
            "-[^][ \t]*\\]\\(?:[ \t]+\\|\\'\\)")))

(defun zwanenzang--split-number-prefix (text number)
  "TEXT, a heading title, as (PREFIX . TITLE) for the ticket NUMBER.
PREFIX is the bracketed token at its start, without the blanks after
it, or nil when there is none or NUMBER is nil."
  (let ((re (zwanenzang--number-prefix-re number))
        (case-fold-search t))
    (if (and re (string-match re text))
        (cons (string-trim-right (substring text 0 (match-end 0)))
              (substring text (match-end 0)))
      (cons nil text))))

(defun zwanenzang--heading-number ()
  "The ticket number of the heading at point, from ZWANENZANG_NUMBER."
  (org-entry-get nil "ZWANENZANG_NUMBER"))

(defun zwanenzang--shown-prefix ()
  "The number prefix the heading at point shows, or nil."
  (save-excursion
    (org-back-to-heading t)
    (let ((case-fold-search nil))
      (car (zwanenzang--split-number-prefix
            (string-trim (substring-no-properties (org-get-heading t t t t)))
            (zwanenzang--heading-number))))))

(defun zwanenzang--wanted-prefix (title)
  "The number prefix the heading at point should show before TITLE, or nil.
A ticket without a number gets none.  With the prefix turned off, one is
still written when TITLE itself would be read as a prefix, so reading
the heading back gives TITLE."
  (let ((number (zwanenzang--heading-number)))
    (and number
         (or zwanenzang-heading-number-prefix
             (car (zwanenzang--split-number-prefix title number)))
         (concat "[" number "]"))))

(defun zwanenzang--heading ()
  "Keyword, title and local tags of the heading at point, as a plist.
The title leaves out the number prefix, see
`zwanenzang-heading-number-prefix'."
  (save-excursion
    (org-back-to-heading t)
    (let ((case-fold-search nil))
      (list :keyword (org-get-todo-state)
            :priority (nth 3 (org-heading-components))
            :title (string-trim
                    (cdr (zwanenzang--split-number-prefix
                          (string-trim (substring-no-properties (org-get-heading t t t t)))
                          (zwanenzang--heading-number))))
            :tags (mapcar #'substring-no-properties (org-get-tags nil t))))))

(defun zwanenzang--set-heading (keyword title tags &rest priority)
  "Give the heading at point KEYWORD, TITLE and TAGS.
An optional PRIORITY value sets the native cookie; nil clears it.
Without that argument the cookie stays.  Level and COMMENT marker stay.
The number prefix follows `zwanenzang--wanted-prefix'."
  (save-excursion
    (org-back-to-heading t)
    (let ((case-fold-search nil)
          (old (zwanenzang--heading))
          (prefix (zwanenzang--wanted-prefix title)))
      (unless (and (equal keyword (plist-get old :keyword))
                   (equal title (plist-get old :title))
                   (equal tags (plist-get old :tags))
                   (equal prefix (zwanenzang--shown-prefix))
                   (or (null priority) (equal (car priority) (plist-get old :priority))))
        (let* ((parts (org-heading-components))
               (priority (if priority (car priority) (nth 3 parts)))
               (headline (or (nth 4 parts) ""))
               ;; The stars stay, and with them markers at the heading.
               (line (concat (and keyword (concat " " keyword))
                             (and priority (format " [#%s]" (org-priority-to-string priority)))
                             (and (string-prefix-p (concat org-comment-string " ") headline)
                                  (concat " " org-comment-string))
                             (and prefix (concat " " prefix))
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

(defvar zwanenzang--document)           ; Document buffers, below

(defun zwanenzang--scope-root ()
  "A marker at the scope root containing point.
That is the nearest heading at or above point with a ZWANENZANG property."
  (when (bound-and-true-p org-src-mode)
    (user-error "zwanenzang: source editors are prose, not tracker scopes"))
  (when zwanenzang--document
    (user-error "zwanenzang: document buffers are prose, not tracker scopes"))
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

(defun zwanenzang--keyword-map (spec statuses keywords &optional retired)
  "Parse the keyword map SPEC against the tracker STATUSES and Org KEYWORDS.
SPEC is the ZWANENZANG_KEYWORDS value or nil.  Return (MAP . PROBLEMS):
MAP is an alist from status to the keyword it is shown with, PROBLEMS
a list of readable lines.  An entry naming a keyword Org does not know
in this buffer, or a status outside the vocabulary, is left out.
RETIRED statuses may have a keyword but need none: no new write uses
them, and a ticket still in one is blocked on its own.  They come last
in MAP, so a keyword shared with a current status maps back to that."
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
      (unless (or (assoc status map) (member status retired))
        (push (format "keyword map: status %s has no keyword" status) problems)))
    (setq map (nreverse map))
    (cons (append (seq-remove (lambda (e) (member (car e) retired)) map)
                  (seq-filter (lambda (e) (member (car e) retired)) map))
          (nreverse problems))))

;;;; Dependencies

(defun zwanenzang--ticket-number (ref)
  "Parse REF, a ticket number such as ZZ-42 or zz-0042, into (PREFIX . N).
PREFIX is upcased and N an integer, so case and leading zeros do not
matter.  Return nil when REF is not number syntax."
  (save-match-data
    (when (string-match "\\`\\([^ \t\n]+\\)-\\([0-9]+\\)\\'" ref)
      (cons (upcase (match-string 1 ref)) (string-to-number (match-string 2 ref))))))

(defun zwanenzang--ticket-ref-normalize (ref)
  "REF in the form the tracker displays numbers, such as ZZ-42.
Anything that is not number syntax is only upcased."
  (let ((number (zwanenzang--ticket-number ref)))
    (if number (format "%s-%d" (car number) (cdr number)) (upcase ref))))

(defun zwanenzang--ticket-ref< (a b)
  "Whether ticket ref A sorts before B: by prefix, then numerically.
Refs that are not number syntax sort after numbers, as strings."
  (let ((na (zwanenzang--ticket-number a))
        (nb (zwanenzang--ticket-number b)))
    (cond ((and na nb) (if (equal (car na) (car nb)) (< (cdr na) (cdr nb))
                         (string< (car na) (car nb))))
          (na t)
          (nb nil)
          (t (string< a b)))))

(defun zwanenzang--dependency-refs ()
  "The entry's prerequisite numbers, normalized as a sorted set."
  (sort (delete-dups (mapcar #'zwanenzang--ticket-ref-normalize
                             (split-string (or (org-entry-get nil "ZWANENZANG_DEPENDS_ON") ""))))
        #'zwanenzang--ticket-ref<))

(defun zwanenzang--dependency-base (sync &rest candidates)
  "The last synced dependency hash in SYNC, read against CANDIDATES.
Versions before unpadded numbers hashed four-digit forms such as ZZ-0042.
When the stored hash is the padded form of one of the ref lists in
CANDIDATES, return that list's current hash, so the old padding alone
never counts as an edit or a conflict."
  (let ((base (zwanenzang--sync-get sync 'depends)))
    (or (and (stringp base)
             (seq-some
              (lambda (refs)
                (and (equal base (zwanenzang--tags-hash
                                  (mapcar (lambda (ref)
                                            (let ((n (zwanenzang--ticket-number ref)))
                                              (if n (format "%s-%04d" (car n) (cdr n)) ref)))
                                          refs)))
                     (zwanenzang--tags-hash refs)))
              candidates))
        base)))

(defun zwanenzang--dependency-displays (ticket known)
  "Resolve TICKET's dependency identities through KNOWN to published numbers.
An unpublished prerequisite cannot be represented in the manual property."
  (sort (mapcar (lambda (id)
                  (let ((target (and known (gethash id known))))
                    (unless (integerp (alist-get 'number target))
                      (user-error "prerequisite %s has no published ticket number" id))
                    (zwanenzang--ticket-ref-normalize (alist-get 'display target))))
                (alist-get 'depends_on ticket))
        #'zwanenzang--ticket-ref<))

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
REFS are human-facing numbers such as ZZ-42, not internal ULIDs; case
and leading zeros do not matter.
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
                 (puthash (zwanenzang--ticket-ref-normalize (alist-get 'display summary))
                          summary summaries))
               known))
    (dolist (heading headings)
      (push (plist-get heading :marker) (gethash (plist-get heading :id) local)))
    (dolist (heading headings)
      (let ((number (org-entry-get (plist-get heading :marker) "ZWANENZANG_NUMBER")))
        (when number
          (setq number (zwanenzang--ticket-ref-normalize number))
          (puthash number (seq-union (gethash number local-numbers)
                                    (gethash (plist-get heading :id) local) #'eq)
                   local-numbers))))
    (dolist (ref (delete-dups (mapcar #'zwanenzang--ticket-ref-normalize refs)))
      (let* ((number-p (zwanenzang--ticket-number ref))
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
                          (format "%s %s" ref (plist-get (zwanenzang--heading) :title)))
                      (if summary (zwanenzang--label summary) ref)))
             (reason
              (cond
               ((not number-p) "expected a ticket ID such as ZZ-42")
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

;;;; Editing dependencies

;; The commands below only edit the heading's ZWANENZANG_DEPENDS_ON; the
;; next push sends it, like a hand edit.  Candidates come from a fresh
;; `list --all' and read "NUMBER Title", so ordinary completion styles
;; match either; status, kind and tags are an annotation, which
;; completion UIs such as marginalia show for any category.

(defun zwanenzang--dependency-annotation (summary)
  "The completion annotation for ticket SUMMARY: status, kind and tags."
  (let ((kind (zwanenzang--null (alist-get 'kind summary)))
        (tags (alist-get 'tags summary)))
    (concat "  "
            (propertize
             (string-join
              (delq nil (list (alist-get 'status summary)
                              (and (stringp kind) kind)
                              (and tags (concat ":" (string-join tags ":") ":"))))
              " ")
             'face 'completions-annotations))))

(defun zwanenzang--dependency-read (prompt candidates)
  "Read one of CANDIDATES with PROMPT; return its value.
CANDIDATES is a list of (TEXT . SUMMARY), in the order to offer them;
SUMMARY may be nil for a reference the tracker does not know."
  (let* ((table (lambda (string pred action)
                  (if (eq action 'metadata)
                      `(metadata
                        (category . zwanenzang-ticket)
                        (display-sort-function . identity)
                        (annotation-function
                         . ,(lambda (text)
                              (let ((summary (cdr (assoc text candidates))))
                                (if summary (zwanenzang--dependency-annotation summary) "")))))
                    (complete-with-action action candidates string pred))))
         (choice (completing-read prompt table nil t)))
    (or (assoc choice candidates)
        (user-error "zwanenzang: no ticket chosen"))))

(defun zwanenzang--dependency-context ()
  "The ticket heading at point for a dependency command, with its tracker.
Return (HEADING ID SUMMARIES): a marker at the heading, its ticket id,
and a fresh hash table of every ticket the scope's tracker knows."
  (let* ((root (zwanenzang--root-at-point))
         (heading (org-with-wide-buffer (zwanenzang--ticket-heading-at-point root)))
         (id (org-with-wide-buffer (org-entry-get heading "ZWANENZANG_ID")))
         (known (zwanenzang--known-tickets (zwanenzang--scope-directory root))))
    (unless (gethash id known)
      (user-error "zwanenzang: the tracker has no ticket %s" id))
    (list heading id known)))

(defun zwanenzang--dependents-of (id known)
  "Ids of the tickets in KNOWN that depend on ID, directly or not, and ID.
Adding any of them as a prerequisite of ID would make a cycle."
  (let ((reverse (make-hash-table :test #'equal))
        (seen (make-hash-table :test #'equal))
        (queue (list id)))
    (maphash (lambda (from summary)
               (dolist (to (alist-get 'depends_on summary))
                 (push from (gethash to reverse))))
             known)
    (while queue
      (let ((next (pop queue)))
        (unless (gethash next seen)
          (puthash next t seen)
          (setq queue (append (gethash next reverse) queue)))))
    seen))

(defun zwanenzang--dependency-candidates (id refs known)
  "Tickets in KNOWN that ticket ID may newly depend on, as (TEXT . SUMMARY).
REFS are its current prerequisites.  Left out are ID itself, REFS,
unnumbered, archived and tombstoned tickets, and those that depend on ID,
which would make a cycle.  Done tickets stay.  Sorted by number."
  (let ((cycle (zwanenzang--dependents-of id known))
        (current (mapcar #'zwanenzang--ticket-ref-normalize refs))
        candidates)
    (maphash
     (lambda (other summary)
       (when (and (not (gethash other cycle))
                  (integerp (alist-get 'number summary))
                  (not (eq (alist-get 'archived summary) t))
                  (not (eq (alist-get 'tombstoned summary) t))
                  (not (member (zwanenzang--ticket-ref-normalize (alist-get 'display summary))
                               current)))
         (push (cons (zwanenzang--label summary) summary) candidates)))
     known)
    (sort candidates (lambda (a b) (zwanenzang--ticket-ref< (alist-get 'display (cdr a))
                                                            (alist-get 'display (cdr b)))))))

(defun zwanenzang--dependency-tokens (heading)
  "The words of HEADING's ZWANENZANG_DEPENDS_ON, as written."
  (org-with-wide-buffer
   (split-string (or (org-entry-get heading "ZWANENZANG_DEPENDS_ON") ""))))

(defun zwanenzang--dependency-write (heading tokens)
  "Set HEADING's ZWANENZANG_DEPENDS_ON to TOKENS, or remove it when empty.
TOKENS are sorted by number; one already there keeps its spelling."
  (let ((tokens (sort (copy-sequence tokens) #'zwanenzang--ticket-ref<)))
    (org-with-wide-buffer
     (goto-char heading)
     (if tokens
         (org-entry-put nil "ZWANENZANG_DEPENDS_ON" (string-join tokens " "))
       (org-entry-delete nil "ZWANENZANG_DEPENDS_ON")))))

;;;###autoload
(defun zwanenzang-add-dependency ()
  "Make the ticket at point depend on another ticket of its tracker.
The nearest ticket heading at or above point gets the chosen ticket's
number in ZWANENZANG_DEPENDS_ON; nothing else changes, and the next
push sends it.  Candidates are the tracker's numbered, active tickets
that are not already prerequisites and would not make a cycle; done
tickets are offered too."
  (interactive)
  (pcase-let* ((`(,heading ,id ,known) (zwanenzang--dependency-context))
               (tokens (zwanenzang--dependency-tokens heading))
               (candidates (zwanenzang--dependency-candidates id tokens known)))
    (unless candidates
      (user-error "zwanenzang: no ticket to add as a prerequisite"))
    (let* ((choice (zwanenzang--dependency-read "Add prerequisite: " candidates))
           (ref (zwanenzang--ticket-ref-normalize (alist-get 'display (cdr choice)))))
      (zwanenzang--dependency-write heading (append tokens (list ref)))
      (message "zwanenzang: %s now depends on %s; push to send it"
               (alist-get 'display (gethash id known)) (car choice)))))

;;;###autoload
(defun zwanenzang-remove-dependency ()
  "Remove one prerequisite from the ticket at point.
Offers the numbers in the nearest ticket heading's ZWANENZANG_DEPENDS_ON,
with titles the tracker knows.  Every spelling of the chosen number is
removed; when none is left, so is the property.  The next push sends it."
  (interactive)
  (pcase-let* ((`(,heading ,id ,known) (zwanenzang--dependency-context))
               (tokens (zwanenzang--dependency-tokens heading))
               (by-number (make-hash-table :test #'equal))
               (candidates nil))
    (unless tokens
      (user-error "zwanenzang: %s has no prerequisites"
                  (alist-get 'display (gethash id known))))
    (maphash (lambda (_ summary)
               (puthash (zwanenzang--ticket-ref-normalize (alist-get 'display summary))
                        summary by-number))
             known)
    (dolist (ref (sort (delete-dups (mapcar #'zwanenzang--ticket-ref-normalize tokens))
                       #'zwanenzang--ticket-ref<))
      (let ((summary (gethash ref by-number)))
        (push (cons (if summary (format "%s %s" ref (alist-get 'title summary)) ref)
                    (cons ref summary))
              candidates)))
    (setq candidates (nreverse candidates))
    (let* ((choice (zwanenzang--dependency-read
                    "Remove prerequisite: "
                    (mapcar (lambda (c) (cons (car c) (cddr c))) candidates)))
           (ref (cadr (assoc (car choice) candidates))))
      (zwanenzang--dependency-write
       heading (seq-remove (lambda (token)
                             (equal (zwanenzang--ticket-ref-normalize token) ref))
                           tokens))
      (message "zwanenzang: %s no longer depends on %s; push to send it"
               (alist-get 'display (gethash id known)) (car choice)))))

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
  root dir tracker-dir map actors
  known statuses tracker                ; last successful read, for dependency checks
  (ids (make-hash-table :test #'equal)) ; id -> marker, unique headings only
  moves
  lines                                 ; what needs a look, newest first
  info                                  ; what happened, newest first
  pulled                                ; ids whose shown state changed
  comments                              ; (ID FRESH RECORDS) per pulled ticket
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

(defun zwanenzang--comment-record (pull comment)
  "COMMENT as PULL renders it in the comments drawer: a header line, text, link."
  (let ((link (zwanenzang--null (alist-get 'link comment))))
    (concat (format "[%s] %s:\n" (alist-get 'ts comment)
                    (zwanenzang--actor-name pull (alist-get 'actor comment)))
            (zwanenzang--comment-text (alist-get 'text comment))
            (and link
                 (concat (org-link-make-string
                          (if (string-match-p "\\`[a-zA-Z][a-zA-Z0-9+.-]*:" link)
                              link
                            (concat "file:" (expand-file-name
                                             link (zwanenzang--pull-tracker-dir pull)))))
                         "\n")))))

(defun zwanenzang--comment-records (pull ticket)
  "TICKET's comments as (ID . RECORD), in the drawer's order, newest first.
RECORD is as `zwanenzang--comment-record' renders it for PULL."
  (mapcar (lambda (c) (cons (alist-get 'id c) (zwanenzang--comment-record pull c)))
          (reverse (alist-get 'comments ticket))))

(defun zwanenzang--comments-content (pull ticket)
  "The :ZWANENZANG_COMMENTS: drawer content for TICKET, newest first.
Reverse replay order, not wall-clock timestamps; leave TICKET unchanged."
  (mapconcat #'cdr (zwanenzang--comment-records pull ticket) ""))

(defun zwanenzang--documents-content (pull ticket)
  "The :ZWANENZANG_DOCUMENTS: drawer content for TICKET.
One item per named document with a current version: a link that opens
it, then the date and author of that version.  The description is the
body, so it is not listed."
  (mapconcat
   (lambda (doc)
     (let* ((name (symbol-name (car doc)))
            (current (zwanenzang--null (alist-get 'current (cdr doc))))
            (version (and current
                          (seq-find (lambda (v) (equal (alist-get 'id v) current))
                                    (alist-get 'versions (cdr doc))))))
       (if (or (equal name "description") (null current))
           ""
         (concat "- "
                 (org-link-make-string
                  (format "zwanenzang:%s/%s" (alist-get 'id ticket) name) name)
                 (if version
                     (format " %s %s"
                             (substring (alist-get 'ts version) 0
                                        (min 10 (length (alist-get 'ts version))))
                             (zwanenzang--actor-name pull (alist-get 'actor version)))
                   "")
                 "\n"))))
   (alist-get 'documents ticket) ""))

(defun zwanenzang--list-content (kinds)
  "Org list text for KINDS, an alist of labels and lists of item lines.
One top-level item per label, its lines as sub-items; a label without
lines is left out, so nothing at all gives the empty string."
  (mapconcat (lambda (kind)
               (if (cdr kind)
                   (concat "- " (car kind) "\n"
                           (mapconcat (lambda (line) (concat "  - " line "\n")) (cdr kind) ""))
                 ""))
             kinds ""))

(defun zwanenzang--one-line (text)
  "TEXT on one line, for a link description or list item."
  (string-trim (replace-regexp-in-string "[ \t]*[\n\r]+[ \t]*" " " text)))

(defun zwanenzang--ticket-link (id known map)
  "An Org link to ticket ID, labelled from its summary in KNOWN.
The label is NUMBER KEYWORD Title, the keyword shown for its status
through the keyword MAP, or the status itself when MAP has none.  An
archived or tombstoned ticket says so; one KNOWN lacks is named by id."
  (let ((summary (and known (gethash id known))))
    (org-link-make-string
     (concat "zwanenzang:" id)
     (if (not summary)
         (format "%s (unknown)" id)
       (let ((status (alist-get 'status summary)))
         (concat (string-join (delq nil (list (alist-get 'display summary)
                                              (or (cdr (assoc status map)) status)
                                              (zwanenzang--one-line
                                               (or (alist-get 'title summary) ""))))
                              " ")
                 (cond ((eq (alist-get 'tombstoned summary) t) " (tombstoned)")
                       ((eq (alist-get 'archived summary) t) " (archived)"))))))))

(defun zwanenzang--ticket-links (ids known map)
  "Links to the tickets IDS, as `zwanenzang--ticket-link' with KNOWN and MAP.
Sorted by number; tickets KNOWN lacks come last."
  (let ((display (lambda (id) (let ((s (and known (gethash id known))))
                                (if s (alist-get 'display s) "")))))
    (mapcar (lambda (id) (zwanenzang--ticket-link id known map))
            (sort (copy-sequence ids)
                  (lambda (a b)
                    (let ((da (funcall display a)) (db (funcall display b)))
                      (cond ((and (string-empty-p da) (string-empty-p db)) (string< a b))
                            ((string-empty-p da) nil)
                            ((string-empty-p db) t)
                            (t (zwanenzang--ticket-ref< da db)))))))))

(defun zwanenzang--relations-content (ticket known map)
  "The :ZWANENZANG_RELATIONS: drawer content for TICKET.
Its prerequisites, the tickets it blocks and its related tickets, as
links labelled through KNOWN and the keyword MAP."
  (zwanenzang--list-content
   `(("Prerequisites" ,@(zwanenzang--ticket-links (alist-get 'depends_on ticket) known map))
     ("Blocks" ,@(zwanenzang--ticket-links (alist-get 'blocks ticket) known map))
     ("Related" ,@(zwanenzang--ticket-links (alist-get 'related ticket) known map)))))

(defun zwanenzang--mr-label (repo url)
  "How a merge request URL in repository alias REPO is labelled.
ALIAS #N when the URL's last path segment is a number N, else ALIAS and
that segment, else the alias alone."
  (let* ((path (replace-regexp-in-string "[?#].*\\'" "" url))
         (segment (car (last (split-string path "/" t)))))
    (cond ((and segment (string-match-p "\\`[0-9]+\\'" segment))
           (format "%s #%s" repo segment))
          ((and segment (not (string-suffix-p ":" segment))) (format "%s %s" repo segment))
          (t repo))))

(defun zwanenzang--code-content (ticket)
  "The :ZWANENZANG_CODE: drawer content for TICKET: its branches and MRs.
A branch is plain text ALIAS: name; a merge request links its URL."
  (zwanenzang--list-content
   `(("Branches" ,@(mapcar (lambda (b)
                             (zwanenzang--one-line
                              (format "%s: %s" (alist-get 'repo b) (alist-get 'name b))))
                           (alist-get 'branches ticket)))
     ("MRs" ,@(mapcar (lambda (m)
                        (org-link-make-string
                         (alist-get 'url m)
                         (zwanenzang--one-line
                          (zwanenzang--mr-label (alist-get 'repo m) (alist-get 'url m)))))
                      (alist-get 'mrs ticket))))))

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

(defun zwanenzang--inline-doc-own-content-p ()
  "Whether the named-document heading at point holds more than its document.
That is what removing the heading would lose and the tracker does not
have: subheadings, properties other than the client's (an Org ID or
CUSTOM_ID among them), planning lines, a TODO keyword, priority or tags
on the heading, or drawers other than its properties and the client's."
  (let ((heading (zwanenzang--heading)))
    (or (save-excursion
          (let ((level (org-current-level)))
            (and (outline-next-heading) (not (eobp))
                 (> (org-current-level) level))))
        (plist-get heading :keyword)
        (plist-get heading :priority)
        (plist-get heading :tags)
        ;; The drawer itself, not `org-entry-properties', which adds
        ;; CATEGORY and other values no heading wrote.
        (let ((block (org-get-property-block)) found)
          (when block
            (save-excursion
              (goto-char (car block))
              (while (and (not found) (re-search-forward org-property-re (cdr block) t))
                (unless (string-prefix-p "ZWANENZANG" (match-string-no-properties 2))
                  (setq found t)))))
          found)
        (seq-some (lambda (s)
                    (or (eq (car s) 'planning)
                        (and (eq (car s) 'drawer)
                             (not (equal (nth 2 s) "PROPERTIES"))
                             (not (string-prefix-p "ZWANENZANG_" (nth 2 s))))))
                  (zwanenzang--body-segments (car (zwanenzang--document-parts)))))))

(defun zwanenzang--migrate-docs (texts)
  "Remove the inline named documents of the ticket at point once synced.
Earlier versions wrote named documents as subheadings; the documents
drawer now links them instead.  A subheading whose text is the one last
synced, or the tracker's current text, is deleted with its subtree.  One
holding edits the tracker lacks, or anything else, stays and is noted, so
the human pushes or discards it.  TEXTS maps document names to their
current text.  Return the conflicts."
  (let ((docs (zwanenzang--doc-headings))
        seen conflicts doomed)
    (dolist (doc docs)
      (let ((name (car doc)))
        (save-excursion
          (goto-char (cdr doc))
          (let* ((local (zwanenzang--document-text))
                 (hash (org-entry-get nil "ZWANENZANG_HASH"))
                 (remote (alist-get (intern name) texts))
                 (note
                  (cond
                   ((or (equal name "description") (member name seen))
                    "this inline heading is not a synced document; move its text and delete it")
                   ((zwanenzang--inline-doc-own-content-p)
                    "the inline heading holds subheadings, properties, planning, tags or drawers of its own; move them, then delete it")
                   ((or (and hash (equal hash (zwanenzang--hash local)))
                        (and remote (equal local (zwanenzang--normalize-text remote)))
                        ;; Nothing to lose, and push would not create it.
                        (and (not remote) (string-empty-p local)))
                    nil)
                   (t "the inline copy has edits the tracker lacks; push it or delete the heading"))))
            (push name seen)
            (if note
                (push (list (format "document %s" name) note nil) conflicts)
              (push (cdr doc) doomed))))))
    ;; Last first, so the earlier subtrees' positions stay valid.
    (dolist (marker doomed)
      (delete-region marker (zwanenzang--subtree-end marker)))
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
        ;; Status is compared as keywords: an agnt shown as NEXT stays
        ;; agnt until the keyword changes.
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
                           (let ((b (zwanenzang--dependency-base sync local remote)))
                             (if (eq b :unknown) (zwanenzang--tags-hash nil) b))))
                   (decision (zwanenzang--merge (zwanenzang--tags-hash local) base
                                                (zwanenzang--tags-hash remote))))
              ;; `same' rewrites too: Org may hold the refs in another
              ;; spelling, such as the old padded ZZ-0042.
              (when (or (settle "dependencies" decision
                                "tracker prerequisites skipped; Org dependencies kept"
                                (string-join remote " ") 'depends (zwanenzang--tags-hash remote))
                        (eq decision 'same))
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
        (setq conflicts (append (nreverse conflicts) (zwanenzang--migrate-docs texts)))
        (zwanenzang--write-body
         (zwanenzang--compose-body
          (zwanenzang--body)
          `(("ZWANENZANG_COMMENTS" . ,(zwanenzang--comments-content pull ticket))
            ("ZWANENZANG_DOCUMENTS" . ,(zwanenzang--documents-content pull ticket))
            ("ZWANENZANG_HIDDEN")
            ("ZWANENZANG_RELATIONS"
             . ,(zwanenzang--relations-content ticket (zwanenzang--pull-known pull) map))
            ("ZWANENZANG_CODE" . ,(zwanenzang--code-content ticket))
            ("ZWANENZANG_CONFLICT" . ,(zwanenzang--conflict-content conflicts)))
          description))
        (push (list (alist-get 'id ticket) fresh (zwanenzang--comment-records pull ticket))
              (zwanenzang--pull-comments pull))
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
          (seq-filter (lambda (s) (and (member (nth 2 s) zwanenzang--tail-drawers)
                                       (not (member (nth 2 s) zwanenzang--link-drawers))))
                      segments)
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

(defvar-local zwanenzang--hide-docs-reported nil
  "Markers at the scope roots whose ZWANENZANG_HIDE_DOCS was reported.")

(defun zwanenzang--report-hide-docs (pull root)
  "Report in PULL that the scope at ROOT has ZWANENZANG_HIDE_DOCS, once.
Named documents are never written inline any more, so there is nothing
to hide.  The property is the human's, so it is not removed; the report
says so once per scope in each Emacs session."
  (setq zwanenzang--hide-docs-reported
        (seq-filter #'marker-buffer zwanenzang--hide-docs-reported))
  (when (and (org-entry-get root "ZWANENZANG_HIDE_DOCS")
             (not (seq-find (lambda (m) (= m root)) zwanenzang--hide-docs-reported)))
    (push (copy-marker root) zwanenzang--hide-docs-reported)
    (zwanenzang--pull-line
     pull "ZWANENZANG_HIDE_DOCS is ignored: documents are links in :ZWANENZANG_DOCUMENTS:; remove the property")))

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
                                              org-todo-keywords-1
                                              (alist-get 'retired_statuses tracker))))
             (setf (zwanenzang--pull-map pull) (car km)
                   (zwanenzang--pull-actors pull) (alist-get 'actors tracker)
                   (zwanenzang--pull-tracker-dir pull) dir)
             (dolist (p (cdr km)) (zwanenzang--pull-line pull "%s" p))
             (zwanenzang--report-hide-docs pull root))
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
  comments                              ; a ticket number per new comment
  saved                                 ; the file was saved for new identities
  refused)

(defun zwanenzang--pull-into (outcome root)
  "Pull the scope at ROOT and add the result to OUTCOME."
  (let ((pull (zwanenzang--pull-scope root)))
    (unless (zwanenzang--pull-refused pull)
      (zwanenzang--take-new-comments outcome pull))
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
                     (delq nil (list (zwanenzang--new-comments-summary
                                      (zwanenzang--outcome-comments outcome))))
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

;;;; New comments

;; Comments a pull brings into a scope are remembered for the session, so
;; the human can step through them and see their tickets in the fringe.
;; None of it is written anywhere: it lives in the buffer and goes with
;; it.  Positions are found again from the buffer whenever they are
;; needed, because pulls rewrite bodies and move subtrees.

(defcustom zwanenzang-new-comment-fringe-mark 'zwanenzang-new-comment
  "Fringe bitmap on ticket headings with new comments, or nil for none.
Text terminals have no fringe; there only the navigation commands work."
  :type '(choice (const :tag "No mark" nil) (symbol :tag "Fringe bitmap")))

(defface zwanenzang-new-comment-fringe
  '((t :inherit warning))
  "Face of the fringe mark on ticket headings with new comments.")

(when (fboundp 'define-fringe-bitmap)
  (define-fringe-bitmap 'zwanenzang-new-comment
    [#b11111110
     #b10000010
     #b10111010
     #b10000010
     #b10110010
     #b10000010
     #b11111110
     #b00110000
     #b00100000]))

(cl-defstruct (zwanenzang--new-comments (:constructor zwanenzang--new-comments-create)
                                        (:copier nil))
  "What this session knows about the comments of one scope."
  root                                  ; marker at the scope root
  (seen (make-hash-table :test #'equal)) ; ticket id -> (ID . RECORD), newest first
  new                                   ; (TICKET-ID . COMMENT-ID), in arrival order
  overlays)                             ; the fringe marks

(defvar-local zwanenzang--new-comment-scopes nil
  "The `zwanenzang--new-comments' of each scope in this buffer pulled this session.")

(defvar zwanenzang--sent-comments (make-hash-table :test #'equal)
  "Event ids of the comments this Emacs session sent; they are never new.")

(defvar zwanenzang--new-comment-search-failed nil
  "Non-nil when the last new-comment search found nothing, so a repeat wraps.")

(defun zwanenzang--new-comment-states ()
  "This buffer's scope comment states, dropping those whose root is gone."
  (setq zwanenzang--new-comment-scopes
        (seq-filter (lambda (state)
                      (or (eq (marker-buffer (zwanenzang--new-comments-root state))
                              (current-buffer))
                          (progn (mapc #'delete-overlay (zwanenzang--new-comments-overlays state))
                                 nil)))
                    zwanenzang--new-comment-scopes)))

(defun zwanenzang--new-comments-of (root &optional create)
  "The comment state of the scope at ROOT, or nil; CREATE makes one if missing.
Call it in ROOT's buffer."
  (or (seq-find (lambda (state) (= (zwanenzang--new-comments-root state) root))
                (zwanenzang--new-comment-states))
      (and create
           (car (push (zwanenzang--new-comments-create :root (copy-marker root t))
                      zwanenzang--new-comment-scopes)))))

(defun zwanenzang--note-new-comments (pull)
  "Record the comments PULL rendered; return those new this session.
The first pull of a scope in a session, and a ticket rendered in it for
the first time, set the baseline: none of their comments are new.
Comments this session sent are never new.  The result is a list of
\(TICKET-ID . COMMENT-ID), oldest first per ticket."
  (with-current-buffer (marker-buffer (zwanenzang--pull-root pull))
    (let* ((root (zwanenzang--pull-root pull))
           (first (null (zwanenzang--new-comments-of root)))
           (seen (zwanenzang--new-comments-seen (zwanenzang--new-comments-of root t)))
           new)
      (pcase-dolist (`(,id ,fresh ,records) (reverse (zwanenzang--pull-comments pull)))
        (let ((old (gethash id seen :none)))
          ;; Comments are compared by id, so a reset that replays old
          ;; ones, or one that slots a late comment in among them, marks
          ;; only the comments this session has not rendered before.
          (unless (or first fresh (eq old :none))
            (dolist (record (reverse records))
              (unless (or (assoc (car record) old)
                          (gethash (car record) zwanenzang--sent-comments))
                (push (cons id (car record)) new))))
          (puthash id records seen)))
      (nreverse new))))

(defun zwanenzang--comment-position (heading records id)
  "Where comment ID starts in the comments drawer of the ticket at HEADING.
RECORDS are the ticket's comments as the last pull rendered them, as
`zwanenzang--comment-records' returns them.  They are matched whole and
in order, each after the one before it, so a comment quoting another's
header line, or one sharing its timestamp and author, is not taken for
it.  A record the drawer no longer holds is skipped.  Return nil when
ID's record is not found."
  (save-excursion
    (goto-char heading)
    (pcase-let ((`(,start . ,end) (zwanenzang--body-bounds)))
      (goto-char start)
      (when (let ((case-fold-search t))
              (re-search-forward "^[ \t]*:ZWANENZANG_COMMENTS:[ \t]*\n" end t))
        (let ((limit (save-excursion
                       (let ((case-fold-search t))
                         (if (re-search-forward "^[ \t]*:END:[ \t]*$" end t)
                             (match-beginning 0)
                           end))))
              (case-fold-search nil)
              found)
          (while (and records (not found))
            (pcase-let ((`(,rid . ,text) (pop records))
                        (from (point))
                        (at nil))
              ;; Usually the drawer is exactly what the pull wrote, and the
              ;; record starts at point; otherwise it starts on a line further on.
              (if (and (<= (+ from (length text)) limit)
                       (string= text (buffer-substring-no-properties
                                      from (+ from (length text)))))
                  (setq at from)
                (while (and (not at) (search-forward text limit t))
                  (if (save-excursion (goto-char (match-beginning 0)) (bolp))
                      (setq at (match-beginning 0))
                    (goto-char (1+ (match-beginning 0)))))
                (unless at (goto-char from)))
              (when at
                (goto-char (+ at (length text)))
                (when (equal rid id) (setq found at)))))
          found)))))

(defun zwanenzang--new-comment-targets (state)
  "Where STATE's new comments are now, as (POS . HEADING), in buffer order.
HEADING is the position of the comment's ticket heading.  A comment is
found in that ticket's comments drawer as the last pull rendered it, by
`zwanenzang--comment-position'; one whose ticket heading left the scope,
has a duplicate or lost the comment is left out."
  (let ((root (zwanenzang--new-comments-root state))
        (seen (zwanenzang--new-comments-seen state))
        targets)
    (when (and (zwanenzang--new-comments-new state)
               (eq (marker-buffer root) (current-buffer)))
      (org-with-wide-buffer
       (when (save-excursion
               (goto-char root)
               (and (org-at-heading-p) (org-entry-get nil "ZWANENZANG")))
         (let ((counts (make-hash-table :test #'equal))
               (headings (make-hash-table :test #'equal)))
           (dolist (tk (car (zwanenzang--scan root)))
             (cl-incf (gethash (plist-get tk :id) counts 0))
             (puthash (plist-get tk :id) (marker-position (plist-get tk :marker)) headings)
             (set-marker (plist-get tk :marker) nil))
           (pcase-dolist (`(,id . ,cid) (zwanenzang--new-comments-new state))
             (let* ((heading (and (= 1 (gethash id counts 0)) (gethash id headings)))
                    (pos (and heading
                              (zwanenzang--comment-position heading (gethash id seen) cid))))
               (when pos (push (cons pos heading) targets))))))))
    (sort targets :key #'car)))

(defun zwanenzang--mark-new-comments (state &optional targets)
  "Put a fringe mark on each ticket heading with STATE's new comments.
TARGETS are STATE's `zwanenzang--new-comment-targets', when known.  The
marks of an earlier call are removed first."
  (mapc #'delete-overlay (zwanenzang--new-comments-overlays state))
  (setf (zwanenzang--new-comments-overlays state) nil)
  (when zwanenzang-new-comment-fringe-mark
    (save-restriction
      (widen)
      (dolist (heading (seq-uniq (mapcar #'cdr (or targets
                                                 (zwanenzang--new-comment-targets state)))))
      (let ((overlay (make-overlay heading (min (1+ heading) (point-max)))))
        (overlay-put overlay 'zwanenzang-new-comment t)
        (overlay-put overlay 'evaporate t)
        (overlay-put overlay 'before-string
                     (propertize "*" 'display
                                 `(left-fringe ,zwanenzang-new-comment-fringe-mark
                                               zwanenzang-new-comment-fringe)))
        (push overlay (zwanenzang--new-comments-overlays state)))))))

(defun zwanenzang--take-new-comments (outcome pull)
  "Record PULL's comments; make the new ones its scope's new comments.
The first pull of OUTCOME's command that brings any replaces the
scope's earlier set; later pulls of the same command add to it, so one
sync keeps what its first pull brought.  A pull bringing none keeps the
set.  OUTCOME collects the new comments' ticket numbers for its report."
  (let ((new (zwanenzang--note-new-comments pull)))
    (with-current-buffer (marker-buffer (zwanenzang--pull-root pull))
      (let ((state (zwanenzang--new-comments-of (zwanenzang--pull-root pull))))
        (when new
          (setf (zwanenzang--new-comments-new state)
                (if (zwanenzang--outcome-comments outcome)
                    (append (zwanenzang--new-comments-new state)
                            (seq-difference new (zwanenzang--new-comments-new state)))
                  new))
          (setf (zwanenzang--outcome-comments outcome)
                (append (zwanenzang--outcome-comments outcome)
                        (mapcar (lambda (n)
                                  (alist-get 'display
                                             (gethash (car n) (zwanenzang--pull-known pull))))
                                new))))
        (zwanenzang--mark-new-comments state)))))

(defun zwanenzang--new-comments-summary (displays)
  "The report part for new comments on the tickets DISPLAYS name, or nil.
DISPLAYS has one ticket number per comment."
  (when displays
    (let (counts)
      (dolist (display displays)
        (cl-incf (alist-get display counts 0 nil #'equal)))
      (format "%d new comment%s: %s" (length displays) (if (cdr displays) "s" "")
              (mapconcat (lambda (c)
                           (if (> (cdr c) 1) (format "%s (%d)" (car c) (cdr c)) (car c)))
                         (sort counts :key #'car :lessp #'zwanenzang--ticket-ref<)
                         ", ")))))

(defun zwanenzang--move-to-new-comment (backward)
  "Move to the next new comment in this buffer, or the previous when BACKWARD.
As `org-next-link': from point, skipping a comment point is on; when
there is none, stay, and the same command again wraps around."
  (let* ((targets (sort (mapcan (lambda (state)
                                  (let ((targets (zwanenzang--new-comment-targets state)))
                                    (zwanenzang--mark-new-comments state targets)
                                    (mapcar #'car targets)))
                                (zwanenzang--new-comment-states))
                        #'<))
         (targets (seq-filter (lambda (pos) (<= (point-min) pos (point-max))) targets))
         (wrap (and zwanenzang--new-comment-search-failed (eq this-command last-command)))
         (found
          (cond
           ((and wrap backward) (car (last targets)))
           (wrap (car targets))
           ;; Point anywhere on a comment's first line is on that comment.
           (backward (car (last (seq-filter (lambda (pos)
                                              (< (save-excursion (goto-char pos) (pos-eol))
                                                 (point)))
                                            targets))))
           (t (seq-find (lambda (pos) (> pos (point))) targets)))))
    (setq zwanenzang--new-comment-search-failed nil)
    (when wrap
      (message "New comment search wrapped back to %s of buffer"
               (if backward "end" "beginning")))
    (if (not found)
        (progn (setq zwanenzang--new-comment-search-failed t)
               (message "No further new comment"))
      (goto-char found)
      ;; Reveal the ticket heading, its entry and the comments drawer;
      ;; siblings and other drawers keep their folds.
      (when (org-invisible-p)
        (org-fold-show-set-visibility 'ancestors))
      (point))))

;;;###autoload
(defun zwanenzang-next-new-comment ()
  "Move to the next comment a pull brought into this buffer this session.
New comments are those the last pull or sync bringing any brought, not
counting comments this session sent; a scope's first pull of the
session brings none.  Point lands on the comment's first line in the
ticket's comments drawer, revealed.  When there is none after point,
point stays; the same command again wraps to the beginning, as
`org-next-link' does."
  (interactive)
  (zwanenzang--move-to-new-comment nil))

;;;###autoload
(defun zwanenzang-previous-new-comment ()
  "Move to the previous new comment in this buffer.
See `zwanenzang-next-new-comment'; a repeat wraps to the end."
  (interactive)
  (zwanenzang--move-to-new-comment t))

;;;###autoload
(defun zwanenzang-clear-new-comments (&optional all-buffers)
  "Forget the new comments of every scope in this buffer, and their marks.
With prefix argument ALL-BUFFERS, of every buffer.  Nothing is written;
the next pull bringing comments starts a new set."
  (interactive "P")
  (dolist (buffer (if all-buffers (buffer-list) (list (current-buffer))))
    (with-current-buffer buffer
      (dolist (state (zwanenzang--new-comment-states))
        (setf (zwanenzang--new-comments-new state) nil)
        (zwanenzang--mark-new-comments state nil))))
  (message "zwanenzang: new comments cleared%s" (if all-buffers " in every buffer" "")))

;;;; Comments

(defvar-local zwanenzang--comment-target nil
  "Compose target: heading marker, scope marker, ticket id and directory.")

(defvar-local zwanenzang--comment-window-configuration nil
  "Window configuration before displaying this compose buffer.")

(defvar-local zwanenzang--comment-return-to nil
  "Source point before composing, which window configurations do not save.")

(defvar-local zwanenzang--comment-status nil
  "The status this draft sets when sent, or nil to leave the status.")

(defvar-local zwanenzang--comment-tags nil
  "Tag changes this draft sends, as (TAG . add) or (TAG . remove), in order.")

(defvar-local zwanenzang--comment-tracker nil
  "The tracker's keyword map and tags, read once for this draft's pickers.")

(defvar zwanenzang-comment-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'zwanenzang-comment-send)
    (define-key map (kbd "C-c C-k") #'zwanenzang-comment-abort)
    (define-key map (kbd "C-c C-t") #'zwanenzang-comment-set-status)
    (define-key map (kbd "C-c C-q") #'zwanenzang-comment-toggle-tags)
    (define-key map (kbd "C-c C-a") #'zwanenzang-comment-hand-to-agent)
    map))

(define-derived-mode zwanenzang-comment-mode org-mode "ZW-Comment"
  "Compose an append-only tracker comment.
C-c C-c sends; C-c C-k aborts.  The buffer contains only comment text.
C-c C-t, C-c C-q and C-c C-a record a status and tag changes, which
the send writes together with the comment; until then nothing changes.")

(defconst zwanenzang-comment-agent-status "todo"
  "The status `zwanenzang-comment-hand-to-agent' sets.")

(defconst zwanenzang-comment-agent-tags '(("ready_for_agent" . add) ("needs_human" . remove))
  "The tag changes `zwanenzang-comment-hand-to-agent' sets.")

(defun zwanenzang--comment-heading ()
  "The ticket heading for a note at point, or nil.
A named document belongs to its direct parent ticket, not an inherited ID.
Structural headings and nested scopes never borrow an ancestor's ticket."
  (when (and (derived-mode-p 'org-mode) (not zwanenzang--document))
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
      (zwanenzang--comment-update-header))))

(defun zwanenzang--comment-pending-p ()
  "Whether this draft would change the ticket's status or tags."
  (or zwanenzang--comment-status zwanenzang--comment-tags))

(defun zwanenzang--comment-update-header ()
  "Show this draft's pending changes and keys in the header line."
  (setq header-line-format
        (if (zwanenzang--comment-pending-p)
            (format "Comment -> %s: C-c C-c send, C-c C-k abort"
                    (string-join
                     (append
                      (and zwanenzang--comment-status
                           (list (or (cdr (assoc zwanenzang--comment-status
                                                 (plist-get zwanenzang--comment-tracker :map)))
                                     zwanenzang--comment-status)))
                      (mapcar (lambda (change)
                                (concat (if (eq (cdr change) 'add) "+" "-") (car change)))
                              zwanenzang--comment-tags))
                     ", "))
          "Comment: C-c C-c send, C-c C-k abort, C-c C-t status, C-c C-q tags, C-c C-a hand to agent"))
  (force-mode-line-update))

(defun zwanenzang--comment-source ()
  "The live heading marker of this draft, or a user error."
  (unless zwanenzang--comment-target
    (user-error "zwanenzang: not a comment compose buffer"))
  (let ((heading (nth 0 zwanenzang--comment-target))
        (root (nth 1 zwanenzang--comment-target)))
    (unless (and (marker-buffer heading) (marker-buffer root))
      (user-error "zwanenzang: comment source buffer was killed"))
    heading))

(defun zwanenzang--comment-ticket-state ()
  "The source heading's keyword and tracker tags, as (KEYWORD . TAGS)."
  (let ((heading (zwanenzang--comment-source)))
    (with-current-buffer (marker-buffer heading)
      (org-with-wide-buffer
       (goto-char heading)
       (let ((shown (zwanenzang--heading)))
         (cons (plist-get shown :keyword)
               (zwanenzang--tracker-tags (plist-get shown :tags))))))))

(defun zwanenzang--comment-read-tracker ()
  "Read the draft's tracker; return its keyword map, retired statuses and tags.
The map is that of the source scope, so keywords mean what push sends."
  (or zwanenzang--comment-tracker
      (setq zwanenzang--comment-tracker
            (pcase-let ((`(,heading ,root ,_id ,dir) zwanenzang--comment-target))
              (zwanenzang--comment-source)
              (with-current-buffer (marker-buffer heading)
                (let* ((read (funcall zwanenzang--call dir '("read")
                                      '((cursors . nil) (since . :null))))
                       (refusal (zwanenzang--tracker-mismatch "comment" root dir read))
                       (tracker (alist-get 'tracker read))
                       (retired (alist-get 'retired_statuses tracker))
                       tags)
                  (when refusal (user-error "%s" refusal))
                  (dolist (summary (alist-get 'tickets (funcall zwanenzang--call dir
                                                                '("list" "--all"))))
                    (dolist (tag (alist-get 'tags summary))
                      (cl-pushnew tag tags :test #'equal)))
                  (list :map (car (zwanenzang--keyword-map
                                   (org-entry-get root "ZWANENZANG_KEYWORDS")
                                   (alist-get 'statuses tracker)
                                   org-todo-keywords-1 retired))
                        :retired retired
                        :tags tags)))))))

(defun zwanenzang--comment-pick-status (status)
  "Record STATUS as this draft's pending status.
A status shown with the heading's current keyword is no change, so
picking it clears a pending status, as push compares by keyword."
  (let ((keyword (cdr (assoc status (plist-get (zwanenzang--comment-read-tracker) :map)))))
    (unless keyword
      (user-error "zwanenzang: status %s has no keyword in this scope" status))
    (setq zwanenzang--comment-status
          (unless (equal keyword (car (zwanenzang--comment-ticket-state))) status))))

(defun zwanenzang--comment-pick-tag (tag change)
  "Record CHANGE, `add' or `remove', of TAG as pending.
A change the heading's current tags already reflect is dropped instead."
  (let ((current (member tag (cdr (zwanenzang--comment-ticket-state)))))
    (setq zwanenzang--comment-tags
          (seq-remove (lambda (c) (equal (car c) tag)) zwanenzang--comment-tags))
    (unless (eq (and current t) (eq change 'add))
      (setq zwanenzang--comment-tags
            (append zwanenzang--comment-tags (list (cons tag change)))))))

(defun zwanenzang--comment-tag-present-p (tag)
  "Whether TAG is on the ticket once this draft's pending changes apply."
  (let ((pending (assoc tag zwanenzang--comment-tags)))
    (if pending
        (eq (cdr pending) 'add)
      (and (member tag (cdr (zwanenzang--comment-ticket-state))) t))))

(defun zwanenzang--comment-read-keyword (map)
  "Ask for a keyword that MAP shows a current status with, as `org-todo' does.
Use Org's fast selection with the source buffer's keys when it has them."
  (let* ((heading (zwanenzang--comment-source))
         (current (car (zwanenzang--comment-ticket-state)))
         (keywords (delete-dups (mapcar #'cdr map))))
    (with-current-buffer (marker-buffer heading)
      (if (and org-use-fast-todo-selection org-todo-key-alist)
          (org-fast-todo-selection current)
        (completing-read "Status keyword: " keywords nil t nil nil current)))))

(defun zwanenzang-comment-set-status ()
  "Choose the status this comment sets when sent.
The choice is a TODO keyword, offered as `org-todo' offers it in the
source buffer.  Choosing the heading's current keyword clears the
pending status.  Nothing is written before \\[zwanenzang-comment-send]."
  (interactive)
  (zwanenzang--comment-source)
  (let* ((tracker (zwanenzang--comment-read-tracker))
         ;; Retired statuses come last in the map, so a shared keyword
         ;; reads as its current status; one only retired cannot be set.
         (map (seq-remove (lambda (e) (member (car e) (plist-get tracker :retired)))
                          (plist-get tracker :map)))
         (keyword (zwanenzang--comment-read-keyword map)))
    (when (and keyword (not (string-empty-p keyword)))
      (let ((status (car (rassoc keyword map))))
        (unless status
          (user-error "zwanenzang: keyword %s is not mapped to a current tracker status"
                      keyword))
        (zwanenzang--comment-pick-status status))))
  (zwanenzang--comment-update-header))

(defun zwanenzang-comment-toggle-tags (tags)
  "Toggle TAGS on the ticket when this comment is sent.
A tag the ticket would carry is removed, any other added.  Candidates
are the source buffer's Org tags and the tags tickets have in the
tracker.  Nothing is written before \\[zwanenzang-comment-send]."
  (interactive
   (let* ((heading (zwanenzang--comment-source))
          (candidates
           (seq-remove
            (lambda (tag) (member tag (list zwanenzang-conflict-tag org-archive-tag)))
            (delete-dups
             (append
              (with-current-buffer (marker-buffer heading)
                (append (seq-filter #'stringp (mapcar #'car-safe org-current-tag-alist))
                        (mapcar #'car (org-get-buffer-tags))))
              (plist-get (zwanenzang--comment-read-tracker) :tags))))))
     (list (completing-read-multiple "Toggle tags: " (sort candidates #'string<)))))
  (zwanenzang--comment-source)
  (dolist (tag tags)
    (unless (string-match-p (concat "\\`" org-tag-re "\\'") tag)
      (user-error "zwanenzang: %S is not an Org tag" tag))
    (when (member tag (list zwanenzang-conflict-tag org-archive-tag))
      (user-error "zwanenzang: %s is not a tracker tag" tag)))
  (dolist (tag tags)
    (zwanenzang--comment-pick-tag
     tag (if (zwanenzang--comment-tag-present-p tag) 'remove 'add)))
  (zwanenzang--comment-update-header))

(defun zwanenzang-comment-hand-to-agent ()
  "Hand the ticket to an agent when this comment is sent.
That is status todo, tag ready_for_agent and no needs_human: the
answer to an agent's question, review feedback or a new hand-over.
Nothing is written before \\[zwanenzang-comment-send]."
  (interactive)
  (zwanenzang--comment-source)
  (zwanenzang--comment-pick-status zwanenzang-comment-agent-status)
  (dolist (change zwanenzang-comment-agent-tags)
    (zwanenzang--comment-pick-tag (car change) (cdr change)))
  (zwanenzang--comment-update-header))

(defun zwanenzang--comment-unpushed (map)
  "Which of keyword and tags the heading at point changed since the last sync.
MAP is the keyword map.  An edit counts even when it matches the tracker:
until a push or pull records it, the pull after the send would compare
the sent change with the old baseline and keep the edit as a conflict."
  (let* ((shown (zwanenzang--heading))
         (keyword (plist-get shown :keyword))
         (tags (zwanenzang--tracker-tags (plist-get shown :tags)))
         (sync (zwanenzang--parse-sync (org-entry-get nil "ZWANENZANG_SYNC")))
         fields)
    (unless (equal keyword (cdr (assoc (zwanenzang--sync-get sync 'status) map)))
      (push "keyword" fields))
    (when (zwanenzang--edited-p (zwanenzang--tags-hash tags)
                                (zwanenzang--sync-get sync 'tags) (null tags))
      (push "tags" fields))
    (nreverse fields)))

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
Pending status and tag changes go in the same batch, after the comment;
with any pending, unpushed keyword or tag edits on the heading refuse
the send.  A refused write retains the draft.  Once accepted locally,
the draft is closed even if publication or the subsequent pull fails,
to avoid resend.  Return the comment's event id."
  (interactive)
  (unless zwanenzang--comment-target
    (user-error "zwanenzang: not a comment compose buffer"))
  (pcase-let* ((`(,heading ,root ,id ,dir) zwanenzang--comment-target)
               (draft (current-buffer))
               (status zwanenzang--comment-status)
               (tag-changes zwanenzang--comment-tags)
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
         (when (or status tag-changes)
           (let* ((tracker (alist-get 'tracker read))
                  (map (car (zwanenzang--keyword-map
                             (org-entry-get root "ZWANENZANG_KEYWORDS")
                             (alist-get 'statuses tracker) org-todo-keywords-1
                             (alist-get 'retired_statuses tracker))))
                  (unpushed (zwanenzang--comment-unpushed map)))
             ;; Sending would make the next pull overwrite the edit, or
             ;; the next push undo the change sent with the comment.
             (when unpushed
               (user-error "zwanenzang: push the heading first: its %s changed locally; draft retained"
                           (string-join unpushed " and ")))))
         ;; The comment comes first, so its event is the first result.
         (let* ((changes
                 (append
                  `(((op . "comment") (ticket . ,id) (data . ((text . ,text)))))
                  (and status `(((op . "status") (ticket . ,id) (data . ((to . ,status))))))
                  (mapcar (lambda (c) `((op . "tag") (ticket . ,id) (data . ((tag . ,(car c))))))
                          (seq-filter (lambda (c) (eq (cdr c) 'add)) tag-changes))
                  (mapcar (lambda (c) `((op . "untag") (ticket . ,id) (data . ((tag . ,(car c))))))
                          (seq-filter (lambda (c) (eq (cdr c) 'remove)) tag-changes))))
                (result (funcall zwanenzang--call dir '("apply")
                                 `((changes . ,(vconcat changes)))))
                (event (alist-get 'event (car (alist-get 'results result))))
                (outcome (zwanenzang--outcome-create)))
           ;; Before any pull, so the comment is never new to this session.
           (when (stringp event) (puthash event t zwanenzang--sent-comments))
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
           (zwanenzang--report-outcome "comment saved in" root outcome)
           event))))))

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
own subheadings stay folded.  Outside scopes Org behaves normally.

With a prefix argument in a scope, \\[org-kill-note-or-show-branches] does
the same for the whole scope, as `zwanenzang-show-scope-branches'.
Setting this to nil turns that off too."
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

(defun zwanenzang--show-branches-here ()
  "Do what plain \\[org-kill-note-or-show-branches] does on this heading."
  (org-back-to-heading t)
  (let ((beg (point))
        (end (save-excursion (org-end-of-subtree t t) (point))))
    (org-fold-hide-subtree)
    (org-fold-show-branches)
    (org-fold-hide-archived-subtrees beg end)))

(defun zwanenzang--accessible-scope-root ()
  "Position of the scope root at or above point, if it is accessible.
Unlike `zwanenzang--scope-root', this never widens: a root outside the
restriction gives nil."
  (save-excursion
    (org-back-to-heading t)
    (let (root)
      (while (and (not (setq root (and (org-entry-get nil "ZWANENZANG")
                                       (point))))
                  (org-up-heading-safe)))
      root)))

(defun zwanenzang--point-hidden-p ()
  "Whether the text at point is hidden by folding.
At the end of a line the character before point decides, so that point
at the end of a visible heading counts as visible."
  (invisible-p (if (and (eolp) (not (bolp))) (1- (point)) (point))))

(defun zwanenzang--show-scope-branches ()
  "Show branches down to tickets for the whole scope containing point.
Return nil, doing nothing, outside scopes or before the first heading.
When the scope root is outside the restriction, each outermost heading
in it is treated instead and the restriction stays.  Point stays where
it is unless that is now hidden; then it moves to the nearest visible
heading at or above it."
  (when (and (derived-mode-p 'org-mode)
             (not (org-before-first-heading-p))
             (org-entry-get nil "ZWANENZANG" t))
    (let ((root (zwanenzang--accessible-scope-root)))
      (save-excursion
        (if root
            (progn (goto-char root) (zwanenzang--show-branches-here))
          (goto-char (point-min))
          (unless (org-at-heading-p) (outline-next-heading))
          (while (and (< (point) (point-max)) (org-at-heading-p))
            (let ((next (save-excursion (org-end-of-subtree t t) (point))))
              (zwanenzang--show-branches-here)
              (goto-char next))))))
    (when (zwanenzang--point-hidden-p)
      (org-back-to-heading t)
      (while (and (invisible-p (point)) (org-up-heading-safe))))
    t))

;;;###autoload
(defun zwanenzang-show-scope-branches ()
  "Fold the scope at point and show its headings down to tickets.
That is \\[org-kill-note-or-show-branches] on the nearest scope root,
without moving point unless it ends up hidden.  Outside scopes, the same
as \\[org-kill-note-or-show-branches] at point.  Prefixed, that key does
this too; see `zwanenzang-show-branches-to-tickets'."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (user-error "zwanenzang: not an Org buffer"))
  (or (zwanenzang--show-scope-branches)
      (if (org-before-first-heading-p)
          (progn (org-fold-show-branches-buffer)
                 (org-fold-hide-archived-subtrees (point-min) (point-max)))
        (zwanenzang--show-branches-here))))

(defun zwanenzang--org-kill-note-or-show-branches (original &optional arg)
  "Call ORIGINAL, or with prefix ARG in a scope show the scope's branches.
In a note buffer the note is still aborted.  See
`zwanenzang-show-branches-to-tickets'."
  (interactive "P")
  (unless (and arg
               zwanenzang-show-branches-to-tickets
               (not org-finish-function)
               (zwanenzang--show-scope-branches))
    (funcall original)))

(advice-add 'org-kill-note-or-show-branches :around
            #'zwanenzang--org-kill-note-or-show-branches)

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

(defun zwanenzang--plan-docs (plan ref ticket texts)
  "Add to PLAN the inline named documents of ticket REF, the heading at point.
Earlier versions wrote them as subheadings, and push still sends their
edits, so nothing typed there is lost; the pull after it removes them.
TICKET and TEXTS are as in `zwanenzang--plan-doc'."
  (let (seen)
    (dolist (doc (zwanenzang--doc-headings))
      (let ((name (car doc)))
        (cond
         ((equal name "description")
          (zwanenzang--plan-line plan "%s: document heading \"description\" not pushed: %s"
                                 (zwanenzang--heading-label)
                                 "the description is the ticket's body"))
         ((member name seen)
          (zwanenzang--plan-line plan "%s: second heading for document %s not pushed"
                                 (zwanenzang--heading-label) name))
         (t
          (push name seen)
          (save-excursion
            (goto-char (cdr doc))
            (zwanenzang--plan-doc plan ref name ticket texts))))))))

(defun zwanenzang--plan-fields (plan heading ref entry map targets &optional known)
  "Add to PLAN what differs from sync state on HEADING, a scanned heading at point.
REF names its ticket in the request.  ENTRY is its read result, nil for a
new ticket.  MAP is the keyword map and TARGETS the ids that cannot be
parents.  KNOWN maps all tracker ids to
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
      ;; Status goes by keyword: an agnt shown as NEXT stays agnt until
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
           (base (zwanenzang--dependency-base sync refs)))
      (when (zwanenzang--edited-p (zwanenzang--tags-hash refs) base (null refs))
        (let (local)
          ;; Never silently drop malformed/unknown references from a push.
          ;; Refuse before apply, so no other field is partially written.
          (dolist (number refs)
            (let ((parsed (zwanenzang--ticket-number number))
                  matches)
              (when (and known parsed)
                (maphash (lambda (id summary)
                           (when (and (integerp (alist-get 'number summary))
                                      (equal parsed (zwanenzang--ticket-number
                                                     (alist-get 'display summary))))
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
    (zwanenzang--plan-docs plan ref ticket (alist-get 'documents entry))))

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

(defun zwanenzang--plan-push (headings blocked entries map &optional known)
  "The plan of one push, comparing Org with a read; the buffer is not changed.
HEADINGS is from `zwanenzang--scan-all', BLOCKED from
`zwanenzang--blocked-headings', ENTRIES the tickets of the read, MAP the
keyword map.  Creates come first, so later
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
            (zwanenzang--plan-fields plan h `((created . ,(cdr new))) nil map targets known))
           ((or (not id) (gethash id targets)))
           ((not (and (rassoc (plist-get shown :keyword) map)
                      (assoc (alist-get 'status (alist-get 'ticket entry)) map))))
           ((string-empty-p (plist-get shown :title))
            (zwanenzang--plan-line plan "%s: not pushed: the heading has no title" id))
           (t
            (zwanenzang--plan-fields plan h id entry map targets known))))))
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
                                                 org-todo-keywords-1
                                                 (alist-get 'retired_statuses
                                                            (alist-get 'tracker result))))
                   known)))
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
  ;; Read the title while the number is known, so its prefix goes too.
  (let ((heading (zwanenzang--heading)))
    (dolist (property (org-entry-properties nil 'standard))
      (when (string-prefix-p "ZWANENZANG" (car property))
        (org-entry-delete nil (car property))))
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
                                          (plist-get (zwanenzang--heading) :title)))
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
  ;; The other tracker's number prefix is not part of the title.
  (let ((heading (zwanenzang--heading)))
    (dolist (property (org-entry-properties nil 'standard))
      (when (and (string-prefix-p "ZWANENZANG" (car property))
                 (not (and document (member (car property)
                                            '("ZWANENZANG_DOC" "ZWANENZANG_DOC_FORMAT")))))
        (org-entry-delete nil (car property))))
    (zwanenzang--set-heading (plist-get heading :keyword) (plist-get heading :title)
                             (remove "zz_conflict" (plist-get heading :tags))))
  (zwanenzang--drop-archive-properties)
  (let ((drawers (mapcar #'list (append '("ZWANENZANG_CONFLICT") zwanenzang--tail-drawers
                                       zwanenzang--legacy-drawers))))
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
                        org-todo-keywords-1
                        (alist-get 'retired_statuses (alist-get 'tracker result))))))
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
                         (list heading) blocked (alist-get 'tickets result) map known)))
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
                                 (if (eq (car field) 'depends)
                                     (zwanenzang--dependency-base sync depends)
                                   (zwanenzang--sync-get sync (car field)))
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
                       org-todo-keywords-1
                       (alist-get 'retired_statuses (alist-get 'tracker result))))
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

;;;; Links

;; A `zwanenzang:' link names a ticket by id, or one of its documents as
;; `<id>/<name>'.  A ticket link jumps to the ticket's heading when the
;; scope it was followed from has one, and otherwise shows the ticket in
;; a read-only buffer.  The buffers these links open remember where they
;; came from, so links in them work as well.

(defvar-local zwanenzang--link-origin nil
  "Where links in a buffer the client made lead: a plist.
:dir is the tracker directory and :root a marker at the scope root
the buffer was opened from, or nil.")

(defun zwanenzang--link-follow (path _arg)
  "Open PATH, the target of a zwanenzang: link."
  (zwanenzang-open path))

(org-link-set-parameters "zwanenzang" :follow #'zwanenzang--link-follow)

(defun zwanenzang--current-link-origin ()
  "The `zwanenzang--link-origin' for a link followed at point."
  (or zwanenzang--link-origin
      (let ((root (zwanenzang--root-at-point)))
        (list :dir (zwanenzang--scope-directory root) :root root))))

(defun zwanenzang--display-buffer (name text origin)
  "Show TEXT in a read-only Org buffer NAME whose links follow ORIGIN.
Return the buffer."
  (let ((buffer (get-buffer-create name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert text)
        (goto-char (point-min))
        (org-mode))
      (setq zwanenzang--link-origin origin)
      (setq buffer-read-only t))
    (pop-to-buffer buffer)
    buffer))

(defun zwanenzang--find-ticket-heading (root id)
  "A position of the heading of ticket ID in the scope at ROOT, or nil."
  (with-current-buffer (marker-buffer root)
    (org-with-wide-buffer
     (let ((heading (seq-find (lambda (h) (equal (plist-get h :id) id))
                              (car (zwanenzang--scan root)))))
       (and heading (marker-position (plist-get heading :marker)))))))

(defun zwanenzang--jump-to (buffer pos)
  "Show POS in BUFFER as following an Org link would, widening if needed."
  (when (eq buffer (current-buffer)) (org-mark-ring-push))
  (pop-to-buffer-same-window buffer)
  (when (or (< pos (point-min)) (> pos (point-max))) (widen))
  (goto-char pos)
  (org-fold-show-context 'link-search)
  buffer)

(defun zwanenzang--show-text (entry known map pull)
  "The text of the read-only buffer showing ENTRY, one ticket of a read.
Tickets it refers to are labelled through KNOWN and the keyword MAP;
PULL carries the actor names and tracker directory for its comments."
  (let* ((ticket (alist-get 'ticket entry))
         (kind (zwanenzang--null (alist-get 'kind ticket)))
         (parent (zwanenzang--null (alist-get 'parent ticket)))
         (description (zwanenzang--normalize-text
                       (or (alist-get 'description (alist-get 'documents entry)) "")))
         (comments (zwanenzang--comments-content pull ticket))
         (documents (zwanenzang--documents-content pull ticket))
         (references (concat
                      (zwanenzang--list-content
                       `(("Parent" ,@(and parent (zwanenzang--ticket-links (list parent) known map)))
                         ("Children" ,@(zwanenzang--ticket-links (alist-get 'children ticket)
                                                                 known map))))
                      (zwanenzang--relations-content ticket known map)
                      (zwanenzang--code-content ticket))))
    (concat "* " (alist-get 'display ticket) " "
            (zwanenzang--one-line (alist-get 'title ticket)) "\n"
            (format "- Status :: %s\n" (alist-get 'status ticket))
            (if kind (format "- Kind :: %s\n" kind) "")
            (let ((tags (alist-get 'tags ticket)))
              (if tags (format "- Tags :: %s\n" (string-join tags " ")) ""))
            (cond ((eq (alist-get 'tombstoned ticket) t) "- Tombstoned\n")
                  ((eq (alist-get 'archived ticket) t) "- Archived\n")
                  (t ""))
            (if (string-empty-p description) ""
              (concat "** Description\n" (zwanenzang--escape-text description)))
            (if (string-empty-p comments) "" (concat "** Comments\n" comments))
            (if (string-empty-p documents) "" (concat "** Documents\n" documents))
            (if (string-empty-p references) "" (concat "** References\n" references)))))

(defun zwanenzang--show-ticket (id origin)
  "Show ticket ID of ORIGIN's tracker in a read-only Org buffer; return it."
  (let* ((dir (plist-get origin :dir))
         (root (plist-get origin :root))
         (live (and root (buffer-live-p (marker-buffer root))))
         (since (or (and live (org-entry-get root "ZWANENZANG_CURSOR")) :null))
         (result (funcall zwanenzang--call dir '("read")
                          `((cursors . ((,(intern id) . :null))) (since . ,since))))
         (tracker (alist-get 'tracker result))
         (entry (seq-find (lambda (e) (equal (alist-get 'id (alist-get 'ticket e)) id))
                          (alist-get 'tickets result)))
         (known (zwanenzang--known-tickets dir))
         (map (if live
                  (with-current-buffer (marker-buffer root)
                    (car (zwanenzang--keyword-map
                          (org-entry-get root "ZWANENZANG_KEYWORDS")
                          (alist-get 'statuses tracker) org-todo-keywords-1
                          (alist-get 'retired_statuses tracker))))
                nil)))
    (unless entry
      (user-error "zwanenzang: the tracker has no ticket %s" id))
    (dolist (e (alist-get 'tickets result))
      (puthash (alist-get 'id (alist-get 'ticket e)) (alist-get 'ticket e) known))
    (zwanenzang--display-buffer
     (format "*zwanenzang %s*" (alist-get 'display (alist-get 'ticket entry)))
     (zwanenzang--show-text entry known map
                            (zwanenzang--pull-create :actors (alist-get 'actors tracker)
                                                     :tracker-dir dir))
     origin)))

(defun zwanenzang-open (&optional path)
  "Open what a zwanenzang: link names; interactively, the link at point.
PATH is a ticket id or `<ticket id>/<document name>'.  A ticket with a
heading in the scope the link is in is shown there; any other ticket
is shown read-only in a buffer of its own.  A document opens in a
buffer for editing it, `zwanenzang-document-mode'.  The tracker
is the one of the scope containing point, or the one the buffer at
point was opened from."
  (interactive)
  (unless path
    (let ((context (org-element-context)))
      (unless (and (eq (org-element-type context) 'link)
                   (equal (org-element-property :type context) "zwanenzang"))
        (user-error "zwanenzang: no zwanenzang: link at point"))
      (setq path (org-element-property :path context))))
  (let ((origin (zwanenzang--current-link-origin)))
    (cond
     ((string-match "\\`[^/]+\\'" path)
      (let* ((root (plist-get origin :root))
             (pos (and root (buffer-live-p (marker-buffer root))
                       (zwanenzang--find-ticket-heading root path))))
        (if pos
            (zwanenzang--jump-to (marker-buffer root) pos)
          (zwanenzang--show-ticket path origin))))
     ((string-match "\\`\\([^/]+\\)/\\(.+\\)\\'" path)
      (zwanenzang--open-document (match-string 1 path) (match-string 2 path) origin))
     (t (user-error "zwanenzang: malformed link zwanenzang:%s" path)))))

;;;; Document buffers

;; Named documents are not written into Org files.  Following a document
;; link opens an editable Org buffer filled from `doc get', remembering the
;; version it shows; saving writes a new version with that version as its
;; base, so a version written since refuses the save instead of being
;; overwritten unseen.  Nothing is written to files.

(defvar-local zwanenzang--document nil
  "What this document buffer edits, a plist.
:id is the ticket id, :name the document name, :display the ticket's
number, :base the version shown (`:null' for a new document), :text the
text as loaded, :origin the link origin (tracker directory and scope
root), :windows and :return-to what to restore when closing, and
:replace the version a refused save found, with :replace-actor its
author.")

(defvar zwanenzang-document-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'zwanenzang-document-save)
    (define-key map (kbd "C-c C-k") #'zwanenzang-document-abort)
    map))

(define-derived-mode zwanenzang-document-mode org-mode "ZW-Doc"
  "Edit a tracker document.
\\[zwanenzang-document-save] writes a new version and pulls the scope the
document was opened from; \\[zwanenzang-document-abort] discards the edit.
When a version was written since this one, saving is refused and the
text kept; saving again asks whether to replace that version.
\\[zwanenzang-document-ediff] compares the text with the tracker's.")

(defun zwanenzang--document-update-header ()
  "Show this document buffer's target and keys in the header line."
  (let ((doc zwanenzang--document))
    (setq header-line-format
          (format "Document %s of %s%s: C-c C-c save, C-c C-k abort"
                  (plist-get doc :name) (plist-get doc :display)
                  (cond ((plist-get doc :replace)
                         (format " (newer version by %s; saving replaces it)"
                                 (plist-get doc :replace-actor)))
                        ((eq (plist-get doc :base) :null) " (new)")
                        (t "")))))
  (force-mode-line-update))

(defun zwanenzang--document-buffer (dir id name)
  "The live buffer editing document NAME of ticket ID in the tracker at DIR."
  (seq-find (lambda (buffer)
              (with-current-buffer buffer
                (let ((doc zwanenzang--document))
                  (and doc (equal (plist-get doc :id) id) (equal (plist-get doc :name) name)
                       (equal (plist-get (plist-get doc :origin) :dir) dir)))))
            (buffer-list)))

(defun zwanenzang--open-document (id name origin &optional new)
  "Open document NAME of ticket ID of ORIGIN's tracker; return the buffer.
Unless NEW, the document's current version is read with `doc get'; NEW
opens an empty buffer for a document to be created.  A buffer already
editing that document is shown as it is when it holds unsaved edits,
and refreshed otherwise."
  (let* ((dir (plist-get origin :dir))
         (existing (zwanenzang--document-buffer dir id name)))
    (if (and existing (buffer-modified-p existing))
        (progn (pop-to-buffer existing) existing)
      (let* ((doc (and (not new)
                       (funcall zwanenzang--call dir (list "doc" "get" id name))))
             (display (if doc (alist-get 'display doc)
                        (or (alist-get 'display (funcall zwanenzang--call dir (list "show" id)))
                            id)))
             (windows (current-window-configuration))
             (return-to (point-marker))
             (buffer (or existing
                         (generate-new-buffer (format "*zwanenzang %s %s*" display name)))))
        (pop-to-buffer buffer)
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (or (alist-get 'text doc) ""))
          (goto-char (point-min)))
        (zwanenzang-document-mode)
        (setq zwanenzang--link-origin origin
              zwanenzang--document
              (list :id id :name name :display display
                    :base (or (and doc (alist-get 'version doc)) :null)
                    :text (zwanenzang--normalize-text (or (alist-get 'text doc) ""))
                    :origin origin :windows windows :return-to return-to))
        (set-buffer-modified-p nil)
        (setq buffer-undo-list nil)
        (zwanenzang--document-update-header)
        buffer))))

(defun zwanenzang--document-check ()
  "Signal unless the current buffer edits a tracker document."
  (unless zwanenzang--document
    (user-error "zwanenzang: not a document buffer")))

(defun zwanenzang--document-close ()
  "Kill this document buffer, restoring the windows and point before it."
  (let ((windows (plist-get zwanenzang--document :windows))
        (return-to (plist-get zwanenzang--document :return-to)))
    (set-buffer-modified-p nil)
    (kill-buffer (current-buffer))
    (when windows (set-window-configuration windows))
    (when (and return-to (marker-buffer return-to))
      (with-current-buffer (marker-buffer return-to)
        (goto-char return-to)))
    (when return-to (set-marker return-to nil))))

(defun zwanenzang-document-abort ()
  "Discard this document buffer without writing a version."
  (interactive)
  (zwanenzang--document-check)
  (when (or (not (buffer-modified-p)) noninteractive
            (y-or-n-p "zwanenzang: discard the edits to this document? "))
    (zwanenzang--document-close)))

(defun zwanenzang--document-current (doc)
  "The current version of DOC's document, as (VERSION ACTOR TEXT).
ACTOR is the author's display name.  Nil when the document has none."
  (let* ((origin (plist-get doc :origin))
         (dir (plist-get origin :dir))
         (root (plist-get origin :root))
         (since (or (and root (buffer-live-p (marker-buffer root))
                         (org-entry-get root "ZWANENZANG_CURSOR"))
                    :null))
         (read (funcall zwanenzang--call dir '("read")
                        `((cursors . ((,(intern (plist-get doc :id)) . :null)))
                          (since . ,since))))
         (entry (seq-find (lambda (e) (equal (alist-get 'id (alist-get 'ticket e))
                                             (plist-get doc :id)))
                          (alist-get 'tickets read)))
         (name (intern (plist-get doc :name)))
         (state (alist-get name (alist-get 'documents (alist-get 'ticket entry))))
         (current (zwanenzang--null (alist-get 'current state)))
         (version (and current (seq-find (lambda (v) (equal (alist-get 'id v) current))
                                         (alist-get 'versions state)))))
    (when current
      (list current
            (if version
                (zwanenzang--actor-name
                 (zwanenzang--pull-create :actors (alist-get 'actors (alist-get 'tracker read)))
                 (alist-get 'actor version))
              "unknown")
            (or (alist-get name (alist-get 'documents entry)) "")))))

(defun zwanenzang-document-save ()
  "Write this buffer as a new version of its document, then pull its scope.
The base is the version the buffer was opened with.  When another
version was written since, nothing is written: the text stays, and
saving again asks whether to replace that version.  An unchanged
document is not written.  Return the accepted event, or nil."
  (interactive)
  (zwanenzang--document-check)
  (let* ((doc zwanenzang--document)
         (origin (plist-get doc :origin))
         (dir (plist-get origin :dir))
         (root (plist-get origin :root))
         ;; The whole document, whatever is narrowed: a save replaces it.
         (text (zwanenzang--normalize-text
                (save-restriction
                  (widen)
                  (buffer-substring-no-properties (point-min) (point-max)))))
         (base (plist-get doc :base)))
    (when (plist-get doc :replace)
      (unless (y-or-n-p (format "Replace version by %s? " (plist-get doc :replace-actor)))
        (user-error "zwanenzang: not saved; the text is kept"))
      (setq base (plist-get doc :replace)))
    (cond
     ((and (eq base :null) (string-empty-p text))
      (user-error "zwanenzang: the document is empty; nothing to save"))
     ((and (not (plist-get doc :replace)) (equal text (plist-get doc :text)))
      (zwanenzang--document-close)
      (message "zwanenzang: document %s unchanged; nothing written" (plist-get doc :name))
      nil)
     (t
      (let ((result
             (condition-case nil
                 (funcall zwanenzang--call dir '("apply")
                          `((changes . [((op . "doc") (ticket . ,(plist-get doc :id))
                                         (data . ((name . ,(plist-get doc :name))
                                                  (text . ,text)
                                                  (base . ,base))))])))
               (zwanenzang-stale-doc-base
                (pcase-let ((`(,version ,actor ,_text) (zwanenzang--document-current doc)))
                  (setq zwanenzang--document
                        (plist-put (plist-put doc :replace (or version :null))
                                   :replace-actor actor))
                  (zwanenzang--document-update-header)
                  (user-error "zwanenzang: %s wrote a version of %s since; text kept.  %s"
                              actor (plist-get doc :name)
                              "Save again to replace it, or abort"))))))
        (let ((event (alist-get 'event (car (alist-get 'results result))))
              (outcome (zwanenzang--outcome-create)))
          ;; The version is written: never offer to write it again.
          (zwanenzang--document-close)
          (zwanenzang--note-sync outcome (alist-get 'sync result))
          (push (format "saved document %s of %s" (plist-get doc :name) (plist-get doc :display))
                (zwanenzang--outcome-info outcome))
          (if (and root (buffer-live-p (marker-buffer root)))
              (progn
                (condition-case err
                    (zwanenzang--pull-into outcome root)
                  (error
                   (push (format "Document saved; pull failed: %s. Pull again; do not save again."
                                 (error-message-string err))
                         (zwanenzang--outcome-problems outcome))
                   (setf (zwanenzang--outcome-pull outcome) (zwanenzang--pull-create))))
                (zwanenzang--report-outcome "document saved in" root outcome))
            (zwanenzang-report
             (format "zwanenzang: saved document %s of %s"
                     (plist-get doc :name) (plist-get doc :display))
             (reverse (zwanenzang--outcome-problems outcome))
             (reverse (zwanenzang--outcome-info outcome))))
          event))))))

(defun zwanenzang-document-ediff ()
  "Compare this document buffer with the tracker's current version, in Ediff."
  (interactive)
  (zwanenzang--document-check)
  (let* ((doc zwanenzang--document)
         (current (zwanenzang--document-current doc))
         (buffer (get-buffer-create (format "*zwanenzang %s %s (tracker)*"
                                            (plist-get doc :display) (plist-get doc :name)))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (or (nth 2 current) ""))
        (org-mode))
      (setq buffer-read-only t))
    (ediff-buffers (current-buffer) buffer)))

;;;###autoload
(defun zwanenzang-new-document (name)
  "Open an empty buffer for a new document NAME of the ticket at point.
Saving it with \\[zwanenzang-document-save] creates the document.  A
name the ticket already has opens that document instead."
  (interactive (list (read-string "Document name: ")))
  (let* ((root (zwanenzang--root-at-point))
         (heading (or (zwanenzang--comment-heading)
                      (user-error "zwanenzang: point is not on a ticket")))
         (id (or (org-entry-get heading "ZWANENZANG_ID")
                 (user-error "zwanenzang: push this ticket before adding a document")))
         (dir (zwanenzang--scope-directory root))
         (origin (list :dir dir :root root)))
    (cond
     ((equal name "description")
      (user-error "zwanenzang: the description is the ticket's body, not a named document"))
     ((not (string-match-p "\\`[A-Za-z0-9_-]\\{1,64\\}\\'" name))
      (user-error "zwanenzang: a document name is 1 to 64 letters, digits, `-' or `_'")))
    (let* ((ticket (funcall zwanenzang--call dir (list "show" id)))
           (exists (zwanenzang--null
                    (alist-get 'current (alist-get (intern name) (alist-get 'documents ticket))))))
      (prog1 (zwanenzang--open-document id name origin (not exists))
        (when exists
          (message "zwanenzang: %s already has a document %s; opened it"
                   (alist-get 'display ticket) name))))))

(add-hook 'org-blocker-hook #'zwanenzang--block-dependencies)
(add-hook 'org-archive-hook #'zwanenzang--archive-hook)

(autoload 'zwanenzang-queue "zwanenzang-queue" nil t)

(provide 'zwanenzang)
;;; zwanenzang.el ends here
