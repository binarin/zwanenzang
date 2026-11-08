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

(defun zwanenzang-test--on-disk ()
  "The text of the visited file on disk."
  (let ((file buffer-file-name))
    (with-temp-buffer (insert-file-contents file) (buffer-string))))

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

(ert-deftest zwanenzang-push-saves-the-file-only-when-it-created-tickets ()
  (zwanenzang-test-with-remote-scope (net trk buf zwanenzang-test--push-org)
    (let ((existing (zwanenzang-test-create trk "Existing")))
      ;; Pull, and a push that creates nothing, do not save.
      (let ((on-disk (zwanenzang-test--on-disk)))
        (zwanenzang-test-pull)
        (zwanenzang-test--edit-title existing "Edited")
        (zwanenzang-test-at-root #'zwanenzang-push)
        (should (equal (alist-get 'title (zwanenzang-test-show trk existing)) "Edited"))
        (should (equal (zwanenzang-test--on-disk) on-disk)))
      (zwanenzang-test-append "** TODO New one\n** TODO New two\n")
      (zwanenzang-test-clear-report)
      (should (string-match-p "2 created, file saved" (zwanenzang-test-at-root #'zwanenzang-push)))
      (should (string-match-p "saved .*scope.org: it holds the ids" (zwanenzang-test-report)))
      (let ((one (zwanenzang-test-id-of "New one"))
            (two (zwanenzang-test-id-of "New two"))
            (on-disk (zwanenzang-test--on-disk)))
        (should (string-match-p (concat ":ZWANENZANG_ID: " one) on-disk))
        (should (string-match-p (concat ":ZWANENZANG_ID: " two) on-disk))
        ;; Emacs killed, unsaved edits gone: the next push creates nothing.
        (let ((file buffer-file-name))
          (revert-buffer t t)
          (should (equal buffer-file-name file)))
        (zwanenzang-test-at-root #'zwanenzang-push)
        (should (= 3 (length (alist-get 'tickets (zwanenzang-test-cli trk "list")))))))))

(ert-deftest zwanenzang-push-refuses-a-read-only-buffer-before-sending ()
  (zwanenzang-test-with-remote-scope (net trk buf zwanenzang-test--push-org)
    (zwanenzang-test-append "** TODO New\n")
    (let ((head (zwanenzang-test-head trk))
          (before (buffer-string)))
      (setq buffer-read-only t)
      (let ((err (should-error (zwanenzang-test-at-root #'zwanenzang-push) :type 'user-error)))
        (should (string-match-p "read-only; nothing was sent" (cadr err))))
      (setq buffer-read-only nil)
      (should (equal (buffer-string) before))
      (should (equal (zwanenzang-test-head trk) head))
      (should-not (alist-get 'tickets (zwanenzang-test-cli trk "list"))))))

(ert-deftest zwanenzang-push-failing-to-write-back-names-what-it-created ()
  (zwanenzang-test-with-remote-scope (net trk buf zwanenzang-test--push-org)
    (zwanenzang-test-append "** TODO New\n")
    (let ((err (cl-letf (((symbol-function 'save-buffer)
                          (lambda (&rest _) (error "Disk full"))))
                 (should-error (zwanenzang-test-at-root #'zwanenzang-push) :type 'user-error)))
          (id (alist-get 'id (car (alist-get 'tickets (zwanenzang-test-cli trk "list"))))))
      (should (string-match-p "the tracker took the push.*Disk full" (cadr err)))
      (should (string-match-p (format "created ZZ-0001 New (%s)" id) (cadr err))))))

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

(ert-deftest zwanenzang-sync-human-wins-over-an-agents-concurrent-document ()
  (zwanenzang-test-with-remote-scope (net trk buf zwanenzang-test--push-org)
    (let ((id (zwanenzang-test-create trk "Ticket")))
      (zwanenzang-test-set-doc trk id "description" "Base text\n")
      (zwanenzang-test-set-doc trk id "plan" "Base plan\n")
      (zwanenzang-test-at-root #'zwanenzang-sync)
      (save-excursion
        (zwanenzang-test-goto id)
        (search-forward "Base text") (replace-match "My text")
        (search-forward "Base plan") (replace-match "My plan"))
      ;; The agent works in its own clone and publishes first.
      (let ((agent (zwanenzang-test-clone net "agent-test-repo")))
        (zwanenzang-test-set-doc agent id "plan" "Agent plan\n")
        (zwanenzang-test-at-root #'zwanenzang-sync)
        (should (equal (zwanenzang-test--doc-text trk id "plan") "My plan\n"))
        (should (equal (zwanenzang-test--doc-text trk id "description") "My text\n"))
        (should (member "Agent plan\n"
                        (mapcar (lambda (v)
                                  (with-temp-buffer
                                    (insert-file-contents-literally
                                     (expand-file-name (format "blobs/%s" (alist-get 'blob v)) trk))
                                    (decode-coding-region (point-min) (point-max) 'utf-8)
                                    (buffer-string)))
                                (zwanenzang-test--doc-versions trk id "plan"))))
        (should-not (seq-some (lambda (v) (eq (alist-get 'lost v) t))
                              (zwanenzang-test--doc-versions trk id "plan")))
        (should-not (member zwanenzang-conflict-tag (zwanenzang-test-tags id)))
        (should-not (string-match-p "ZWANENZANG_CONFLICT" (zwanenzang-test-entry id)))
        ;; The agent gets the human's version on its next sync.
        (zwanenzang-test-cli agent "sync")
        (should (equal (zwanenzang-test--doc-text agent id "plan") "My plan\n"))))))

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

(ert-deftest zwanenzang-push-keeps-a-drawer-like-line-with-a-human-drawer-below ()
  (zwanenzang-test-with-remote-scope (net trk buf zwanenzang-test--push-org)
    (let ((id (zwanenzang-test-create trk "Ticket"))
          (text "text\n:B:\ntail\n"))
      (zwanenzang-test-set-doc trk id "description" text)
      (zwanenzang-test-pull)
      (should (string-match-p "text\n,:B:\ntail\n" (zwanenzang-test-entry id)))
      (cl-flet ((add-drawer-below ()
                  (save-excursion
                    (zwanenzang-test-goto id)
                    (search-forward "tail\n")
                    (unless (looking-at-p ":NOTES:")
                      (insert ":NOTES:\nmine\n:END:\n"))))
                (pushes-nothing ()
                  (let ((head (zwanenzang-test-head trk)))
                    (zwanenzang-test-at-root #'zwanenzang-push)
                    (should (equal (zwanenzang-test-head trk) head))
                    (should (equal (zwanenzang-test--doc-text trk id "description") text)))))
        (add-drawer-below)
        (pushes-nothing)
        ;; A file an earlier version wrote, without the comma.
        (save-excursion
          (zwanenzang-test-goto id)
          (search-forward ",:B:")
          (replace-match ":B:"))
        (zwanenzang-test-at-root #'zwanenzang-pull)
        (should (string-match-p "mine" (zwanenzang-test-entry id)))
        (should (string-match-p "text\n:B:\ntail\n" (zwanenzang-test-entry id)))
        (pushes-nothing)
        ;; Bare, with the drawer directly below it, as first read.
        (save-excursion
          (zwanenzang-test-goto id)
          (search-forward ":NOTES:\nmine\n:END:\n")
          (replace-match "")
          (search-forward "tail\n")
          (insert ":NOTES:\nmine\n:END:\n"))
        (pushes-nothing)))))

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
      (should (string-match-p "pull of Project blocked"
                              (zwanenzang-test-at-root #'zwanenzang-sync)))
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

(ert-deftest zwanenzang-sync-offline-is-reported-not-failed ()
  (zwanenzang-test-with-remote-scope (net trk buf zwanenzang-test--push-org)
    (let ((id (zwanenzang-test-create trk "Ticket")))
      (zwanenzang-test-at-root #'zwanenzang-sync)
      (zwanenzang-test-delete-dir (expand-file-name "remote-test-repo" net))
      (zwanenzang-test--edit-title id "Edited offline")
      (zwanenzang-test-append "** TODO Written offline\n")
      (zwanenzang-test-clear-report)
      (let ((summary (zwanenzang-test-at-root #'zwanenzang-sync)))
        (should (string-match-p "1 created, 1 pushed" summary))
        (should (string-match-p "see \\*zwanenzang\\*" summary)))
      (should (string-match-p "not published: fetch-failed" (zwanenzang-test-report)))
      ;; Local success: state is in the clone and in the sync state.
      (should (equal (alist-get 'title (zwanenzang-test-show trk id)) "Edited offline"))
      (should (zwanenzang-test-id-of "Written offline")))))

(ert-deftest zwanenzang-sync-reports-checkout-results ()
  (zwanenzang-test-with-remote-scope (net trk buf zwanenzang-test--push-org)
    (let ((checkout (zwanenzang-test-clone net "checkout-test-repo")))
      (zwanenzang-test-git trk "config" "--local" "--add" "zwanenzang.checkout" checkout)
      (zwanenzang-test-create trk "Ticket")
      (with-temp-file (expand-file-name "untracked" checkout))
      (zwanenzang-test-clear-report)
      (should (string-match-p "see \\*zwanenzang\\*" (zwanenzang-test-at-root #'zwanenzang-sync)))
      (should (string-match-p (concat "checkout " (regexp-quote checkout) ": skipped, dirty")
                              (zwanenzang-test-report)))
      (delete-file (expand-file-name "untracked" checkout))
      (zwanenzang-test-clear-report)
      (should-not (string-match-p "see \\*zwanenzang\\*"
                                  (zwanenzang-test-at-root #'zwanenzang-sync)))
      (should (string-match-p (concat "checkout " (regexp-quote checkout) ": \\(updated\\|up-to-date\\)")
                              (zwanenzang-test-report))))))

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

(ert-deftest zwanenzang-unarchive-the-heading-at-point-or-its-subtree ()
  (zwanenzang-test-with-remote-scope (net trk buf zwanenzang-test--push-org)
    (let* ((top (zwanenzang-test-create trk "Top"))
           (kid (zwanenzang-test-create trk "Kid" "--parent" top))
           (grand (zwanenzang-test-create trk "Grand" "--parent" kid))
           (outside (zwanenzang-test-create trk "Outside")))
      (zwanenzang-test-pull)
      (dolist (id (list top kid grand outside))
        (zwanenzang-test-cli trk "archive" id))
      (zwanenzang-test-pull)
      (save-excursion (zwanenzang-test-goto kid)
                      (org-entry-put nil "ARCHIVE_TIME" "2026-11-08 Sun 10:00"))
      (save-excursion
        (zwanenzang-test-goto top)
        (zwanenzang-unarchive))
      (should (eq (alist-get 'archived (zwanenzang-test-show trk top)) :false))
      (should (eq (alist-get 'archived (zwanenzang-test-show trk kid)) t))
      (should (equal (alist-get 'status (zwanenzang-test-show trk top)) "draft"))
      ;; Point in the body counts; the prefix takes the subtree too.
      (save-excursion
        (zwanenzang-test-goto kid)
        (forward-line 2)
        (zwanenzang-unarchive '(4)))
      (should (eq (alist-get 'archived (zwanenzang-test-show trk kid)) :false))
      (should (eq (alist-get 'archived (zwanenzang-test-show trk grand)) :false))
      (should (eq (alist-get 'archived (zwanenzang-test-show trk outside)) t))
      (should-not (zwanenzang-test-property kid "ARCHIVE_TIME"))
      ;; Nothing there to do is reported, and writes nothing.
      (let ((head (zwanenzang-test-head trk)))
        (zwanenzang-test-clear-report)
        (save-excursion
          (zwanenzang-test-goto top)
          (zwanenzang-unarchive))
        (should (string-match-p "no archived ticket here" (zwanenzang-test-report)))
        (should (equal (zwanenzang-test-head trk) head)))
      (save-excursion
        (goto-char (point-min))
        (outline-next-heading)
        (should-error (zwanenzang-unarchive) :type 'user-error)))))

(ert-deftest zwanenzang-repeat-sync-is-stable ()
  (zwanenzang-test-with-remote-scope (net trk buf zwanenzang-test--push-org)
    (let ((id (zwanenzang-test-create trk "Ticket" "--tag" "a")))
      (zwanenzang-test-set-doc trk id "description" "Text\n#+begin_src sh\nls\n#+end_src\n* no\n")
      (zwanenzang-test-set-doc trk id "plan" "Plan\n")
      (zwanenzang-test-set-doc trk id "status" "Hidden\n")
      (zwanenzang-test-cli trk "comment" id "A comment\n* starred\n:END:\n")
      (zwanenzang-test-append "** Group\n*** NEXT New :x:\nNew text\n")
      (zwanenzang-test-at-root #'zwanenzang-sync)
      (let ((before (buffer-string))
            (tick (buffer-modified-tick))
            (head (zwanenzang-test-head trk)))
        (should (string-match-p ": nothing changed\\'" (zwanenzang-test-at-root #'zwanenzang-sync)))
        (should (equal (buffer-string) before))
        (should (= (buffer-modified-tick) tick))
        (should (equal (zwanenzang-test-head trk) head))))))

(ert-deftest zwanenzang-sync-all-covers-every-scope-and-survives-a-failure ()
  (zwanenzang-test-with-remote-scope (net trk buf zwanenzang-test--push-org)
    (zwanenzang-test-with-tracker other
      (let* ((second (expand-file-name "second.org" net))
             (broken (expand-file-name "broken.org" net))
             (zwanenzang-org-files (list broken buffer-file-name second)))
        (with-temp-file broken
          (insert "* Broken\n:PROPERTIES:\n:ZWANENZANG: /nonexistent/zwanenzang\n:END:\n"))
        (with-temp-file second
          (insert (format zwanenzang-test--push-org other) "** TODO Over there\n"))
        (zwanenzang-test-append "** TODO Over here\n")
        (unwind-protect
            (progn
              (zwanenzang-test-clear-report)
              (should (string-match-p "synced 2 scopes, 1 failed" (zwanenzang-sync-all)))
              (should (zwanenzang-test-id-of "Over here"))
              (should (equal (mapcar (lambda (s) (alist-get 'title s))
                                     (alist-get 'tickets (zwanenzang-test-cli other "list")))
                             '("Over there")))
              (should (string-match-p "broken.org: Broken: .*not a directory"
                                      (zwanenzang-test-report))))
          (dolist (file (list broken second))
            (let ((b (find-buffer-visiting file)))
              (when b
                (with-current-buffer b (set-buffer-modified-p nil))
                (kill-buffer b)))))))))

(defun zwanenzang-test--writing-before-apply (dir id times)
  "A CLI call that writes a new plan of ticket ID in DIR before TIMES applies.
Returns (CALL . COUNTER), COUNTER a cons whose car counts the applies."
  (let ((applies (list 0)))
    (cons (lambda (d args &optional input)
            (when (member "apply" args)
              (when (< (car applies) times)
                (zwanenzang-test-set-doc dir id "plan"
                                         (format "Agent plan %d\n" (car applies))))
              (cl-incf (car applies)))
            (zwanenzang-test-call d args input))
          applies)))

(ert-deftest zwanenzang-push-retries-once-on-a-stale-document-base ()
  (zwanenzang-test-with-remote-scope (net trk buf zwanenzang-test--push-org)
    (let ((id (zwanenzang-test-create trk "Ticket")))
      (zwanenzang-test-set-doc trk id "plan" "Base plan\n")
      (zwanenzang-test-pull)
      (save-excursion
        (zwanenzang-test-goto id)
        (search-forward "Base plan") (replace-match "My plan"))
      (zwanenzang-test-append "** TODO Also new\n")
      (pcase-let ((`(,call . ,applies) (zwanenzang-test--writing-before-apply trk id 1)))
        (let ((zwanenzang--call call))
          (should (string-match-p "1 created, 1 pushed"
                                  (zwanenzang-test-at-root #'zwanenzang-push))))
        (should (= (car applies) 2)))
      (should (equal (zwanenzang-test--doc-text trk id "plan") "My plan\n"))
      (should (= 3 (length (zwanenzang-test--doc-versions trk id "plan"))))
      (should (= 2 (length (alist-get 'tickets (zwanenzang-test-cli trk "list")))))
      (should-not (member zwanenzang-conflict-tag (zwanenzang-test-tags id))))))

(ert-deftest zwanenzang-push-fails-after-a-second-stale-base-leaving-the-buffer ()
  (zwanenzang-test-with-remote-scope (net trk buf zwanenzang-test--push-org)
    (let ((id (zwanenzang-test-create trk "Ticket")))
      (zwanenzang-test-set-doc trk id "plan" "Base plan\n")
      (zwanenzang-test-pull)
      (save-excursion
        (zwanenzang-test-goto id)
        (search-forward "Base plan") (replace-match "My plan"))
      (zwanenzang-test-append "** TODO Also new\n")
      (let ((before (buffer-string))
            (on-disk (zwanenzang-test--on-disk)))
        (pcase-let ((`(,call . ,applies) (zwanenzang-test--writing-before-apply trk id 2)))
          (let* ((zwanenzang--call call)
                 (err (should-error (zwanenzang-test-at-root #'zwanenzang-push)
                                    :type 'user-error)))
            (should (string-match-p "stale-doc-base" (cadr err))))
          (should (= (car applies) 2)))
        (should (equal (buffer-string) before))
        (should (equal (zwanenzang-test--on-disk) on-disk))
        (should (= 1 (length (alist-get 'tickets (zwanenzang-test-cli trk "list")))))))))

(ert-deftest zwanenzang-push-reports-keyword-map-problems ()
  (zwanenzang-test-with-remote-scope (net trk buf
                                          (concat "#+TODO: TODO | DONE\n"
                                                  "* Project\n:PROPERTIES:\n:ZWANENZANG: %s\n"
                                                  ":ZWANENZANG_KEYWORDS: TODO=todo,draft DONE=done\n"
                                                  ":END:\n"))
    (zwanenzang-test-clear-report)
    (should (string-match-p "see \\*zwanenzang\\*" (zwanenzang-test-at-root #'zwanenzang-push)))
    (with-temp-buffer
      (insert (zwanenzang-test-report))
      (should (= 1 (how-many "keyword map: status doing has no keyword"
                             (point-min) (point-max)))))))

(ert-deftest zwanenzang-push-sends-nothing-for-a-file-with-the-old-escaping ()
  ;; Earlier versions put a comma on `#+' and drawer-like lines.
  (zwanenzang-test-with-remote-scope (net trk buf zwanenzang-test--push-org)
    (let ((id (zwanenzang-test-create trk "Ticket"))
          (applied nil))
      (zwanenzang-test-set-doc trk id "description"
                               "Text\n#+begin_src sh\nls\n#+end_src\n#+TITLE: x\n")
      (zwanenzang-test-set-doc trk id "plan" "Plan\n#+begin_quote\nq\n#+end_quote\n")
      (zwanenzang-test-pull)
      (save-excursion
        (goto-char (point-min))
        (outline-next-heading)
        (while (re-search-forward "^#\\+" nil t)
          (replace-match ",#+")))
      (should (string-match-p ",#\\+begin_src" (zwanenzang-test-entry id)))
      (let ((head (zwanenzang-test-head trk))
            (zwanenzang--call (lambda (dir args &optional input)
                                (when (member "apply" args) (setq applied t))
                                (zwanenzang-test-call dir args input))))
        (should (string-match-p ": nothing changed\\'"
                                (zwanenzang-test-at-root #'zwanenzang-push)))
        (should-not applied)
        (should (equal (zwanenzang-test-head trk) head)))
      (should (equal (zwanenzang-test--doc-text trk id "description")
                     "Text\n#+begin_src sh\nls\n#+end_src\n#+TITLE: x\n")))))

(ert-deftest zwanenzang-sync-all-goes-on-past-any-error-in-a-scope ()
  (zwanenzang-test-with-remote-scope (net trk buf zwanenzang-test--push-org)
    (zwanenzang-test-with-tracker other
      (zwanenzang-test-create other "Has to land in a read-only buffer")
      (let* ((stuck (expand-file-name "stuck.org" net))
             (zwanenzang-org-files (list stuck buffer-file-name)))
        (with-temp-file stuck (insert (format zwanenzang-test--push-org other)))
        (with-current-buffer (find-file-noselect stuck) (setq buffer-read-only t))
        (zwanenzang-test-append "** TODO Over here\n")
        (unwind-protect
            (progn
              (zwanenzang-test-clear-report)
              (should (string-match-p "synced 1 scopes, 1 failed" (zwanenzang-sync-all)))
              (should (zwanenzang-test-id-of "Over here"))
              (should (string-match-p "stuck.org: Project: .*read-only"
                                      (zwanenzang-test-report))))
          (kill-buffer (find-buffer-visiting stuck)))))))

(provide 'zwanenzang-push-integration-test)
;;; zwanenzang-push-integration-test.el ends here
