;;; zwanenzang-pull-integration-test.el --- Pull against the real CLI  -*- lexical-binding: t; -*-

;;; Commentary:

;; Each test creates a disposable tracker, changes it through the CLI and
;; pulls it into an Org file in another disposable directory.

;;; Code:

(require 'ert)
(require 'zwanenzang)
(require 'zwanenzang-test-helpers)
(require 'zwanenzang-pull-test)

(defconst zwanenzang-test--org
  (concat "#+TODO: TODO NEXT WAIT | DONE CNCL\n"
          "* Project\n"
          ":PROPERTIES:\n"
          ":ZWANENZANG: %s\n"
          ":ZWANENZANG_KEYWORDS: TODO=next,todo NEXT=agnt,revw WAIT=wait"
          " DONE=done CNCL=cncl\n"
          ":END:\n")
  "An Org file with one scope; %s is the tracker.")

(defun zwanenzang-test--file-text ()
  "The text of the visited file on disk."
  (let ((file buffer-file-name))
    (with-temp-buffer (insert-file-contents file) (buffer-string))))

(ert-deftest zwanenzang-pull-preserves-ancestor-fold-through-body-updates ()
  (dolist (org-fold-core-style '(overlays text-properties))
    (zwanenzang-test-with-remote-scope (net trk buf zwanenzang-test--org)
      (let ((first (zwanenzang-test-create trk "First"))
            (later (zwanenzang-test-create trk "Later")))
        (zwanenzang-test-set-doc trk first "plan" "* Literal heading\nDocument prose\n")
        (zwanenzang-test-set-doc trk later "plan" "Later prose\n")
        (zwanenzang-test-pull)
        (goto-char (point-min)) (outline-next-heading)
        (org-fold-subtree t)
        (org-narrow-to-subtree)
        (let ((begin (line-end-position))
              (end (copy-marker (point-max) t))
              (minimum (copy-marker (point-min)))
              (position (point-marker)))
          (dotimes (iteration 3)
            (when (= iteration 1)
              (zwanenzang-test-set-doc trk first "description" "New description\n")
              (zwanenzang-test-set-doc trk first "plan" "** New literal heading\nNew plan\n")
              (zwanenzang-test-cli trk "comment" first "New comment"))
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (zwanenzang-pull)
              (unless (= iteration 1)
                (should (equal text (buffer-substring-no-properties (point-min) (point-max))))))
            (should (= position (point)))
            (should (= minimum (point-min)))
            (should (= end (point-max)))
            (should (equal (list (cons begin (marker-position end)))
                           (zwanenzang-test--outline-ranges))))
          (save-excursion
            (zwanenzang-test-goto first)
            (should-not (nth 2 (assoc "ZWANENZANG_COMMENTS"
                                     (zwanenzang--drawer-visibility))))
            (should-not (zwanenzang--doc-headings))
            (should (assoc "ZWANENZANG_DOCUMENTS" (zwanenzang--drawer-visibility))))
          (let ((text (buffer-substring-no-properties (point-min) (point-max))))
            (org-fold-core-save-visibility t nil)
            (zwanenzang-pull)
            (should (equal text (buffer-substring-no-properties (point-min) (point-max))))
            (should (equal (list (cons begin (marker-position end)))
                           (zwanenzang-test--outline-ranges))))
          (mapc (lambda (marker) (set-marker marker nil)) (list end minimum position)))))))

(ert-deftest zwanenzang-sync-keeps-unchanged-comments-folded ()
  (zwanenzang-test-with-scope (trk buf zwanenzang-test--org)
    (let ((id (zwanenzang-test-create trk "Ticket")))
      (zwanenzang-test-cli trk "comment" id "First comment")
      (zwanenzang-test-pull)
      (org-fold-hide-drawer-all)
      ;; An unrelated remote body update rewrites the whole entry body.
      (zwanenzang-test-set-doc trk id "description" "New description\n")
      (zwanenzang-test-goto id)
      (zwanenzang-sync)
      (zwanenzang-test-goto id)
      (should (nth 2 (assoc "PROPERTIES" (zwanenzang--drawer-visibility))))
      (should (nth 2 (assoc "ZWANENZANG_COMMENTS" (zwanenzang--drawer-visibility))))
      ;; Repeating sync must not reveal either drawer or dirty clean text.
      (let ((before (buffer-string)))
        (zwanenzang-sync)
        (should (equal before (buffer-string))))
      (zwanenzang-test-goto id)
      (should (nth 2 (assoc "ZWANENZANG_COMMENTS" (zwanenzang--drawer-visibility))))
      (zwanenzang-test-cli trk "comment" id "Second comment")
      (zwanenzang-sync)
      (let ((entry (zwanenzang-test-entry id)))
        (should (< (string-match "Second comment" entry)
                   (string-match "First comment" entry))))
      (zwanenzang-test-goto id)
      (should (nth 2 (assoc "PROPERTIES" (zwanenzang--drawer-visibility))))
      (should-not (nth 2 (assoc "ZWANENZANG_COMMENTS"
                               (zwanenzang--drawer-visibility)))))))

(ert-deftest zwanenzang-sync-fills-only-missing-ticket-org-ids ()
  (zwanenzang-test-with-scope (trk buf zwanenzang-test--org)
    (let ((first (zwanenzang-test-create trk "First"))
          (second (zwanenzang-test-create trk "Second")))
      (zwanenzang-test-set-doc trk first "plan" "A plan\n")
      (zwanenzang-test-pull)
      (let ((first-id (zwanenzang-test-property first "ID"))
            (second-id (zwanenzang-test-property second "ID")))
        (should first-id)
        (should second-id)
        (should-not (equal first-id second-id))
        (should-not (equal first-id first))
        ;; Upgrade an existing heading; preserve the other heading's human ID.
        (zwanenzang-test-goto first)
        (org-entry-delete nil "ID")
        (zwanenzang-test-goto second)
        (org-entry-put nil "ID" "human-id")
        (let ((on-disk (zwanenzang-test--file-text)))
          (zwanenzang-sync)
          (should (equal on-disk (zwanenzang-test--file-text))))
        (setq first-id (zwanenzang-test-property first "ID"))
        (should first-id)
        (should (equal (zwanenzang-test-property second "ID") "human-id"))
        (let ((before (buffer-string)))
          (zwanenzang-sync)
          (should (equal before (buffer-string))))
        ;; Only ticket headings get IDs, not structural/document headings.
        (org-map-entries
         (lambda ()
           (unless (org-entry-get nil "ZWANENZANG_ID")
             (should-not (org-entry-get nil "ID")))))
        (should (equal (zwanenzang-test-property first "ZWANENZANG_ID") first))))))

(ert-deftest zwanenzang-pull-discovers-tickets-with-state ()
  (zwanenzang-test-with-scope (trk buf zwanenzang-test--org)
    (let* ((parent (zwanenzang-test-create trk "Parent" "--tag" "alpha"))
           (child (zwanenzang-test-create trk "Child" "--parent" parent "--status" "agnt"))
           (lone (zwanenzang-test-create trk "Lone" "--status" "revw")))
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
      ;; A todo is shown as TODO and remembered as todo, not next.
      (should (string-match-p "\\`\\*\\*\\* TODO \\[ZZ-1\\] Parent +:alpha:\\'"
                              (zwanenzang-test-heading parent)))
      (should (string-match-p "status=todo " (zwanenzang-test-property parent "ZWANENZANG_SYNC")))
      (should (string-prefix-p "**** NEXT [ZZ-2] Child" (zwanenzang-test-heading child)))
      (should (string-prefix-p "*** NEXT [ZZ-3] Lone" (zwanenzang-test-heading lone)))
      (should (equal (zwanenzang-test-property parent "ZWANENZANG_NUMBER") "ZZ-1"))
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
                 (concat ":END:\n"
                         "Intro\n,\\* not a heading\n"
                         ":ZWANENZANG_COMMENTS:\n"
                         "\\[[-0-9T:Z]+\\] tester:\nsecond\n"
                         "\\[[-0-9T:Z]+\\] tester:\nfirst\n,\\* starred\n,:END:\n:END:\n"
                         ":ZWANENZANG_DOCUMENTS:\n"
                         (regexp-quote (format "- [[zwanenzang:%s/plan][plan]] " parent))
                         "[0-9]\\{4\\}-[0-9][0-9]-[0-9][0-9] tester\n"
                         (regexp-quote (format "- [[zwanenzang:%s/status][status]] " parent))
                         "[-0-9]+ tester\n"
                         ":END:\n\\'")
                 entry)))
      ;; Named documents are links only: no subheadings are written.
      (save-excursion
        (zwanenzang-test-goto parent)
        (should-not (zwanenzang--doc-headings)))
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
      (should (string-match-p "\\`\\*\\*\\* DONE \\[ZZ-1\\] New +:b:\\'" (zwanenzang-test-heading id)))
      (should (string-match-p "status=done " (zwanenzang-test-property id "ZWANENZANG_SYNC")))
      (should (string-match-p (concat "New text\n:ZWANENZANG_COMMENTS:\n.*\nlater\n:END:\n"
                                      ":ZWANENZANG_DOCUMENTS:\n- .*/plan\\]\\[plan\\]\\] .*\n:END:\n\\'")
                              (zwanenzang-test-entry id)))
      (save-excursion
        (zwanenzang-test-goto id)
        (should-not (zwanenzang--doc-headings)))
      (should-not (member zwanenzang-conflict-tag (zwanenzang-test-tags id))))))

(ert-deftest zwanenzang-pull-writes-org-prose-verbatim-and-below-it-the-comments ()
  (zwanenzang-test-with-scope (trk buf zwanenzang-test--org)
    (let ((id (zwanenzang-test-create trk "Prose"))
          (prose "See [[https://example.invalid][this]]:\n#+begin_src sh\nls\n#+end_src\n"))
      (zwanenzang-test-set-doc trk id "description" prose)
      (zwanenzang-test-cli trk "comment" id "[[https://example.invalid][there]]\n#+begin_quote\nq\n#+end_quote")
      (zwanenzang-test-pull)
      (let ((entry (zwanenzang-test-entry id)))
        (should (string-match-p (concat (regexp-quote prose) ":ZWANENZANG_COMMENTS:\n") entry))
        (should (string-match-p
                 "tester:\n\\[\\[https://example.invalid\\]\\[there\\]\\]\n#\\+begin_quote\n"
                 entry)))
      (let ((before (buffer-string)))
        (zwanenzang-test-pull)
        (should (equal (buffer-string) before))))))

(ert-deftest zwanenzang-pull-moves-a-comments-drawer-from-the-old-position ()
  (zwanenzang-test-with-scope (trk buf zwanenzang-test--org)
    (let ((id (zwanenzang-test-create trk "Old layout")))
      (zwanenzang-test-set-doc trk id "description" "Text\n,#+begin_src\n")
      (zwanenzang-test-cli trk "comment" id "note")
      (zwanenzang-test-pull)
      (save-excursion
        (zwanenzang-test-goto id)
        (zwanenzang--write-body
         (concat ":PROPERTIES:\n"
                 (mapconcat (lambda (p) (format ":%s: %s\n" (car p) (cdr p)))
                            (seq-filter (lambda (p) (string-prefix-p "ZWANENZANG" (car p)))
                                        (org-entry-properties nil 'standard))
                            "")
                 ":END:\n"
                 ":ZWANENZANG_COMMENTS:\n[old] tester:\n  : note\n:END:\n"
                 "Text\n,,#+begin_src\n")))
      (let ((sync (zwanenzang-test-property id "ZWANENZANG_DESC_HASH")))
        (zwanenzang-test-pull)
        (should (equal (zwanenzang-test-property id "ZWANENZANG_DESC_HASH") sync)))
      (let ((entry (zwanenzang-test-entry id)))
        (should (string-match-p "Text\n,,#\\+begin_src\n:ZWANENZANG_COMMENTS:\n.*tester:\nnote\n:END:\n\\'"
                                entry))
        (with-temp-buffer
          (insert entry)
          (should (= 1 (how-many ":ZWANENZANG_COMMENTS:" (point-min) (point-max))))))
      (should-not (member zwanenzang-conflict-tag (zwanenzang-test-tags id))))))

(ert-deftest zwanenzang-pull-counts-a-heading-with-two-conflicts-once ()
  ;; Field conflict and a skipped move on one heading.
  (zwanenzang-test-with-scope (trk buf zwanenzang-test--org)
    (let ((x (zwanenzang-test-create trk "X"))
          (y (zwanenzang-test-create trk "Y")))
      (zwanenzang-test-pull)
      (save-excursion
        (zwanenzang-test-goto y)
        (org-cut-subtree)
        (zwanenzang-test-goto x)
        (org-end-of-subtree t t)
        (org-paste-subtree 4)
        (zwanenzang-test-goto x)
        (org-edit-headline "X mine"))
      (zwanenzang-test-cli trk "title" x "X theirs")
      (zwanenzang-test-cli trk "parent" x y)
      (zwanenzang-test-clear-report)
      (should (string-match-p "1 with conflicts" (zwanenzang-test-pull)))
      (should (string-match-p "ZZ-1 Org \"X mine\", tracker \"X theirs\": conflict in title"
                              (zwanenzang-test-report))))))

(ert-deftest zwanenzang-pull-reports-what-changed-per-ticket ()
  (zwanenzang-test-with-scope (trk buf zwanenzang-test--org)
    (let ((a (zwanenzang-test-create trk "A")))
      (zwanenzang-test-create trk "B")
      (zwanenzang-test-clear-report)
      (zwanenzang-test-pull)
      (should (string-match-p "new ZZ-1 A\n  new ZZ-2 B" (zwanenzang-test-report)))
      (zwanenzang-test-cli trk "title" a "A2")
      (zwanenzang-test-clear-report)
      (should (string-match-p "1 pulled\\'" (zwanenzang-test-pull)))
      (should (string-match-p "pulled ZZ-1 A2" (zwanenzang-test-report)))
      (should-not (string-match-p "ZZ-2" (zwanenzang-test-report)))
      ;; A clean run: the echo stays one line and points nowhere.
      (should (string-match-p ": nothing changed\\'" (zwanenzang-test-pull))))))

(ert-deftest zwanenzang-pull-keeps-local-edits-and-records-conflicts ()
  (zwanenzang-test-with-scope (trk buf zwanenzang-test--org)
    (let ((id (zwanenzang-test-create trk "Base" "--status" "next")))
      (zwanenzang-test-set-doc trk id "description" "Base text\n")
      (zwanenzang-test-pull)
      ;; Org: title and description edited; status left alone.
      (save-excursion
        (zwanenzang-test-goto id)
        (org-edit-headline "Mine")
        (search-forward "Base text")
        (replace-match "My text"))
      ;; Tracker: the same fields, and the status.
      (zwanenzang-test-cli trk "title" id "Theirs")
      (zwanenzang-test-cli trk "status" id "agnt")
      (zwanenzang-test-set-doc trk id "description" "Their text\n")
      (zwanenzang-test-clear-report)
      (zwanenzang-test-pull)
      (should (string-match-p "\\`\\*\\*\\* NEXT \\[ZZ-1\\] Mine +:zz_conflict:\\'"
                              (zwanenzang-test-heading id)))
      (let ((entry (zwanenzang-test-entry id)))
        (should (string-match-p
                 (concat ":ZWANENZANG_CONFLICT:\n"
                         "- title: tracker title skipped; Org title kept\n  : Theirs\n"
                         "- description: tracker description skipped; Org text kept\n"
                         "  : Their text\n"
                         ":END:\n")
                 entry))
        (should (string-match-p "My text\n\\'" entry)))
      (should (string-match-p "conflict in title, description"
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
        (search-forward "My text") (replace-match "Their text"))
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

(ert-deftest zwanenzang-pull-conflicts-on-a-move-made-cyclic-by-an-earlier-move ()
  ;; Org nests C under A; the tracker moves B under C and A under B.
  ;; Moving A first puts C, and so B's new parent, inside B's subtree.
  (zwanenzang-test-with-scope (trk buf zwanenzang-test--org)
    (let ((a (zwanenzang-test-create trk "A"))
          (b (zwanenzang-test-create trk "B"))
          (c (zwanenzang-test-create trk "C")))
      (zwanenzang-test-pull)
      (save-excursion
        (zwanenzang-test-goto c)
        (org-cut-subtree)
        (zwanenzang-test-goto a)
        (org-end-of-subtree t t)
        (org-paste-subtree 4))
      (zwanenzang-test-cli trk "parent" b c)
      (zwanenzang-test-cli trk "parent" a b)
      (zwanenzang-test-clear-report)
      (zwanenzang-test-pull)
      (should (equal (zwanenzang-test-parent-heading a) "B"))
      (should (equal (zwanenzang-test-parent-heading c) "A"))
      (should (equal (zwanenzang-test-parent-heading b) "Inbox"))
      (should (member zwanenzang-conflict-tag (zwanenzang-test-tags b)))
      (should (string-match-p "- parent: tracker parent .* is nested inside this heading"
                              (zwanenzang-test-entry b)))
      ;; The sync state still has the nesting before the skipped move.
      (should (string-match-p "parent=- nest=-\\'" (zwanenzang-test-property b "ZWANENZANG_SYNC")))
      (should (string-match-p "Org \"B\", tracker \"B\": conflict in parent"
                              (zwanenzang-test-report)))
      ;; One heading, one count, however many reasons.
      (should (string-match-p "1 with conflicts" (zwanenzang-test-pull)))
      ;; The next pull reaches the same verdict.
      (zwanenzang-test-pull)
      (should (equal (zwanenzang-test-parent-heading b) "Inbox"))
      (should (string-match-p "parent=- nest=-\\'" (zwanenzang-test-property b "ZWANENZANG_SYNC"))))))

(ert-deftest zwanenzang-pull-refuses-to-move-under-own-descendant ()
  (zwanenzang-test-with-scope (trk buf zwanenzang-test--org)
    (let ((x (zwanenzang-test-create trk "X"))
          (y (zwanenzang-test-create trk "Y")))
      (zwanenzang-test-pull)
      (save-excursion
        (zwanenzang-test-goto y)
        (org-cut-subtree)
        (zwanenzang-test-goto x)
        (org-end-of-subtree t t)
        (org-paste-subtree 4))
      (zwanenzang-test-cli trk "parent" x y)
      (zwanenzang-test-pull)
      (should (equal (zwanenzang-test-parent-heading x) "Inbox"))
      (should (equal (zwanenzang-test-parent-heading y) "X"))
      (should (member zwanenzang-conflict-tag (zwanenzang-test-tags x)))
      (should (string-match-p (format "- parent: tracker parent %s is nested inside this heading" y)
                              (zwanenzang-test-entry x)))
      (should (string-match-p "parent=- nest=-\\'" (zwanenzang-test-property x "ZWANENZANG_SYNC"))))))

(ert-deftest zwanenzang-pull-conflicts-when-the-map-lost-the-synced-status ()
  ;; The human removed the keyword; the map no longer shows the synced
  ;; status, so nothing says Org still has it: no keyword reappears.
  (zwanenzang-test-with-scope (trk buf zwanenzang-test--org)
    (let ((id (zwanenzang-test-create trk "Draft")))
      (zwanenzang-test-pull)
      (should (string-match-p "status=todo " (zwanenzang-test-property id "ZWANENZANG_SYNC")))
      (save-excursion
        (zwanenzang-test-goto id)
        (zwanenzang--set-heading nil "Draft" nil)
        (goto-char (point-min))
        (outline-next-heading)
        (org-entry-put nil "ZWANENZANG_KEYWORDS"
                       "TODO=next NEXT=agnt,revw WAIT=wait DONE=done CNCL=cncl"))
      (zwanenzang-test-cli trk "status" id "next")
      (zwanenzang-test-pull)
      (should (string-match-p "\\`\\*\\*\\* \\[ZZ-1\\] Draft +:zz_conflict:\\'" (zwanenzang-test-heading id)))
      (should (string-match-p "- status: tracker has next (TODO); Org keyword kept"
                              (zwanenzang-test-entry id))))))

(ert-deftest zwanenzang-pull-keeps-archive-tag-and-ignores-tag-order ()
  (zwanenzang-test-with-scope (trk buf zwanenzang-test--org)
    (let ((id (zwanenzang-test-create trk "Old" "--tag" "a" "--tag" "b")))
      (zwanenzang-test-pull)
      (save-excursion
        (zwanenzang-test-goto id)
        (org-set-tags '("b" "a" "ARCHIVE")))
      (zwanenzang-test-cli trk "title" id "New")
      (zwanenzang-test-cli trk "tag" id "c")
      (zwanenzang-test-pull)
      ;; Reordered tags were no change, so the new tag applies; ARCHIVE stays.
      (should (equal (zwanenzang-test-tags id) '("a" "b" "c" "ARCHIVE")))
      (should (string-prefix-p "*** TODO [ZZ-1] New " (zwanenzang-test-heading id)))
      (should-not (string-match-p "ZWANENZANG_CONFLICT" (zwanenzang-test-entry id)))
      (should (equal (zwanenzang-test-property id "ZWANENZANG_SYNC")
                     (zwanenzang--format-sync
                      `((status . "todo") (title . ,(zwanenzang--hash "New"))
                        (priority . "-1") (scheduled . nil)
                        (tags . ,(zwanenzang--tags-hash '("a" "b" "c")))
                        (depends . ,(zwanenzang--tags-hash nil))
                        (parent . nil) (nest . nil))))))))

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
      (should (equal (zwanenzang-test-heading archived) "*** TODO [ZZ-1] Archived, renamed"))
      (should (string-match-p "ZZ-1 Archived, renamed: archived in the tracker"
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
          (fine (zwanenzang-test-create trk "Fine"))
          dup-org-id)
      (zwanenzang-test-pull)
      ;; Copy the Dup subtree: two headings with one id.
      (save-excursion
        (zwanenzang-test-goto dup)
        (setq dup-org-id (org-entry-get nil "ID"))
        (should dup-org-id)
        (org-copy-subtree)
        (goto-char (point-max))
        (org-paste-subtree 2)
        ;; One duplicate has no Org ID; the other retains the copied ID.
        (zwanenzang-test-goto dup)
        (org-entry-delete nil "ID"))
      (zwanenzang-test-cli trk "title" dup "Dup renamed")
      (zwanenzang-test-cli trk "title" fine "Fine renamed")
      (zwanenzang-test-clear-report)
      (zwanenzang-test-pull)
      (should (string-match-p "Fine renamed" (zwanenzang-test-heading fine)))
      (let ((copies (org-map-entries (lambda () (plist-get (zwanenzang--heading) :title))
                                     (format "ZWANENZANG_ID=\"%s\"" dup))))
        (should (equal copies '("Dup" "Dup"))))
      (should (equal (org-map-entries (lambda () (org-entry-get nil "ID"))
                                     (format "ZWANENZANG_ID=\"%s\"" dup))
                     (list nil dup-org-id)))
      (org-map-entries
       (lambda ()
         (should (member zwanenzang-conflict-tag (org-get-tags nil t)))
         (should (string-match-p "- id: duplicate: ZWANENZANG_ID"
                                 (zwanenzang--body))))
       (format "ZWANENZANG_ID=\"%s\"" dup))
      (save-excursion
        (zwanenzang-test-goto "01ZZZZZZZZZZZZZZZZZZZZZZZZ")
        (should-not (org-entry-get nil "ID"))
        (should (member zwanenzang-conflict-tag (org-get-tags nil t)))
        (should (string-match-p "- id: foreign: the tracker has no ticket"
                                (zwanenzang--body))))
      (should (string-match-p "foreign" (zwanenzang-test-report)))
      (should (string-match-p "duplicate" (zwanenzang-test-report))))))

(ert-deftest zwanenzang-pull-blocks-statuses-without-a-keyword ()
  (zwanenzang-test-with-scope (trk buf (concat "#+TODO: TODO NEXT | DONE\n"
                                               "* Project\n:PROPERTIES:\n:ZWANENZANG: %s\n"
                                               ":ZWANENZANG_KEYWORDS: TODO=next,todo NEXT=agnt"
                                               " DONE=done,cncl,revw\n:END:\n"))
    (let ((known (zwanenzang-test-create trk "Known"))
          (waiting (zwanenzang-test-create trk "Waiting" "--status" "wait")))
      (zwanenzang-test-clear-report)
      (zwanenzang-test-pull)
      (should (string-match-p "keyword map: status wait has no keyword"
                              (zwanenzang-test-report)))
      (should (string-match-p "Waiting: not inserted" (zwanenzang-test-report)))
      (should-not (org-find-property "ZWANENZANG_ID" waiting))
      ;; The scope cursor stays, so the ticket comes back once it maps.
      (should-not (save-excursion (goto-char (point-min)) (outline-next-heading)
                                  (org-entry-get nil "ZWANENZANG_CURSOR")))
      ;; Model an existing pre-upgrade heading without a standard Org ID.
      (zwanenzang-test-goto known)
      (org-entry-delete nil "ID")
      (zwanenzang-test-cli trk "status" known "wait")
      (zwanenzang-test-pull)
      (should-not (zwanenzang-test-property known "ID"))
      (should (member zwanenzang-conflict-tag (zwanenzang-test-tags known)))
      (should (string-prefix-p "*** TODO [ZZ-1] Known" (zwanenzang-test-heading known)))
      (should (string-match-p "status: tracker status wait has no keyword"
                              (zwanenzang-test-entry known)))
      (save-excursion
        (goto-char (point-min))
        (outline-next-heading)
        (org-entry-put nil "ZWANENZANG_KEYWORDS"
                       "TODO=next,todo NEXT=agnt,wait DONE=done,cncl,revw"))
      (zwanenzang-test-pull)
      (should (string-prefix-p "*** NEXT [ZZ-1] Known" (zwanenzang-test-heading known)))
      (should (zwanenzang-test-property known "ID"))
      (should (string-prefix-p "*** NEXT [ZZ-2] Waiting" (zwanenzang-test-heading waiting))))))

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
        (should (equal (zwanenzang-test-heading a) "*** TODO [ZZ-1] A2"))
        (should (equal (zwanenzang-test-parent-heading b) "Inbox"))
        (undo-boundary)
        (let ((last-command nil)) (undo))
        (should (equal (buffer-string) unfolded-start))))))

(ert-deftest zwanenzang-pull-renders-relations-and-code-drawers ()
  (zwanenzang-test-with-scope (trk buf zwanenzang-test--org)
    (let* ((pre (zwanenzang-test-create trk "Prerequisite" "--status" "done"))
           (main (zwanenzang-test-create trk "Main"))
           (other (zwanenzang-test-create trk "Other" "--status" "agnt"))
           (plain (zwanenzang-test-create trk "Plain")))
      (zwanenzang-test-cli trk "depend" main pre)
      (zwanenzang-test-cli trk "relate" main other)
      (zwanenzang-test-cli trk "branch" main "app" "zz-2-main")
      (zwanenzang-test-cli trk "mr" main "app" "https://forge.example/o/app/pulls/5")
      (zwanenzang-test-cli trk "comment" main "A note")
      (zwanenzang-test-set-doc trk main "description" "Main text\n")
      (zwanenzang-test-set-doc trk main "status" "Hidden\n")
      (zwanenzang-test-pull)
      (should (string-match-p
               (concat "\nMain text\n"
                       ":ZWANENZANG_COMMENTS:\n.*\nA note\n:END:\n"
                       ":ZWANENZANG_DOCUMENTS:\n.*\n:END:\n"
                       (regexp-quote
                        (concat ":ZWANENZANG_RELATIONS:\n"
                                "- Prerequisites\n"
                                "  - [[zwanenzang:" pre "][ZZ-1 DONE Prerequisite]]\n"
                                "- Related\n"
                                "  - [[zwanenzang:" other "][ZZ-3 NEXT Other]]\n"
                                ":END:\n"
                                ":ZWANENZANG_CODE:\n"
                                "- Branches\n"
                                "  - app: zz-2-main\n"
                                "- MRs\n"
                                "  - [[https://forge.example/o/app/pulls/5][app #5]]\n"
                                ":END:\n"))
                       "\\'")
               (zwanenzang-test-entry main)))
      ;; The other ends: blocks and related, no code drawer.
      (let ((entry (zwanenzang-test-entry pre)))
        (should (string-match-p
                 (regexp-quote (concat ":ZWANENZANG_RELATIONS:\n- Blocks\n"
                                       "  - [[zwanenzang:" main "][ZZ-2 TODO Main]]\n:END:\n"))
                 entry))
        (should-not (string-match-p "ZWANENZANG_CODE" entry)))
      (should (string-match-p (regexp-quote (concat "- Related\n  - [[zwanenzang:" main "]"))
                              (zwanenzang-test-entry other)))
      (should-not (string-match-p "ZWANENZANG_RELATIONS\\|ZWANENZANG_CODE"
                                  (zwanenzang-test-entry plain)))
      ;; Nothing is read back: the tracker keeps its description.
      (should (equal (zwanenzang-test-property main "ZWANENZANG_DESC_HASH")
                     (zwanenzang--hash "Main text\n")))
      (let ((before (buffer-string)))
        (should (string-match-p ": nothing changed\\'" (zwanenzang-test-pull)))
        (should (equal (buffer-string) before)))
      ;; Pushing sends nothing for the generated drawers.
      (let ((head (zwanenzang-test-head trk)))
        (zwanenzang-test-at-root #'zwanenzang-push)
        (should (equal (zwanenzang-test-head trk) head))))))

(ert-deftest zwanenzang-pull-rewrites-link-drawers-without-reporting-them ()
  (zwanenzang-test-with-scope (trk buf zwanenzang-test--org)
    (let* ((pre (zwanenzang-test-create trk "Prerequisite"))
           (main (zwanenzang-test-create trk "Main")))
      (zwanenzang-test-cli trk "depend" main pre)
      (zwanenzang-test-pull)
      ;; Only the prerequisite changed; the dependent's drawer follows it.
      (zwanenzang-test-cli trk "title" pre "Renamed")
      (zwanenzang-test-cli trk "status" pre "done")
      (zwanenzang-test-clear-report)
      (should (string-match-p ": 1 pulled\\'" (zwanenzang-test-pull)))
      (should (string-match-p "pulled ZZ-1 Renamed" (zwanenzang-test-report)))
      (should-not (string-match-p "pulled ZZ-2" (zwanenzang-test-report)))
      (should (string-match-p (regexp-quote (concat "[[zwanenzang:" pre "][ZZ-1 DONE Renamed]]"))
                              (zwanenzang-test-entry main)))
      (should (string-match-p (regexp-quote (concat "[[zwanenzang:" main "][ZZ-2 TODO Main]]"))
                              (zwanenzang-test-entry pre)))
      ;; A change confined to the drawers is rewritten, not reported.
      (zwanenzang-test-cli trk "branch" main "app" "topic")
      (zwanenzang-test-clear-report)
      (should (string-match-p ": nothing changed\\'" (zwanenzang-test-pull)))
      (should (string-match-p "- Branches\n  - app: topic\n" (zwanenzang-test-entry main))))))

(ert-deftest zwanenzang-open-follows-ticket-links ()
  (zwanenzang-test-with-scope (trk buf zwanenzang-test--org)
    (let* ((pre (zwanenzang-test-create trk "Prerequisite" "--kind" "bug"))
           (main (zwanenzang-test-create trk "Main")))
      (zwanenzang-test-cli trk "depend" main pre)
      (zwanenzang-test-set-doc trk pre "description" "Why\n* not a heading\n")
      (zwanenzang-test-cli trk "comment" pre "Looked at it")
      (zwanenzang-test-pull)
      ;; In scope: the link jumps to the heading.
      (zwanenzang-test-goto main)
      (search-forward (concat "[[zwanenzang:" pre))
      (org-open-at-point)
      (should (eq (current-buffer) buf))
      (should (equal (org-entry-get nil "ZWANENZANG_ID") pre))
      (should (looking-at-p "\\*+ TODO \\[ZZ-1\\] Prerequisite"))
      ;; Out of scope: a read-only buffer from the tracker.
      (zwanenzang-test-goto pre)
      (org-cut-subtree)
      (zwanenzang-test-goto main)
      (search-forward (concat "[[zwanenzang:" pre))
      (let ((shown (zwanenzang-open)))
        (unwind-protect
            (with-current-buffer shown
              (should (equal (buffer-name) "*zwanenzang ZZ-1*"))
              (should (derived-mode-p 'org-mode))
              (should buffer-read-only)
              (let ((text (buffer-string)))
                (should (string-prefix-p "* ZZ-1 Prerequisite\n- Status :: todo\n- Kind :: bug\n"
                                         text))
                (should (string-match-p "\n\\*\\* Description\nWhy\n,\\* not a heading\n" text))
                (should (string-match-p "\n\\*\\* Comments\n\\[.*\\] tester:\nLooked at it\n" text))
                (should (string-match-p
                         (regexp-quote (concat "** References\n- Blocks\n  - [[zwanenzang:"
                                               main "][ZZ-2 TODO Main]]\n"))
                         text)))
              ;; Its links lead back into the scope it was opened from.
              (goto-char (point-min))
              (search-forward (concat "[[zwanenzang:" main))
              (org-open-at-point)
              (should (eq (current-buffer) buf))
              (should (equal (org-entry-get nil "ZWANENZANG_ID") main)))
          (kill-buffer shown))))))

(ert-deftest zwanenzang-pull-ignores-hide-docs-and-reports-it-once ()
  (zwanenzang-test-with-scope (trk buf (replace-regexp-in-string
                                        ":END:" ":ZWANENZANG_HIDE_DOCS: status description\n:END:"
                                        zwanenzang-test--org t t))
    (let ((id (zwanenzang-test-create trk "Ticket")))
      (zwanenzang-test-set-doc trk id "description" "Shown\n")
      (zwanenzang-test-set-doc trk id "status" "Agent summary\n")
      (zwanenzang-test-clear-report)
      (zwanenzang-test-pull)
      (let ((entry (zwanenzang-test-entry id)))
        (should (string-match-p "\nShown\n:ZWANENZANG_DOCUMENTS:\n" entry))
        (should (string-match-p (regexp-quote (format "[[zwanenzang:%s/status][status]]" id))
                                entry)))
      (should (string-match-p "ZWANENZANG_HIDE_DOCS is ignored" (zwanenzang-test-report)))
      (zwanenzang-test-clear-report)
      (should (string-match-p ": nothing changed\\'" (zwanenzang-test-pull)))
      (should-not (string-match-p "HIDE_DOCS" (zwanenzang-test-report)))
      ;; The property is the human's: it stays.
      (should (org-entry-get (save-excursion (goto-char (point-min)) (outline-next-heading) (point))
                             "ZWANENZANG_HIDE_DOCS")))))

(ert-deftest zwanenzang-pull-replaces-the-legacy-hidden-drawer ()
  (zwanenzang-test-with-scope (trk buf zwanenzang-test--org)
    (let ((id (zwanenzang-test-create trk "Ticket")))
      (zwanenzang-test-set-doc trk id "status" "Agent summary\n")
      (zwanenzang-test-pull)
      (save-excursion
        (zwanenzang-test-goto id)
        (zwanenzang--write-body
         (replace-regexp-in-string
          ":ZWANENZANG_DOCUMENTS:\n\\(?:.*\n\\)*?:END:\n"
          (format ":ZWANENZANG_HIDDEN:\n[[zwanenzang:%s/status][status (hidden)]]\n:END:\n" id)
          (zwanenzang--body) t t)))
      (should (string-match-p "ZWANENZANG_HIDDEN" (zwanenzang-test-entry id)))
      (zwanenzang-test-pull)
      (let ((entry (zwanenzang-test-entry id)))
        (should-not (string-match-p "ZWANENZANG_HIDDEN\\|(hidden)" entry))
        (should (= 1 (with-temp-buffer
                       (insert entry)
                       (how-many ":ZWANENZANG_DOCUMENTS:" (point-min) (point-max)))))))))

(ert-deftest zwanenzang-pull-after-reset-compares-in-full-without-duplicate-comments ()
  ;; An event that sorts before one already pulled arrives later, as a
  ;; merge from another clone would deliver it.
  (zwanenzang-test-with-scope (trk buf zwanenzang-test--org)
    (let* ((id (zwanenzang-test-create trk "Ticket"))
           (base (alist-get 'last_event (zwanenzang-test-show trk id))))
      (zwanenzang-test-cli trk "comment" id "Middle comment")
      (zwanenzang-test-cli trk "comment" id "Newest comment")
      (zwanenzang-test-pull)
      (let ((actor "00000000000000000000000001"))
        (zwanenzang-test-append-raw
         trk actor
         (json-serialize `((id . ,(zwanenzang-test-ulid-next base)) (actor . ,actor)
                           (parent . ,base) (ts . "2026-11-07T00:00:00Z") (entity . ,id)
                           (op . "comment") (data . ((text . "Late older comment")))))))
      (zwanenzang-test-clear-report)
      (zwanenzang-test-pull)
      (should (string-match-p "compared in full" (zwanenzang-test-report)))
      (let ((entry (zwanenzang-test-entry id)))
        (with-temp-buffer
          (insert entry)
          (dolist (text '("Newest comment" "Middle comment" "Late older comment"))
            (should (= 1 (how-many text (point-min) (point-max))))))
        (should (< (string-match "Newest comment" entry)
                   (string-match "Middle comment" entry)))
        (should (< (string-match "Middle comment" entry)
                   (string-match "Late older comment" entry))))
      (let ((before (buffer-string)))
        (zwanenzang-test-pull)
        (should (equal before (buffer-string)))))))

(provide 'zwanenzang-pull-integration-test)
;;; zwanenzang-pull-integration-test.el ends here
