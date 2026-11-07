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

(defun zwanenzang-report (summary &optional details)
  "Echo SUMMARY and append it with DETAILS to the `*zwanenzang*' buffer.
DETAILS is a list of strings, one line each.  This is for outcomes that
are not failures, such as a sync that could not publish; the report keeps
what the one-line echo cannot hold."
  (with-current-buffer (get-buffer-create zwanenzang-report-buffer)
    (unless (derived-mode-p 'special-mode)
      (special-mode))
    (let ((inhibit-read-only t))
      (save-excursion
        (goto-char (point-max))
        (unless (bobp) (insert "\n"))
        (insert (format-time-string "[%F %T] ") summary "\n")
        (dolist (line details)
          (insert "  " line "\n")))))
  (message "%s%s" summary
           (if details (format " (see %s)" zwanenzang-report-buffer) "")))

;;;; Text in Org

;; Tracker text goes into Org bodies.  A line that Org would read as a
;; heading, a drawer boundary or an in-buffer setting gets a leading comma,
;; as Org escapes such lines in blocks, so a description cannot break the
;; outline it sits in.  Reading strips that one comma again, so the two
;; are inverse.

(defconst zwanenzang--escaped-line-re
  (concat "\\`,*\\(?:\\*+\\(?:[ \t]\\|\\'\\)\\|#\\+"
          "\\|[ \t]*:\\(?:\\w\\|[-_]\\)+:[ \t]*\\'\\)")
  "Lines that need a comma in front to stay plain text in an Org body.")

(defun zwanenzang--map-lines (fn text)
  "Apply FN to each line of TEXT and join the results again."
  (mapconcat fn (split-string text "\n") "\n"))

(defun zwanenzang--escape-text (text)
  "TEXT with every structural line escaped by a leading comma."
  (zwanenzang--map-lines
   (lambda (line)
     (if (string-match-p zwanenzang--escaped-line-re line) (concat "," line) line))
   text))

(defun zwanenzang--unescape-text (text)
  "TEXT with the comma `zwanenzang--escape-text' added removed."
  (zwanenzang--map-lines
   (lambda (line)
     (if (and (string-prefix-p "," line)
              (string-match-p zwanenzang--escaped-line-re (substring line 1)))
         (substring line 1)
       line))
   text))

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
;; description is the text, without drawers or planning lines.

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
         ((and start (string-match-p org-planning-line-re line))
          (push (list 'planning (concat line "\n")) segments)
          (cl-incf i))
         ((and (string-match org-drawer-regexp line)
               (not (string-equal-ignore-case (match-string 1 line) "END"))
               (setq end (cl-loop for j from (1+ i) below n
                                  when (string-match-p org-property-end-re (aref lines j))
                                  return j)))
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
name is dropped, and one with non-empty content is written after the
other drawers.  Drawers not named stay where they are.  Without
DESCRIPTION the text is kept exactly as it stands; with it the text is
replaced by DESCRIPTION, escaped, after all drawers."
  (let* ((segments (zwanenzang--body-segments body))
         (kept (seq-remove (lambda (s)
                             (or (eq (car s) 'text)
                                 (and (eq (car s) 'drawer) (assoc (nth 2 s) drawers))))
                           segments)))
    (concat (mapconcat #'cadr kept "")
            (mapconcat (lambda (d) (or (zwanenzang--render-drawer (car d) (cdr d)) ""))
                       drawers "")
            (if description
                (zwanenzang--escape-text (zwanenzang--normalize-text description))
              (zwanenzang--segments-text segments)))))

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

(defun zwanenzang--scan (root)
  "The ticket headings in the scope at ROOT, in buffer order, and its inbox.
Return (TICKETS . INBOX).  Each ticket is a plist with :id, :marker and
:nest, the id of the nearest ticket heading above it in the scope or
nil.  INBOX is a marker at the root's child with ZWANENZANG_INBOX: t,
or nil.  The subtree of a scope root nested inside is another scope and
is skipped."
  (save-excursion
    (goto-char root)
    (let ((root-level (org-current-level))
          (end (zwanenzang--subtree-end root))
          stack tickets inbox)
      (outline-next-heading)
      (while (< (point) end)
        (let ((level (org-current-level)))
          (if (org-entry-get nil "ZWANENZANG")
              (org-end-of-subtree t t)
            (while (and stack (>= (caar stack) level)) (pop stack))
            (let ((id (org-entry-get nil "ZWANENZANG_ID")))
              (when (and (not inbox) (= level (1+ root-level))
                         (equal (org-entry-get nil "ZWANENZANG_INBOX") "t"))
                (setq inbox (zwanenzang--heading-marker)))
              (when id
                (push (list :id id :marker (zwanenzang--heading-marker)
                            :nest (cdr (seq-find #'cdr stack)))
                      tickets))
              (push (cons level id) stack))
            (outline-next-heading))))
      (cons (nreverse tickets) inbox))))

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
  moves lines (pulled 0) (new 0) (moved 0) (conflicted 0) (blocked 0))

(defun zwanenzang--pull-line (pull format &rest args)
  "Add a line to PULL's report, formatted from FORMAT and ARGS."
  (push (apply #'format format args) (zwanenzang--pull-lines pull)))

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
               (zwanenzang--fixed-width (alist-get 'text c) "  ")
               (and link
                    (concat "  "
                            (org-link-make-string
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
      (push (cons (alist-get 'id ticket) (or expected :inbox)) (zwanenzang--pull-moves pull))
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

(defun zwanenzang--note-result (pull ticket result)
  "Count RESULT of pulling TICKET in PULL and report what needs attention."
  (cond
   ((eq result 'blocked)
    (cl-incf (zwanenzang--pull-blocked pull))
    (zwanenzang--pull-line pull "%s: blocked, tracker status %s has no keyword"
                           (zwanenzang--label ticket) (alist-get 'status ticket)))
   (result
    (cl-incf (zwanenzang--pull-conflicted pull))
    (zwanenzang--pull-line pull "%s: conflict in %s" (zwanenzang--label ticket)
                           (string-join result ", "))))
  (when (eq (alist-get 'archived ticket) t)
    (zwanenzang--pull-line pull "%s: archived in the tracker" (zwanenzang--label ticket))))

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
              (cl-incf (zwanenzang--pull-new pull))))
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
            (zwanenzang--note-result pull (alist-get 'ticket entry)
                                     (zwanenzang--pull-ticket pull entry (plist-get tk :nest))))
          (cl-incf (zwanenzang--pull-pulled pull)))))
    (dolist (move (reverse (zwanenzang--pull-moves pull)))
      (zwanenzang--rescan pull)
      (let* ((from (gethash (car move) ids))
             (to (if (eq (cdr move) :inbox)
                     (zwanenzang--ensure-inbox root)
                   (gethash (cdr move) ids)))
             (label (alist-get 'display (alist-get 'ticket (gethash (car move) entries)))))
        (if (and (<= from to) (< to (zwanenzang--subtree-end from)))
            (zwanenzang--pull-line pull "%s: not moved, the new parent is nested inside it" label)
          (zwanenzang--move-subtree from to)
          (cl-incf (zwanenzang--pull-moved pull)))))
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

(defun zwanenzang--known-ids (dir)
  "The ids of every ticket the tracker at DIR knows, as a hash set."
  (let ((ids (make-hash-table :test #'equal)))
    (dolist (s (alist-get 'tickets (funcall zwanenzang--call dir '("list" "--all"))))
      (puthash (alist-get 'id s) t ids))
    ids))

(defun zwanenzang--pull-scope (root)
  "Pull the scope at ROOT, a marker at its root heading; return the summary.
The CLI is only read from.  All changes to the buffer are one undo step
and the buffer is not saved."
  (with-current-buffer (marker-buffer root)
    (org-with-wide-buffer
     (let* ((case-fold-search nil)
            (dir (zwanenzang--scope-directory root))
            (tickets (car (zwanenzang--scan root)))
            (counts (make-hash-table :test #'equal))
            (known (zwanenzang--known-ids dir))
            (pull (zwanenzang--pull-create :root root :dir dir))
            blocked cursors)
       (dolist (tk tickets)
         (cl-incf (gethash (plist-get tk :id) counts 0)))
       ;; Duplicate and foreign ids block only their headings, and are
       ;; never sent to read.
       (dolist (tk tickets)
         (let* ((id (plist-get tk :id))
                (line (line-number-at-pos (plist-get tk :marker) t))
                (note
                 (cond
                  ((> (gethash id counts) 1)
                   (format "duplicate: ZWANENZANG_ID %s is on %d headings in this scope (lines %s)"
                           id (gethash id counts)
                           (mapconcat (lambda (o) (number-to-string
                                                   (line-number-at-pos (plist-get o :marker) t)))
                                      (seq-filter (lambda (o) (equal (plist-get o :id) id)) tickets)
                                      ", ")))
                  ((not (gethash id known))
                   (format "foreign: the tracker has no ticket %s" id)))))
           (if note
               (progn (push (cons tk note) blocked)
                      (zwanenzang--pull-line pull "line %d: %s" line note))
             (puthash id (plist-get tk :marker) (zwanenzang--pull-ids pull))
             (push (cons (intern id)
                         (or (org-entry-get (plist-get tk :marker) "ZWANENZANG_CURSOR") :null))
                   cursors))))
       (let* ((result (funcall zwanenzang--call dir '("read")
                               `((cursors . ,(nreverse cursors))
                                 (since . ,(or (org-entry-get root "ZWANENZANG_CURSOR") :null)))))
              (tracker (alist-get 'tracker result))
              (stored (org-entry-get root "ZWANENZANG_TRACKER"))
              (scope-name (substring-no-properties
                           (save-excursion (goto-char root) (org-get-heading t t t t)))))
         (if (and stored (not (equal stored (alist-get 'id tracker))))
             (zwanenzang-report
              (format "zwanenzang: pull of %s blocked: it is bound to tracker %s, %s is %s"
                      scope-name stored dir (alist-get 'id tracker)))
           (let ((km (zwanenzang--keyword-map (org-entry-get root "ZWANENZANG_KEYWORDS")
                                              (alist-get 'statuses tracker)
                                              org-todo-keywords-1)))
             (setf (zwanenzang--pull-map pull) (car km)
                   (zwanenzang--pull-hidden pull)
                   (split-string (or (org-entry-get root "ZWANENZANG_HIDE_DOCS") ""))
                   (zwanenzang--pull-actors pull) (alist-get 'actors tracker)
                   (zwanenzang--pull-tracker-dir pull) dir)
             (dolist (p (cdr km)) (zwanenzang--pull-line pull "%s" p)))
           (when (eq (alist-get 'reset result) t)
             (zwanenzang--pull-line
              pull "history changed under the scope cursor: compared in full"))
           (zwanenzang--one-undo-step
             (zwanenzang--apply-read pull result blocked tickets))
           (zwanenzang-report
            (format (concat "zwanenzang: pulled %s: %d tickets, %d new, %d moved,"
                            " %d with conflicts, %d blocked")
                    scope-name (zwanenzang--pull-pulled pull) (zwanenzang--pull-new pull)
                    (zwanenzang--pull-moved pull) (zwanenzang--pull-conflicted pull)
                    (zwanenzang--pull-blocked pull))
            (reverse (zwanenzang--pull-lines pull)))))))))

;;;###autoload
(defun zwanenzang-pull ()
  "Pull the tracker's state into the scope containing point.
Only the buffer changes: the tracker is read, not written, and nothing
is saved.  The changes undo as one step.  A summary is echoed and a
report appended to the `*zwanenzang*' buffer."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (user-error "zwanenzang: not an Org buffer"))
  (zwanenzang--pull-scope (zwanenzang--scope-root)))

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
        (goto-char (point-min)))
      (special-mode))
    (pop-to-buffer buffer)
    buffer))

(provide 'zwanenzang)
;;; zwanenzang.el ends here
