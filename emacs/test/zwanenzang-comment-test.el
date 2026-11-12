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
        (let ((zwanenzang--call (lambda (&rest _) (user-error "refused")))
              (compose-windows (current-window-configuration)))
          (should-error (zwanenzang-comment-send) :type 'user-error)
          (should (window-configuration-equal-p
                   compose-windows (current-window-configuration)))
          (should (eq draft (window-buffer (selected-window)))))
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

(defun zwanenzang-test-comment-restores-windows (finish)
  "Check FINISH restores the pre-compose layout and preserves human text."
  (zwanenzang-test-with-scope
      (tracker source "* Scope\n:PROPERTIES:\n:ZWANENZANG: %s\n:END:\n** TODO Ticket\nOriginal description\n")
    (goto-char (point-min))
    (zwanenzang-push)
    (re-search-forward "Original description")
    (insert " with an unsynced human edit")
    (re-search-backward "TODO Ticket")
    (let ((id (org-entry-get nil "ZWANENZANG_ID"))
          (side (generate-new-buffer " *comment side*")))
      (unwind-protect
          (dolist (layout '(single distinct duplicate same-window agenda))
            (ert-info ((format "Layout: %s" layout))
              (save-window-excursion
                (delete-other-windows)
                (switch-to-buffer source)
                (zwanenzang-test-goto id)
                (end-of-line)
                (unless (eq layout 'single)
                  (cond
                   ((eq layout 'agenda) (switch-to-buffer side))
                   ((memq layout '(distinct duplicate))
                    (set-window-buffer (split-window-right)
                                       (if (eq layout 'duplicate) source side)))))
                ;; Normalize batch Emacs's initially zero-height minibuffer.
                (set-window-configuration (current-window-configuration))
                (let ((before (current-window-configuration))
                      (points (mapcar #'window-point (window-list)))
                      (source-point (with-current-buffer source (point)))
                      (text (with-current-buffer source (buffer-string)))
                      (head (zwanenzang-test-head tracker))
                      (display-buffer-overriding-action
                       (if (eq layout 'same-window)
                           '(display-buffer-same-window)
                         '(display-buffer-pop-up-window)))
                      (split-height-threshold 0)
                      (split-width-threshold nil)
                      draft)
                  (unwind-protect
                      (progn
                        ;; Like agenda note routing, the current source buffer
                        ;; need not be the selected window's buffer.
                        (with-current-buffer source (zwanenzang-comment))
                        (setq draft (window-buffer (selected-window)))
                        (with-current-buffer draft
                          (insert "A comment\n")
                          (funcall finish))
                        (should-not (buffer-live-p draft))
                        (should (window-configuration-equal-p
                                 before (current-window-configuration)))
                        (should (equal points (mapcar #'window-point (window-list))))
                        (should (= source-point (with-current-buffer source (point))))
                        (with-current-buffer source
                          (should (string-match-p "Original description with an unsynced human edit"
                                                  (buffer-string))))
                        (when (eq finish #'zwanenzang-comment-abort)
                          (should (equal text (with-current-buffer source (buffer-string))))
                          (should (equal head (zwanenzang-test-head tracker)))))
                    (when (buffer-live-p draft)
                      (with-current-buffer draft (set-buffer-modified-p nil))
                      (kill-buffer draft)))))))
        (kill-buffer side))
      (let ((ticket (zwanenzang-test-show tracker id)))
        (should (= (length (alist-get 'comments ticket))
                   (if (eq finish #'zwanenzang-comment-send) 5 0)))))))

(ert-deftest zwanenzang-comment-abort-restores-windows ()
  (zwanenzang-test-comment-restores-windows #'zwanenzang-comment-abort))

(ert-deftest zwanenzang-comment-send-restores-windows ()
  (zwanenzang-test-comment-restores-windows #'zwanenzang-comment-send))

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
      (set-window-configuration (current-window-configuration))
      (let ((windows (current-window-configuration)))
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
        (should (window-configuration-equal-p windows (current-window-configuration))))
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

(ert-deftest zwanenzang-comment-send-renders-newest-first-and-keeps-human-edits ()
  (save-window-excursion
    (zwanenzang-test-with-scope
        (tracker source "* Scope\n:PROPERTIES:\n:ZWANENZANG: %s\n:END:\n** TODO Ticket\nDescription\n*** plan\n:PROPERTIES:\n:ZWANENZANG_DOC: plan\n:END:\nPlan text\n")
      (goto-char (point-min))
      (zwanenzang-push)
      (re-search-forward "TODO Ticket")
      (let ((id (org-entry-get nil "ZWANENZANG_ID")))
        (zwanenzang-test-cli tracker "comment" id "Oldest comment")
        (zwanenzang-test-cli tracker "comment" id "Middle comment")
        (zwanenzang-test-pull)
        (goto-char (point-min))
        (re-search-forward "^Description$")
        (insert " locally edited")
        (re-search-forward "^Plan text$")
        (insert " locally edited")
        (zwanenzang-test-goto id)
        (org-add-note)
        (insert "Newest comment")
        (zwanenzang-comment-send)
        (with-current-buffer source
          ;; The accepted send already pulled; no separate sync is needed.
          (let ((entry (zwanenzang-test-entry id)))
            (should (< (string-match "Newest comment" entry)
                       (string-match "Middle comment" entry)))
            (should (< (string-match "Middle comment" entry)
                       (string-match "Oldest comment" entry))))
          (should (string-match-p "Description locally edited" (buffer-string)))
          (should (string-match-p "Plan text locally edited" (buffer-string)))
          (let ((before (buffer-string))
                (head (zwanenzang-test-head tracker)))
            (zwanenzang-test-pull)
            (should (equal before (buffer-string)))
            (should (equal head (zwanenzang-test-head tracker)))))
        ;; Sending a comment did not publish either unrelated human edit.
        (should (equal "Description\n"
                       (alist-get 'text (zwanenzang-test-cli
                                         tracker "doc" "get" id "description"))))
        (should (equal "Plan text\n"
                       (alist-get 'text (zwanenzang-test-cli
                                         tracker "doc" "get" id "plan"))))
        (should (equal '("Oldest comment" "Middle comment" "Newest comment")
                       (mapcar (lambda (c) (alist-get 'text c))
                               (alist-get 'comments (zwanenzang-test-show tracker id)))))))))

(provide 'zwanenzang-comment-test)
;;; zwanenzang-comment-test.el ends here
