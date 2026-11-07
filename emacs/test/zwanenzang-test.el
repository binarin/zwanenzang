;;; zwanenzang-test.el --- Tests that need no CLI  -*- lexical-binding: t; -*-

;;; Commentary:

;; Parsing, rendering and the call helper's error mapping, plus the
;; disposable-repository guard itself.  Where a program is needed, a small
;; shell script stands in for the CLI.

;;; Code:

(require 'ert)
(require 'zwanenzang)
(require 'zwanenzang-test-helpers)

(defun zwanenzang-test--fake-program (dir script)
  "Write SCRIPT, a shell script body, as an executable in DIR; return its name.
The script sees the arguments it was given in \"$@\" and its stdin."
  (let ((file (expand-file-name "fake-zwanenzang" dir)))
    (with-temp-file file
      (insert "#!/bin/sh\n" script "\n"))
    (set-file-modes file #o755)
    file))

;;;; JSON

(ert-deftest zwanenzang-json-keeps-null-and-false-apart-from-nil ()
  (with-temp-buffer
    (insert "{\"cursor\": null, \"reset\": false, \"tickets\": [], \"o\": {}}")
    (let ((v (zwanenzang--json-parse)))
      (should (eq (alist-get 'cursor v) :null))
      (should (eq (alist-get 'reset v) :false))
      (should (null (alist-get 'tickets v)))
      (should (assq 'o v))))
  (should (equal (zwanenzang--json-encode '((cursors . ((ZZ-0042 . :null)))
                                            (since . :null)))
                 "{\"cursors\":{\"ZZ-0042\":null},\"since\":null}"))
  (should (equal (zwanenzang--json-encode nil) "{}")))

;;;; Calling the CLI

(ert-deftest zwanenzang-call-passes-directory-arguments-and-stdin ()
  (zwanenzang-test-with-dir dir
    (let ((zwanenzang-program
           (zwanenzang-test--fake-program
            dir "printf '{\"args\": \"%s\", \"stdin\": ' \"$*\"; cat; printf '}'")))
      (let ((v (zwanenzang-test-call dir '("read") '((since . :null)))))
        (should (equal (alist-get 'args v)
                       (concat "-C " (file-name-as-directory dir)
                               " --actor-name tester read")))
        (should (equal (alist-get 'stdin v) '((since . :null))))))))

(ert-deftest zwanenzang-call-signals-user-error-on-error-object ()
  (zwanenzang-test-with-dir dir
    (let ((zwanenzang-program
           (zwanenzang-test--fake-program
            dir "echo '{\"error\": {\"code\": \"not-a-tracker\", \"message\": \"no tracker\"}}'; exit 1")))
      (let ((err (should-error (zwanenzang-test-call dir '("read")) :type 'user-error)))
        (should (equal (cadr err) "zwanenzang: not-a-tracker: no tracker")))
      (let ((r (zwanenzang-test-run dir '("read"))))
        (should (eql (plist-get r :exit) 1))
        (should (equal (alist-get 'code (zwanenzang--error-object (plist-get r :json)))
                       "not-a-tracker"))))))

(ert-deftest zwanenzang-call-signals-user-error-on-usage-error ()
  (zwanenzang-test-with-dir dir
    (let ((zwanenzang-program
           (zwanenzang-test--fake-program
            dir "echo \"error: unrecognized subcommand 'frob'\" >&2; exit 2")))
      (let ((err (should-error (zwanenzang-test-call dir '("frob")) :type 'user-error)))
        (should (equal (cadr err)
                       "zwanenzang: usage: error: unrecognized subcommand 'frob'"))))))

(ert-deftest zwanenzang-call-signals-user-error-on-missing-or-silent-program ()
  (zwanenzang-test-with-dir dir
    (let ((zwanenzang-program (expand-file-name "no-such-program" dir)))
      (should-error (zwanenzang-test-call dir '("read")) :type 'user-error))
    (let ((zwanenzang-program (zwanenzang-test--fake-program dir "exit 0")))
      (should-error (zwanenzang-test-call dir '("read")) :type 'user-error))))

;;;; Configuration and reports

(ert-deftest zwanenzang-org-files-defaults-to-agenda-files ()
  (zwanenzang-test-with-dir dir
    (let* ((file (expand-file-name "a.org" dir))
           (org-agenda-files (list file)))
      (with-temp-file file)
      (should (eq zwanenzang-org-files 'agenda))
      (should (equal (zwanenzang--org-files) (list file)))
      (let ((default-directory (file-name-as-directory dir))
            (zwanenzang-org-files '("b.org")))
        (should (equal (zwanenzang--org-files)
                       (list (expand-file-name "b.org" dir))))))))

(ert-deftest zwanenzang-report-appends-to-report-buffer ()
  (let ((buf (get-buffer zwanenzang-report-buffer)))
    (when buf (kill-buffer buf)))
  (unwind-protect
      (progn
        (should (equal (zwanenzang-report "sync: pushed") "sync: pushed"))
        (should (equal (zwanenzang-report "sync: push-rejected"
                                          '("upstream moved" "retry later"))
                       "sync: push-rejected (see *zwanenzang*)"))
        (with-current-buffer zwanenzang-report-buffer
          (should buffer-read-only)
          (should (string-match-p
                   (concat "\\`\\[[-0-9]+ [:0-9]+\\] sync: pushed\n\n"
                           "\\[[-0-9]+ [:0-9]+\\] sync: push-rejected\n"
                           "  upstream moved\n  retry later\n\\'")
                   (buffer-string)))))
    (kill-buffer zwanenzang-report-buffer)))

;;;; The disposable-repository guard

(ert-deftest zwanenzang-guard-accepts-marked-temp-directory ()
  (zwanenzang-test-with-dir dir
    (should-not (zwanenzang-test-not-disposable dir))
    (zwanenzang-test-assert-opens-disposable dir)))

(ert-deftest zwanenzang-guard-refuses-directory-outside-temp ()
  (should (string-match-p "not under the temporary directory"
                          (zwanenzang-test-not-disposable "/srv/zwanenzang-test-repo")))
  (should-error (zwanenzang-test-assert-disposable "/srv/zwanenzang-test-repo")))

(ert-deftest zwanenzang-guard-refuses-unmarked-temp-directory ()
  (let ((dir (make-temp-file "zwanenzang-el-unmarked-" t)))
    (unwind-protect
        (progn
          (should (string-match-p "does not end in -test-repo"
                                  (zwanenzang-test-not-disposable dir)))
          (should-error (zwanenzang-test-assert-disposable dir))
          (should-error (zwanenzang-test-assert-opens-disposable dir)))
      (delete-directory dir t))))

(ert-deftest zwanenzang-guard-resolves-symbolic-links ()
  (let* ((parent (make-temp-file "zwanenzang-el-links-" t))
         (link (expand-file-name "escape-test-repo" parent)))
    (unwind-protect
        (progn
          (make-symbolic-link "/" link)
          (should (zwanenzang-test-not-disposable link)))
      (delete-file link)
      (delete-directory parent t))))

(ert-deftest zwanenzang-guard-refuses-unmarked-tracker-above ()
  ;; The CLI would open the tracker above a marked directory, so the
  ;; marked directory alone is not enough.
  (let* ((outer (make-temp-file "zwanenzang-el-outer-" t))
         (inner (expand-file-name "inner-test-repo" outer)))
    (unwind-protect
        (progn
          (make-directory inner)
          (with-temp-file (expand-file-name "zwanenzang.toml" outer))
          (should-not (zwanenzang-test-not-disposable inner))
          (should-error (zwanenzang-test-assert-opens-disposable inner)))
      (delete-directory outer t))))

(ert-deftest zwanenzang-guard-runs-nothing-in-refused-directory ()
  (let* ((outer (make-temp-file "zwanenzang-el-outer-" t))
         (ran (expand-file-name "ran" outer))
         (zwanenzang-program
          (zwanenzang-test--fake-program outer (format "touch '%s'; echo '{}'" ran))))
    (unwind-protect
        (progn
          (should-error (zwanenzang-test-call outer '("read") nil))
          (should-error (zwanenzang-test-run outer '("read") nil))
          (should-not (file-exists-p ran)))
      (delete-directory outer t))))

(defun zwanenzang-test--set-checkouts (tracker &rest paths)
  "Configure exactly PATHS as the checkouts of the disposable TRACKER."
  (ignore-errors
    (zwanenzang-test-git tracker "config" "--local" "--unset-all" "zwanenzang.checkout"))
  (dolist (p paths)
    (zwanenzang-test-git tracker "config" "--local" "--add" "zwanenzang.checkout" p)))

(ert-deftest zwanenzang-guard-refuses-existing-unmarked-checkout ()
  (zwanenzang-test-with-tracker tracker
    (let ((human (make-temp-file "zwanenzang-el-human-" t)))
      (unwind-protect
          (progn
            (zwanenzang-test--set-checkouts tracker human)
            (should-error (zwanenzang-test-assert-opens-disposable tracker))
            (zwanenzang-test--set-checkouts tracker "/")
            (should-error (zwanenzang-test-assert-opens-disposable tracker))
            ;; Relative to the clone: its parent is not marked.
            (zwanenzang-test--set-checkouts tracker "..")
            (should-error (zwanenzang-test-assert-opens-disposable tracker)))
        (delete-directory human t)))))

(ert-deftest zwanenzang-guard-walks-up-from-missing-checkout ()
  (zwanenzang-test-with-tracker tracker
    ;; Not created yet, under the disposable clone: accepted.
    (zwanenzang-test--set-checkouts tracker "later-test-repo")
    (zwanenzang-test-assert-opens-disposable tracker)
    ;; No `~' expansion: the CLI reads this as a directory named `~' in
    ;; the clone.
    (zwanenzang-test--set-checkouts tracker "~/home-test-repo")
    (zwanenzang-test-assert-opens-disposable tracker)
    ;; Missing and unmarked.
    (zwanenzang-test--set-checkouts tracker "later")
    (should-error (zwanenzang-test-assert-opens-disposable tracker))
    ;; Missing and marked, but its nearest existing ancestor is not
    ;; disposable.
    (zwanenzang-test--set-checkouts tracker "/zwanenzang-nonexistent/later-test-repo")
    (should-error (zwanenzang-test-assert-opens-disposable tracker))
    ;; Any marked value is checked, not just the first.
    (zwanenzang-test--set-checkouts tracker "later-test-repo" "later")
    (should-error (zwanenzang-test-assert-opens-disposable tracker))))

(ert-deftest zwanenzang-guard-accepts-disposable-checkout ()
  (zwanenzang-test-with-tracker tracker
    (zwanenzang-test-with-dir human
      (zwanenzang-test--set-checkouts tracker human)
      (zwanenzang-test-assert-opens-disposable tracker)
      (should (zwanenzang-test-call tracker '("read") '((cursors)))))))

(provide 'zwanenzang-test)
;;; zwanenzang-test.el ends here
