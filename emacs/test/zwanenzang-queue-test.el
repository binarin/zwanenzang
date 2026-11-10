;;; zwanenzang-queue-test.el --- Native priority and org-ql queue tests -*- lexical-binding: t; -*-

;;; Code:
(require 'ert)
(require 'zwanenzang-queue)
(require 'zwanenzang-pull-test)
(declare-function org-ql--normalize-query "org-ql" t t)

(ert-deftest zwanenzang-priority-numeric-cookies-and-unset ()
  (zwanenzang-test-with-org "* TODO [#12] Numeric\n"
    (setq-local org-priority-highest 1 org-priority-lowest 12 org-priority-default 5)
    (should (= (plist-get (zwanenzang--heading) :priority) 12))
    (zwanenzang--set-heading "TODO" "Renamed" nil)
    (should (= (plist-get (zwanenzang--heading) :priority) 12))
    (zwanenzang--set-heading "TODO" "Renamed" nil 5)
    (should (= (plist-get (zwanenzang--heading) :priority) 5))
    (zwanenzang--set-heading "TODO" "Renamed" nil nil)
    (should-not (plist-get (zwanenzang--heading) :priority))
    (should (= (org-get-priority (org-get-heading))
               (org-get-priority "TODO [#5] Renamed")))))

(ert-deftest zwanenzang-priority-mismatched-settings-refuse-without-changing-them ()
  (zwanenzang-test-with-org "* Scope\n"
    (let* ((root (point-marker))
           (result '((tracker (id . "synthetic")
                              (priority (highest . 1) (default . 5) (lowest . 12))))))
      (should (string-match-p "align Org" (zwanenzang--tracker-mismatch "pull" root "/t" result)))
      (should (= org-priority-default ?B))
      (setq-local org-priority-highest 1 org-priority-lowest 12 org-priority-default 5)
      (should-not (zwanenzang--tracker-mismatch "push" root "/t" result)))))

(defun zwanenzang-queue-test--ticket (id priority activity waiting &optional tags)
  "Synthetic Org ticket ID with PRIORITY, ACTIVITY, WAITING and TAGS."
  (concat "** TODO " (if priority (format "[#%s] " priority) "") id
          " :" (or tags "needs_human") ":\n:PROPERTIES:\n:ZWANENZANG_ID: " id "\n"
          (and activity (concat ":ZWANENZANG_ACTIVITY: " activity "\n"))
          (and waiting (concat ":ZWANENZANG_TAG_SINCE: {\"needs_human\":{\"ts\":\"" waiting "\"}}\n"))
          ":END:\n"))

(defun zwanenzang-queue-test--ids ()
  "IDs in current queue order."
  (save-excursion
    (goto-char (point-min))
    (let (ids)
      (while (not (eobp))
        (when-let* ((identity (zwanenzang-queue--identity))) (push (cdr identity) ids))
        (forward-line 1))
      (nreverse ids))))

(ert-deftest zwanenzang-queue-real-org-ql-sorts-switches-and-never-writes ()
  (let ((source (generate-new-buffer "*zz-queue-source*"))
        (old "2026-01-01T00:00:00Z") (new "2026-02-01T00:00:00Z"))
    (unwind-protect
        (progn
          (with-current-buffer source
            (insert "#+TODO: TODO | DONE\n* Scope :needs_human:\n:PROPERTIES:\n:ZWANENZANG: /synthetic\n:END:\n"
                    (zwanenzang-queue-test--ticket "a" "A" new old)
                    (zwanenzang-queue-test--ticket "b" nil old new)
                    (zwanenzang-queue-test--ticket "c" "A" old new)
                    (zwanenzang-queue-test--ticket "d" "A" nil nil)
                    ;; Inherited attention must not imply queue membership.
                    (zwanenzang-queue-test--ticket "excluded" "A" old old "other")
                    "*** TODO Document :needs_human:\n:PROPERTIES:\n:ZWANENZANG_DOC: plan\n:END:\n"
                    (zwanenzang-queue-test--ticket "inactive" "A" old old)
                    (zwanenzang-queue-test--ticket "done" "A" old old))
            (org-mode)
            (goto-char (point-min))
            (search-forward ":ZWANENZANG_ID: inactive")
            (org-entry-put nil "ZWANENZANG_INACTIVE" "t")
            (search-forward ":ZWANENZANG_ID: done")
            (org-todo "DONE"))
          (let ((before (with-current-buffer source (buffer-string)))
                (zwanenzang--call (lambda (&rest _) (ert-fail "Queue called CLI"))))
            (save-window-excursion
              (zwanenzang-queue--render (list source) 'activity)
              (should (equal (zwanenzang-queue-test--ids) '("c" "a" "d" "b")))
              (goto-char (point-min))
              (while (not (equal (cdr (zwanenzang-queue--identity)) "a")) (forward-line 1))
              (zwanenzang-queue-select-age 'waiting)
              (should (eq zwanenzang-queue-age-mode 'waiting))
              (should (equal (cdr (zwanenzang-queue--identity)) "a"))
              (should (equal (zwanenzang-queue-test--ids) '("a" "c" "d" "b")))
              (should (string-match-p "waiting for human" header-line-format))
              (zwanenzang-queue-refresh)
              (should (equal (zwanenzang-queue-test--ids) '("a" "c" "d" "b"))))
            (should (equal before (with-current-buffer source (buffer-string))))))
      (kill-buffer source)
      (when (get-buffer "*zwanenzang queue*") (kill-buffer "*zwanenzang queue*")))))

(ert-deftest zwanenzang-queue-native-numeric-default-and-display ()
  (let ((source (generate-new-buffer "*zz-numeric-source*")))
    (unwind-protect
        (progn
          (with-current-buffer source
            (insert "#+TODO: TODO | DONE\n#+PRIORITIES: 1 12 5\n* Scope\n:PROPERTIES:\n:ZWANENZANG: /synthetic\n:END:\n"
                    (zwanenzang-queue-test--ticket "low" "12" "2026-01-01T00:00:00Z" nil)
                    (zwanenzang-queue-test--ticket "default" nil "2026-02-01T00:00:00Z" nil))
            (org-mode))
          (save-window-excursion
            (zwanenzang-queue--render (list source) 'activity)
            (should (equal (zwanenzang-queue-test--ids) '("default" "low")))
            (should (string-match-p (regexp-quote "[#12]") (buffer-string)))))
      (kill-buffer source)
      (when (get-buffer "*zwanenzang queue*") (kill-buffer "*zwanenzang queue*")))))

(ert-deftest zwanenzang-queue-age-unknown-and-future-are-visible ()
  (should (equal (zwanenzang-queue--age nil) "unknown"))
  (should (equal (zwanenzang-queue--age "invalid") "unknown"))
  (should (equal (zwanenzang-queue--age "2999-01-01T00:00:00Z") "future clock")))

(provide 'zwanenzang-queue-test)
;;; zwanenzang-queue-test.el ends here
