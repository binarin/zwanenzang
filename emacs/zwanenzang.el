;;; zwanenzang.el --- Org client for the zwanenzang tracker  -*- lexical-binding: t; -*-

;; Author: Alexey Lebedeff
;; Version: 0.1.0
;; Package-Requires: ((emacs "31.1"))
;; Keywords: outlines, tools

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Two-way sync between Org subtrees and zwanenzang trackers.  A heading
;; with a ZWANENZANG property naming a tracker location is a scope root;
;; the ticket headings beneath it sync with that tracker through the
;; `zwanenzang' CLI and its JSON contract.
;;
;; Everything happens through explicit interactive commands: there is no
;; minor mode, hook or timer.  CLI calls are synchronous.
;;
;; The design is in docs/design/03-org-client.md and the CLI contract in
;; docs/cli-json.md of the zwanenzang repository.

;;; Code:

(require 'cl-lib)
(require 'org)
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

(defun zwanenzang-call (directory args &optional input)
  "Run the CLI on the tracker at or above DIRECTORY with ARGS; return its JSON.
INPUT, when non-nil, is encoded as JSON on stdin.  A failed command
signals `user-error' naming the error code and message: a JSON error
object, a usage error (exit status 2), or a non-zero exit with no JSON.
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
      (user-error "zwanenzang: %s: %s"
                  (alist-get 'code err) (alist-get 'message err)))
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
;; Org escapes such lines in blocks: a heading line, and a drawer-like line
;; that would otherwise read as a drawer (one with an :END: below it, or
;; named like the client's own drawers).  Reading strips that one comma
;; again, along with the comma of any `#+' line an earlier version of the
;; client escaped, so the two are inverse.

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
  (let ((rest (split-string text "\n"))
        (case-fold-search t)
        out)
    (while rest
      (let ((line (pop rest)))
        (push (if (or (string-match-p zwanenzang--heading-line-re line)
                      (string-match-p zwanenzang--escaped-line-re line)
                      (string-match-p zwanenzang--client-drawer-re line)
                      (and (string-match-p zwanenzang--drawer-line-re line)
                           (not (string-match-p zwanenzang--end-line-re line))
                           (seq-some (lambda (l) (string-match-p zwanenzang--end-line-re l))
                                     rest)))
                  (concat "," line)
                line)
              out)))
    (string-join (nreverse out) "\n")))

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
Nil when nothing does.  Only a drawer of the client's can hold one of the
client's opening lines, so a lone drawer-like line of text in front of
them is text, not a drawer running through them."
  (let ((case-fold-search t)
        (own (string-match-p zwanenzang--client-drawer-re (aref lines start))))
    (cl-loop for j from (1+ start) below (length lines)
             for line = (aref lines j)
             when (string-match-p zwanenzang--end-line-re line) return j
             when (and (not own) (string-match-p zwanenzang--client-drawer-re line))
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

(defun zwanenzang--write-body (new)
  "Replace the body of the heading at point with NEW, if it differs."
  (unless (equal new (zwanenzang--body))
    (save-excursion
      (org-back-to-heading t)
      (end-of-line)
      (when (eobp) (insert "\n"))
      (pcase-let ((`(,start . ,end) (zwanenzang--body-bounds)))
        (goto-char start)
        (delete-region start end)
        (insert new)))))

