;;; zwanenzang-test-helpers.el --- Shared ERT helpers  -*- lexical-binding: t; -*-

;;; Commentary:

;; Every tracker these tests touch is a directory under the system temporary
;; directory whose name ends in `-test-repo'.  Each helper that opens, writes
;; to or pushes from one checks both markers first and signals otherwise,
;; as tests/common/mod.rs does for the Rust tests.  The CLI searches upward
;; from -C DIR for the tracker it opens, and sync can write the human
;; checkouts a clone lists, so those are checked as well.  The client itself
;; has no bypass; this guard exists only here.
;;
;; Every CLI invocation in the tests goes through `zwanenzang-test-run' or
;; `zwanenzang-test-call', and every git invocation through
;; `zwanenzang-test-git', even where the program is a stand-in script, so
;; the guard is the one way in.  Tests never call `zwanenzang--run',
;; `zwanenzang-call' or git directly.

;;; Code:

(require 'ert)
(require 'zwanenzang)

(defconst zwanenzang-test-marker "-test-repo")

(defun zwanenzang-test--temp-root ()
  "The system temporary directory, with symbolic links resolved."
  (file-name-as-directory
   (file-truename temporary-file-directory)))

(defun zwanenzang-test-not-disposable (path)
  "Why PATH is not disposable, or nil when it carries both markers."
  (let ((p (directory-file-name (file-truename (expand-file-name path))))
        (tmp (zwanenzang-test--temp-root)))
    (cond
     ((not (string-prefix-p tmp (file-name-as-directory p)))
      (format "%s is not under the temporary directory %s" p tmp))
     ((not (string-suffix-p zwanenzang-test-marker (file-name-nondirectory p)))
      (format "%s: directory name does not end in %s" p zwanenzang-test-marker)))))

(defun zwanenzang-test-assert-disposable (path)
  "Signal an error unless PATH is disposable."
  (let ((why (zwanenzang-test-not-disposable path)))
    (when why (error "Refusing to touch %s" why))))

(defconst zwanenzang-test--git-config-global
  (expand-file-name "gitconfig" (file-name-directory (or load-file-name buffer-file-name)))
  "`GIT_CONFIG_GLOBAL' for git and the CLI: the gitconfig beside this file.
It holds no user configuration and turns off automatic maintenance and
gc, which would otherwise race the next git command.")

(defun zwanenzang-test--git-env ()
  "`process-environment' for git and the CLI: no user or system configuration."
  (append (list "GIT_CONFIG_NOSYSTEM=1"
                (concat "GIT_CONFIG_GLOBAL=" zwanenzang-test--git-config-global)
                "GIT_DIR" "GIT_WORK_TREE")
          process-environment))

(defun zwanenzang-test-git (dir &rest args)
  "Run git with ARGS in the disposable DIR and return its stdout.
Git sees an identity and no user or system configuration."
  (zwanenzang-test-assert-disposable dir)
  (let ((process-environment (zwanenzang-test--git-env)))
    (with-temp-buffer
      (let ((exit (apply #'call-process "git" nil (list t nil) nil
                         "-C" dir
                         "-c" "user.name=Test" "-c" "user.email=test@example.invalid"
                         "-c" "init.defaultBranch=main" "-c" "commit.gpgsign=false"
                         args)))
        (unless (eql exit 0)
          (error "git %S in %s failed with %s" args dir exit))
        (buffer-string)))))

(defun zwanenzang-test--checkouts (root)
  "The `zwanenzang.checkout' values configured in the clone at ROOT."
  (zwanenzang-test-assert-disposable root)
  (let ((process-environment (zwanenzang-test--git-env)))
    (with-temp-buffer
      (let ((exit (call-process "git" nil (list t nil) nil "-C" root "config" "--local"
                                "--null" "--get-all" "zwanenzang.checkout")))
        (unless (memql exit '(0 1))
          (error "Cannot inspect checkout configuration of %s" root))
        (split-string (buffer-string) "\0" t)))))

(defun zwanenzang-test--checkout-path (root configured)
  "The checkout path CONFIGURED names, resolved as the CLI does.
An absolute value stands as it is; anything else is relative to the
clone ROOT, whatever the current directory.  There is no `~' or shell
expansion: a leading `~' is an ordinary directory name to the CLI."
  (if (string-prefix-p "/" configured)
      configured
    (concat (file-name-as-directory root) configured)))

(defun zwanenzang-test--assert-checkout-disposable (root configured)
  "Signal unless the checkout CONFIGURED in the clone at ROOT is disposable.
A path that does not exist yet must carry the name marker, and its
nearest existing ancestor must be disposable."
  ;; No file name handlers: to the CLI, \"/ssh:host:/x\" or \"/:x\" is an
  ;; ordinary local path.
  (let ((file-name-handler-alist nil)
        (path (zwanenzang-test--checkout-path root configured)))
    ;; Lisp collapses `..' lexically and the CLI physically, which differ
    ;; across a symbolic link, so such values are refused outright.
    (when (member ".." (split-string path "/"))
      (error "Refusing checkout path with `..': %s" configured))
    (if (file-exists-p path)
        (zwanenzang-test-assert-disposable path)
      (unless (string-suffix-p zwanenzang-test-marker
                               (file-name-nondirectory (directory-file-name path)))
        (error "Unmarked checkout path: %s" path))
      (let ((ancestor path))
        (while (not (file-exists-p ancestor))
          (setq ancestor (file-name-directory (directory-file-name ancestor))))
        (zwanenzang-test-assert-disposable ancestor)))))

(defun zwanenzang-test-assert-opens-disposable (dir)
  "Signal unless DIR and everything the CLI could touch from it are disposable.
That is the tracker the CLI would open from DIR and the human checkouts
it lists."
  (zwanenzang-test-assert-disposable dir)
  ;; `locate-dominating-file' may abbreviate to `~'; the CLI sees the
  ;; canonical root.
  (let ((root (file-truename
               (or (locate-dominating-file (file-truename dir) "zwanenzang.toml")
                   dir))))
    (let ((why (zwanenzang-test-not-disposable root)))
      (when why
        (error "Refusing to run in %s: the CLI would open the tracker at %s" dir why)))
    (when (file-exists-p (expand-file-name ".git" root))
      (dolist (configured (zwanenzang-test--checkouts root))
        ;; The CLI skips an empty value without touching anything.
        (unless (string-empty-p configured)
          (zwanenzang-test--assert-checkout-disposable root configured))))))

(defun zwanenzang-test-make-dir ()
  "Create and return a fresh disposable directory."
  (let ((dir (make-temp-file (expand-file-name "zwanenzang-el-" (zwanenzang-test--temp-root))
                             t zwanenzang-test-marker)))
    (zwanenzang-test-assert-disposable dir)
    dir))

(defun zwanenzang-test-delete-dir (dir)
  "Delete the disposable directory DIR."
  (zwanenzang-test-assert-disposable dir)
  (delete-directory dir t))

(defmacro zwanenzang-test-with-time-zone (zone &rest body)
  "Run BODY with the local time zone set to the TZ rule ZONE.
Weekday names are the C locale's.  Comment headers are Org timestamps
in local time, so a test that compares them fixes both."
  (declare (indent 1) (debug (form body)))
  (let ((old (make-symbol "old")))
    `(let ((,old (getenv "TZ"))
           (system-time-locale "C"))
       (unwind-protect
           (progn (setenv "TZ" ,zone) ,@body)
         (setenv "TZ" ,old)))))

(defmacro zwanenzang-test-with-dir (var &rest body)
  "Bind VAR to a fresh disposable directory around BODY, then delete it."
  (declare (indent 1) (debug (symbolp body)))
  `(let ((,var (zwanenzang-test-make-dir)))
     (unwind-protect (progn ,@body)
       (zwanenzang-test-delete-dir ,var))))

(defun zwanenzang-test-run (dir args &optional input)
  "`zwanenzang--run' in the disposable DIR, as actor \"tester\"."
  (zwanenzang-test-assert-opens-disposable dir)
  (let ((process-environment (zwanenzang-test--git-env)))
    (zwanenzang--run dir (append '("--actor-name" "tester") args) input)))

(defun zwanenzang-test-call (dir args &optional input)
  "`zwanenzang-call' in the disposable DIR, as actor \"tester\"."
  (zwanenzang-test-assert-opens-disposable dir)
  (let ((process-environment (zwanenzang-test--git-env)))
    (zwanenzang-call dir (append '("--actor-name" "tester") args) input)))

(defun zwanenzang-test-call-configured (dir args &optional input)
  "`zwanenzang-call' in the disposable DIR with no added actor name.
`zwanenzang-actor-name' and the clone's default decide the identity."
  (zwanenzang-test-assert-opens-disposable dir)
  (let ((process-environment (zwanenzang-test--git-env)))
    (zwanenzang-call dir args input)))

(defmacro zwanenzang-test-with-tracker (var &rest body)
  "Bind VAR to a fresh disposable tracker with prefix ZZ around BODY.
The tracker is initialized against a bare remote that lives as long as
the tracker does."
  (declare (indent 1) (debug (symbolp body)))
  (let ((remote (make-symbol "remote")))
    `(zwanenzang-test-with-dir ,remote
       (zwanenzang-test-git ,remote "init" "--quiet" "--bare" "remote-test-repo")
       (zwanenzang-test-with-dir ,var
         (zwanenzang-test-call ,remote
            (list "init" ,var "--remote"
                  (expand-file-name "remote-test-repo?ref=main" ,remote)
                  "--prefix" "ZZ" "--name" "Test"))
         ,@body))))

;;;; Trackers and Org scopes for pull tests

(defun zwanenzang-test-cli (dir &rest args)
  "Run the CLI with ARGS on the disposable tracker DIR; return its JSON."
  (zwanenzang-test-call dir args))

(defun zwanenzang-test-create (dir title &rest args)
  "Create a ticket TITLE with extra ARGS in DIR; return its id."
  (alist-get 'id (alist-get 'ticket (apply #'zwanenzang-test-cli dir "create" title args))))

(defun zwanenzang-test-show (dir ref)
  "The ticket object REF in DIR."
  (zwanenzang-test-cli dir "show" ref))

(defun zwanenzang-test-set-doc (dir ref name text)
  "Write TEXT as the next version of document NAME of REF in DIR."
  (let* ((doc (alist-get (intern name) (alist-get 'documents (zwanenzang-test-show dir ref))))
         (base (or (and doc (stringp (alist-get 'current doc)) (alist-get 'current doc)) "none"))
         (file (make-temp-file (expand-file-name "doc-" (zwanenzang-test--temp-root)))))
    (unwind-protect
        (progn
          (with-temp-file file (insert text))
          (zwanenzang-test-cli dir "doc" "set" ref name "--base" base "--file" file))
      (delete-file file))))

(defun zwanenzang-test-write-inline-doc (text)
  "Write TEXT in the inline named-document heading at point.
The client no longer writes named documents into Org; this recreates the
`org-src-v1' form earlier versions wrote, for migration and push tests."
  (zwanenzang--write-body (zwanenzang--compose-document nil text))
  (zwanenzang--put "ZWANENZANG_DOC_FORMAT" zwanenzang--document-format))

(defun zwanenzang-test-inline-doc (dir id name text &optional legacy)
  "Give ticket ID's heading an inline document NAME holding TEXT; return a marker.
This is the subheading earlier versions pulled.  Its sync state is the
current version of NAME in the tracker DIR and the hash of that text,
so TEXT other than the tracker's is a local edit.  LEGACY writes the
comma-escaped body instead of the `org-src-v1' source block."
  (let* ((doc (alist-get (intern name) (alist-get 'documents (zwanenzang-test-show dir id))))
         (version (and doc (stringp (alist-get 'current doc)) (alist-get 'current doc)))
         (synced (and version (alist-get 'text (zwanenzang-test-cli dir "doc" "get" id name)))))
    (save-excursion
      (zwanenzang-test-goto id)
      (let ((level (org-current-level)))
        (goto-char (zwanenzang--subtree-end (point)))
        (unless (bolp) (insert "\n"))
        (let ((marker (copy-marker (point))))
          (insert (make-string (1+ level) ?*) " " name
                  "\n:PROPERTIES:\n:ZWANENZANG_DOC: " name "\n:END:\n")
          (goto-char marker)
          (if legacy
              (zwanenzang--write-body
               (zwanenzang--compose-body (zwanenzang--body) nil text))
            (zwanenzang-test-write-inline-doc text))
          (when version
            (org-entry-put nil "ZWANENZANG_VERSION" version)
            (org-entry-put nil "ZWANENZANG_HASH"
                           (zwanenzang--hash (zwanenzang--normalize-text synced))))
          marker)))))

(defun zwanenzang-test-append-raw (dir actor line)
  "Append the raw event LINE to ACTOR's log in the disposable tracker DIR."
  (zwanenzang-test-assert-disposable dir)
  (let ((file (expand-file-name (format "events/%s.jsonl" actor) dir)))
    (write-region (concat line "\n") nil file t 'silent)))

(defun zwanenzang-test-legacy-comment (dir ref text)
  "Add a comment holding TEXT to ticket REF in the disposable tracker DIR.
The CLI refuses heading lines in new comments, but replay accepts the
ones written before that, which this recreates: a raw event of the
ticket's creator after the tracker's newest event, committed."
  (let* ((ticket (zwanenzang-test-show dir ref))
         (created (alist-get 'created ticket))
         (base (car (sort (mapcar (lambda (tk) (alist-get 'last_event tk))
                                  (alist-get 'tickets (zwanenzang-test-cli dir "query" "--all")))
                          #'string>))))
    (zwanenzang-test-append-raw
     dir (alist-get 'actor created)
     (json-serialize `((id . ,(zwanenzang-test-ulid-next base))
                       (actor . ,(alist-get 'actor created))
                       (as . ,(alist-get 'identity created))
                       (parent . ,base) (ts . ,(alist-get 'ts created))
                       (entity . ,(alist-get 'id ticket))
                       (op . "comment") (data . ((text . ,text))))))
    (zwanenzang-test-git dir "add" "events")
    (zwanenzang-test-git dir "commit" "--quiet" "-m" "A legacy comment")))

(defconst zwanenzang-test--crockford "0123456789ABCDEFGHJKMNPQRSTVWXYZ")

(defun zwanenzang-test-ulid-next (ulid)
  "The ULID right after ULID."
  (let ((chars (copy-sequence ulid))
        (i (1- (length ulid)))
        (carry t))
    (while (and carry (>= i 0))
      (let ((v (1+ (seq-position zwanenzang-test--crockford (aref chars i)))))
        (setq carry (= v 32))
        (aset chars i (aref zwanenzang-test--crockford (% v 32)))
        (cl-decf i)))
    chars))

(defmacro zwanenzang-test-with-scope (spec &rest body)
  "Run BODY with a disposable tracker and an Org file scoped to it.
SPEC is (TRACKER BUFFER ORG-TEXT).  ORG-TEXT is the file's text, with
%s where the tracker location goes.  BUFFER visits the file, and the
client runs the CLI only through the guarded `zwanenzang-test-call'."
  (declare (indent 1) (debug ((symbolp symbolp form) body)))
  (let ((dir (make-symbol "dir")))
    `(zwanenzang-test-with-tracker ,(nth 0 spec)
       (zwanenzang-test-with-dir ,dir
         (let* ((file (expand-file-name "scope.org" ,dir))
                (zwanenzang--call #'zwanenzang-test-call)
                ,(nth 1 spec))
           (with-temp-file file (insert (format ,(nth 2 spec) ,(nth 0 spec))))
           (setq ,(nth 1 spec) (find-file-noselect file))
           (unwind-protect
               (with-current-buffer ,(nth 1 spec) ,@body)
             (with-current-buffer ,(nth 1 spec) (set-buffer-modified-p nil))
             (kill-buffer ,(nth 1 spec))))))))

(defmacro zwanenzang-test-with-remote-scope (spec &rest body)
  "Run BODY with a tracker on a bare remote and an Org file scoped to it.
SPEC is (NET TRACKER BUFFER ORG-TEXT), ORG-TEXT as in
`zwanenzang-test-with-scope'.  NET is the disposable directory holding
`remote-test-repo', TRACKER the initialized tracker checkout in it."
  (declare (indent 1) (debug ((symbolp symbolp symbolp form) body)))
  (let ((net (nth 0 spec)) (tracker (nth 1 spec)) (buffer (nth 2 spec)))
    `(zwanenzang-test-with-dir ,net
       (let* ((,tracker (expand-file-name "tracker-test-repo" ,net))
              (file (expand-file-name "scope.org" ,net))
              (zwanenzang--call #'zwanenzang-test-call)
              ,buffer)
         (zwanenzang-test-git ,net "init" "--quiet" "--bare" "remote-test-repo")
         (zwanenzang-test-call ,net
            (list "init" ,tracker "--remote"
                  (expand-file-name "remote-test-repo?ref=main" ,net)
                  "--prefix" "ZZ" "--name" "Test"))
         (with-temp-file file (insert (format ,(nth 3 spec) ,tracker)))
         (setq ,buffer (find-file-noselect file))
         (unwind-protect
             (with-current-buffer ,buffer ,@body)
           (with-current-buffer ,buffer (set-buffer-modified-p nil))
           (kill-buffer ,buffer))))))

(defun zwanenzang-test-clone (net name)
  "Clone `remote-test-repo' in the disposable NET as NAME; return the clone."
  (zwanenzang-test-git net "clone" "--quiet" "remote-test-repo" name)
  (expand-file-name name net))

(defun zwanenzang-test-head (dir)
  "The current commit of the disposable repository DIR."
  (string-trim (zwanenzang-test-git dir "rev-parse" "HEAD")))

(defun zwanenzang-test-pull ()
  "Pull the scope of the first heading in the current buffer; return the summary."
  (save-excursion
    (goto-char (point-min))
    (outline-next-heading)
    (zwanenzang-pull)))

(defun zwanenzang-test-at-root (command &rest args)
  "Call COMMAND with ARGS at the first heading of the current buffer."
  (save-excursion
    (goto-char (point-min))
    (outline-next-heading)
    (apply command args)))

(defun zwanenzang-test-append (text)
  "Add TEXT at the end of the current buffer."
  (save-excursion
    (goto-char (point-max))
    (unless (bolp) (insert "\n"))
    (insert text)))

(defun zwanenzang-test-id-of (title)
  "The ZWANENZANG_ID of the first heading titled TITLE.
The title is the client's, without the number prefix."
  (save-excursion
    (goto-char (point-min))
    (let (found)
      (unless (org-at-heading-p) (outline-next-heading))
      (while (and (not found) (org-at-heading-p))
        (if (equal (plist-get (zwanenzang--heading) :title) title)
            (setq found (point))
          (outline-next-heading)))
      (unless found (error "No heading %s" title))
      (org-entry-get found "ZWANENZANG_ID"))))

(defun zwanenzang-test-goto (id)
  "Move to the only heading with ZWANENZANG_ID ID and return point."
  (let ((found (org-find-property "ZWANENZANG_ID" id)))
    (unless found (error "No heading for %s" id))
    (goto-char found)))

(defun zwanenzang-test-heading (id)
  "The heading line of ticket ID, without text properties."
  (save-excursion
    (zwanenzang-test-goto id)
    (buffer-substring-no-properties (line-beginning-position) (line-end-position))))

(defun zwanenzang-test-entry (id)
  "The text of ticket ID's heading and body, up to the next heading."
  (save-excursion
    (zwanenzang-test-goto id)
    (buffer-substring-no-properties (point) (save-excursion (outline-next-heading) (point)))))

(defun zwanenzang-test-property (id property)
  "PROPERTY of ticket ID's heading."
  (save-excursion (zwanenzang-test-goto id) (org-entry-get nil property)))

(defun zwanenzang-test-tags (id)
  "The local tags of ticket ID's heading."
  (save-excursion (zwanenzang-test-goto id) (org-get-tags nil t)))

(defun zwanenzang-test-parent-heading (id)
  "The title of the heading directly above ticket ID's heading."
  (save-excursion
    (zwanenzang-test-goto id)
    (org-up-heading-safe)
    (plist-get (zwanenzang--heading) :title)))

(defun zwanenzang-test-report ()
  "The text of the report buffer."
  (with-current-buffer (get-buffer-create zwanenzang-report-buffer)
    (buffer-substring-no-properties (point-min) (point-max))))

(defun zwanenzang-test-clear-report ()
  "Empty the report buffer."
  (with-current-buffer (get-buffer-create zwanenzang-report-buffer)
    (let ((inhibit-read-only t)) (erase-buffer))))

(provide 'zwanenzang-test-helpers)
;;; zwanenzang-test-helpers.el ends here
