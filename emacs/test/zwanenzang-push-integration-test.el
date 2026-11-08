;;; zwanenzang-push-integration-test.el --- Push against the real CLI  -*- lexical-binding: t; -*-

;;; Commentary:

;; Each test has a disposable bare remote and a tracker clone, and an Org
;; file scoped to the clone.  Some add a second clone acting as an agent.

;;; Code:

(require 'ert)
(require 'zwanenzang)
(require 'zwanenzang-test-helpers)

(defconst zwanenzang-test--push-org
  (concat "#+TODO: TODO NEXT WAIT | DONE CNCL\n"
          "* Project\n"
          ":PROPERTIES:\n"
          ":ZWANENZANG: %s\n"
          ":ZWANENZANG_KEYWORDS: TODO=todo,draft NEXT=doing,review DONE=done"
          " CNCL=cancelled,blocked\n"
          ":ZWANENZANG_HIDE_DOCS: status\n"
          ":END:\n")
  "An Org file with one scope; %s is the tracker.  WAIT has no status.")

(defun zwanenzang-test--doc-versions (dir id name)
  "The versions of document NAME of ticket ID in DIR."
  (alist-get 'versions (alist-get (intern name)
                                  (alist-get 'documents (zwanenzang-test-show dir id)))))

(defun zwanenzang-test--doc-text (dir id name)
  "The current text of document NAME of ticket ID in DIR."
  (alist-get 'text (zwanenzang-test-cli dir "doc" "get" id name)))

(defun zwanenzang-test--edit-title (id title)
  "Set the title of ticket ID's heading to TITLE."
  (save-excursion (zwanenzang-test-goto id) (org-edit-headline title)))

(defun zwanenzang-test--goto-title (title)
  "Move to the heading titled TITLE."
  (goto-char (point-min))
  (re-search-forward (format org-complex-heading-regexp-format (regexp-quote title)))
  (org-back-to-heading t))

(defun zwanenzang-test--move-under (id target-title)
  "Refile ticket ID's subtree as the last child of the heading TARGET-TITLE."
  (save-excursion
    (zwanenzang-test-goto id)
    (org-cut-subtree)
    (zwanenzang-test--goto-title target-title)
    (let ((level (1+ (org-current-level))))
      (org-end-of-subtree t t)
      (org-paste-subtree level))))

(ert-deftest zwanenzang-push-creates-from-headings-parent-and-child-together ()
  (zwanenzang-test-with-remote-scope (net trk buf zwanenzang-test--push-org)
    (zwanenzang-test-append (concat "** NEXT Parent :alpha:\nParent text\n"
                                    "*** Group\n"
                                    "**** TODO Child\n"
                                    "***** the plan\n:PROPERTIES:\n:ZWANENZANG_DOC: plan\n:END:\n"
                                    "Plan text\n"
                                    "** Just structure\n"))
    (zwanenzang-test-clear-report)
    (should (string-match-p "2 created" (zwanenzang-test-at-root #'zwanenzang-push)))
    (let* ((parent (zwanenzang-test-id-of "Parent"))
           (child (zwanenzang-test-id-of "Child"))
           (shown (zwanenzang-test-show trk child)))
      (should parent)
      (should child)
      (should-not (zwanenzang-test-id-of "Just structure"))
      (should (equal (alist-get 'status (zwanenzang-test-show trk parent)) "doing"))
      (should (equal (alist-get 'tags (zwanenzang-test-show trk parent)) '("alpha")))
      (should (equal (zwanenzang-test--doc-text trk parent "description") "Parent text\n"))
      (should (equal (alist-get 'status shown) "todo"))
      (should (equal (alist-get 'parent shown) parent))
      (should (equal (zwanenzang-test--doc-text trk child "plan") "Plan text\n"))
      ;; The pull that ended the push landed numbers and sync state.
      (should (equal (zwanenzang-test-property parent "ZWANENZANG_NUMBER") "ZZ-0001"))
      (should (zwanenzang-test-property child "ZWANENZANG_CURSOR"))
      (should (string-match-p (format "nest=%s\\'" parent)
                              (zwanenzang-test-property child "ZWANENZANG_SYNC")))
      (should-not (member zwanenzang-conflict-tag (zwanenzang-test-tags child)))
      (should (string-match-p "created ZZ-0001 Parent" (zwanenzang-test-report)))
      ;; Published, so another clone sees them.
      (let ((other (zwanenzang-test-clone net "other-test-repo")))
        (should (equal (alist-get 'title (zwanenzang-test-show other child)) "Child")))
      ;; And nothing is left to send.
      (let ((head (zwanenzang-test-head trk))
            (before (buffer-string)))
        (zwanenzang-test-at-root #'zwanenzang-push)
        (should (equal (zwanenzang-test-head trk) head))
        (should (equal (buffer-string) before))))))

(ert-deftest zwanenzang-push-keeps-identity-when-the-final-pull-fails ()
  (zwanenzang-test-with-remote-scope (net trk buf zwanenzang-test--push-org)
    (zwanenzang-test-append "** TODO New\n")
    (let* ((real zwanenzang--call)
           (applied nil)
           (zwanenzang--call (lambda (dir args &optional input)
                               (when (and applied (member "list" args))
                                 (user-error "zwanenzang: boom"))
                               (when (member "apply" args) (setq applied t))
                               (funcall real dir args input))))
      (should-error (zwanenzang-test-at-root #'zwanenzang-push) :type 'user-error))
    (should (zwanenzang-test-id-of "New"))
    ;; The retry creates nothing more.
    (zwanenzang-test-at-root #'zwanenzang-push)
    (should (= 1 (length (alist-get 'tickets (zwanenzang-test-cli trk "list")))))))

(ert-deftest zwanenzang-push-refused-apply-changes-nothing ()
  ;; A tag the CLI refuses refuses the batch: no identity is written.
  (zwanenzang-test-with-remote-scope (net trk buf zwanenzang-test--push-org)
    (zwanenzang-test-append "** TODO New\n")
    (let ((before (buffer-string))
          (zwanenzang--call (lambda (dir args &optional input)
                              (if (member "apply" args)
                                  (user-error "zwanenzang: invalid-tag: nope")
                                (zwanenzang-test-call dir args input)))))
      (should-error (zwanenzang-test-at-root #'zwanenzang-push) :type 'user-error)
      (should (equal (buffer-string) before)))))

(ert-deftest zwanenzang-push-sends-field-edits-and-clears-conflicts ()
  (zwanenzang-test-with-remote-scope (net trk buf zwanenzang-test--push-org)
    (let ((id (zwanenzang-test-create trk "Base" "--tag" "old")))
      (zwanenzang-test-pull)
      (save-excursion
        (zwanenzang-test-goto id)
        (org-edit-headline "Mine")
        (org-todo "NEXT")
        (org-set-tags '("new")))
      ;; An agent changes the title too: the pull sees a conflict.
      (zwanenzang-test-cli trk "title" id "Theirs")
      (zwanenzang-test-pull)
      (should (member zwanenzang-conflict-tag (zwanenzang-test-tags id)))
      (zwanenzang-test-clear-report)
      (should (string-match-p "1 pushed" (zwanenzang-test-at-root #'zwanenzang-push)))
      (let ((shown (zwanenzang-test-show trk id)))
        (should (equal (alist-get 'title shown) "Mine"))
        (should (equal (alist-get 'status shown) "doing"))
        (should (equal (alist-get 'tags shown) '("new"))))
      (should (string-match-p "pushed ZZ-0001 Mine: status, title, tags"
                              (zwanenzang-test-report)))
      (should-not (member zwanenzang-conflict-tag (zwanenzang-test-tags id)))
      (should-not (string-match-p "ZWANENZANG_CONFLICT" (zwanenzang-test-entry id)))
      (should (string-match-p "status=doing " (zwanenzang-test-property id "ZWANENZANG_SYNC"))))))

(ert-deftest zwanenzang-push-without-sync-keeps-the-text-when-a-remote-version-wins ()
  ;; Push does not fetch first, so its version can lose on the remote.
  ;; The text stays in Org and the next push settles it.
  (zwanenzang-test-with-remote-scope (net trk buf zwanenzang-test--push-org)
    (let ((id (zwanenzang-test-create trk "Ticket")))
      (zwanenzang-test-set-doc trk id "plan" "Base plan\n")
      (zwanenzang-test-pull)
      (let ((agent (zwanenzang-test-clone net "agent-test-repo")))
        (zwanenzang-test-set-doc agent id "plan" "Agent plan\n")
        (save-excursion
          (zwanenzang-test-goto id)
          (search-forward "Base plan") (replace-match "My plan"))
        (zwanenzang-test-at-root #'zwanenzang-push)
        (should (member zwanenzang-conflict-tag (zwanenzang-test-tags id)))
        (should (string-match-p "My plan" (buffer-string)))
        (zwanenzang-test-at-root #'zwanenzang-push)
        (should (equal (zwanenzang-test--doc-text trk id "plan") "My plan\n"))
        (should-not (member zwanenzang-conflict-tag (zwanenzang-test-tags id)))))))

(ert-deftest zwanenzang-push-sends-a-new-document ()
  (zwanenzang-test-with-remote-scope (net trk buf zwanenzang-test--push-org)
    (let ((id (zwanenzang-test-create trk "Ticket")))
      (zwanenzang-test-pull)
      (save-excursion
        (zwanenzang-test-goto id)
        (org-end-of-subtree t t)
        (insert "**** Notes for later\n:PROPERTIES:\n:ZWANENZANG_DOC: notes\n:END:\nA note\n"
                "**** Secret\n:PROPERTIES:\n:ZWANENZANG_DOC: status\n:END:\nNo\n"))
      (zwanenzang-test-clear-report)
      (zwanenzang-test-at-root #'zwanenzang-push)
      (should (equal (zwanenzang-test--doc-text trk id "notes") "A note\n"))
      (should-not (alist-get 'status (alist-get 'documents (zwanenzang-test-show trk id))))
      (should (string-match-p "document status not pushed" (zwanenzang-test-report)))
      (save-excursion
        (zwanenzang-test-goto id)
        (goto-char (cdr (assoc "notes" (zwanenzang--doc-headings))))
        (should (org-entry-get nil "ZWANENZANG_VERSION"))))))

(ert-deftest zwanenzang-push-reparents-through-a-grouping-heading ()
  (zwanenzang-test-with-remote-scope (net trk buf zwanenzang-test--push-org)
    (let* ((p (zwanenzang-test-create trk "P"))
           (c (zwanenzang-test-create trk "C")))
      (zwanenzang-test-pull)
      (save-excursion
        (zwanenzang-test-goto p)
        (org-end-of-subtree t t)
        (insert "**** Group\n"))
      (zwanenzang-test--move-under c "Group")
      (zwanenzang-test-at-root #'zwanenzang-push)
      (should (equal (alist-get 'parent (zwanenzang-test-show trk c)) p))
      (should (string-match-p (format "parent=%s nest=%s\\'" p p)
                              (zwanenzang-test-property c "ZWANENZANG_SYNC")))
      (should (equal (zwanenzang-test-parent-heading c) "Group"))
      ;; Out to the inbox again: no ancestor.
      (zwanenzang-test--move-under c "Inbox")
      (zwanenzang-test-at-root #'zwanenzang-push)
      (should (eq (alist-get 'parent (zwanenzang-test-show trk c)) :null)))))

(ert-deftest zwanenzang-push-leaves-the-parent-of-a-ticket-parked-in-the-inbox ()
  (zwanenzang-test-with-remote-scope (net trk buf zwanenzang-test--push-org)
    (let* ((p (zwanenzang-test-create trk "P"))
           (c (zwanenzang-test-create trk "C" "--parent" p)))
      ;; An archived parent gets no heading, so the child lands in the inbox.
      (zwanenzang-test-cli trk "archive" p)
      (zwanenzang-test-pull)
      (should (equal (zwanenzang-test-parent-heading c) "Inbox"))
      (zwanenzang-test--edit-title c "C renamed")
      (zwanenzang-test-at-root #'zwanenzang-push)
      (let ((shown (zwanenzang-test-show trk c)))
        (should (equal (alist-get 'title shown) "C renamed"))
        (should (equal (alist-get 'parent shown) p))))))

(ert-deftest zwanenzang-push-skips-blocked-headings-and-pushes-the-rest ()
  (zwanenzang-test-with-remote-scope (net trk buf zwanenzang-test--push-org)
    (let ((dup (zwanenzang-test-create trk "Dup"))
          (tomb (zwanenzang-test-create trk "Tomb"))
          (wait (zwanenzang-test-create trk "Wait"))
          (bare (zwanenzang-test-create trk "Bare"))
          (fine (zwanenzang-test-create trk "Fine")))
      (zwanenzang-test-pull)
      (zwanenzang-test-cli trk "tombstone" tomb)
      (zwanenzang-test-append (concat "** TODO Foreign\n:PROPERTIES:\n"
                                      ":ZWANENZANG_ID: 01ZZZZZZZZZZZZZZZZZZZZZZZZ\n:END:\n"
                                      "** WAIT New unmapped\n"))
      (save-excursion
        (zwanenzang-test-goto dup)
        (org-copy-subtree)
        (goto-char (point-max))
        (org-paste-subtree 2))
      (zwanenzang-test--edit-title tomb "Tomb edit")
      (zwanenzang-test--edit-title wait "Wait edit")
      (zwanenzang-test--edit-title bare "Bare edit")
      (zwanenzang-test--edit-title fine "Fine edit")
      (save-excursion (zwanenzang-test-goto wait) (org-todo "WAIT"))
      (save-excursion (zwanenzang-test-goto bare) (org-todo 'none))
      (zwanenzang-test-clear-report)
      (zwanenzang-test-at-root #'zwanenzang-push)
      (should (equal (alist-get 'title (zwanenzang-test-show trk fine)) "Fine edit"))
      (should (equal (alist-get 'title (zwanenzang-test-show trk tomb)) "Tomb"))
      (should (equal (alist-get 'title (zwanenzang-test-show trk wait)) "Wait"))
      (should (equal (alist-get 'title (zwanenzang-test-show trk bare)) "Bare"))
      (should-not (zwanenzang-test-id-of "New unmapped"))
      (should (= 5 (length (alist-get 'tickets (zwanenzang-test-cli trk "list" "--all")))))
      (let ((report (zwanenzang-test-report)))
        (should (string-match-p "foreign: the tracker has no ticket" report))
        (should (string-match-p "duplicate: ZWANENZANG_ID" report))
        (should (string-match-p "\"New unmapped\" not created: keyword WAIT" report)))
      (should (string-match-p "keyword WAIT has no status" (zwanenzang-test-entry wait)))
      (should (member zwanenzang-conflict-tag (zwanenzang-test-tags wait)))
      (should (string-match-p "no TODO keyword" (zwanenzang-test-entry bare)))
      (should (string-match-p "tombstoned" (zwanenzang-test-entry tomb)))
      ;; Stays that way: the notes are not lost between runs.
      (let ((before (buffer-string)))
        (zwanenzang-test-at-root #'zwanenzang-push)
        (should (equal (buffer-string) before))))))

(ert-deftest zwanenzang-push-refuses-another-tracker-entirely ()
  (zwanenzang-test-with-remote-scope (net trk buf zwanenzang-test--push-org)
    (zwanenzang-test-append "** TODO New\n")
    (save-excursion
      (goto-char (point-min))
      (outline-next-heading)
      (org-entry-put nil "ZWANENZANG_TRACKER" "01AAAAAAAAAAAAAAAAAAAAAAAA"))
    (let ((before (buffer-string))
          (head (zwanenzang-test-head trk)))
      (should (string-match-p "push of Project blocked"
                              (zwanenzang-test-at-root #'zwanenzang-push)))
      (should (equal (buffer-string) before))
      (should (equal (zwanenzang-test-head trk) head)))))

(ert-deftest zwanenzang-push-of-nothing-writes-nothing ()
  (zwanenzang-test-with-remote-scope (net trk buf zwanenzang-test--push-org)
    (zwanenzang-test-create trk "Ticket")
    (zwanenzang-test-pull)
    (let ((head (zwanenzang-test-head trk))
          (before (buffer-string))
          (tick (buffer-modified-tick))
          (applied nil))
      (let ((zwanenzang--call (lambda (dir args &optional input)
                                (when (member "apply" args) (setq applied t))
                                (zwanenzang-test-call dir args input))))
        (should (string-match-p ": nothing changed\\'"
                                (zwanenzang-test-at-root #'zwanenzang-push))))
      (should-not applied)
      (should (equal (zwanenzang-test-head trk) head))
      (should (equal (buffer-string) before))
      (should (= (buffer-modified-tick) tick)))))

(ert-deftest zwanenzang-revival-by-archive-time-unarchives-and-follows-the-keyword ()
  (zwanenzang-test-with-remote-scope (net trk buf zwanenzang-test--push-org)
    (let ((id (zwanenzang-test-create trk "Ticket" "--status" "done"))
          (other (zwanenzang-test-create trk "Other")))
      (zwanenzang-test-pull)
      (zwanenzang-test-cli trk "archive" id)
      (zwanenzang-test-cli trk "archive" other)
      (zwanenzang-test-pull)
      (save-excursion
        (zwanenzang-test-goto id)
        (org-entry-put nil "ARCHIVE_TIME" "2026-11-08 Sun 10:00")
        (org-entry-put nil "ARCHIVE_FILE" "/tmp/x.org")
        (org-entry-put nil "ARCHIVE_OLPATH" "Project")
        (org-todo "NEXT"))
      (zwanenzang-test-at-root #'zwanenzang-push)
      (let ((shown (zwanenzang-test-show trk id)))
        (should (eq (alist-get 'archived shown) :false))
        (should (equal (alist-get 'status shown) "doing")))
      (should-not (zwanenzang-test-property id "ARCHIVE_TIME"))
      (should-not (zwanenzang-test-property id "ARCHIVE_FILE"))
      (should-not (zwanenzang-test-property id "ARCHIVE_OLPATH"))
      ;; No ARCHIVE_TIME, so this one stays archived.
      (should (eq (alist-get 'archived (zwanenzang-test-show trk other)) t)))))

(ert-deftest zwanenzang-revival-keeps-archive-properties-when-apply-fails ()
  (zwanenzang-test-with-remote-scope (net trk buf zwanenzang-test--push-org)
    (let ((id (zwanenzang-test-create trk "Ticket")))
      (zwanenzang-test-pull)
      (zwanenzang-test-cli trk "archive" id)
      (save-excursion (zwanenzang-test-goto id)
                      (org-entry-put nil "ARCHIVE_TIME" "2026-11-08 Sun 10:00"))
      (let ((zwanenzang--call (lambda (dir args &optional input)
                                (if (member "apply" args)
                                    (user-error "zwanenzang: boom")
                                  (zwanenzang-test-call dir args input)))))
        (should-error (zwanenzang-test-at-root #'zwanenzang-push) :type 'user-error))
      (should (zwanenzang-test-property id "ARCHIVE_TIME")))))

(provide 'zwanenzang-push-integration-test)
;;; zwanenzang-push-integration-test.el ends here
