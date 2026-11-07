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

(defun zwanenzang-test--git-env ()
  "`process-environment' for git and the CLI: no user or system configuration."
  (append '("GIT_CONFIG_NOSYSTEM=1" "GIT_CONFIG_GLOBAL=/dev/null"
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

(defmacro zwanenzang-test-with-tracker (var &rest body)
  "Bind VAR to a fresh disposable tracker with prefix ZZ around BODY."
  (declare (indent 1) (debug (symbolp body)))
  `(zwanenzang-test-with-dir ,var
     (zwanenzang-test-call ,var '("init" "--prefix" "ZZ" "--name" "Test"))
     ,@body))

(provide 'zwanenzang-test-helpers)
;;; zwanenzang-test-helpers.el ends here
