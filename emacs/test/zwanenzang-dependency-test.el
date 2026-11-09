;;; zwanenzang-dependency-test.el --- Manual dependency UX  -*- lexical-binding: t; -*-

;;; Commentary:

;; Pure Org transition tests: no CLI, filesystem or network is needed.

;;; Code:

(require 'ert)
(require 'zwanenzang)

(defmacro zwanenzang-dependency-test--with-org (&rest body)
  "Run BODY in a scope with two prerequisites and one dependent."
  (declare (indent 0) (debug t))
  `(with-temp-buffer
     (insert "#+TODO: TODO NEXT | DONE CANCEL\n"
             "* Project\n:PROPERTIES:\n:ZWANENZANG: /unused\n"
             ":ZWANENZANG_TRACKER: tracker\n"
             ":ZWANENZANG_KEYWORDS: TODO=todo NEXT=doing DONE=done CANCEL=cancelled\n:END:\n"
             "** TODO First\n:PROPERTIES:\n:ZWANENZANG_ID: A\n:END:\n"
             "** DONE Second\n:PROPERTIES:\n:ZWANENZANG_ID: B\n:END:\n"
             "** TODO Dependent\n:PROPERTIES:\n:ZWANENZANG_ID: C\n"
             ":ZWANENZANG_DEPENDS_ON: A B\n:END:\n")
     (org-mode)
     (let ((org-log-done nil)
           (org-log-repeat nil)
           (zwanenzang--call (lambda (&rest _) (ert-fail "TODO check called CLI"))))
       (zwanenzang-dependency-test--goto "C")
       ,@body)))

(defun zwanenzang-dependency-test--goto (id)
  "Move to the heading with ticket ID."
  (goto-char (point-min))
  (search-forward (concat ":ZWANENZANG_ID: " id "\n"))
  (org-back-to-heading t))

(defun zwanenzang-dependency-test--snapshot (&rest summaries)
  "Remember SUMMARIES as the current scope's successful read."
  (let ((known (make-hash-table :test #'equal)))
    (dolist (summary summaries)
      (puthash (alist-get 'id summary) summary known))
    (zwanenzang--remember-dependencies
     (zwanenzang--pull-create
      :root (zwanenzang--scope-root) :known known :tracker "tracker"
      :statuses '("todo" "doing" "done" "cancelled" "unmapped")))))

(ert-deftest zwanenzang-dependency-blocks-completion-without-changing-properties ()
  (zwanenzang-dependency-test--with-org
    (let ((before (buffer-string)))
      (org-todo "DONE")
      (should (equal (org-get-todo-state) "TODO"))
      (should (equal before (buffer-string)))
      (should (string-match-p "A First: unfinished" org-block-entry-blocking))
      (should (string-match-p "no tracker snapshot" org-block-entry-blocking))
      (should-not (string-match-p "Second" org-block-entry-blocking)))
    (org-todo "NEXT")
    (should (equal (org-get-todo-state) "NEXT"))
    (org-todo 'none)
    (should-not (org-get-todo-state))
    (org-todo "CANCEL")
    (should-not (org-get-todo-state))))

(ert-deftest zwanenzang-dependency-local-edits-unblock-without-sync-or-automation ()
  (zwanenzang-dependency-test--with-org
    (zwanenzang-dependency-test--goto "A")
    (org-todo "DONE")
    (zwanenzang-dependency-test--goto "C")
    (should (equal (org-get-todo-state) "TODO"))
    (org-todo "DONE")
    (should (equal (org-get-todo-state) "DONE"))
    (zwanenzang-dependency-test--goto "A")
    (org-todo "TODO")
    (zwanenzang-dependency-test--goto "C")
    (should (equal (org-get-todo-state) "DONE"))
    ;; Already completed tickets may change between done keywords.
    (org-todo "CANCEL")
    (should (equal (org-get-todo-state) "CANCEL"))
    (org-todo "TODO")
    (should (equal (org-get-todo-state) "TODO"))))

(ert-deftest zwanenzang-dependency-honors-native-force-and-noblocking ()
  (zwanenzang-dependency-test--with-org
    (org-todo '(64))
    ;; Triple prefix cycles without running blockers.  NEXT is the next
    ;; keyword here; a second forced cycle reaches DONE.
    (when (equal (org-get-todo-state) "NEXT") (org-todo '(64)))
    (should (equal (org-get-todo-state) "DONE"))
    (org-todo "TODO")
    (org-entry-put nil "NOBLOCKING" "t")
    (org-todo "DONE")
    (should (equal (org-get-todo-state) "DONE"))
    (should (equal (org-entry-get nil "ZWANENZANG_DEPENDS_ON") "A B"))))

(ert-deftest zwanenzang-dependency-hook-is-scoped-and-property-is-not-inherited ()
  (zwanenzang-dependency-test--with-org
    (goto-char (point-max))
    (insert "*** TODO Ordinary child\n")
    (forward-line -1)
    (org-todo "DONE")
    (should (equal (org-get-todo-state) "DONE"))
    (goto-char (point-max))
    (insert "* TODO Unrelated\n:PROPERTIES:\n:ZWANENZANG_DEPENDS_ON: unknown\n:END:\n")
    (org-back-to-heading t)
    (org-todo "DONE")
    (should (equal (org-get-todo-state) "DONE"))
    ;; A nested scope must not resolve IDs in its outer scope.
    (zwanenzang-dependency-test--goto "C")
    (org-entry-put nil "ZWANENZANG" "/other")
    (org-todo "DONE")
    (should (equal (org-get-todo-state) "TODO"))
    (should (string-match-p "unknown; sync" org-block-entry-blocking))))

(ert-deftest zwanenzang-dependency-snapshot-supports-absent-and-archived-tickets ()
  (zwanenzang-dependency-test--with-org
    (org-entry-put nil "ZWANENZANG_DEPENDS_ON" "remote")
    (org-todo "DONE")
    (should (equal (org-get-todo-state) "TODO"))
    (zwanenzang-dependency-test--snapshot
     '((id . "remote") (display . "ZZ-0099") (title . "Elsewhere")
       (status . "todo") (archived . t)))
    (org-todo "DONE")
    (should (equal (org-get-todo-state) "TODO"))
    (should (string-match-p "ZZ-0099 Elsewhere: unfinished (todo)" org-block-entry-blocking))
    (should (string-match-p "snapshot .* old" org-block-entry-blocking))
    (zwanenzang-dependency-test--snapshot
     '((id . "remote") (display . "ZZ-0099") (title . "Elsewhere")
       (status . "cancelled") (archived . t)))
    (should (= 1 (length zwanenzang--dependency-snapshots)))
    (org-todo "DONE")
    (should (equal (org-get-todo-state) "DONE"))))

(ert-deftest zwanenzang-dependency-unknown-unmapped-and-tombstoned-are-not-done ()
  (zwanenzang-dependency-test--with-org
    (org-entry-put nil "ZWANENZANG_DEPENDS_ON" "missing unknown deleted")
    (zwanenzang-dependency-test--snapshot
     '((id . "unknown") (display . "ZZ-0098") (title . "New status") (status . "unmapped"))
     '((id . "deleted") (display . "ZZ-0099") (title . "Deleted")
       (status . "done") (tombstoned . t)))
    (org-todo "DONE")
    (should (equal (org-get-todo-state) "TODO"))
    (should (string-match-p "missing: unknown ticket" org-block-entry-blocking))
    (should (string-match-p "New status: unmapped status unmapped" org-block-entry-blocking))
    (should (string-match-p "Deleted: tombstoned" org-block-entry-blocking))))

(ert-deftest zwanenzang-dependency-local-state-wins-except-known-tombstone ()
  (zwanenzang-dependency-test--with-org
    (org-entry-put nil "ZWANENZANG_DEPENDS_ON" "A")
    (zwanenzang-dependency-test--snapshot
     '((id . "A") (status . "done")))
    (org-todo "DONE")
    (should (equal (org-get-todo-state) "TODO"))
    (zwanenzang-dependency-test--goto "A")
    (org-todo "DONE")
    (zwanenzang-dependency-test--goto "C")
    (zwanenzang-dependency-test--snapshot
     '((id . "A") (status . "todo")))
    (org-todo "DONE")
    (should (equal (org-get-todo-state) "DONE"))
    (org-todo "TODO")
    (zwanenzang-dependency-test--snapshot
     '((id . "A") (status . "done") (tombstoned . t)))
    (org-todo "DONE")
    (should (equal (org-get-todo-state) "TODO"))))

(ert-deftest zwanenzang-dependency-duplicate-local-ids-and-cycles-block-naturally ()
  (zwanenzang-dependency-test--with-org
    (org-entry-put nil "ZWANENZANG_DEPENDS_ON" "C")
    (org-todo "DONE")
    (should (equal (org-get-todo-state) "TODO"))
    (org-entry-put nil "ZWANENZANG_DEPENDS_ON" "A")
    (goto-char (point-max))
    (insert "** DONE Duplicate\n:PROPERTIES:\n:ZWANENZANG_ID: A\n:END:\n")
    (zwanenzang-dependency-test--goto "C")
    (org-todo "DONE")
    (should (equal (org-get-todo-state) "TODO"))
    (should (string-match-p "duplicate headings" org-block-entry-blocking))))

(ert-deftest zwanenzang-dependency-snapshot-is-invalidated-by-scope-changes ()
  (zwanenzang-dependency-test--with-org
    (org-entry-put nil "ZWANENZANG_DEPENDS_ON" "remote")
    (zwanenzang-dependency-test--snapshot '((id . "remote") (status . "done")))
    (let ((root (zwanenzang--scope-root)))
      (org-entry-put root "ZWANENZANG" "/changed")
      (should-not (zwanenzang--dependency-snapshot root))
      (org-todo "DONE")
      (should (equal (org-get-todo-state) "TODO"))
      (org-entry-put root "ZWANENZANG" "/unused")
      (org-entry-put root "ZWANENZANG_TRACKER" "different")
      (should-not (zwanenzang--dependency-snapshot root)))))

(provide 'zwanenzang-dependency-test)
;;; zwanenzang-dependency-test.el ends here