(defun zwanenzang--put (property value)
  "Set PROPERTY of the entry at point to VALUE, or remove it when nil.
Nothing changes when it already has that value."
  (unless (equal (org-entry-get nil property) value)
    (if value
        (org-entry-put nil property value)
      (org-entry-delete nil property))))

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
            :title (string-trim (substring-no-properties (org-get-heading t t t t)))
            :tags (mapcar #'substring-no-properties (org-get-tags nil t))))))

(defun zwanenzang--set-heading (keyword title tags)
  "Give the heading at point KEYWORD, TITLE and TAGS.
Its level, priority and COMMENT marker stay.  Nothing is written when
the heading already reads that way."
  (save-excursion
    (org-back-to-heading t)
    (let ((case-fold-search nil)
          (old (zwanenzang--heading)))
      (unless (and (equal keyword (plist-get old :keyword))
                   (equal title (plist-get old :title))
                   (equal tags (plist-get old :tags)))
        (let* ((parts (org-heading-components))
               (priority (nth 3 parts))
               (headline (or (nth 4 parts) ""))
               ;; The stars stay, and with them markers at the heading.
               (line (concat (and keyword (concat " " keyword))
                             (and priority (format " [#%c]" priority))
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
  (let* ((end (zwanenzang--subtree-end from))
         (from-level (save-excursion (goto-char from) (org-current-level)))
         (text (buffer-substring-no-properties from end)))
    (unless (string-suffix-p "\n" text) (setq text (concat text "\n")))
    (delete-region from end)
    (save-excursion
      (goto-char to)
      (let ((delta (- (1+ (org-current-level)) from-level)))
        (goto-char (zwanenzang--subtree-end to))
        (unless (bolp) (insert "\n"))
        (insert (zwanenzang--relevel text delta))))))

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

;;;; Sync state

;; ZWANENZANG_SYNC holds the fields as last synced: the tracker status,
;; hashes of title and tags, the tracker parent and the nesting the
;; heading had then (they differ when the parent has no heading in scope).
;; "-" is none; a missing key is unknown.

(defconst zwanenzang--sync-keys '(status title tags parent nest))

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
  "The :ZWANENZANG_COMMENTS: drawer content for TICKET, oldest first."
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
   (alist-get 'comments ticket) ""))

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
  (let ((local (zwanenzang--hash (zwanenzang--body-description (zwanenzang--body)))))
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
              (pcase (zwanenzang--merge-prose remote fresh "ZWANENZANG_HASH")
                ('conflict
                 (push (list (format "document %s" name)
                             (format "tracker version %s skipped; Org text kept" version)
                             remote)
                       conflicts))
                (decision
                 (when (eq decision 'apply)
                   (zwanenzang--write-body
                    (zwanenzang--compose-body (zwanenzang--body) nil remote)))
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
        (let ((remote (alist-get 'tags ticket)))
          (when (settle "tags" (zwanenzang--merge (zwanenzang--tags-hash tags)
                                                  (zwanenzang--sync-get sync 'tags)
                                                  (zwanenzang--tags-hash remote))
                        "tracker tags skipped; Org tags kept"
                        (if remote (string-join remote " ") "(none)")
                        'tags (zwanenzang--tags-hash remote))
            (setq tags remote)))
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
        (zwanenzang--put "ZWANENZANG_CURSOR" (zwanenzang--null (alist-get 'cursor entry)))
        (zwanenzang--put "ZWANENZANG_SYNC" (zwanenzang--format-sync new-sync))
        (when desc-state
          (zwanenzang--put "ZWANENZANG_DESC_VERSION" (nth 0 desc-state))
          (zwanenzang--put "ZWANENZANG_DESC_HASH" (nth 1 desc-state)))
        (zwanenzang--set-heading
         keyword title
         (append tags
                 (and (member org-archive-tag (plist-get heading :tags)) (list org-archive-tag))
                 (and conflicts (list zwanenzang-conflict-tag))))
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
          (zwanenzang--tracker-tags (plist-get heading :tags))
          (zwanenzang--segments-text segments)
          (seq-filter (lambda (s) (member (nth 2 s) zwanenzang--tail-drawers)) segments)
          (mapcar (lambda (doc)
                    (save-excursion
                      (goto-char (cdr doc))
                      (zwanenzang--body-description (zwanenzang--body))))
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
        (id (alist-get 'id (alist-get 'tracker result))))
    (when (and stored (not (equal stored id)))
      (format "zwanenzang: %s of %s blocked: it is bound to tracker %s, %s is %s"
              what (zwanenzang--scope-name root) stored dir id))))

(defun zwanenzang--hide-docs (root)
  "The names in the ZWANENZANG_HIDE_DOCS of the scope at ROOT."
  (split-string (or (org-entry-get root "ZWANENZANG_HIDE_DOCS") "")))

(defun zwanenzang--pull-scope (root)
  "Pull the scope at ROOT, a marker at its root heading; return the pull.
The CLI is only read from.  All changes to the buffer are one undo step
and the buffer is not saved."
  (with-current-buffer (marker-buffer root)
    (org-with-wide-buffer
     (let* ((case-fold-search nil)
            (dir (zwanenzang--scope-directory root))
            (tickets (car (zwanenzang--scan root)))
            (blocked (zwanenzang--blocked-headings tickets (zwanenzang--known-tickets dir)))
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
           (zwanenzang--one-undo-step
             (zwanenzang--apply-read pull result blocked tickets))))
       pull))))

;;;; Reports of a whole command

(cl-defstruct (zwanenzang--outcome (:constructor zwanenzang--outcome-create)
                                   (:copier nil))
  "What one command collected on one scope, for its report."
  pull                                  ; the last pull: its conflicts still stand
  problems info                         ; lines, newest first
  pulled (new 0) (moved 0) (created 0) (pushed 0)
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
        (zwanenzang-report (zwanenzang--outcome-refused outcome))
      (let* ((pull (zwanenzang--outcome-pull outcome))
             (parts (delq nil
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
                             "with conflicts" "blocked")))))
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
  touched                               ; (ID . what changed) of tickets
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
  (let* ((local (zwanenzang--body-description (zwanenzang--body)))
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

(defun zwanenzang--plan-fields (plan heading ref entry map hidden targets)
  "Add to PLAN what differs from sync state on HEADING, a scanned heading at point.
REF names its ticket in the request.  ENTRY is its read result, nil for a
new ticket.  MAP is the keyword map, HIDDEN the hidden documents and
TARGETS the ids that cannot be parents."
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
    (when (zwanenzang--edited-p (zwanenzang--tags-hash tags)
                                (zwanenzang--sync-get sync 'tags) (null tags))
      (let ((remote (alist-get 'tags ticket)))
        (dolist (tag (seq-difference tags remote))
          (zwanenzang--plan-add plan "tag" ref `((tag . ,tag))))
        (dolist (tag (seq-difference remote tags))
          (zwanenzang--plan-add plan "untag" ref `((tag . ,tag))))))
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
    ("doc" (let ((name (alist-get 'name (alist-get 'data change))))
             (if (equal name "description") name (format "document %s" name))))
    (op op)))

(defun zwanenzang--plan-push (headings blocked entries map hidden)
  "The plan of one push, comparing Org with a read; the buffer is not changed.
HEADINGS is from `zwanenzang--scan-all', BLOCKED from
`zwanenzang--blocked-headings', ENTRIES the tickets of the read, MAP the
keyword map and HIDDEN the hidden documents.  Creates come first, so later
changes can refer to them.  The rest go in buffer order, ancestors first,
so a reshuffled nesting has no moment with a parent cycle."
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
               (before (length (zwanenzang--plan-changes plan)))
               (shown (zwanenzang--heading)))
          (cond
           (new
            (zwanenzang--plan-fields plan h `((created . ,(cdr new))) nil map hidden targets))
           ((or (not id) (gethash id targets)))
           ((not (and (rassoc (plist-get shown :keyword) map)
                      (assoc (alist-get 'status (alist-get 'ticket entry)) map))))
           ((string-empty-p (plist-get shown :title))
            (zwanenzang--plan-line plan "%s: not pushed: the heading has no title" id))
           (t
            (zwanenzang--plan-fields plan h id entry map hidden targets)
            (let ((added (- (length (zwanenzang--plan-changes plan)) before)))
              (when (> added 0)
                (push (cons id (delete-dups
                                (mapcar #'zwanenzang--plan-label
                                        (reverse (seq-take (zwanenzang--plan-changes plan) added)))))
                      (zwanenzang--plan-touched plan)))))))))
    plan))

(defun zwanenzang--drop-archive-properties ()
  "Remove what `org-archive-subtree' left on the entry at point."
  (dolist (property (org-entry-properties nil 'standard))
    (when (string-prefix-p "ARCHIVE_" (car property))
      (org-entry-delete nil (car property)))))

(defun zwanenzang--send-plan (plan dir outcome)
  "Send PLAN to the tracker at DIR and write back what it returns to Org.
The identity of a new ticket is written right away, whatever fails after
this: without it the next push would create the ticket again.  An empty
plan sends nothing.  OUTCOME collects the report."
  (let ((changes (reverse (zwanenzang--plan-changes plan))))
    (when changes
      (let* ((result (funcall zwanenzang--call dir '("apply")
                              `((changes . ,(vconcat changes)))))
             (created (alist-get 'created result))
             (labels (mapcar (lambda (ticket) (cons (alist-get 'id ticket)
                                                    (zwanenzang--label ticket)))
                             (alist-get 'tickets result))))
        (pcase-dolist (`(,marker . ,index) (reverse (zwanenzang--plan-news plan)))
          (let ((id (alist-get (intern (number-to-string index)) created)))
            (org-entry-put marker "ZWANENZANG_ID" id)
            (cl-incf (zwanenzang--outcome-created outcome))
            (push (format "created %s" (cdr (assoc id labels)))
                  (zwanenzang--outcome-info outcome))))
        (dolist (marker (zwanenzang--plan-revived plan))
          (save-excursion
            (goto-char marker)
            (zwanenzang--drop-archive-properties)))
        (pcase-dolist (`(,id . ,what) (reverse (zwanenzang--plan-touched plan)))
          (cl-incf (zwanenzang--outcome-pushed outcome))
          (push (format "pushed %s: %s" (cdr (assoc id labels)) (string-join what ", "))
                (zwanenzang--outcome-info outcome)))
        (zwanenzang--note-sync outcome (alist-get 'sync result))))))

(defun zwanenzang--push-scope (root outcome)
  "Push the scope at ROOT and pull again, adding the result to OUTCOME.
A failed apply signals, having written nothing to the tracker or the buffer."
  (with-current-buffer (marker-buffer root)
    (org-with-wide-buffer
     (let* ((case-fold-search nil)
            (dir (zwanenzang--scope-directory root))
            (headings (plist-get (zwanenzang--scan-all root) :headings))
            (tickets (seq-filter (lambda (h) (plist-get h :id)) headings))
            (blocked (zwanenzang--blocked-headings tickets (zwanenzang--known-tickets dir)))
            (result (zwanenzang--read-scope root dir tickets blocked))
            (refused (zwanenzang--tracker-mismatch "push" root dir result)))
       (if refused
           (setf (zwanenzang--outcome-refused outcome) refused)
         (let ((plan (zwanenzang--plan-push
                      headings blocked (alist-get 'tickets result)
                      (car (zwanenzang--keyword-map (org-entry-get root "ZWANENZANG_KEYWORDS")
                                                    (alist-get 'statuses (alist-get 'tracker result))
                                                    org-todo-keywords-1))
                      (remove "description" (zwanenzang--hide-docs root)))))
           (setf (zwanenzang--outcome-problems outcome)
                 (append (zwanenzang--plan-lines plan) (zwanenzang--outcome-problems outcome)))
           (zwanenzang--send-plan plan dir outcome)
           (zwanenzang--pull-into outcome root)))))))

;;;###autoload
(defun zwanenzang-push ()
  "Push the human's edits in the scope containing point to the tracker.
Whatever differs from the last sync is sent, new tickets included, and
Org's value wins.  A pull follows, so numbers and cursors land.  The
buffer is edited but not saved; a report goes to the `*zwanenzang*' buffer."
  (interactive)
  (let ((root (zwanenzang--root-at-point))
        (outcome (zwanenzang--outcome-create)))
    (zwanenzang--push-scope root outcome)
    (zwanenzang--report-outcome "pushed" root outcome)))

(defun zwanenzang--sync-scope (root)
  "Run the CLI's sync, a pull and a push on the scope at ROOT; report the result."
  (let ((outcome (zwanenzang--outcome-create))
        (dir (with-current-buffer (marker-buffer root) (zwanenzang--scope-directory root))))
    (zwanenzang--note-sync outcome (alist-get 'sync (funcall zwanenzang--call dir '("sync"))))
    (zwanenzang--pull-into outcome root)
    (unless (zwanenzang--outcome-refused outcome)
      (zwanenzang--push-scope root outcome))
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
A scope that fails is reported and the others still run."
  (interactive)
  (let ((done 0) failures)
    (dolist (file (zwanenzang--org-files))
      (if (not (file-exists-p file))
          (push (format "%s: no such file" file) failures)
        (with-current-buffer (find-file-noselect file)
          (dolist (root (zwanenzang--scope-roots))
            (condition-case err
                (progn (zwanenzang--sync-scope root)
                       (cl-incf done))
              (user-error
               (push (format "%s: %s: %s" file
                             (org-with-wide-buffer (zwanenzang--scope-name root))
                             (error-message-string err))
                     failures)))))))
    (zwanenzang-report (format "zwanenzang: synced %d scopes, %d failed" done (length failures))
                       (reverse failures))))

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

(provide 'zwanenzang)
;;; zwanenzang.el ends here
