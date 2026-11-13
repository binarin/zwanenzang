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
             ":ZWANENZANG_KEYWORDS: TODO=next NEXT=agnt DONE=done CANCEL=cncl\n:END:\n"
             "** TODO First\n:PROPERTIES:\n:ZWANENZANG_ID: A\n:ZWANENZANG_NUMBER: ZZ-1\n:END:\n"
             "** DONE Second\n:PROPERTIES:\n:ZWANENZANG_ID: B\n:ZWANENZANG_NUMBER: ZZ-2\n:END:\n"
             "** TODO Dependent\n:PROPERTIES:\n:ZWANENZANG_ID: C\n:ZWANENZANG_NUMBER: ZZ-3\n"
             ":ZWANENZANG_DEPENDS_ON: ZZ-1 ZZ-2\n:END:\n")
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
      :statuses '("next" "agnt" "done" "cncl" "unmapped")))))

(ert-deftest zwanenzang-dependency-refs-compare-by-prefix-and-number ()
  (should (equal (zwanenzang--ticket-number "zz-0042") '("ZZ" . 42)))
  (should (equal (zwanenzang--ticket-number "ZZ-42") '("ZZ" . 42)))
  (should-not (zwanenzang--ticket-number "42"))
  (should-not (zwanenzang--ticket-number "ZZ-4x"))
  (should (equal (zwanenzang--ticket-ref-normalize "zz-0042") "ZZ-42"))
  (should (equal (zwanenzang--ticket-ref-normalize "zz-0") "ZZ-0"))
  (should (equal (zwanenzang--ticket-ref-normalize "junk") "JUNK"))
  (should (equal (sort (list "ZZ-10" "JUNK" "AB-3" "ZZ-9") #'zwanenzang--ticket-ref<)
                 '("AB-3" "ZZ-9" "ZZ-10" "JUNK")))
  (with-temp-buffer
    (org-mode)
    (insert "* T\n:PROPERTIES:\n:ZWANENZANG_DEPENDS_ON: zz-010 ZZ-9 ZZ-0009 ZZ-10\n:END:\n")
    (goto-char (point-min))
    (should (equal (zwanenzang--dependency-refs) '("ZZ-9" "ZZ-10")))))

(ert-deftest zwanenzang-dependency-base-reads-padded-sync-state ()
  (let* ((padded (zwanenzang--tags-hash '("ZZ-0009" "ZZ-0010")))
         (sync `((depends . ,padded))))
    (should (equal (zwanenzang--dependency-base sync '("ZZ-9" "ZZ-10"))
                   (zwanenzang--tags-hash '("ZZ-9" "ZZ-10"))))
    ;; Another set keeps the stored hash, so it still counts as an edit.
    (should (equal (zwanenzang--dependency-base sync '("ZZ-9")) padded))
    (should (equal (zwanenzang--dependency-base sync '("ZZ-9") '("ZZ-10" "ZZ-9"))
                   (zwanenzang--tags-hash '("ZZ-10" "ZZ-9"))))
    (should (eq (zwanenzang--dependency-base nil '("ZZ-9")) :unknown))))

(ert-deftest zwanenzang-dependency-padded-refs-and-numbers-match ()
  (zwanenzang-dependency-test--with-org
    ;; Org numbers written by older clients are padded.
    (zwanenzang-dependency-test--goto "A")
    (org-entry-put nil "ZWANENZANG_NUMBER" "ZZ-0001")
    (zwanenzang-dependency-test--goto "C")
    (org-entry-put nil "ZWANENZANG_DEPENDS_ON" "zz-0001 ZZ-02")
    (org-todo "DONE")
    (should (equal (org-get-todo-state) "TODO"))
    (should (string-match-p "ZZ-1 First: unfinished" org-block-entry-blocking))
    (zwanenzang-dependency-test--goto "A")
    (org-todo "DONE")
    (zwanenzang-dependency-test--goto "C")
    (org-todo "DONE")
    (should (equal (org-get-todo-state) "DONE"))
    ;; A snapshot match is by number as well.
    (org-todo "TODO")
    (org-entry-put nil "ZWANENZANG_DEPENDS_ON" "ZZ-0099")
    (zwanenzang-dependency-test--snapshot
     '((id . "remote") (display . "ZZ-99") (title . "Elsewhere") (status . "done")))
    (org-todo "DONE")
    (should (equal (org-get-todo-state) "DONE"))))

(ert-deftest zwanenzang-dependency-blocks-completion-without-changing-properties ()
  (zwanenzang-dependency-test--with-org
    (let ((before (buffer-string)))
      (org-todo "DONE")
      (should (equal (org-get-todo-state) "TODO"))
      (should (equal before (buffer-string)))
      (should (string-match-p "ZZ-1 First: unfinished" org-block-entry-blocking))
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
    (should (equal (org-entry-get nil "ZWANENZANG_DEPENDS_ON") "ZZ-1 ZZ-2"))))

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
    (org-entry-put nil "ZWANENZANG_DEPENDS_ON" "ZZ-99")
    (org-todo "DONE")
    (should (equal (org-get-todo-state) "TODO"))
    (zwanenzang-dependency-test--snapshot
     '((id . "remote") (display . "ZZ-99") (title . "Elsewhere")
       (status . "next") (archived . t)))
    (org-todo "DONE")
    (should (equal (org-get-todo-state) "TODO"))
    (should (string-match-p "ZZ-99 Elsewhere: unfinished (next)" org-block-entry-blocking))
    (should (string-match-p "snapshot .* old" org-block-entry-blocking))
    (zwanenzang-dependency-test--snapshot
     '((id . "remote") (display . "ZZ-99") (title . "Elsewhere")
       (status . "cncl") (archived . t)))
    (should (= 1 (length zwanenzang--dependency-snapshots)))
    (org-todo "DONE")
    (should (equal (org-get-todo-state) "DONE"))))

(ert-deftest zwanenzang-dependency-unknown-unmapped-and-tombstoned-are-not-done ()
  (zwanenzang-dependency-test--with-org
    (org-entry-put nil "ZWANENZANG_DEPENDS_ON" "ZZ-97 ZZ-98 ZZ-99")
    (zwanenzang-dependency-test--snapshot
     '((id . "unknown") (display . "ZZ-98") (title . "New status") (status . "unmapped"))
     '((id . "deleted") (display . "ZZ-99") (title . "Deleted")
       (status . "done") (tombstoned . t)))
    (org-todo "DONE")
    (should (equal (org-get-todo-state) "TODO"))
    (should (string-match-p "ZZ-97: unknown ticket" org-block-entry-blocking))
    (should (string-match-p "New status: unmapped status unmapped" org-block-entry-blocking))
    (should (string-match-p "Deleted: tombstoned" org-block-entry-blocking))))

(ert-deftest zwanenzang-dependency-local-state-wins-except-known-tombstone ()
  (zwanenzang-dependency-test--with-org
    (org-entry-put nil "ZWANENZANG_DEPENDS_ON" "ZZ-1")
    (zwanenzang-dependency-test--snapshot
     '((id . "A") (display . "ZZ-1") (status . "done")))
    (org-todo "DONE")
    (should (equal (org-get-todo-state) "TODO"))
    (zwanenzang-dependency-test--goto "A")
    (org-todo "DONE")
    (zwanenzang-dependency-test--goto "C")
    (zwanenzang-dependency-test--snapshot
     '((id . "A") (display . "ZZ-1") (status . "next")))
    (org-todo "DONE")
    (should (equal (org-get-todo-state) "DONE"))
    (org-todo "TODO")
    (zwanenzang-dependency-test--snapshot
     '((id . "A") (display . "ZZ-1") (status . "done") (tombstoned . t)))
    (org-todo "DONE")
    (should (equal (org-get-todo-state) "TODO"))))

(ert-deftest zwanenzang-dependency-duplicate-local-ids-and-cycles-block-naturally ()
  (zwanenzang-dependency-test--with-org
    (org-entry-put nil "ZWANENZANG_DEPENDS_ON" "ZZ-3")
    (org-todo "DONE")
    (should (equal (org-get-todo-state) "TODO"))
    (org-entry-put nil "ZWANENZANG_DEPENDS_ON" "ZZ-1")
    (goto-char (point-max))
    (insert "** DONE Duplicate\n:PROPERTIES:\n:ZWANENZANG_ID: A\n:END:\n")
    (zwanenzang-dependency-test--goto "C")
    (org-todo "DONE")
    (should (equal (org-get-todo-state) "TODO"))
    (should (string-match-p "duplicate headings" org-block-entry-blocking))))

(ert-deftest zwanenzang-dependency-snapshot-is-invalidated-by-scope-changes ()
  (zwanenzang-dependency-test--with-org
    (org-entry-put nil "ZWANENZANG_DEPENDS_ON" "ZZ-99")
    (zwanenzang-dependency-test--snapshot
     '((id . "remote") (display . "ZZ-99") (status . "done")))
    (let ((root (zwanenzang--scope-root)))
      (org-entry-put root "ZWANENZANG" "/changed")
      (should-not (zwanenzang--dependency-snapshot root))
      (org-todo "DONE")
      (should (equal (org-get-todo-state) "TODO"))
      (org-entry-put root "ZWANENZANG" "/unused")
      (org-entry-put root "ZWANENZANG_TRACKER" "different")
      (should-not (zwanenzang--dependency-snapshot root)))))

(ert-deftest zwanenzang-dependency-requires-human-facing-ticket-ids ()
  (zwanenzang-dependency-test--with-org
    (zwanenzang-dependency-test--goto "A")
    (org-todo "DONE")
    (zwanenzang-dependency-test--goto "C")
    (org-entry-put nil "ZWANENZANG_DEPENDS_ON" "A")
    (org-todo "DONE")
    (should (equal (org-get-todo-state) "TODO"))
    (should (string-match-p "expected a ticket ID" org-block-entry-blocking))
    (org-entry-put nil "ZWANENZANG_DEPENDS_ON" "ZZ-1")
    (org-todo "DONE")
    (should (equal (org-get-todo-state) "DONE"))))

(ert-deftest zwanenzang-dependency-snapshot-resolves-number-to-local-stable-id ()
  (zwanenzang-dependency-test--with-org
    (zwanenzang-dependency-test--goto "A")
    (org-entry-delete nil "ZWANENZANG_NUMBER")
    (org-todo "DONE")
    (zwanenzang-dependency-test--goto "C")
    (org-entry-put nil "ZWANENZANG_DEPENDS_ON" "ZZ-1")
    (zwanenzang-dependency-test--snapshot
     '((id . "A") (display . "ZZ-1") (status . "next")))
    (org-todo "DONE")
    (should (equal (org-get-todo-state) "DONE"))))

(provide 'zwanenzang-dependency-test)
;;; zwanenzang-dependency-test.el ends here
