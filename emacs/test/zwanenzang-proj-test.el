;;; zwanenzang-proj-test.el --- Push and the PROJ rule  -*- lexical-binding: t; -*-

;;; Commentary:

;; The CLI refuses a status change on a PROJ ticket while its subtree is
;; unfinished, and then accepts only done or cncl.  Push leaves such a
;; change out and reports it, so the rest of the scope still goes.

;;; Code:

(require 'ert)
(require 'zwanenzang)
(require 'zwanenzang-test-helpers)
(require 'zwanenzang-pull-test)
(require 'zwanenzang-push-integration-test)

(defun zwanenzang-test--proj-tree (trk)
  "Create a PROJ ticket with a child and a grandchild in TRK; return their ids."
  (let* ((proj (zwanenzang-test-create trk "Project" "--tag" "PROJ"))
         (child (zwanenzang-test-create trk "Child" "--parent" proj))
         (grandchild (zwanenzang-test-create trk "Grandchild" "--parent" child)))
    (list proj child grandchild)))

(defun zwanenzang-test--keyword (id keyword)
  "Give ticket ID's heading KEYWORD, without Org's blockers or logging."
  (save-excursion
    (zwanenzang-test-goto id)
    (let ((org-enforce-todo-dependencies nil)
          (org-blocker-hook nil)
          (org-log-done nil))
      (org-todo keyword))))

(ert-deftest zwanenzang-push-finishes-a-project-with-its-subtree ()
  (zwanenzang-test-with-remote-scope (net trk buf zwanenzang-test--push-org)
    (pcase-let ((`(,proj ,child ,grandchild) (zwanenzang-test--proj-tree trk)))
      (zwanenzang-test-pull)
      ;; The project comes first in buffer order, so its change is sent
      ;; before its children's; the write as a whole finishes the subtree.
      (dolist (id (list proj child grandchild))
        (zwanenzang-test--keyword id "DONE"))
      (zwanenzang-test-clear-report)
      (should (string-match-p "3 pushed" (zwanenzang-test-at-root #'zwanenzang-push)))
      (dolist (id (list proj child grandchild))
        (should (equal (alist-get 'status (zwanenzang-test-show trk id)) "done"))))))

(ert-deftest zwanenzang-push-leaves-out-a-refused-project-status ()
  (zwanenzang-test-with-remote-scope (net trk buf zwanenzang-test--push-org)
    (pcase-let ((`(,proj ,child ,grandchild) (zwanenzang-test--proj-tree trk))
                (other (zwanenzang-test-create trk "Other")))
      (zwanenzang-test-pull)
      (zwanenzang-test--keyword proj "DONE")
      (zwanenzang-test--keyword child "DONE")
      (zwanenzang-test--keyword other "NEXT")
      (save-excursion
        (zwanenzang-test-goto proj)
        (search-forward "Project")
        (replace-match "Project renamed" t t))
      (zwanenzang-test-clear-report)
      (let ((summary (zwanenzang-test-at-root #'zwanenzang-push)))
        (should (string-match-p "see \\*zwanenzang\\*" summary)))
      (should (string-match-p
               "ZZ-1 Project: status not pushed: tagged PROJ, it has unfinished descendants ZZ-3"
               (zwanenzang-test-report)))
      ;; Everything else went, the project's other fields included.
      (let ((shown (zwanenzang-test-show trk proj)))
        (should (equal (alist-get 'status shown) "todo"))
        (should (equal (alist-get 'title shown) "Project renamed")))
      (should (equal (alist-get 'status (zwanenzang-test-show trk child)) "done"))
      (should (equal (alist-get 'status (zwanenzang-test-show trk other)) "agnt"))
      ;; Org keeps the keyword, so the next push tries again.
      (should (string-prefix-p "*** DONE" (zwanenzang-test-heading proj)))
      (should-not (member zwanenzang-conflict-tag (zwanenzang-test-tags proj)))
      (zwanenzang-test--keyword grandchild "CNCL")
      (zwanenzang-test-clear-report)
      (zwanenzang-test-at-root #'zwanenzang-push)
      (should-not (string-match-p "not pushed" (zwanenzang-test-report)))
      (should (equal (alist-get 'status (zwanenzang-test-show trk proj)) "done")))))

(ert-deftest zwanenzang-push-leaves-out-an-unfinished-status-of-a-finished-project ()
  (zwanenzang-test-with-remote-scope (net trk buf zwanenzang-test--push-org)
    (let* ((proj (zwanenzang-test-create trk "Project" "--tag" "PROJ"))
           (child (zwanenzang-test-create trk "Child" "--parent" proj "--status" "done")))
      (ignore child)
      (zwanenzang-test-pull)
      (zwanenzang-test--keyword proj "NEXT")
      (zwanenzang-test-clear-report)
      (zwanenzang-test-at-root #'zwanenzang-push)
      (should (string-match-p "ZZ-1 Project: status not pushed: tagged PROJ, it may only become done or cncl now"
                              (zwanenzang-test-report)))
      (should (equal (alist-get 'status (zwanenzang-test-show trk proj)) "todo")))))

(ert-deftest zwanenzang-push-reopens-a-finished-project ()
  (zwanenzang-test-with-remote-scope (net trk buf zwanenzang-test--push-org)
    (let* ((proj (zwanenzang-test-create trk "Project" "--tag" "PROJ"))
           (child (zwanenzang-test-create trk "Child" "--parent" proj "--status" "done")))
      (zwanenzang-test-cli trk "status" proj "done")
      ;; Left open below the finished project, as lint reports.
      (zwanenzang-test-cli trk "status" child "next")
      (zwanenzang-test-pull)
      (zwanenzang-test--keyword proj "TODO")
      (zwanenzang-test-clear-report)
      (zwanenzang-test-at-root #'zwanenzang-push)
      (should-not (string-match-p "not pushed" (zwanenzang-test-report)))
      (should (equal (alist-get 'status (zwanenzang-test-show trk proj)) "next")))))

(ert-deftest zwanenzang-plan-proj-repeats-until-nothing-is-refused ()
  ;; A child project left out leaves its parent project unfinished too.
  (let* ((plan (zwanenzang--plan-create))
         (summary (lambda (id number status parent)
                    `((id . ,id) (display . ,(format "ZZ-%d" number)) (number . ,number)
                      (title . ,id) (status . ,status) (parent . ,(or parent :null))
                      (tags . ,(if (member id '("outer" "inner")) ["PROJ"] []))
                      (tombstoned . :false))))
         (known (make-hash-table :test #'equal)))
    (dolist (s (list (funcall summary "outer" 1 "todo" nil)
                     (funcall summary "inner" 2 "todo" "outer")
                     (funcall summary "leaf" 3 "todo" "inner")))
      (puthash (alist-get 'id s) s known))
    (zwanenzang--plan-add plan "status" "outer" '((to . "done")))
    (zwanenzang--plan-add plan "status" "inner" '((to . "done")))
    (zwanenzang--plan-proj plan nil known)
    (should-not (zwanenzang--plan-changes plan))
    (should (equal (length (zwanenzang--plan-lines plan)) 2))))

(provide 'zwanenzang-proj-test)
;;; zwanenzang-proj-test.el ends here
