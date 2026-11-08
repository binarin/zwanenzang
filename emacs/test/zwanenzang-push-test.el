;;; zwanenzang-push-test.el --- Building a push without the CLI  -*- lexical-binding: t; -*-

;;; Commentary:

;; Org text and a made-up read in, the list of changes out.

;;; Code:

(require 'ert)
(require 'zwanenzang)
(require 'zwanenzang-pull-test)

(defconst zwanenzang-test--map
  '(("todo" . "TODO") ("draft" . "TODO") ("doing" . "NEXT") ("review" . "NEXT")
    ("done" . "DONE"))
  "A keyword map, as `zwanenzang--keyword-map' parses it.")

(defconst zwanenzang-test--root
  (concat "#+TODO: TODO NEXT WAIT | DONE\n"
          "* Root\n:PROPERTIES:\n:ZWANENZANG: /t\n:END:\n"))

(cl-defun zwanenzang-test--synced (id title &key (stars "**") (keyword "TODO") (status "draft")
                                      tags parent nest (text "") (shown-title title) shown-tags)
  "A ticket heading ID synced as TITLE, STATUS, TAGS, PARENT, NEST and TEXT.
It shows KEYWORD, SHOWN-TITLE and SHOWN-TAGS, and has an empty description."
  (concat stars " " keyword " " shown-title
          (if shown-tags (format " :%s:" (string-join shown-tags ":")) "") "\n"
          ":PROPERTIES:\n"
          ":ZWANENZANG_ID: " id "\n"
          (format ":ZWANENZANG_SYNC: status=%s title=%s tags=%s parent=%s nest=%s\n"
                  status (zwanenzang--hash title) (zwanenzang--tags-hash tags)
                  (or parent "-") (or nest "-"))
          ":ZWANENZANG_DESC_HASH: " (zwanenzang--hash text) "\n"
          ":END:\n"))

(cl-defun zwanenzang-test--entry (id title &key (status "draft") tags parent archived tombstoned
                                     docs)
  "A read result for ticket ID.  DOCS is an alist of name, version and text."
  `((ticket (id . ,id) (display . ,id) (title . ,title) (status . ,status) (tags . ,tags)
            (parent . ,(or parent :null))
            (archived . ,(if archived t :false))
            (tombstoned . ,(if tombstoned t :false))
            (documents . ,(mapcar (lambda (d) `(,(intern (nth 0 d)) (current . ,(nth 1 d)))) docs)))
    (documents . ,(mapcar (lambda (d) (cons (intern (nth 0 d)) (nth 2 d))) docs))))

