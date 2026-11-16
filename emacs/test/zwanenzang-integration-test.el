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
  (zwanenzang-test-with-dir remote
    (zwanenzang-test-git remote "init" "--quiet" "--bare" "remote-test-repo")
    (zwanenzang-test-with-dir dir
      (let* ((init (zwanenzang-test-call
                    remote
                    (list "init" dir "--remote"
                          (expand-file-name "remote-test-repo?ref=main" remote)
                          "--prefix" "ZZ" "--name" "Test")))
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
        (should (stringp (alist-get 'cursor (car tickets)))))))))

(ert-deftest zwanenzang-integration-writes-as-the-configured-identity ()
  (zwanenzang-test-with-tracker dir
    (let ((id (zwanenzang-test-create dir "Shared")))
      ;; No name and no clone default: the write is refused.
      (let ((err (should-error (zwanenzang-test-call-configured
                                dir (list "comment" id "nobody"))
                               :type 'user-error)))
        (should (string-prefix-p "zwanenzang: actor-required: " (cadr err))))
      (let ((zwanenzang-actor-name "agent"))
        (should (equal (alist-get 'as (alist-get 'event (zwanenzang-test-call-configured
                                                          dir (list "comment" id "as agent"))))
                       "agent")))
      ;; nil leaves the choice to the clone's default.
      (zwanenzang-test-git dir "config" "--local" "zwanenzang.defaultActor" "tester")
      (zwanenzang-test-call-configured dir (list "comment" id "as the default"))
      (let* ((read (zwanenzang-test-call dir '("read") '((since . :null))))
             (ticket (alist-get 'ticket (car (alist-get 'tickets read))))
             (pull (zwanenzang--pull-create
                    :actors (alist-get 'actors (alist-get 'tracker read))
                    :tracker-dir dir)))
        (should (equal (mapcar (lambda (c) (zwanenzang--author pull c))
                               (alist-get 'comments ticket))
                       '("agent" "tester")))))))

(ert-deftest zwanenzang-integration-explicit-identity-wins-over-the-setting ()
  (zwanenzang-test-with-tracker dir
    (let ((id (zwanenzang-test-create dir "Shared"))
          (zwanenzang-actor-name "agent"))
      ;; `zwanenzang-test-call' passes --actor-name tester itself.
      (should (equal (alist-get 'as (alist-get 'event (zwanenzang-test-call
                                                        dir (list "comment" id "explicit"))))
                     "tester"))
      (should (equal (alist-get 'as (alist-get 'event (zwanenzang-test-call-configured
                                                        dir (list "comment" id "setting"))))
                     "agent")))))

(ert-deftest zwanenzang-integration-command-error-is-user-error ()
  (zwanenzang-test-with-dir dir
    (let ((err (should-error (zwanenzang-test-call dir '("read") '((cursors)))
                             :type 'user-error)))
      (should (string-prefix-p "zwanenzang: not-a-tracker: " (cadr err))))))

(ert-deftest zwanenzang-integration-failed-publication-returns-sync-json ()
  ;; A tracker whose bare remote is gone: `sync' exits 1 with its result,
  ;; which the client reports rather than treating as a failure.
  (zwanenzang-test-with-dir net
    (let ((remote (expand-file-name "remote-test-repo" net))
          (clone (expand-file-name "a-test-repo" net)))
      (zwanenzang-test-git net "init" "--quiet" "--bare" "remote-test-repo")
      (let ((init (zwanenzang-test-call
                   net
                   (list "init" clone "--remote"
                         (expand-file-name "remote-test-repo?ref=main" net)
                         "--prefix" "ZZ" "--name" "Test"))))
        (should (eq (alist-get 'pushed (alist-get 'sync init)) t)))
      (zwanenzang-test-delete-dir remote)
      (should (eql (plist-get (zwanenzang-test-run clone '("sync")) :exit) 1))
      (let ((sync (alist-get 'sync (zwanenzang-test-call clone '("sync")))))
        (should (eq (alist-get 'pushed sync) :false))
        (should (equal (alist-get 'code (alist-get 'error sync)) "fetch-failed"))))))

(provide 'zwanenzang-integration-test)
;;; zwanenzang-integration-test.el ends here
