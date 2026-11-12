;;; zwanenzang-queue-test.el --- Native priority and org-ql queue tests -*- lexical-binding: t; -*-

;;; Code:
(require 'ert)
(require 'zwanenzang-queue)
(require 'zwanenzang-pull-test)
;; A test below binds `noninteractive' to nil around a remote file name. Load
;; Tramp now, while it is still t, so Tramp does not install its kill-emacs
;; hook, which would save a connection cache into the user's config directory.
(require 'tramp)
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

(ert-deftest zwanenzang-priority-remedy-uses-active-org-and-asks-before-visiting ()
  (dolist (settings '((65 90 70) (1 12 5)))
    (zwanenzang-test-with-org
        (format "#+PRIORITIES: %s %s %s\n* Scope\n"
                (if (= (car settings) 65) "A" "1")
                (if (= (car settings) 65) "Z" "12")
                (if (= (car settings) 65) "F" "5"))
      (goto-char (point-max))
      (org-back-to-heading)
      (let* ((root (point-marker))
             (before (buffer-string))
             (kill-ring nil)
             (noninteractive nil)
             (result '((tracker (id . "synthetic")
                                (priority (highest . 65) (lowest . 67) (default . 66)))))
             (refusal (zwanenzang--tracker-mismatch "push" root "/ssh:host:/tracker/" result))
             (expected (apply #'format "# 0..64 are numeric priorities; 65..90 are character codes A..Z.\n[priority]\nhighest = %d\nlowest = %d\ndefault = %d\n" settings))
             opened asked notice)
        (should (string-match-p (regexp-quote expected) refusal))
        (should (string-match-p "character codes A..Z" refusal))
        (should (string-match-p "Either align Org to the tracker values" refusal))
        (should (string-match-p "every user of the tracker" refusal))
        (should (string-match-p "save, commit and push in the tracker clone, then retry" refusal))
        (cl-letf (((symbol-function 'message)
                   (lambda (text &rest args) (setq notice (apply #'format text args))))
                  ((symbol-function 'y-or-n-p)
                   (lambda (prompt) (setq asked prompt notice nil) nil))
                  ((symbol-function 'find-file-other-window)
                   (lambda (file) (setq opened file))))
          (cl-letf (((symbol-function 'zwanenzang-report) (lambda (text) text)))
            (should (equal
                     (zwanenzang--report-outcome
                      "pushed" root (zwanenzang--outcome-create :refused refusal))
                     refusal)))
          (should (equal (car kill-ring) expected))
          (should (string-match-p "/ssh:host:/tracker/zwanenzang.toml" asked))
          (should (string-match-p "priority settings differ;.*copied to kill-ring" asked))
          (should-not opened)
          (should (string-match-p "copied to kill-ring (see \\*zwanenzang\\*)" notice))
          (should (string-match-p "save, commit and push, then retry" notice))
          (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) (setq notice nil) t)))
            (zwanenzang--offer-priority-remedy refusal))
          (should (equal opened "/ssh:host:/tracker/zwanenzang.toml"))
          (should (string-match-p "copied to kill-ring" notice)))
        (should (equal before (buffer-string)))
        ;; A tracker identity mismatch takes precedence and has no remedy.
        (org-entry-put root "ZWANENZANG_TRACKER" "other")
        (should-not (get-text-property
                     0 'zwanenzang-priority-remedy
                     (zwanenzang--tracker-mismatch "pull" root "/t" result)))))))

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
