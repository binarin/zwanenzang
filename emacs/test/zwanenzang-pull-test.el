;;; zwanenzang-pull-test.el --- Pull logic that needs no CLI  -*- lexical-binding: t; -*-

;;; Commentary:

;; Org text in, model out; model in, Org text out; and the
;; apply-or-conflict decisions, all without running the CLI.

;;; Code:

(require 'ert)
(require 'zwanenzang)

(defmacro zwanenzang-test-with-org (text &rest body)
  "Run BODY in an Org buffer holding TEXT, with point at the start."
  (declare (indent 1) (debug (form body)))
  `(with-temp-buffer
     (insert ,text)
     (org-mode)
     (goto-char (point-min))
     ,@body))

;;;; Text

(ert-deftest zwanenzang-escape-keeps-structure-out-of-text ()
  (let ((text (concat "* heading\n** deeper\n*bold* stays\n#+TODO: X\n"
                      ":END:\n  :PROPERTIES:\n,* already\nplain\n*\n")))
    (should (equal (zwanenzang--escape-text text)
                   (concat ",* heading\n,** deeper\n*bold* stays\n,#+TODO: X\n"
                           ",:END:\n,  :PROPERTIES:\n,,* already\nplain\n,*\n")))
    (should (equal (zwanenzang--unescape-text (zwanenzang--escape-text text)) text))
    ;; A comma that escapes nothing is the human's and stays.
    (should (equal (zwanenzang--unescape-text ",plain\n") ",plain\n"))))

(ert-deftest zwanenzang-normalize-text-ignores-surrounding-blank-lines ()
  (should (equal (zwanenzang--normalize-text "\n  \nText\n\nmore  \n\n") "Text\n\nmore\n"))
  (should (equal (zwanenzang--normalize-text " \n\n") ""))
  (should (equal (zwanenzang--normalize-text "x") "x\n")))

(ert-deftest zwanenzang-fixed-width-quotes-every-line ()
  (should (equal (zwanenzang--fixed-width "one\n\n:END:\n* two\n" "  ")
                 "  : one\n  :\n  : :END:\n  : * two\n"))
  (should (equal (zwanenzang--fixed-width "\n" "  ") "")))

;;;; Bodies

(defconst zwanenzang-test--body
  (concat "SCHEDULED: <2026-11-07 Sat>\n"
          ":PROPERTIES:\n:ZWANENZANG_ID: X\n:END:\n"
          ":LOGBOOK:\n- note\n:END:\n"
          "First line\n"
          ":ZWANENZANG_COMMENTS:\n[ts] a:\n  : hi\n:END:\n"
          ",* escaped\n"
          ":UNCLOSED:\n"
          "last\n"))

(ert-deftest zwanenzang-body-segments-split-planning-drawers-and-text ()
  (let ((segments (zwanenzang--body-segments zwanenzang-test--body)))
    (should (equal (mapcar (lambda (s) (if (eq (car s) 'drawer) (nth 2 s) (car s))) segments)
                   '(planning "PROPERTIES" "LOGBOOK" text "ZWANENZANG_COMMENTS"
                              text text text)))
    (should (equal (apply #'concat (mapcar #'cadr segments)) zwanenzang-test--body))))

(ert-deftest zwanenzang-body-segments-end-drawers-in-any-case ()
  ;; Org closes a drawer at a lowercase :end: too.
  (let ((body ":PROPERTIES:\n:ZWANENZANG_ID: X\n:end:\n:LOGBOOK:\n- n\n:End:\nText\n"))
    (should (equal (mapcar (lambda (s) (if (eq (car s) 'drawer) (nth 2 s) (car s)))
                           (zwanenzang--body-segments body))
                   '("PROPERTIES" "LOGBOOK" text)))
    (should (equal (zwanenzang--body-description body) "Text\n")))
  ;; Planning keywords stay case-sensitive.
  (should (equal (caar (zwanenzang--body-segments "scheduled: soon\n")) 'text))
  ;; Tracker text with such a line cannot close a drawer either.
  (should (equal (zwanenzang--escape-text ":end:\n") ",:end:\n")))

(ert-deftest zwanenzang-description-excludes-drawers-and-planning ()
  (should (equal (zwanenzang--body-description zwanenzang-test--body)
                 "First line\n* escaped\n:UNCLOSED:\nlast\n"))
  (should (equal (zwanenzang--body-description "") ""))
  (should (equal (zwanenzang--body-description ":PROPERTIES:\n:A: b\n:END:\n\n") "")))

(ert-deftest zwanenzang-compose-body-replaces-own-drawers-and-description ()
  (should (equal (zwanenzang--compose-body
                  zwanenzang-test--body
                  '(("ZWANENZANG_COMMENTS" . "[ts] b:\n  : new\n")
                    ("ZWANENZANG_HIDDEN" . nil)
                    ("ZWANENZANG_CONFLICT" . ""))
                  "* new text\n")
                 (concat "SCHEDULED: <2026-11-07 Sat>\n"
                         ":PROPERTIES:\n:ZWANENZANG_ID: X\n:END:\n"
                         ":LOGBOOK:\n- note\n:END:\n"
                         ":ZWANENZANG_COMMENTS:\n[ts] b:\n  : new\n:END:\n"
                         ",* new text\n")))
  ;; Without a description the text stays exactly as it was.
  (let ((kept (zwanenzang--compose-body zwanenzang-test--body
                                        '(("ZWANENZANG_COMMENTS" . nil)))))
    (should (equal kept (concat "SCHEDULED: <2026-11-07 Sat>\n"
                                ":PROPERTIES:\n:ZWANENZANG_ID: X\n:END:\n"
                                ":LOGBOOK:\n- note\n:END:\n"
                                "First line\n,* escaped\n:UNCLOSED:\nlast\n")))
    (should (equal (zwanenzang--body-description kept)
                   (zwanenzang--body-description zwanenzang-test--body)))))

(ert-deftest zwanenzang-written-description-reads-back-unchanged ()
  (let* ((text "Intro\n* not a heading\n:END:\n#+TITLE: no\n\nend\n")
         (body (zwanenzang--compose-body ":PROPERTIES:\n:END:\n" nil text)))
    (should (equal (zwanenzang--body-description body) text))
    (zwanenzang-test-with-org (concat "* T\n" body "* Next\n")
      (should (equal (length (org-map-entries #'point)) 2)))))

;;;; Headings and scopes

(ert-deftest zwanenzang-set-heading-keeps-level-priority-and-comment ()
  (zwanenzang-test-with-org (concat "#+TODO: TODO NEXT | DONE\n"
                                    "** TODO [#A] COMMENT Old title :a:zz_conflict:\nbody\n")
    (outline-next-heading)
    (should (equal (zwanenzang--heading)
                   '(:keyword "TODO" :title "Old title" :tags ("a" "zz_conflict"))))
    (zwanenzang--set-heading "DONE" "New title" '("b"))
    (should (string-match-p "\\`\\*\\* DONE \\[#A\\] COMMENT New title +:b:\\'"
                            (buffer-substring (line-beginning-position) (line-end-position))))
    (zwanenzang--set-heading nil "Bare" nil)
    (should (equal (buffer-substring (line-beginning-position) (line-end-position))
                   "** [#A] COMMENT Bare"))))

