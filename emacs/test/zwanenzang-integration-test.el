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

(provide 'zwanenzang-integration-test)
;;; zwanenzang-integration-test.el ends here
