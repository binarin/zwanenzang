;;; zwanenzang-branches-test.el --- Showing branches down to tickets  -*- lexical-binding: t; -*-

;;; Commentary:

;; `org-kill-note-or-show-branches' (C-c C-k) in and around scopes.  No CLI.

;;; Code:

(require 'ert)
(require 'zwanenzang)
(require 'zwanenzang-pull-test)

(defconst zwanenzang-test--branches
  (concat
   "* Projects\n"
   "** Tracker\n:PROPERTIES:\n:ZWANENZANG: /not-a-tracker\n:END:\n"
   "*** Inbox\n:PROPERTIES:\n:ZWANENZANG_INBOX: t\n:END:\n"
   "**** TODO Ticket A\n:PROPERTIES:\n:ZWANENZANG_ID: A\n:END:\nDescription A\n"
   "***** plan\n:PROPERTIES:\n:ZWANENZANG_DOC: plan\n:END:\n#+begin_src org\nPlan\n#+end_src\n"
   "***** Notes\n****** Deep note\n"
   "***** TODO Child ticket\n:PROPERTIES:\n:ZWANENZANG_ID: C\n:END:\n"
   "****** status\n:PROPERTIES:\n:ZWANENZANG_DOC: status\n:END:\n"
   "****** TODO Grandchild ticket\n:PROPERTIES:\n:ZWANENZANG_ID: G\n:END:\n"
   "**** TODO New ticket\n***** Draft notes\n"
   "*** Grouping\n**** DONE Ticket B\n:PROPERTIES:\n:ZWANENZANG_ID: B\n:END:\n"
   "* Elsewhere\n** TODO Sub\n:PROPERTIES:\n:ZWANENZANG_ID: outside-any-scope\n:END:\n"
   "*** Deep\n"))

(defun zwanenzang-test--visible-headings ()
  "The titles of the headings whose lines are visible, in buffer order."
  (save-excursion
    (goto-char (point-min))
    (let (titles)
      (while (re-search-forward org-outline-regexp-bol nil t)
        (unless (invisible-p (point))
          (push (org-get-heading t t t t) titles)))
      (nreverse titles))))

(defun zwanenzang-test--show-branches-at (heading)
  "Fold to an overview, then press C-c C-k on HEADING, or before the first one."
  (org-fold-show-all)
  (org-cycle-overview)
  (goto-char (point-min))
  (when heading
    (re-search-forward (format "^\\*+ \\(?:[A-Z]+ \\)?%s$" (regexp-quote heading)))
    ;; Org acts on the nearest visible heading, so make this one visible.
    (org-fold-show-set-visibility 'ancestors))
  (org-kill-note-or-show-branches)
  (zwanenzang-test--visible-headings))

(defconst zwanenzang-test--branches-scope
  '("Inbox" "Ticket A" "Child ticket" "Grandchild ticket" "New ticket"
    "Grouping" "Ticket B"))

(ert-deftest zwanenzang-show-branches-stops-at-tickets ()
  (dolist (org-fold-core-style '(overlays text-properties))
    (zwanenzang-test-with-org zwanenzang-test--branches
      (should (equal (zwanenzang-test--show-branches-at "Tracker")
                     `("Projects" "Tracker" ,@zwanenzang-test--branches-scope
                       "Elsewhere")))
      ;; From above the scope root, the scope's part is limited the same way.
      (should (equal (zwanenzang-test--show-branches-at "Projects")
                     `("Projects" "Tracker" ,@zwanenzang-test--branches-scope
                       "Elsewhere")))
      ;; On a ticket, only its child tickets show. 
      (should (equal (zwanenzang-test--show-branches-at "Ticket A")
                     '("Projects" "Tracker" "Inbox" "Ticket A" "Child ticket"
                       "Grandchild ticket" "Elsewhere")))
      ;; Within a non-ticket heading below a ticket, Org's own behaviour.
      (should (equal (zwanenzang-test--show-branches-at "Notes")
                     '("Projects" "Tracker" "Inbox" "Ticket A" "Notes" "Deep note"
                       "Elsewhere")))
      ;; The bodies stay folded.
      (zwanenzang-test--show-branches-at "Tracker")
      (goto-char (point-min))
      (search-forward "Description A")
      (should (invisible-p (1- (point)))))))

(ert-deftest zwanenzang-show-branches-buffer-wide-and-outside-scopes ()
  (zwanenzang-test-with-org (concat "Preamble\n" zwanenzang-test--branches)
    (should (equal (zwanenzang-test--show-branches-at nil)
                   `("Projects" "Tracker" ,@zwanenzang-test--branches-scope
                     "Elsewhere" "Sub" "Deep"))))
  (zwanenzang-test-with-org zwanenzang-test--branches
    ;; An identity outside any scope is not a ticket.
    (should (equal (zwanenzang-test--show-branches-at "Elsewhere")
                   '("Projects" "Elsewhere" "Sub" "Deep")))))

(ert-deftest zwanenzang-show-branches-can-be-turned-off ()
  (zwanenzang-test-with-org zwanenzang-test--branches
    (let ((zwanenzang-show-branches-to-tickets nil))
      (should (equal (zwanenzang-test--show-branches-at "Ticket A")
                     '("Projects" "Tracker" "Inbox" "Ticket A" "plan" "Notes"
                       "Deep note" "Child ticket" "status" "Grandchild ticket"
                       "Elsewhere"))))))

;;;; With a prefix argument: the whole scope

(defconst zwanenzang-test--scope-branches
  (concat
   "* Projects\n"
   "** Tracker\n:PROPERTIES:\n:ZWANENZANG: /not-a-tracker\n:END:\n"
   "*** Inbox\n:PROPERTIES:\n:ZWANENZANG_INBOX: t\n:END:\n"
   "**** TODO Ticket A\n:PROPERTIES:\n:ZWANENZANG_ID: A\n:END:\nDescription A\n"
   "***** plan\n:PROPERTIES:\n:ZWANENZANG_DOC: plan\n:END:\n#+begin_src org\nPlan text\n#+end_src\n"
   "***** Notes\n****** Deep note\n"
   "***** TODO Child ticket\n:PROPERTIES:\n:ZWANENZANG_ID: C\n:END:\n"
   "*** Grouping\n**** DONE Ticket B\n:PROPERTIES:\n:ZWANENZANG_ID: B\n:END:\n"
   "**** Old stuff :ARCHIVE:\n***** Old child\n"
   "*** Inner\n:PROPERTIES:\n:ZWANENZANG: /inner\n:END:\n"
   "**** TODO Inner ticket\n:PROPERTIES:\n:ZWANENZANG_ID: I\n:END:\n"
   "***** Inner notes\nInner text\n"
   "* Elsewhere\n** TODO Sub\n*** Deep\nDeep text\n"))

(defun zwanenzang-test--goto (text)
  "Move point to the start of the first TEXT."
  (goto-char (point-min))
  (search-forward text)
  (goto-char (match-beginning 0)))

(defun zwanenzang-test--scope-branches-at (text &optional plain)
  "Unfold everything, put point on TEXT and press C-u C-c C-k.
With PLAIN, press C-c C-k without the prefix.  TEXT nil means the start
of the accessible buffer.  Return the visible headings."
  (org-fold-show-all)
  (if text (zwanenzang-test--goto text) (goto-char (point-min)))
  (let ((current-prefix-arg (unless plain '(4))))
    (call-interactively #'org-kill-note-or-show-branches))
  (zwanenzang-test--visible-headings))

(defconst zwanenzang-test--scope-branches-tracker
  '("Projects" "Tracker" "Inbox" "Ticket A" "Child ticket" "Grouping"
    "Ticket B" "Old stuff" "Inner" "Inner ticket"
    "Elsewhere" "Sub" "Deep"))

(ert-deftest zwanenzang-show-scope-branches-from-deep-inside ()
  (dolist (org-fold-core-style '(overlays text-properties))
    (zwanenzang-test-with-org zwanenzang-test--scope-branches
      ;; The same as plain C-c C-k on the root, from wherever point is.
      (let ((reference (zwanenzang-test--scope-branches-at "** Tracker" t)))
        (should (equal reference zwanenzang-test--scope-branches-tracker))
        (should (equal (zwanenzang-test--scope-branches-at "Plan text")
                       reference))
        ;; Hidden point moves to the nearest visible heading above it.
        (should (looking-at-p "^\\*\\*\\*\\* TODO Ticket A$"))
        (should (equal (zwanenzang-test--scope-branches-at "Deep note")
                       reference))
        (should (looking-at-p "^\\*\\*\\*\\* TODO Ticket A$"))
        (should (equal (zwanenzang-test--scope-branches-at "Old child")
                       reference))
        (should (looking-at-p "^\\*\\*\\*\\* Old stuff"))
        ;; Visible point stays where it is, even mid-heading.
        (should (equal (zwanenzang-test--scope-branches-at "Child ticket")
                       reference))
        (should (looking-at-p "Child ticket$"))
        ;; Bodies and archived subtrees stay hidden.
        (zwanenzang-test--goto "Description A")
        (should (invisible-p (point)))
        (zwanenzang-test--goto "Old child")
        (should (invisible-p (point)))))))

(ert-deftest zwanenzang-show-scope-branches-nested-scopes ()
  (zwanenzang-test-with-org zwanenzang-test--scope-branches
    ;; In the inner scope, only it is folded; the outer one stays open.
    (should (equal (zwanenzang-test--scope-branches-at "Inner text")
                   '("Projects" "Tracker" "Inbox" "Ticket A" "plan" "Notes"
                     "Deep note" "Child ticket" "Grouping" "Ticket B"
                     "Old stuff" "Old child" "Inner" "Inner ticket"
                     "Elsewhere" "Sub" "Deep")))
    (should (looking-at-p "^\\*\\*\\*\\* TODO Inner ticket$"))
    ;; From the outer scope, the inner one is covered.
    (should (equal (zwanenzang-test--scope-branches-at "Grouping")
                   zwanenzang-test--scope-branches-tracker))))

(ert-deftest zwanenzang-show-scope-branches-falls-back-outside-scopes ()
  (dolist (text '("Deep text" "Elsewhere" "Projects"))
    (zwanenzang-test-with-org zwanenzang-test--scope-branches
      (let ((plain (zwanenzang-test--scope-branches-at text t))
            (plain-point (point)))
        (should (equal (zwanenzang-test--scope-branches-at text) plain))
        (should (= (point) plain-point)))))
  (zwanenzang-test-with-org (concat "Preamble\n" zwanenzang-test--scope-branches)
    (let ((plain (zwanenzang-test--scope-branches-at nil t)))
      (should (equal (zwanenzang-test--scope-branches-at nil) plain)))))

(ert-deftest zwanenzang-show-scope-branches-still-aborts-notes ()
  (zwanenzang-test-with-org zwanenzang-test--scope-branches
    (let* ((aborted 'not-called)
           (org-finish-function (lambda () (setq aborted org-note-abort))))
      (org-fold-show-all)
      (zwanenzang-test--goto "Plan text")
      (let ((current-prefix-arg '(4)))
        (call-interactively #'org-kill-note-or-show-branches))
      (should (eq aborted t))
      ;; Nothing was folded.
      (should-not (invisible-p (point))))))

(ert-deftest zwanenzang-show-scope-branches-can-be-turned-off ()
  (zwanenzang-test-with-org zwanenzang-test--scope-branches
    (let ((zwanenzang-show-branches-to-tickets nil))
      (let ((plain (zwanenzang-test--scope-branches-at "Plan text" t))
            (plain-point (point)))
        (should (equal (zwanenzang-test--scope-branches-at "Plan text") plain))
        (should (= (point) plain-point))))))

(ert-deftest zwanenzang-show-scope-branches-keeps-narrowing ()
  (dolist (org-fold-core-style '(overlays text-properties))
    (zwanenzang-test-with-org zwanenzang-test--scope-branches
      (zwanenzang-test--goto "**** TODO Ticket A")
      (org-narrow-to-subtree)
      (let ((beg (point-min)) (end (point-max)))
        (should (equal (zwanenzang-test--scope-branches-at "Plan text")
                       '("Ticket A" "Child ticket")))
        (should (looking-at-p "^\\*\\*\\*\\* TODO Ticket A$"))
        (should (= (point-min) beg))
        (should (= (point-max) end))))
    ;; Narrowed to two siblings below the root: each is treated.
    (zwanenzang-test-with-org zwanenzang-test--scope-branches
      (zwanenzang-test--goto "*** Inbox")
      (narrow-to-region (point) (progn (zwanenzang-test--goto "*** Inner")
                                       (point)))
      (should (equal (zwanenzang-test--scope-branches-at "Deep note")
                     '("Inbox" "Ticket A" "Child ticket" "Grouping"
                       "Ticket B" "Old stuff")))
      (should (buffer-narrowed-p)))))

(ert-deftest zwanenzang-show-scope-branches-modifies-and-runs-nothing ()
  (zwanenzang-test-with-org zwanenzang-test--scope-branches
    (set-buffer-modified-p nil)
    (let ((tick (buffer-chars-modified-tick)))
      (cl-letf (((symbol-function 'make-process)
                 (lambda (&rest _) (ert-fail "Must not start a process")))
                ((symbol-function 'call-process)
                 (lambda (&rest _) (ert-fail "Must not run a process")))
                ((symbol-function 'process-file)
                 (lambda (&rest _) (ert-fail "Must not run a process"))))
        (zwanenzang-test--scope-branches-at "Plan text")
        (zwanenzang-show-scope-branches))
      (should-not (buffer-modified-p))
      (should (= (buffer-chars-modified-tick) tick)))))

(ert-deftest zwanenzang-show-scope-branches-command ()
  (zwanenzang-test-with-org zwanenzang-test--scope-branches
    (org-fold-show-all)
    (zwanenzang-test--goto "Plan text")
    (call-interactively #'zwanenzang-show-scope-branches)
    (should (equal (zwanenzang-test--visible-headings)
                   zwanenzang-test--scope-branches-tracker))
    (should (looking-at-p "^\\*\\*\\*\\* TODO Ticket A$"))))

(ert-deftest zwanenzang-show-branches-docstring-names-keys ()
  ;; Every command reference in the option's help is substituted.
  (should-not (string-match-p
               "\\[org-kill-note-or-show-branches\\]"
               (documentation-property 'zwanenzang-show-branches-to-tickets
                                       'variable-documentation))))

(provide 'zwanenzang-branches-test)
;;; zwanenzang-branches-test.el ends here
