;;; pull.el --- Pull demo/scope.org and dump the report  -*- lexical-binding: t; -*-

;;; Commentary:

;; emacs --batch -Q -L <zwanenzang-el>/share/emacs/site-lisp -l demo/pull.el REPORT
;;
;; Visits demo/scope.org, moves to the scope root, runs `zwanenzang-pull',
;; saves the file and writes the `*zwanenzang*' buffer to REPORT, a file name
;; relative to demo/.  demo/pull.sh supplies the arguments.

;;; Code:

(require 'zwanenzang)

(let* ((demo (file-name-directory load-file-name))
       (report (expand-file-name (pop command-line-args-left) demo))
       (make-backup-files nil)
       (create-lockfiles nil))
  (prefer-coding-system 'utf-8)
  (with-current-buffer (find-file-noselect (expand-file-name "scope.org" demo))
    (goto-char (org-find-property "ZWANENZANG"))
    (let ((location (file-truename (org-entry-get nil "ZWANENZANG"))))
      (unless (and (string-prefix-p (file-truename temporary-file-directory) location)
                   (string-suffix-p "-test-repo" location))
        (error "Refusing to touch %s: not a *-test-repo under the temporary directory"
               location)))
    (zwanenzang-pull)
    (save-buffer))
  (with-current-buffer zwanenzang-report-buffer
    (write-region nil nil report)))

;;; pull.el ends here