(ert-deftest zwanenzang-tracker-tags-leave-out-conflict-and-archive ()
  (should (equal (zwanenzang--tracker-tags '("a" "zz_conflict" "ARCHIVE" "b")) '("a" "b"))))

(ert-deftest zwanenzang-scan-finds-tickets-nesting-and-inbox ()
  (zwanenzang-test-with-org
      (concat "* Above\n"
              "** Root\n:PROPERTIES:\n:ZWANENZANG: /t\n:END:\n"
              "*** Group\n"
              "**** TODO A\n:PROPERTIES:\n:ZWANENZANG_ID: A\n:END:\n"
              "***** plan\n:PROPERTIES:\n:ZWANENZANG_DOC: plan\n:END:\n"
              "***** TODO B\n:PROPERTIES:\n:ZWANENZANG_ID: B\n:END:\n"
              "*** Inbox\n:PROPERTIES:\n:ZWANENZANG_INBOX: t\n:END:\n"
              "**** TODO C\n:PROPERTIES:\n:ZWANENZANG_ID: C\n:END:\n"
              "*** Other scope\n:PROPERTIES:\n:ZWANENZANG: /u\n:END:\n"
              "**** TODO D\n:PROPERTIES:\n:ZWANENZANG_ID: D\n:END:\n"
              "*** TODO E\n:PROPERTIES:\n:ZWANENZANG_ID: E\n:END:\n"
              "* Outside\n"
              "** TODO F\n:PROPERTIES:\n:ZWANENZANG_ID: F\n:END:\n")
    (search-forward "TODO B")
    (let* ((root (zwanenzang--scope-root))
           (scan (zwanenzang--scan root)))
      (should (equal (org-entry-get root "ZWANENZANG") "/t"))
      (should (equal (mapcar (lambda (tk) (list (plist-get tk :id) (plist-get tk :nest)))
                             (car scan))
                     '(("A" nil) ("B" "A") ("C" nil) ("E" nil))))
      (should (equal (save-excursion (goto-char (cdr scan)) (org-get-heading t t t t))
                     "Inbox")))
    (goto-char (point-min))
    (should-error (zwanenzang--scope-root) :type 'user-error)
    (search-forward "TODO F")
    (should-error (zwanenzang--scope-root) :type 'user-error)))

(ert-deftest zwanenzang-ensure-inbox-creates-it-once ()
  (zwanenzang-test-with-org "* Root\n:PROPERTIES:\n:ZWANENZANG: /t\n:END:\n** Mine\n* Next\n"
    (let* ((root (copy-marker (point)))
           (inbox (zwanenzang--ensure-inbox root)))
      (should (equal (buffer-string)
                     (concat "* Root\n:PROPERTIES:\n:ZWANENZANG: /t\n:END:\n** Mine\n"
                             "** Inbox\n:PROPERTIES:\n:ZWANENZANG_INBOX: t\n:END:\n* Next\n")))
      (should (= (zwanenzang--ensure-inbox root) inbox)))))

(ert-deftest zwanenzang-move-subtree-relevels-under-target ()
  (zwanenzang-test-with-org "* A\n** B\nbody\n*** C\n* D\n** E\n"
    (let ((b (save-excursion (search-forward "** B") (copy-marker (line-beginning-position))))
          (e (save-excursion (search-forward "** E") (copy-marker (line-beginning-position)))))
      (zwanenzang--move-subtree b e)
      (should (equal (buffer-string) "* A\n* D\n** E\n*** B\nbody\n**** C\n")))))

(ert-deftest zwanenzang-relevel-ignores-escaped-lines ()
  (should (equal (zwanenzang--relevel "** A\n,* text\n*** B\n" -1) "* A\n,* text\n** B\n")))

(ert-deftest zwanenzang-doc-headings-are-direct-children-only ()
  (zwanenzang-test-with-org
      (concat "* T\n** plan\n:PROPERTIES:\n:ZWANENZANG_DOC: plan\n:END:\n"
              "** Child\n*** notes\n:PROPERTIES:\n:ZWANENZANG_DOC: notes\n:END:\n* U\n")
    (should (equal (mapcar #'car (zwanenzang--doc-headings)) '("plan")))))

(ert-deftest zwanenzang-one-undo-step-undoes-together-and-cancels-on-error ()
  (with-temp-buffer
    (buffer-enable-undo)
    (insert "start\n")
    (undo-boundary)
    (zwanenzang--one-undo-step
      (goto-char (point-max))
      (insert "one\n")
      (undo-boundary)
      (insert "two\n"))
    (should (equal (buffer-string) "start\none\ntwo\n"))
    (undo-boundary)
    (let ((last-command nil)) (undo))
    (should (equal (buffer-string) "start\n"))
    (should-error (zwanenzang--one-undo-step (insert "lost") (error "Boom")))
    (should (equal (buffer-string) "start\n"))))

;;;; Keyword map

(ert-deftest zwanenzang-keyword-map-shares-keywords-and-reports-gaps ()
  (let ((statuses '("draft" "todo" "doing" "blocked" "done"))
        (keywords '("TODO" "NEXT" "DONE")))
    (should (equal (zwanenzang--keyword-map "TODO=todo,draft NEXT=doing DONE=done,blocked"
                                            statuses keywords)
                   '((("todo" . "TODO") ("draft" . "TODO") ("doing" . "NEXT")
                      ("done" . "DONE") ("blocked" . "DONE")))))
    (should (equal (zwanenzang--keyword-map
                    "TODO=todo,draft NEXT=doing,todo WAIT=blocked DONE=done,nope bad"
                    statuses keywords)
                   '((("todo" . "TODO") ("draft" . "TODO") ("doing" . "NEXT") ("done" . "DONE"))
                     "keyword map: status todo has two keywords, TODO and NEXT"
                     "keyword map: WAIT is not a TODO keyword in this buffer"
                     "keyword map: nope is not a tracker status"
                     "keyword map: malformed entry bad"
                     "keyword map: status blocked has no keyword")))))

(ert-deftest zwanenzang-keyword-map-defaults-to-same-names ()
  (should (equal (zwanenzang--keyword-map nil '("todo" "doing" "done") '("TODO" "WAIT" "DONE"))
                 '((("todo" . "TODO") ("done" . "DONE"))
                   "keyword map: status doing has no keyword"))))

;;;; Sync state and decisions

(ert-deftest zwanenzang-sync-state-round-trips ()
  (let ((alist (zwanenzang--parse-sync "status=draft title=abc tags=def parent=- nest=P")))
    (should (equal alist '((status . "draft") (title . "abc") (tags . "def")
                           (parent . nil) (nest . "P"))))
    (should (equal (zwanenzang--format-sync alist)
                   "status=draft title=abc tags=def parent=- nest=P"))
    (should (eq (zwanenzang--sync-get alist 'parent) nil))
    (should (eq (zwanenzang--sync-get (zwanenzang--parse-sync nil) 'title) :unknown))))

(ert-deftest zwanenzang-merge-applies-keeps-or-conflicts ()
  (dolist (case '(;; local base remote -> result
                  ("a" "a" "a" same)
                  ("a" "a" "b" apply)
                  ("b" "a" "a" keep)
                  ("b" "a" "c" conflict)
                  ("b" "a" "b" same)
                  ("a" :unknown "b" conflict)
                  ("a" :unknown "a" same)
                  (nil "a" "a" keep)))
    (should (eq (apply #'zwanenzang--merge (butlast case)) (car (last case))))))

(ert-deftest zwanenzang-tags-hash-ignores-order ()
  (should (equal (zwanenzang--tags-hash '("b" "a" "c")) (zwanenzang--tags-hash '("a" "b" "c"))))
  (should-not (equal (zwanenzang--tags-hash '("a" "b")) (zwanenzang--tags-hash '("a")))))

(ert-deftest zwanenzang-merge-parent-moves-only-when-nesting-unchanged ()
  (dolist (case '(;; nest base-nest remote base-parent expected -> result
                  ("P" "P" "P" "P" "P" same)
                  ("P" "P" "Q" "P" "Q" move)       ; new parent in scope
                  ("P" "P" "Q" "P" nil move)       ; new parent elsewhere: inbox
                  ("P" "P" nil "P" nil move)       ; cleared: inbox
                  (nil nil nil "P" nil same)       ; already not nested
                  ("R" "P" "P" "P" "P" keep)       ; moved locally only
                  ("R" "P" "Q" "P" "Q" conflict)   ; both moved
                  ("Q" "P" "Q" "P" "Q" same)       ; both moved alike
                  (nil nil "P" "P" nil same)       ; parent never in scope
                  ("P" :unknown "P" :unknown "P" same)
                  (nil :unknown "P" :unknown "P" conflict)))
    (should (eq (apply #'zwanenzang--merge-parent (butlast case)) (car (last case))))))

;;;; Rendering tracker state

(ert-deftest zwanenzang-comments-render-names-links-and-quoted-text ()
  (let ((pull (zwanenzang--pull-create
               :tracker-dir "/trk/"
               :actors '((A1 . "Alice")))))
    (should (equal (zwanenzang--comments-content
                    pull
                    '((comments ((actor . "A1") (ts . "2026-11-07T10:00:00Z")
                                 (text . "first\n* line") (link . :null))
                                ((actor . "01UNDECLARED0000000000000") (ts . "2026-11-07T11:00:00Z")
                                 (text . "second") (link . "docs/x.md"))
                                ((actor . "A1") (ts . "2026-11-07T12:00:00Z")
                                 (text . "third") (link . "https://example.invalid/mr/1")))))
                   (concat "[2026-11-07T10:00:00Z] Alice:\n  : first\n  : * line\n"
                           "[2026-11-07T11:00:00Z] 01UNDECLAR:\n  : second\n"
                           "  [[file:/trk/docs/x.md]]\n"
                           "[2026-11-07T12:00:00Z] Alice:\n  : third\n"
                           "  [[https://example.invalid/mr/1]]\n")))))

(ert-deftest zwanenzang-hidden-documents-render-as-links ()
  (let ((pull (zwanenzang--pull-create :hidden '("status" "plan" "absent"))))
    (should (equal (zwanenzang--hidden-content
                    pull '((id . "01T") (documents (status (current . "V1"))
                                                   (plan (current . :null)))))
                   "[[zwanenzang:01T/status][status (hidden)]]\n"))))

(ert-deftest zwanenzang-add-conflict-appends-to-the-drawer ()
  (zwanenzang-test-with-org
      (concat "* TODO T :a:\n:PROPERTIES:\n:ZWANENZANG_ID: X\n:END:\n"
              ":ZWANENZANG_CONFLICT:\n- title: skipped\n  : New\n:END:\nText\n")
    (zwanenzang--add-conflict '("parent" "kept" nil))
    (should (equal (buffer-substring-no-properties (line-end-position) (point-max))
                   (concat "\n:PROPERTIES:\n:ZWANENZANG_ID: X\n:END:\n"
                           ":ZWANENZANG_CONFLICT:\n- title: skipped\n  : New\n- parent: kept\n"
                           ":END:\nText\n")))
    (should (equal (org-get-tags nil t) '("a" "zz_conflict")))))

(ert-deftest zwanenzang-conflicts-render-notes-and-values ()
  (should (equal (zwanenzang--conflict-content
                  '(("title" "tracker title skipped" "New") ("tombstoned" "gone" nil)))
                 "- title: tracker title skipped\n  : New\n- tombstoned: gone\n")))

(provide 'zwanenzang-pull-test)
;;; zwanenzang-pull-test.el ends here
