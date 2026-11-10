;;; zwanenzang-comment-test.el --- Comment composition tests -*- lexical-binding: t; -*-

(require 'zwanenzang-test-helpers)
(require 'org-agenda)

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

(provide 'zwanenzang-comment-test)
;;; zwanenzang-comment-test.el ends here
