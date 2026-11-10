;;; zwanenzang-comment-test.el --- Comment composition tests -*- lexical-binding: t; -*-

(require 'zwanenzang-test-helpers)
(require 'org-agenda)

(ert-deftest zwanenzang-comment-named-document-routing ()
  (dolist (command '(org-add-note zwanenzang-comment))
    (with-temp-buffer
      (org-mode)
      (insert "* Scope\n:PROPERTIES:\n:ZWANENZANG: /tmp\n:END:\n** TODO Parent\n:PROPERTIES:\n:ZWANENZANG_ID: parent\n:END:\n*** plan\n:PROPERTIES:\n:ZWANENZANG_DOC: plan\n:END:\nParent plan text\n*** TODO Child\n:PROPERTIES:\n:ZWANENZANG_ID: child\n:END:\n**** plan\n:PROPERTIES:\n:ZWANENZANG_DOC: plan\n:END:\nChild plan text\n")
      (dolist (owner '("Parent" "Child"))
        (goto-char (point-min))
        (search-forward (concat owner " plan text"))
        (let ((source (current-buffer)) (before (buffer-string)))
          (save-restriction
            (org-narrow-to-subtree)
            (save-window-excursion
              (unwind-protect
                  (progn
                    (funcall command)
                    (should (derived-mode-p 'zwanenzang-comment-mode))
                    (should (equal (nth 2 zwanenzang--comment-target)
                                   (downcase owner)))
                    (with-current-buffer source
                      (org-with-wide-buffer
                       (should (equal before (buffer-string))))))
                (when zwanenzang--comment-target (zwanenzang-comment-abort))))))))))

(ert-deftest zwanenzang-comment-named-document-bypass-and-agenda ()
  (with-temp-buffer
    (org-mode)
    (insert "* Scope\n:PROPERTIES:\n:ZWANENZANG: /tmp\n:END:\n** TODO Ticket\n:PROPERTIES:\n:ZWANENZANG_ID: ticket\n:END:\n*** plan\n:PROPERTIES:\n:ZWANENZANG_DOC: plan\n:END:\nPlan text\n")
    (goto-char (point-min))
    (search-forward "Plan text")
    (let (plain)
      (let ((current-prefix-arg '(4)))
        (zwanenzang--org-add-note (lambda () (setq plain t))))
      (should plain)
      (setq plain nil)
      (let ((zwanenzang-redirect-org-notes nil))
        (zwanenzang--org-add-note (lambda () (setq plain t))))
      (should plain))
    (let ((marker (point-marker)))
      (save-window-excursion
        (with-temp-buffer
          (org-agenda-mode)
          (let ((inhibit-read-only t))
            (insert (propertize "Plan" 'org-marker marker)))
          (goto-char (point-min))
          (unwind-protect
              (progn
                (org-agenda-add-note)
                (set-buffer (window-buffer (selected-window)))
                (should (derived-mode-p 'zwanenzang-comment-mode))
                (should (equal "ticket" (nth 2 zwanenzang--comment-target))))
            (when zwanenzang--comment-target (zwanenzang-comment-abort))))))))

(ert-deftest zwanenzang-comment-named-document-boundaries ()
  (with-temp-buffer
    (org-mode)
    (insert "* Scope\n:PROPERTIES:\n:ZWANENZANG: /tmp\n:END:\n** TODO Parent\n:PROPERTIES:\n:ZWANENZANG_ID: parent\n:END:\n*** Structure\n**** orphan-doc\n:PROPERTIES:\n:ZWANENZANG_DOC: plan\n:END:\n*** TODO New\n**** new-doc\n:PROPERTIES:\n:ZWANENZANG_DOC: plan\n:END:\n*** Nested scope\n:PROPERTIES:\n:ZWANENZANG: /tmp\n:END:\n**** nested-doc\n:PROPERTIES:\n:ZWANENZANG_DOC: plan\n:END:\n* Outside document\n:PROPERTIES:\n:ZWANENZANG_DOC: plan\n:END:\n")
    (dolist (title '("Structure" "orphan-doc" "nested-doc" "Outside document"))
      (goto-char (point-min))
      (search-forward title)
      (let (plain)
        (cl-letf (((symbol-function 'zwanenzang-comment)
                   (lambda () (ert-fail "Crossed a structural or scope boundary"))))
          (zwanenzang--org-add-note (lambda () (setq plain t)))
          (should plain))))
    (goto-char (point-min))
    (search-forward "new-doc")
    (should-error (org-add-note) :type 'user-error)))

(ert-deftest zwanenzang-comment-named-document-send-preserves-prose ()
  (zwanenzang-test-with-scope
      (tracker source "* Scope\n:PROPERTIES:\n:ZWANENZANG: %s\n:END:\n** TODO Ticket\nHuman description\n*** plan\n:PROPERTIES:\n:ZWANENZANG_DOC: plan\n:END:\nHuman plan\n")
    (goto-char (point-min))
    (zwanenzang-push)
    (let* ((id (zwanenzang-test-id-of "Ticket"))
           (before (zwanenzang-test-show tracker id)))
      (goto-char (point-min))
      (search-forward "Human description")
      (insert " locally edited")
      (search-forward "Human plan")
      (insert " locally edited")
      (org-add-note)
      (should (derived-mode-p 'zwanenzang-comment-mode))
      (insert "A comment from the plan")
      (zwanenzang-comment-send)
      (let ((after (zwanenzang-test-show tracker id)))
        (should (= 1 (length (alist-get 'comments after))))
        (should (equal "A comment from the plan"
                       (alist-get 'text (car (alist-get 'comments after)))))
        (should (equal (alist-get 'documents before) (alist-get 'documents after))))
      (with-current-buffer source
        (should (string-match-p "Human description locally edited" (buffer-string)))
        (should (string-match-p "Human plan locally edited" (buffer-string)))
        (goto-char (point-min))
        (search-forward "TODO Ticket")
        (should (string-match-p "A comment from the plan" (zwanenzang--body)))))))

(ert-deftest zwanenzang-comment-named-document-refuses-unsafe-owner ()
  (dolist (unsafe '(foreign duplicate malformed-document-id))
    (zwanenzang-test-with-scope
        (tracker source "* Scope\n:PROPERTIES:\n:ZWANENZANG: %s\n:END:\n** TODO Ticket\n*** plan\n:PROPERTIES:\n:ZWANENZANG_DOC: plan\n:END:\nPlan text\n")
      (goto-char (point-min))
      (zwanenzang-push)
      (let ((id (zwanenzang-test-id-of "Ticket"))
            (head (zwanenzang-test-head tracker)))
        (zwanenzang-test-goto id)
        (pcase unsafe
          ('foreign (org-entry-put nil "ZWANENZANG_ID" "foreign"))
          ('duplicate
           (zwanenzang-test-append
            (format "** TODO Copy\n:PROPERTIES:\n:ZWANENZANG_ID: %s\n:END:\n" id))))
        (goto-char (point-min))
        (search-forward "Plan text")
        (when (eq unsafe 'malformed-document-id)
          (org-entry-put nil "ZWANENZANG_ID" "malformed"))
        (save-window-excursion
          (unwind-protect
              (progn
                (org-add-note)
                (should (derived-mode-p 'zwanenzang-comment-mode))
                (insert "Must not be sent")
                (should-error (zwanenzang-comment-send) :type 'user-error)
                (should (equal head (zwanenzang-test-head tracker))))
            (when zwanenzang--comment-target (zwanenzang-comment-abort))))))))

(ert-deftest zwanenzang-comment-note-routing ()
  (with-temp-buffer
    (org-mode)
    (insert "* Outside\n* Scope\n:PROPERTIES:\n:ZWANENZANG: /tmp\n:END:\n** TODO Ticket\n:PROPERTIES:\n:ZWANENZANG_ID: ticket\n:END:\n** Structure\n** TODO New\n")
    (let ((plain 0) (comments 0))
      (cl-letf (((symbol-function 'zwanenzang-comment)
                 (lambda () (cl-incf comments))))
        (goto-char (point-min))
        (zwanenzang--org-add-note (lambda () (cl-incf plain)))
        (re-search-forward "TODO Ticket")
        (zwanenzang--org-add-note (lambda () (cl-incf plain)))
        (let ((current-prefix-arg '(4)))
          (zwanenzang--org-add-note (lambda () (cl-incf plain))))
        (let ((zwanenzang-redirect-org-notes nil))
          (zwanenzang--org-add-note (lambda () (cl-incf plain))))
        (re-search-forward "Structure")
        (zwanenzang--org-add-note (lambda () (cl-incf plain)))
        (should (= comments 1))
        (should (= plain 4)))
      (re-search-forward "TODO New")
      (should-error (org-add-note) :type 'user-error))))

(ert-deftest zwanenzang-comment-compose-send-and-abort ()
  (zwanenzang-test-with-scope
      (tracker source "* Scope\n:PROPERTIES:\n:ZWANENZANG: %s\n:END:\n** TODO Ticket\n")
    (goto-char (point-min))
    (zwanenzang-push)
    (goto-char (point-min))
    (re-search-forward "TODO Ticket")
    (let* ((id (org-entry-get nil "ZWANENZANG_ID"))
           (head (zwanenzang-test-head tracker)))
      (org-add-note)
      (should (derived-mode-p 'zwanenzang-comment-mode))
      (insert "Discard me")
      (zwanenzang-comment-abort)
      (should (equal head (zwanenzang-test-head tracker)))
      (pop-to-buffer source)
      (zwanenzang-test-goto id)
      (org-add-note)
      (let ((draft (current-buffer)))
        (should-error (zwanenzang-comment-send) :type 'user-error)
        (should (buffer-live-p draft))
        (insert "- A human comment with [[https://example.org][a link]].\n")
        ;; A refusal keeps text for retry.
        (let ((zwanenzang--call (lambda (&rest _) (user-error "refused"))))
          (should-error (zwanenzang-comment-send) :type 'user-error))
        (should (buffer-live-p draft))
        (zwanenzang-comment-send)
        (should-not (buffer-live-p draft)))
      (let ((comments (alist-get 'comments
                                 (zwanenzang-test-call tracker (list "show" id)))))
        (should (= 1 (length comments)))
        (should (string-prefix-p "- A human comment" (alist-get 'text (car comments)))))
      (with-current-buffer source
        (should (string-match-p "ZWANENZANG_COMMENTS" (buffer-string)))
        (should (string-match-p "A human comment" (buffer-string)))))))

(ert-deftest zwanenzang-comment-state-change-notes-untouched ()
  (with-temp-buffer
    (org-mode)
    (insert "* TODO Ticket\n:PROPERTIES:\n:ZWANENZANG: /tmp\n:ZWANENZANG_ID: ticket\n:END:\n")
    (goto-char (point-min))
    (let ((org-log-done 'note) logged)
      (cl-letf (((symbol-function 'org-add-log-setup)
                 (lambda (&rest args) (setq logged args)))
                ((symbol-function 'zwanenzang-comment)
                 (lambda () (ert-fail "State change redirected"))))
        (org-todo "DONE")
        (should logged)))))

(ert-deftest zwanenzang-comment-target-change-and-pull-failure ()
  (zwanenzang-test-with-scope
      (tracker source "* Scope\n:PROPERTIES:\n:ZWANENZANG: %s\n:END:\n** TODO Ticket\n")
    (goto-char (point-min))
    (zwanenzang-push)
    (re-search-forward "TODO Ticket")
    (let ((id (org-entry-get nil "ZWANENZANG_ID"))
          (head (zwanenzang-test-head tracker)))
      (zwanenzang-comment)
      (insert "Saved despite failed pull")
      (let* ((draft (current-buffer))
             (target zwanenzang--comment-target))
        (with-current-buffer source
          (goto-char (car target))
          (org-entry-put nil "ZWANENZANG_ID" "changed"))
        (should-error (zwanenzang-comment-send) :type 'user-error)
        (should (equal head (zwanenzang-test-head tracker)))
        (with-current-buffer source
          (goto-char (car target))
          (org-entry-put nil "ZWANENZANG_ID" id))
        (cl-letf (((symbol-function 'zwanenzang--pull-into)
                   (lambda (&rest _) (error "Pull unavailable"))))
          (zwanenzang-comment-send))
        (should-not (buffer-live-p draft)))
      (should (= 1 (length (alist-get 'comments
                                      (zwanenzang-test-call tracker (list "show" id))))))
      (with-current-buffer zwanenzang-report-buffer
        (should (string-match-p "Comment saved locally; pull failed" (buffer-string)))))))

(ert-deftest zwanenzang-comment-agenda-note-routing ()
  (with-temp-buffer
    (org-mode)
    (insert "* TODO Ticket\n:PROPERTIES:\n:ZWANENZANG: /tmp\n:ZWANENZANG_ID: ticket\n:END:\n")
    (goto-char (point-min))
    (let ((marker (point-marker)) called)
      (with-temp-buffer
        (org-agenda-mode)
        (let ((inhibit-read-only t))
          (insert (propertize "Ticket" 'org-marker marker)))
        (goto-char (point-min))
        (cl-letf (((symbol-function 'zwanenzang-comment)
                   (lambda () (setq called t))))
          (org-agenda-add-note)
          (should called))))))

(provide 'zwanenzang-comment-test)
;;; zwanenzang-comment-test.el ends here