(defun zwanenzang-test--plan (text entries &optional hidden)
  "The plan for the scope in the Org TEXT, given read ENTRIES and HIDDEN docs.
A ticket without an entry is foreign to the tracker."
  (with-temp-buffer
    (insert text)
    (org-mode)
    (goto-char (point-min))
    (outline-next-heading)
    (let* ((case-fold-search nil)
           (root (zwanenzang--heading-marker))
           (headings (plist-get (zwanenzang--scan-all root) :headings))
           (known (make-hash-table :test #'equal)))
      (dolist (e entries)
        (puthash (alist-get 'id (alist-get 'ticket e)) t known))
      (zwanenzang--plan-push
       headings
       (zwanenzang--blocked-headings (seq-filter (lambda (h) (plist-get h :id)) headings) known)
       entries zwanenzang-test--map hidden))))

(defun zwanenzang-test--changes (text entries &optional hidden)
  "The changes planned for TEXT and ENTRIES, in the order they are sent."
  (reverse (zwanenzang--plan-changes (zwanenzang-test--plan text entries hidden))))

(ert-deftest zwanenzang-plan-sends-nothing-when-org-matches-the-sync-state ()
  (should-not (zwanenzang-test--changes
               (concat zwanenzang-test--root (zwanenzang-test--synced "A" "Title"))
               (list (zwanenzang-test--entry "A" "Title")))))

(ert-deftest zwanenzang-plan-leaves-to-pull-what-only-the-tracker-changed ()
  (should-not (zwanenzang-test--changes
               (concat zwanenzang-test--root (zwanenzang-test--synced "A" "Title"))
               (list (zwanenzang-test--entry "A" "Theirs" :status "doing" :tags '("x")
                                             :parent "P"
                                             :docs '(("description" "V1" "Their text\n")))))))

(ert-deftest zwanenzang-plan-sends-field-edits-and-the-human-wins ()
  ;; The tracker moved too; Org's values go out regardless.
  (should (equal (zwanenzang-test--changes
                  (concat zwanenzang-test--root
                          (zwanenzang-test--synced "A" "Title" :keyword "DONE"
                                                   :shown-title "Mine"
                                                   :tags '("old" "kept")
                                                   :shown-tags '("kept" "new"
                                                                 "zz_conflict" "ARCHIVE")))
                  (list (zwanenzang-test--entry "A" "Theirs" :status "doing"
                                                :tags '("kept" "old" "agent"))))
                 '(((op . "status") (ticket . "A") (data (to . "done")))
                   ((op . "title") (ticket . "A") (data (to . "Mine")))
                   ((op . "tag") (ticket . "A") (data (tag . "new")))
                   ((op . "untag") (ticket . "A") (data (tag . "old")))
                   ((op . "untag") (ticket . "A") (data (tag . "agent")))))))

(ert-deftest zwanenzang-plan-sends-status-only-when-the-keyword-changed ()
  ;; A draft shown as TODO stays draft.
  (should-not (zwanenzang-test--changes
               (concat zwanenzang-test--root (zwanenzang-test--synced "A" "T" :status "draft"))
               (list (zwanenzang-test--entry "A" "T" :status "draft"))))
  ;; The first status of the keyword is written.
  (should (equal (zwanenzang-test--changes
                  (concat zwanenzang-test--root
                          (zwanenzang-test--synced "A" "T" :status "draft" :keyword "NEXT"))
                  (list (zwanenzang-test--entry "A" "T" :status "draft")))
                 '(((op . "status") (ticket . "A") (data (to . "doing"))))))
  ;; An agent already moved it to another status of that keyword: they agree.
  (should-not (zwanenzang-test--changes
               (concat zwanenzang-test--root
                       (zwanenzang-test--synced "A" "T" :status "draft" :keyword "NEXT"))
               (list (zwanenzang-test--entry "A" "T" :status "review")))))

(ert-deftest zwanenzang-plan-bases-documents-on-the-current-version ()
  (let ((text (concat zwanenzang-test--root
                      (zwanenzang-test--synced "A" "T" :text "Old\n")
                      "My text\n"
                      "*** plan\n:PROPERTIES:\n:ZWANENZANG_DOC: plan\n:ZWANENZANG_VERSION: V1\n"
                      ":ZWANENZANG_HASH: " (zwanenzang--hash "Old plan\n") "\n:END:\n"
                      "My plan\n")))
    ;; V9 and V8 are newer than anything Org saw.
    (should (equal (zwanenzang-test--changes
                    text (list (zwanenzang-test--entry
                                "A" "T" :docs '(("description" "V9" "Agent text\n")
                                                ("plan" "V8" "Agent plan\n")))))
                   '(((op . "doc") (ticket . "A")
                      (data (name . "description") (text . "My text\n") (base . "V9")))
                     ((op . "doc") (ticket . "A")
                      (data (name . "plan") (text . "My plan\n") (base . "V8"))))))
    ;; Text that already agrees is not sent.
    (should-not (zwanenzang-test--changes
                 text (list (zwanenzang-test--entry
                             "A" "T" :docs '(("description" "V9" "My text\n")
                                             ("plan" "V8" "My plan\n"))))))))

(ert-deftest zwanenzang-plan-does-not-send-the-comments-drawer-as-description ()
  (should-not (zwanenzang-test--changes
               (concat zwanenzang-test--root
                       (zwanenzang-test--synced "A" "T" :text "Text\n")
                       "Text\n:ZWANENZANG_COMMENTS:\n[ts] a:\nhello\n:END:\n")
               (list (zwanenzang-test--entry "A" "T" :docs '(("description" "V" "Text\n")))))))

(ert-deftest zwanenzang-plan-does-not-wipe-a-field-it-has-no-sync-state-for ()
  (should-not (zwanenzang-test--changes
               (concat zwanenzang-test--root
                       "** TODO T\n:PROPERTIES:\n:ZWANENZANG_ID: A\n:END:\n")
               (list (zwanenzang-test--entry "A" "T" :status "todo" :tags '("x") :parent "P"
                                             :docs '(("description" "V" "Text\n")))))))

(ert-deftest zwanenzang-plan-sends-new-documents-with-a-null-base ()
  (should (equal (zwanenzang-test--changes
                  (concat zwanenzang-test--root
                          (zwanenzang-test--synced "A" "T")
                          "*** my plan\n:PROPERTIES:\n:ZWANENZANG_DOC: plan\n:END:\nNew plan\n"
                          "*** nothing yet\n:PROPERTIES:\n:ZWANENZANG_DOC: empty\n:END:\n")
                  (list (zwanenzang-test--entry "A" "T")))
                 '(((op . "doc") (ticket . "A")
                    (data (name . "plan") (text . "New plan\n") (base . :null)))))))

(ert-deftest zwanenzang-plan-refuses-hidden-and-repeated-documents ()
  (let ((plan (zwanenzang-test--plan
               (concat zwanenzang-test--root
                       (zwanenzang-test--synced "A" "T")
                       "*** s\n:PROPERTIES:\n:ZWANENZANG_DOC: status\n:END:\nText\n"
                       "*** d\n:PROPERTIES:\n:ZWANENZANG_DOC: description\n:END:\nText\n"
                       "*** p\n:PROPERTIES:\n:ZWANENZANG_DOC: plan\n:END:\nOne\n"
                       "*** p\n:PROPERTIES:\n:ZWANENZANG_DOC: plan\n:END:\nTwo\n")
               (list (zwanenzang-test--entry "A" "T"))
               '("status"))))
    (should (equal (reverse (zwanenzang--plan-changes plan))
                   '(((op . "doc") (ticket . "A")
                      (data (name . "plan") (text . "One\n") (base . :null))))))
    (let ((lines (string-join (zwanenzang--plan-lines plan) "\n")))
      (should (string-match-p "document status not pushed: it is in ZWANENZANG_HIDE_DOCS" lines))
      (should (string-match-p "\"description\" not pushed" lines))
      (should (string-match-p "second heading for document plan" lines)))))

(ert-deftest zwanenzang-plan-creates-first-and-refers-to-them ()
  (should (equal (zwanenzang-test--changes
                  (concat zwanenzang-test--root
                          (zwanenzang-test--synced "A" "Existing")
                          "** Group\n"
                          "*** NEXT Parent :tagged:\nBody\n"
                          "**** Inner group\n"
                          "***** TODO Child\n"
                          "****** the plan\n:PROPERTIES:\n:ZWANENZANG_DOC: plan\n:END:\nPlan\n"
                          "** Plain heading\n")
                  (list (zwanenzang-test--entry "A" "Existing")))
                 '(((op . "create") (data (title . "Parent") (status . "doing")))
                   ((op . "create") (data (title . "Child") (status . "todo")))
                   ((op . "tag") (ticket (created . 0)) (data (tag . "tagged")))
                   ((op . "doc") (ticket (created . 0))
                    (data (name . "description") (text . "Body\n") (base . :null)))
                   ((op . "parent") (ticket (created . 1)) (data (to (created . 0))))
                   ((op . "doc") (ticket (created . 1))
                    (data (name . "plan") (text . "Plan\n") (base . :null)))))))

(ert-deftest zwanenzang-plan-sends-parent-when-the-nesting-changed ()
  (let ((p (zwanenzang-test--synced "P" "P"))
        (entries (list (zwanenzang-test--entry "P" "P")
                       (zwanenzang-test--entry "C" "C" :parent "Q"))))
    ;; Under a grouping heading under P, nesting recorded as none.
    (should (equal (zwanenzang-test--changes
                    (concat zwanenzang-test--root p "*** Group\n"
                            (zwanenzang-test--synced "C" "C" :stars "****"))
                    entries)
                   '(((op . "parent") (ticket . "C") (data (to . "P"))))))
    ;; Moved out from under P: no ancestor.
    (should (equal (zwanenzang-test--changes
                    (concat zwanenzang-test--root p
                            "** Inbox\n:PROPERTIES:\n:ZWANENZANG_INBOX: t\n:END:\n"
                            (zwanenzang-test--synced "C" "C" :stars "***" :nest "P" :parent "P"))
                    entries)
                   '(((op . "parent") (ticket . "C") (data (to . :null))))))
    ;; Parked in the inbox, nesting unchanged: the tracker parent stays.
    (should-not (zwanenzang-test--changes
                 (concat zwanenzang-test--root p
                         "** Inbox\n:PROPERTIES:\n:ZWANENZANG_INBOX: t\n:END:\n"
                         (zwanenzang-test--synced "C" "C" :stars "***" :parent "Q"))
                 entries))))

(ert-deftest zwanenzang-plan-skips-blocked-headings ()
  (let* ((foreign (zwanenzang-test--synced "F" "Foreign" :shown-title "Foreign edit"))
         (tomb (zwanenzang-test--synced "T" "Tomb" :shown-title "Tomb edit"))
         (unmapped (zwanenzang-test--synced "U" "Unmapped" :keyword "WAIT"
                                            :shown-title "Unmapped edit"))
         (bare (replace-regexp-in-string
                "\\`\\*\\* TODO " "** "
                (zwanenzang-test--synced "B" "Bare" :shown-title "Bare edit")))
         (unmapped-status (zwanenzang-test--synced "S" "S" :shown-title "S edit"))
         (plan (zwanenzang-test--plan
                (concat zwanenzang-test--root foreign tomb unmapped bare unmapped-status)
                (list (zwanenzang-test--entry "T" "Tomb" :tombstoned t)
                      (zwanenzang-test--entry "U" "Unmapped")
                      (zwanenzang-test--entry "B" "Bare")
                      (zwanenzang-test--entry "S" "S" :status "cancelled")))))
    (should-not (zwanenzang--plan-changes plan)))
  ;; Both copies of a duplicate.
  (let ((dup (zwanenzang-test--synced "D" "D" :shown-title "D edit")))
    (should-not (zwanenzang-test--changes
                 (concat zwanenzang-test--root dup dup)
                 (list (zwanenzang-test--entry "D" "D"))))))

(ert-deftest zwanenzang-plan-reports-new-headings-it-cannot-create ()
  (let ((plan (zwanenzang-test--plan
               (concat zwanenzang-test--root
                       "** WAIT Unmapped\n"
                       "*** TODO Below unmapped\n"
                       (zwanenzang-test--synced "F" "Foreign")
                       "*** TODO Below foreign\n"
                       (zwanenzang-test--synced "C" "Moved below foreign" :stars "***"))
               (list (zwanenzang-test--entry "C" "Moved below foreign")))))
    (should-not (zwanenzang--plan-changes plan))
    (let ((lines (string-join (zwanenzang--plan-lines plan) "\n")))
      (should (string-match-p "\"Unmapped\" not created: keyword WAIT has no status" lines))
      (should (string-match-p "\"Below unmapped\" not created: the ticket heading above" lines))
      (should (string-match-p "\"Below foreign\" not created" lines))
      (should (string-match-p "parent not pushed" lines)))))

(ert-deftest zwanenzang-plan-revives-archived-headings-with-archive-time ()
  (let* ((heading (zwanenzang-test--synced "A" "T" :status "done" :keyword "NEXT"))
         (restored (replace-regexp-in-string
                    ":END:" ":ARCHIVE_TIME: 2026-11-08 Sun 10:00\n:END:" heading t t)))
    (should (equal (zwanenzang-test--changes
                    (concat zwanenzang-test--root restored)
                    (list (zwanenzang-test--entry "A" "T" :status "done" :archived t)))
                   '(((op . "unarchive") (ticket . "A") (data))
                     ((op . "status") (ticket . "A") (data (to . "doing"))))))
    ;; Not archived in the tracker, or no ARCHIVE_TIME: nothing to revive.
    (should (equal (mapcar (lambda (c) (alist-get 'op c))
                           (zwanenzang-test--changes
                            (concat zwanenzang-test--root restored)
                            (list (zwanenzang-test--entry "A" "T" :status "done"))))
                   '("status")))
    (should (equal (mapcar (lambda (c) (alist-get 'op c))
                           (zwanenzang-test--changes
                            (concat zwanenzang-test--root heading)
                            (list (zwanenzang-test--entry "A" "T" :status "done" :archived t))))
                   '("status")))))

(ert-deftest zwanenzang-written-fields-leave-out-no-ops-and-new-tickets ()
  (should (equal (zwanenzang--written-fields
                  '(((op . "create") (data (title . "N")))
                    ((op . "tag") (ticket (created . 0)) (data (tag . "x")))
                    ((op . "title") (ticket . "A") (data (to . "T")))
                    ((op . "tag") (ticket . "A") (data (tag . "x")))
                    ((op . "untag") (ticket . "A") (data (tag . "y")))
                    ((op . "status") (ticket . "A") (data (to . "done")))
                    ((op . "title") (ticket . "B") (data (to . "T"))))
                  '(((written . t)) ((written . t)) ((written . t)) ((written . t))
                    ((written . t)) ((written . :false)) ((written . :false))))
                 '(("A" "title" "tags")))))

(provide 'zwanenzang-push-test)
;;; zwanenzang-push-test.el ends here
