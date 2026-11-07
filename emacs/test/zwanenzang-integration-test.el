;;; zwanenzang-integration-test.el --- Tests against the real CLI  -*- lexical-binding: t; -*-

;;; Commentary:

;; These drive `zwanenzang-program' against disposable trackers created by
;; the helpers.  Under `nix flake check' that is the CLI built from the
;; same flake, substituted into the package's default.

;;; Code:

(require 'ert)
(require 'zwanenzang)
(require 'zwanenzang-test-helpers)

(ert-deftest zwanenzang-integration-init-then-read ()
  (zwanenzang-test-with-dir dir
    (let* ((init (zwanenzang-test-call dir '("init" "--prefix" "ZZ" "--name" "Test")))
           (tracker-id (alist-get 'id (alist-get 'tracker init))))
      (should (stringp tracker-id))
      (let ((empty (zwanenzang-test-call dir '("read") '((cursors)))))
        (should (equal (alist-get 'id (alist-get 'tracker empty)) tracker-id))
        (should (eq (alist-get 'cursor empty) :null))
        (should (null (alist-get 'tickets empty))))
      (zwanenzang-test-call dir '("create" "First ticket"))
      (let* ((scope (zwanenzang-test-call dir '("read") '((since . :null))))
             (tickets (alist-get 'tickets scope))
             (ticket (alist-get 'ticket (car tickets))))
        (should (equal (alist-get 'id (alist-get 'tracker scope)) tracker-id))
        (should (stringp (alist-get 'cursor scope)))
        (should (eq (alist-get 'reset scope) :false))
        (should (= (length tickets) 1))
        (should (equal (alist-get 'title ticket) "First ticket"))
        (should (stringp (alist-get 'cursor (car tickets))))))))

(ert-deftest zwanenzang-integration-command-error-is-user-error ()
  (zwanenzang-test-with-dir dir
    (let ((err (should-error (zwanenzang-test-call dir '("read") '((cursors)))
                             :type 'user-error)))
      (should (string-prefix-p "zwanenzang: not-a-tracker: " (cadr err))))))

(ert-deftest zwanenzang-integration-failed-publication-returns-sync-json ()
  ;; A clone whose bare remote is gone: `sync' exits 1 with its result,
  ;; which the client reports rather than treating as a failure.
  (zwanenzang-test-with-dir net
    (let ((remote (expand-file-name "remote-test-repo" net))
          (clone (expand-file-name "a-test-repo" net)))
      (zwanenzang-test-git net "init" "--quiet" "--bare" "remote-test-repo")
      (zwanenzang-test-git net "clone" "--quiet" "remote-test-repo" "a-test-repo")
      (let ((init (zwanenzang-test-call clone '("init" "--prefix" "ZZ" "--name" "Test"))))
        (should (eq (alist-get 'pushed (alist-get 'sync init)) t)))
      (zwanenzang-test-delete-dir remote)
      (should (eql (plist-get (zwanenzang-test-run clone '("sync")) :exit) 1))
      (let ((sync (alist-get 'sync (zwanenzang-test-call clone '("sync")))))
        (should (eq (alist-get 'pushed sync) :false))
        (should (equal (alist-get 'code (alist-get 'error sync)) "fetch-failed"))))))

(provide 'zwanenzang-integration-test)
;;; zwanenzang-integration-test.el ends here
