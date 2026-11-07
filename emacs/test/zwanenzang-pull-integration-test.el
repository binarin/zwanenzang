;;; zwanenzang-pull-integration-test.el --- Pull against the real CLI  -*- lexical-binding: t; -*-

;;; Commentary:

;; Each test creates a disposable tracker, changes it through the CLI and
;; pulls it into an Org file in another disposable directory.

;;; Code:

(require 'ert)
(require 'zwanenzang)
(require 'zwanenzang-test-helpers)

(defconst zwanenzang-test--org
  (concat "#+TODO: TODO NEXT WAIT | DONE CNCL\n"
          "* Project\n"
          ":PROPERTIES:\n"
          ":ZWANENZANG: %s\n"
          ":ZWANENZANG_KEYWORDS: TODO=todo,draft NEXT=doing,review WAIT=blocked"
          " DONE=done CNCL=cancelled\n"
          ":ZWANENZANG_HIDE_DOCS: status\n"
          ":END:\n")
  "An Org file with one scope; %s is the tracker.")

(defun zwanenzang-test--file-text ()
  "The text of the visited file on disk."
  (let ((file buffer-file-name))
    (with-temp-buffer (insert-file-contents file) (buffer-string))))

(ert-deftest zwanenzang-pull-discovers-tickets-with-state ()
  (zwanenzang-test-with-scope (trk buf zwanenzang-test--org)
    (let* ((parent (zwanenzang-test-create trk "Parent" "--tag" "alpha"))
           (child (zwanenzang-test-create trk "Child" "--parent" parent "--status" "doing"))
           (lone (zwanenzang-test-create trk "Lone" "--status" "review")))
      (zwanenzang-test-cli trk "comment" parent "first\n* starred\n:END:")
      (zwanenzang-test-cli trk "comment" parent "second")
      (zwanenzang-test-set-doc trk parent "description" "Intro\n* not a heading\n")
      (zwanenzang-test-set-doc trk parent "plan" "Plan text\n")
      (zwanenzang-test-set-doc trk parent "status" "Hidden status\n")
      (let ((on-disk (zwanenzang-test--file-text)))
        (should (string-match-p "3 tickets\\|3 new" (zwanenzang-test-pull)))
        ;; Edited, not saved.
        (should (buffer-modified-p))
        (should (equal (zwanenzang-test--file-text) on-disk)))
      (should (equal (zwanenzang-test-parent-heading parent) "Inbox"))
      (should (equal (zwanenzang-test-parent-heading child) "Parent"))
      (should (equal (zwanenzang-test-parent-heading lone) "Inbox"))
      ;; A draft is shown as TODO and remembered as draft.
      (should (string-match-p "\\`\\*\\*\\* TODO Parent +:alpha:\\'"
                              (zwanenzang-test-heading parent)))
      (should (string-match-p "status=draft " (zwanenzang-test-property parent "ZWANENZANG_SYNC")))
      (should (string-prefix-p "**** NEXT Child" (zwanenzang-test-heading child)))
      (should (string-prefix-p "*** NEXT Lone" (zwanenzang-test-heading lone)))
      (should (equal (zwanenzang-test-property parent "ZWANENZANG_NUMBER") "ZZ-0001"))
      (should (zwanenzang-test-property parent "ZWANENZANG_CURSOR"))
      (should (zwanenzang-test-property parent "ZWANENZANG_DESC_VERSION"))
      (save-excursion
        (goto-char (point-min))
        (should (equal (org-entry-get (line-beginning-position 2) "ZWANENZANG_TRACKER")
                       (alist-get 'id (alist-get 'tracker
                                                 (zwanenzang-test-call trk '("read") '((cursors)))))))
        (should (org-entry-get (line-beginning-position 2) "ZWANENZANG_CURSOR")))
      (let ((entry (zwanenzang-test-entry parent)))
        (should (string-match-p
                 (concat ":ZWANENZANG_COMMENTS:\n"
                         "\\[[-0-9T:Z]+\\] tester:\n  : first\n  : \\* starred\n  : :END:\n"
                         "\\[[-0-9T:Z]+\\] tester:\n  : second\n:END:\n"
                         ":ZWANENZANG_HIDDEN:\n"
                         (regexp-quote (format "[[zwanenzang:%s/status][status (hidden)]]" parent))
                         "\n:END:\n"
                         "Intro\n,\\* not a heading\n\\'")
                 entry)))
      (save-excursion
        (zwanenzang-test-goto parent)
        (let ((docs (zwanenzang--doc-headings)))
          (should (equal (mapcar #'car docs) '("plan")))
          (goto-char (cdr (car docs)))
          (should (equal (zwanenzang--body-description (zwanenzang--body)) "Plan text\n"))
          (should (org-entry-get nil "ZWANENZANG_VERSION"))))
      ;; Pulling again with nothing new changes nothing.
      (let ((before (buffer-string)))
        (zwanenzang-test-pull)
        (should (equal (buffer-string) before))))))

(ert-deftest zwanenzang-pull-applies-remote-changes-to-unchanged-fields ()
  (zwanenzang-test-with-scope (trk buf zwanenzang-test--org)
    (let ((id (zwanenzang-test-create trk "Old" "--tag" "a")))
      (zwanenzang-test-set-doc trk id "description" "Old text\n")
      (zwanenzang-test-set-doc trk id "plan" "Old plan\n")
      (zwanenzang-test-pull)
      (zwanenzang-test-cli trk "title" id "New")
      (zwanenzang-test-cli trk "status" id "done")
      (zwanenzang-test-cli trk "tag" id "b")
      (zwanenzang-test-cli trk "tag" id "a" "--remove")
      (zwanenzang-test-set-doc trk id "description" "New text\n")
      (zwanenzang-test-set-doc trk id "plan" "New plan\n")
      (zwanenzang-test-cli trk "comment" id "later")
      (zwanenzang-test-pull)
      (should (string-match-p "\\`\\*\\*\\* DONE New +:b:\\'" (zwanenzang-test-heading id)))
      (should (string-match-p "status=done " (zwanenzang-test-property id "ZWANENZANG_SYNC")))
      (should (string-match-p "  : later\n:END:\nNew text\n\\'" (zwanenzang-test-entry id)))
      (save-excursion
        (zwanenzang-test-goto id)
        (goto-char (cdar (zwanenzang--doc-headings)))
        (should (equal (zwanenzang--body-description (zwanenzang--body)) "New plan\n")))
      (should-not (member zwanenzang-conflict-tag (zwanenzang-test-tags id))))))

(ert-deftest zwanenzang-pull-keeps-local-edits-and-records-conflicts ()
  (zwanenzang-test-with-scope (trk buf zwanenzang-test--org)
    (let ((id (zwanenzang-test-create trk "Base" "--status" "todo")))
      (zwanenzang-test-set-doc trk id "description" "Base text\n")
      (zwanenzang-test-set-doc trk id "plan" "Base plan\n")
      (zwanenzang-test-pull)
      ;; Org: title, description and plan edited; status left alone.
      (save-excursion
        (zwanenzang-test-goto id)
        (org-edit-headline "Mine")
        (search-forward "Base text")
        (replace-match "My text")
        (search-forward "Base plan")
        (replace-match "My plan"))
      ;; Tracker: the same fields, and the status.
      (zwanenzang-test-cli trk "title" id "Theirs")
      (zwanenzang-test-cli trk "status" id "doing")
      (zwanenzang-test-set-doc trk id "description" "Their text\n")
      (zwanenzang-test-set-doc trk id "plan" "Their plan\n")
      (zwanenzang-test-clear-report)
      (zwanenzang-test-pull)
      (should (string-match-p "\\`\\*\\*\\* NEXT Mine +:zz_conflict:\\'"
                              (zwanenzang-test-heading id)))
      (let ((entry (zwanenzang-test-entry id)))
        (should (string-match-p
                 (concat ":ZWANENZANG_CONFLICT:\n"
                         "- title: tracker title skipped; Org title kept\n  : Theirs\n"
                         "- description: tracker description skipped; Org text kept\n"
                         "  : Their text\n"
                         "- document plan: tracker version [0-9A-Z]+ skipped; Org text kept\n"
                         "  : Their plan\n"
                         ":END:\n")
                 entry))
        (should (string-match-p "My text\n\\'" entry)))
      (should (string-match-p "conflict in title, description, document plan"
                              (zwanenzang-test-report)))
      ;; Taking the tracker's title by hand resolves that field only.
      (save-excursion (zwanenzang-test-goto id) (org-edit-headline "Theirs"))
      (zwanenzang-test-pull)
      (let ((entry (zwanenzang-test-entry id)))
        (should-not (string-match-p "- title:" entry))
        (should (string-match-p "- description:" entry)))
      ;; Once every field agrees, the tag and drawer go.
      (save-excursion
        (zwanenzang-test-goto id)
        (search-forward "My text") (replace-match "Their text")
        (search-forward "My plan") (replace-match "Their plan"))
      (zwanenzang-test-pull)
      (should-not (member zwanenzang-conflict-tag (zwanenzang-test-tags id)))
      (should-not (string-match-p "ZWANENZANG_CONFLICT" (zwanenzang-test-entry id))))))

(ert-deftest zwanenzang-pull-moves-subtrees-when-the-parent-changes ()
  (zwanenzang-test-with-scope (trk buf zwanenzang-test--org)
    (let* ((p1 (zwanenzang-test-create trk "P1"))
           (p2 (zwanenzang-test-create trk "P2"))
           (child (zwanenzang-test-create trk "Child" "--parent" p1))
           (grand (zwanenzang-test-create trk "Grand" "--parent" child))
           (outside (zwanenzang-test-create trk "Outside"))
           (moved-here (zwanenzang-test-create trk "Moved here" "--parent" p1)))
      (zwanenzang-test-pull)
      (should (equal (zwanenzang-test-parent-heading child) "P1"))
      ;; New parent in scope: the subtree follows.
      (zwanenzang-test-cli trk "parent" child p2)
      (zwanenzang-test-pull)
      (should (equal (zwanenzang-test-parent-heading child) "P2"))
      (should (equal (zwanenzang-test-parent-heading grand) "Child"))
      (should (string-prefix-p "***** " (zwanenzang-test-heading grand)))
      ;; Parent cleared: under the inbox.
      (zwanenzang-test-cli trk "parent" child "--clear")
      (zwanenzang-test-pull)
      (should (equal (zwanenzang-test-parent-heading child) "Inbox"))
      ;; New parent without a heading in scope: under the inbox.
      (save-excursion
        (zwanenzang-test-goto outside)
        (org-cut-subtree))
      (zwanenzang-test-cli trk "parent" moved-here outside)
      (zwanenzang-test-pull)
      (should (equal (zwanenzang-test-parent-heading moved-here) "Inbox"))
      ;; Nesting changed in Org and the parent in the tracker: conflict.
      (save-excursion
        (zwanenzang-test-goto child)
        (org-cut-subtree)
        (zwanenzang-test-goto p1)
        (org-end-of-subtree t t)
        (org-paste-subtree 4))
      (zwanenzang-test-cli trk "parent" child p2)
      (zwanenzang-test-pull)
      (should (equal (zwanenzang-test-parent-heading child) "P1"))
      (should (member zwanenzang-conflict-tag (zwanenzang-test-tags child)))
      (should (string-match-p (format "- parent: tracker parent is %s; Org nesting kept" p2)
                              (zwanenzang-test-entry child))))))

(ert-deftest zwanenzang-pull-conflicts-when-the-map-lost-the-synced-status ()
  ;; The human removed the keyword; the map no longer shows the synced
  ;; status, so nothing says Org still has it: no keyword reappears.
  (zwanenzang-test-with-scope (trk buf zwanenzang-test--org)
    (let ((id (zwanenzang-test-create trk "Draft")))
      (zwanenzang-test-pull)
      (should (string-match-p "status=draft " (zwanenzang-test-property id "ZWANENZANG_SYNC")))
      (save-excursion
        (zwanenzang-test-goto id)
        (zwanenzang--set-heading nil "Draft" nil)
        (goto-char (point-min))
        (outline-next-heading)
        (org-entry-put nil "ZWANENZANG_KEYWORDS"
                       "TODO=todo NEXT=doing,review WAIT=blocked DONE=done CNCL=cancelled"))
      (zwanenzang-test-cli trk "status" id "todo")
      (zwanenzang-test-pull)
      (should (string-match-p "\\`\\*\\*\\* Draft +:zz_conflict:\\'" (zwanenzang-test-heading id)))
      (should (string-match-p "- status: tracker has todo (TODO); Org keyword kept"
                              (zwanenzang-test-entry id))))))

(ert-deftest zwanenzang-pull-leaves-archived-and-flags-tombstoned ()
  (zwanenzang-test-with-scope (trk buf zwanenzang-test--org)
    (let ((archived (zwanenzang-test-create trk "Archived"))
          (gone (zwanenzang-test-create trk "Gone")))
      (zwanenzang-test-pull)
      (zwanenzang-test-cli trk "title" archived "Archived, renamed")
      (zwanenzang-test-cli trk "archive" archived)
      (zwanenzang-test-cli trk "tombstone" gone)
      (zwanenzang-test-clear-report)
      (zwanenzang-test-pull)
      ;; Archived: stays, still updated, reported, no ARCHIVE tag.
      (should (equal (zwanenzang-test-parent-heading archived) "Inbox"))
      (should (equal (zwanenzang-test-heading archived) "*** TODO Archived, renamed"))
      (should (string-match-p "ZZ-0001 Archived, renamed: archived in the tracker"
                              (zwanenzang-test-report)))
      ;; Tombstoned: stays, flagged.
      (should (member zwanenzang-conflict-tag (zwanenzang-test-tags gone)))
      (should (string-match-p "- tombstoned: the ticket is tombstoned"
                              (zwanenzang-test-entry gone))))))

(ert-deftest zwanenzang-pull-blocks-foreign-and-duplicate-headings-only ()
  (zwanenzang-test-with-scope (trk buf (concat zwanenzang-test--org
                                               "** TODO Foreign\n:PROPERTIES:\n"
                                               ":ZWANENZANG_ID: 01ZZZZZZZZZZZZZZZZZZZZZZZZ\n:END:\n"))
    (let ((dup (zwanenzang-test-create trk "Dup"))
          (fine (zwanenzang-test-create trk "Fine")))
      (zwanenzang-test-pull)
      ;; Copy the Dup subtree: two headings with one id.
      (save-excursion
        (zwanenzang-test-goto dup)
        (org-copy-subtree)
        (goto-char (point-max))
        (org-paste-subtree 2))
      (zwanenzang-test-cli trk "title" dup "Dup renamed")
      (zwanenzang-test-cli trk "title" fine "Fine renamed")
      (zwanenzang-test-clear-report)
      (zwanenzang-test-pull)
      (should (string-match-p "Fine renamed" (zwanenzang-test-heading fine)))
      (let ((copies (org-map-entries (lambda () (org-get-heading t t t t))
                                     (format "ZWANENZANG_ID=\"%s\"" dup))))
        (should (equal copies '("Dup" "Dup"))))
      (org-map-entries
       (lambda ()
         (should (member zwanenzang-conflict-tag (org-get-tags nil t)))
         (should (string-match-p "- id: duplicate: ZWANENZANG_ID"
                                 (zwanenzang--body))))
       (format "ZWANENZANG_ID=\"%s\"" dup))
      (save-excursion
        (zwanenzang-test-goto "01ZZZZZZZZZZZZZZZZZZZZZZZZ")
        (should (member zwanenzang-conflict-tag (org-get-tags nil t)))
        (should (string-match-p "- id: foreign: the tracker has no ticket"
                                (zwanenzang--body))))
      (should (string-match-p "foreign" (zwanenzang-test-report)))
      (should (string-match-p "duplicate" (zwanenzang-test-report))))))

(ert-deftest zwanenzang-pull-blocks-statuses-without-a-keyword ()
  (zwanenzang-test-with-scope (trk buf (concat "#+TODO: TODO NEXT | DONE\n"
                                               "* Project\n:PROPERTIES:\n:ZWANENZANG: %s\n"
                                               ":ZWANENZANG_KEYWORDS: TODO=todo,draft NEXT=doing"
                                               " DONE=done,cancelled,review\n:END:\n"))
    (let ((known (zwanenzang-test-create trk "Known"))
          (waiting (zwanenzang-test-create trk "Waiting" "--status" "blocked")))
      (zwanenzang-test-clear-report)
      (zwanenzang-test-pull)
      (should (string-match-p "keyword map: status blocked has no keyword"
                              (zwanenzang-test-report)))
      (should (string-match-p "Waiting: not inserted" (zwanenzang-test-report)))
      (should-not (org-find-property "ZWANENZANG_ID" waiting))
      ;; The scope cursor stays, so the ticket comes back once it maps.
      (should-not (save-excursion (goto-char (point-min)) (outline-next-heading)
                                  (org-entry-get nil "ZWANENZANG_CURSOR")))
      (zwanenzang-test-cli trk "status" known "blocked")
      (zwanenzang-test-pull)
      (should (member zwanenzang-conflict-tag (zwanenzang-test-tags known)))
      (should (string-prefix-p "*** TODO Known" (zwanenzang-test-heading known)))
      (should (string-match-p "status: tracker status blocked has no keyword"
                              (zwanenzang-test-entry known)))
      (save-excursion
        (goto-char (point-min))
        (outline-next-heading)
        (org-entry-put nil "ZWANENZANG_KEYWORDS"
                       "TODO=todo,draft NEXT=doing,blocked DONE=done,cancelled,review"))
      (zwanenzang-test-pull)
      (should (string-prefix-p "*** NEXT Known" (zwanenzang-test-heading known)))
      (should (string-prefix-p "*** NEXT Waiting" (zwanenzang-test-heading waiting))))))

(ert-deftest zwanenzang-pull-refuses-another-tracker ()
  (zwanenzang-test-with-scope (trk buf zwanenzang-test--org)
    (zwanenzang-test-create trk "Something")
    (save-excursion
      (goto-char (point-min))
      (outline-next-heading)
      (org-entry-put nil "ZWANENZANG_TRACKER" "01AAAAAAAAAAAAAAAAAAAAAAAA"))
    (let ((before (buffer-string)))
      (should (string-match-p "blocked" (zwanenzang-test-pull)))
      (should (equal (buffer-string) before)))))

(ert-deftest zwanenzang-pull-failure-leaves-buffer-untouched ()
  (zwanenzang-test-with-scope (trk buf zwanenzang-test--org)
    (zwanenzang-test-create trk "Something")
    (zwanenzang-test-pull)
    (let ((before (buffer-string))
          (calls 0))
      ;; Fail the second call (read), after list succeeded.
      (let ((zwanenzang--call (lambda (dir args &optional input)
                                (when (= (cl-incf calls) 2) (user-error "zwanenzang: boom"))
                                (zwanenzang-test-call dir args input))))
        (should-error (zwanenzang-test-pull) :type 'user-error))
      (should (equal (buffer-string) before)))))

(ert-deftest zwanenzang-pull-is-one-undo-step-whatever-the-folding ()
  (zwanenzang-test-with-scope (trk buf zwanenzang-test--org)
    (let* ((a (zwanenzang-test-create trk "A"))
           (b (zwanenzang-test-create trk "B" "--parent" a)))
      (zwanenzang-test-pull)
      (let ((unfolded-start (buffer-string)))
        (zwanenzang-test-cli trk "title" a "A2")
        (zwanenzang-test-cli trk "parent" b "--clear")
        (zwanenzang-test-set-doc trk a "description" "Text\n")
        (org-overview)
        (undo-boundary)
        (zwanenzang-test-pull)
        (should (equal (zwanenzang-test-heading a) "*** TODO A2"))
        (should (equal (zwanenzang-test-parent-heading b) "Inbox"))
        (undo-boundary)
        (let ((last-command nil)) (undo))
        (should (equal (buffer-string) unfolded-start))))))

(ert-deftest zwanenzang-open-shows-hidden-document ()
  (zwanenzang-test-with-scope (trk buf zwanenzang-test--org)
    (let ((id (zwanenzang-test-create trk "With status")))
      (zwanenzang-test-set-doc trk id "status" "Agent summary\n")
      (zwanenzang-test-pull)
      (zwanenzang-test-goto id)
      (search-forward "[[zwanenzang:")
      (let ((shown (zwanenzang-open)))
        (unwind-protect
            (with-current-buffer shown
              (should (equal (buffer-string) "Agent summary\n"))
              (should buffer-read-only))
          (kill-buffer shown)))
      ;; Following the link through Org works too.
      (with-current-buffer buf
        (zwanenzang-test-goto id)
        (search-forward "[[zwanenzang:")
        (org-open-at-point)
        (should (get-buffer "*zwanenzang ZZ-0001 status*"))
        (kill-buffer "*zwanenzang ZZ-0001 status*")))))

(ert-deftest zwanenzang-pull-after-reset-compares-in-full-without-duplicate-comments ()
  ;; An event that sorts before one already pulled arrives later, as a
  ;; merge from another clone would deliver it.
  (zwanenzang-test-with-scope (trk buf zwanenzang-test--org)
    (let* ((id (zwanenzang-test-create trk "Ticket"))
           (base (alist-get 'last_event (zwanenzang-test-show trk id))))
      (zwanenzang-test-cli trk "comment" id "only comment")
      (zwanenzang-test-pull)
      (let ((actor "00000000000000000000000001"))
        (zwanenzang-test-append-raw
         trk actor
         (json-serialize `((id . ,(zwanenzang-test-ulid-next base)) (actor . ,actor)
                           (parent . ,base) (ts . "2026-11-07T00:00:00Z") (entity . ,id)
                           (op . "tag") (data . ((tag . "late")))))))
      (zwanenzang-test-clear-report)
      (zwanenzang-test-pull)
      (should (string-match-p "compared in full" (zwanenzang-test-report)))
      (should (member "late" (zwanenzang-test-tags id)))
      (let ((entry (zwanenzang-test-entry id)))
        (with-temp-buffer
          (insert entry)
          (should (= 1 (how-many "only comment" (point-min) (point-max)))))))))

(provide 'zwanenzang-pull-integration-test)
;;; zwanenzang-pull-integration-test.el ends here
