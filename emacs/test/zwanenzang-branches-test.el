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

(provide 'zwanenzang-branches-test)
;;; zwanenzang-branches-test.el ends here
