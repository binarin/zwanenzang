;;; zwanenzang-new-comment-test.el --- New comments from pulls  -*- lexical-binding: t; -*-

;;; Commentary:

;; Comments a pull brings are remembered for the session: the report
;; names them, ticket headings get a fringe mark and the navigation
;; commands step through them.  These tests drive the real CLI against
;; disposable trackers.

;;; Code:

(require 'ert)
(require 'zwanenzang)
(require 'zwanenzang-test-helpers)

(defconst zwanenzang-test--new-comment-org
  (concat "#+TODO: TODO NEXT WAIT | DONE CNCL\n"
          "* Project\n"
          ":PROPERTIES:\n"
          ":ZWANENZANG: %s\n"
          ":ZWANENZANG_KEYWORDS: TODO=next,todo NEXT=agnt,revw WAIT=wait"
          " DONE=done CNCL=cncl\n"
          ":END:\n")
  "An Org file with one scope; %s is the tracker.")

(defun zwanenzang-test--display (dir id)
  "The display number of ticket ID in the tracker DIR."
  (alist-get 'display (zwanenzang-test-show dir id)))

(defvar zwanenzang-test--message nil
  "The last message a new-comment command showed.")

(defun zwanenzang-test--next-comment (&optional backward)
  "Run the next (or, when BACKWARD, previous) new-comment command as a key would.
Record its last message in `zwanenzang-test--message' and return the
text of the comment at point, the line after its header."
  (let* ((command (if backward #'zwanenzang-previous-new-comment
                    #'zwanenzang-next-new-comment))
         (this-command command))
    (setq zwanenzang-test--message nil)
    (cl-letf (((symbol-function 'message)
               (lambda (format &rest args)
                 (setq zwanenzang-test--message (apply #'format-message format args)))))
      (funcall command))
    (setq last-command command)
    (zwanenzang-test--comment-at-point)))

(defun zwanenzang-test--comment-at-point ()
  "The first text line of the comment whose header point is on, or nil.
The line is without the indentation that makes it the item's text."
  (when (looking-at "^- \\[[^]\n]+\\] [^\n]*:$")
    (save-excursion
      (forward-line 1)
      (string-remove-prefix
       "  " (buffer-substring-no-properties (point) (line-end-position))))))

(defun zwanenzang-test--marked-headings ()
  "The ZWANENZANG_IDs of the headings carrying a new-comment fringe mark."
  (let (ids)
    (dolist (overlay (overlays-in (point-min) (point-max)))
      (when (overlay-get overlay 'zwanenzang-new-comment)
        (save-excursion
          (goto-char (overlay-start overlay))
          (should (org-at-heading-p))
          (should (equal (get-text-property 0 'display (overlay-get overlay 'before-string))
                         '(left-fringe zwanenzang-new-comment zwanenzang-new-comment-fringe)))
          (push (org-entry-get nil "ZWANENZANG_ID") ids))))
    (sort ids #'string<)))

(defun zwanenzang-test--new-comment-texts ()
  "The texts of the new comments in the current buffer, in buffer order."
  (save-excursion
    (goto-char (point-min))
    (let (texts)
      (dolist (state zwanenzang--new-comment-scopes)
        (dolist (target (zwanenzang--new-comment-targets state))
          (goto-char (car target))
          (push (cons (car target) (zwanenzang-test--comment-at-point)) texts)))
      (mapcar #'cdr (sort texts :key #'car)))))

(ert-deftest zwanenzang-new-comments-summary-groups-by-ticket ()
  (should-not (zwanenzang--new-comments-summary nil))
  (should (equal "1 new comment: ZZ-7" (zwanenzang--new-comments-summary '("ZZ-7"))))
  (should (equal "4 new comments: ZZ-2 (2), ZZ-10, 01ABCDEFGH"
                 (zwanenzang--new-comments-summary '("ZZ-10" "01ABCDEFGH" "ZZ-2" "ZZ-2")))))

;; The newest comment comes first in the drawer, as a pull writes it.
(defconst zwanenzang-test--quoting-records
  '(("new" . "- [2026-11-13T00:00:01Z] Agent:\n  Quoting the old header:\n  - [2026-11-13T00:00:00Z] Agent:\n  quoted prose\n")
    ("old" . "- [2026-11-13T00:00:00Z] Agent:\n  Actual old comment\n"))
  "Two comment records, the newer quoting the older's header line.")

(defconst zwanenzang-test--same-header-records
  '(("b" . "- [2026-11-13T00:00:00Z] Agent:\n  Second\n  - [2026-11-13T00:00:00Z] Agent:\n  not a comment\n")
    ("a" . "- [2026-11-13T00:00:00Z] Agent:\n  First\n"))
  "Two comment records with one header, the newer repeating it in its text.")

(defun zwanenzang-test--record-text (records id &optional edit)
  "The first text line of comment ID, found among RECORDS in a drawer.
The drawer holds RECORDS, passed through EDIT when given."
  (with-temp-buffer
    (org-mode)
    (insert "* Ticket\n:ZWANENZANG_COMMENTS:\n"
            (funcall (or edit #'identity) (mapconcat #'cdr records ""))
            ":END:\n")
    (let ((pos (zwanenzang--comment-position 1 records id)))
      (when pos
        (goto-char pos)
        (forward-line 1)
        (string-remove-prefix
         "  " (buffer-substring-no-properties (point) (line-end-position)))))))

(ert-deftest zwanenzang-new-comment-position-takes-whole-records ()
  (should (equal "Actual old comment"
                 (zwanenzang-test--record-text zwanenzang-test--quoting-records "old")))
  (should (equal "Quoting the old header:"
                 (zwanenzang-test--record-text zwanenzang-test--quoting-records "new")))
  (should (equal "First"
                 (zwanenzang-test--record-text zwanenzang-test--same-header-records "a")))
  (should (equal "Second"
                 (zwanenzang-test--record-text zwanenzang-test--same-header-records "b")))
  ;; Text the human added in the drawer moves records; they are still found.
  (should (equal "Actual old comment"
                 (zwanenzang-test--record-text zwanenzang-test--quoting-records "old"
                                               (lambda (s) (concat "A note of mine\n" s)))))
  ;; A record the drawer lost is skipped, not matched elsewhere.
  (should-not (zwanenzang-test--record-text
               zwanenzang-test--quoting-records "old"
               (lambda (s) (replace-regexp-in-string "Actual old comment\n" "" s)))))

(ert-deftest zwanenzang-new-comments-quoting-a-header-land-on-the-real-comment ()
  (zwanenzang-test-with-scope (trk buf zwanenzang-test--new-comment-org)
    (let ((id (zwanenzang-test-create trk "Ticket")))
      (zwanenzang-test-pull)
      (zwanenzang-test-cli trk "comment" id "Quoted one")
      (let* ((old (car (alist-get 'comments (zwanenzang-test-show trk id))))
             (header (format "- [%s] tester:" (alist-get 'ts old))))
        (zwanenzang-test-cli trk "comment" id (format "Replying to\n%s\nQuoted one" header))
        (zwanenzang-test-cli trk "comment" id (format "Again\n%s\nQuoted one" header)))
      (zwanenzang-test-pull)
      (should (equal '("Again" "Replying to" "Quoted one") (zwanenzang-test--new-comment-texts)))
      (goto-char (point-min))
      (should (equal "Again" (zwanenzang-test--next-comment)))
      (should (equal "Replying to" (zwanenzang-test--next-comment)))
      (should (equal "Quoted one" (zwanenzang-test--next-comment))))))

(ert-deftest zwanenzang-new-comments-first-pull-and-new-tickets-are-the-baseline ()
  (zwanenzang-test-with-scope (trk buf zwanenzang-test--new-comment-org)
    (let ((old (zwanenzang-test-create trk "Old")))
      (zwanenzang-test-cli trk "comment" old "Already there")
      (zwanenzang-test-clear-report)
      (should-not (string-match-p "new comment" (zwanenzang-test-pull)))
      (should-not (zwanenzang-test--new-comment-texts))
      (should-not (zwanenzang-test--marked-headings))
      ;; A ticket appearing in the scope brings its comments with it.
      (let ((later (zwanenzang-test-create trk "Later")))
        (zwanenzang-test-cli trk "comment" later "Came with the ticket")
        (should-not (string-match-p "new comment" (zwanenzang-test-pull)))
        (should-not (zwanenzang-test--new-comment-texts)))
      (goto-char (point-min))
      (let ((start (point)))
        (should-not (zwanenzang-test--next-comment))
        (should (= start (point)))
        (should (equal "No further new comment" zwanenzang-test--message))))))

(ert-deftest zwanenzang-new-comments-are-reported-marked-and-navigated ()
  (zwanenzang-test-with-scope (trk buf zwanenzang-test--new-comment-org)
    (let ((first (zwanenzang-test-create trk "First"))
          (second (zwanenzang-test-create trk "Second"))
          (quiet (zwanenzang-test-create trk "Quiet")))
      (zwanenzang-test-cli trk "comment" first "Old comment")
      (zwanenzang-test-pull)
      (zwanenzang-test-cli trk "comment" first "First new")
      (zwanenzang-test-cli trk "comment" first "Second new")
      (zwanenzang-test-cli trk "comment" second "Third new")
      (zwanenzang-test-clear-report)
      (let ((summary (zwanenzang-test-pull)))
        (should (string-match-p
                 (regexp-quote (format "3 new comments: %s (2), %s"
                                       (zwanenzang-test--display trk first)
                                       (zwanenzang-test--display trk second)))
                 summary))
        (should (string-match-p "new comments" (zwanenzang-test-report))))
      (should (equal (sort (list first second) #'string<) (zwanenzang-test--marked-headings)))
      (should-not (member quiet (zwanenzang-test--marked-headings)))
      ;; Everything folded: navigation reveals the ticket and its comments
      ;; drawer only.
      (org-overview)
      (org-fold-hide-drawer-all)
      (goto-char (point-min))
      (let ((modified (buffer-modified-p))
            (head (zwanenzang-test-head trk))
            (next-error-last-buffer nil))
        (should (equal "Second new" (zwanenzang-test--next-comment)))
        (should-not (org-invisible-p))
        (save-excursion
          (zwanenzang-test-goto first)
          (should-not (nth 2 (assoc "ZWANENZANG_COMMENTS" (zwanenzang--drawer-visibility))))
          (should (nth 2 (assoc "PROPERTIES" (zwanenzang--drawer-visibility)))))
        (save-excursion
          (zwanenzang-test-goto quiet)
          (should (org-invisible-p)))
        (should (equal "First new" (zwanenzang-test--next-comment)))
        ;; Anywhere on a comment's first line is on that comment.
        (end-of-line)
        (should (equal "Third new" (zwanenzang-test--next-comment)))
        (let ((at (point)))
          (zwanenzang-test--next-comment)
          (should (= at (point)))
          (should (equal "No further new comment" zwanenzang-test--message)))
        ;; Repeating the command wraps.
        (should (equal "Second new" (zwanenzang-test--next-comment)))
        (should (string-match-p "wrapped back to beginning" zwanenzang-test--message))
        (forward-char 3)
        (let ((at (point)))
          (zwanenzang-test--next-comment t)
          (should (= at (point)))
          (should (equal "No further new comment" zwanenzang-test--message)))
        (should (equal "Third new" (zwanenzang-test--next-comment t)))
        (should (string-match-p "wrapped back to end" zwanenzang-test--message))
        (should (equal "First new" (zwanenzang-test--next-comment t)))
        ;; Navigation writes nothing and leaves next-error alone.
        (should (eq modified (buffer-modified-p)))
        (should (equal head (zwanenzang-test-head trk)))
        (should-not next-error-last-buffer))
      ;; A pull bringing nothing keeps the set; one bringing comments
      ;; replaces it.
      (zwanenzang-test-pull)
      (should (equal '("Second new" "First new" "Third new") (zwanenzang-test--new-comment-texts)))
      (zwanenzang-test-cli trk "comment" quiet "Replacement")
      (should (string-match-p (regexp-quote (format "1 new comment: %s"
                                                    (zwanenzang-test--display trk quiet)))
                              (zwanenzang-test-pull)))
      (should (equal '("Replacement") (zwanenzang-test--new-comment-texts)))
      (should (equal (list quiet) (zwanenzang-test--marked-headings)))
      (zwanenzang-clear-new-comments)
      (should-not (zwanenzang-test--new-comment-texts))
      (should-not (zwanenzang-test--marked-headings)))))

(ert-deftest zwanenzang-new-comments-survive-body-rewrites-and-moves ()
  (zwanenzang-test-with-scope (trk buf zwanenzang-test--new-comment-org)
    (let ((parent (zwanenzang-test-create trk "Parent"))
          (child (zwanenzang-test-create trk "Child")))
      (zwanenzang-test-pull)
      (zwanenzang-test-cli trk "comment" child "Moved along")
      (zwanenzang-test-pull)
      (should (equal '("Moved along") (zwanenzang-test--new-comment-texts)))
      ;; The tracker moves the ticket and rewrites its body; the comment
      ;; is still found.
      (zwanenzang-test-cli trk "parent" child parent)
      (zwanenzang-test-set-doc trk child "description" "A new description\n")
      (zwanenzang-test-pull)
      (should (equal "Parent" (zwanenzang-test-parent-heading child)))
      (should (equal '("Moved along") (zwanenzang-test--new-comment-texts)))
      (should (equal (list child) (zwanenzang-test--marked-headings)))
      ;; Human text above moves everything too.
      (goto-char (point-min))
      (insert "Some notes\n")
      (should (equal "Moved along" (zwanenzang-test--next-comment)))
      ;; A heading that left the scope is skipped.
      (zwanenzang-test-goto child)
      (org-cut-subtree)
      (should-not (zwanenzang-test--new-comment-texts))
      (goto-char (point-min))
      (should-not (zwanenzang-test--next-comment)))))

(ert-deftest zwanenzang-new-comments-after-a-reset-are-only-the-late-ones ()
  (zwanenzang-test-with-scope (trk buf zwanenzang-test--new-comment-org)
    (let* ((id (zwanenzang-test-create trk "Ticket"))
           (base (alist-get 'last_event (zwanenzang-test-show trk id))))
      (zwanenzang-test-pull)
      (zwanenzang-test-cli trk "comment" id "Middle comment")
      (zwanenzang-test-cli trk "comment" id "Newest comment")
      (zwanenzang-test-pull)
      (should (equal '("Newest comment" "Middle comment") (zwanenzang-test--new-comment-texts)))
      (let ((actor "00000000000000000000000001"))
        (zwanenzang-test-append-raw
         trk actor
         (json-serialize `((id . ,(zwanenzang-test-ulid-next base)) (actor . ,actor)
                           (parent . ,base) (ts . "2026-11-07T00:00:00Z") (entity . ,id)
                           (op . "comment") (data . ((text . "Late older comment")))))))
      (zwanenzang-test-clear-report)
      (should (string-match-p "1 new comment:" (zwanenzang-test-pull)))
      (should (string-match-p "compared in full" (zwanenzang-test-report)))
      (should (equal '("Late older comment") (zwanenzang-test--new-comment-texts))))))

(ert-deftest zwanenzang-new-comments-leave-out-what-this-session-sent ()
  (save-window-excursion
    (zwanenzang-test-with-scope (trk buf zwanenzang-test--new-comment-org)
      (let ((id (zwanenzang-test-create trk "Ticket")))
        (zwanenzang-test-pull)
        ;; Another actor's comment arrives with the follow-up pull of a send.
        (zwanenzang-test-cli trk "comment" id "From an agent")
        (zwanenzang-test-goto id)
        (zwanenzang-comment)
        (insert "From this Emacs")
        (let ((event (zwanenzang-comment-send)))
          (should (gethash event zwanenzang--sent-comments)))
        (set-buffer buf)
        (should (string-match-p "1 new comment:" (zwanenzang-test-report)))
        (should (equal '("From an agent") (zwanenzang-test--new-comment-texts)))
        ;; A send whose pull failed is still this session's own.
        (zwanenzang-test-goto id)
        (zwanenzang-comment)
        (insert "Sent while pull failed")
        (cl-letf (((symbol-function 'zwanenzang--pull-into)
                   (lambda (&rest _) (error "Pull unavailable"))))
          (zwanenzang-comment-send))
        (set-buffer buf)
        (should-not (string-match-p "new comment" (zwanenzang-test-pull)))
        (should (string-match-p "Sent while pull failed" (zwanenzang-test-entry id)))
        (should (equal '("From an agent") (zwanenzang-test--new-comment-texts)))))))

(ert-deftest zwanenzang-new-comments-collect-every-pull-of-one-sync ()
  (zwanenzang-test-with-scope (trk buf zwanenzang-test--new-comment-org)
    (let ((id (zwanenzang-test-create trk "Ticket")))
      (zwanenzang-test-pull)
      (zwanenzang-test-cli trk "comment" id "Before the sync")
      (zwanenzang-test-pull)
      (should (equal '("Before the sync") (zwanenzang-test--new-comment-texts)))
      (zwanenzang-test-cli trk "comment" id "Seen by the first pull")
      (let ((push (symbol-function 'zwanenzang--push-scope)))
        (cl-letf (((symbol-function 'zwanenzang--push-scope)
                   (lambda (&rest args)
                     ;; Arrives between the sync's own pull and push's pull.
                     (zwanenzang-test-cli trk "comment" id "Seen by the push's pull")
                     (apply push args))))
          (zwanenzang-test-clear-report)
          (zwanenzang-test-at-root #'zwanenzang-sync)))
      (should (string-match-p "2 new comments:" (zwanenzang-test-report)))
      (should (equal '("Seen by the push's pull" "Seen by the first pull")
                     (zwanenzang-test--new-comment-texts))))))

(ert-deftest zwanenzang-new-comments-are-per-scope-and-cleared-per-buffer ()
  (zwanenzang-test-with-scope (trk buf zwanenzang-test--new-comment-org)
    (zwanenzang-test-with-tracker other
      (zwanenzang-test-with-dir elsewhere
        (zwanenzang-test-append (format "* Other\n:PROPERTIES:\n:ZWANENZANG: %s\n:END:\n" other))
        (let* ((a (zwanenzang-test-create trk "In A"))
               (b (zwanenzang-test-create other "In B"))
               (file (expand-file-name "third.org" elsewhere))
               (third (progn (with-temp-file file
                               (insert (format zwanenzang-test--new-comment-org trk)))
                             (find-file-noselect file))))
          (unwind-protect
              (cl-flet ((pull-b ()
                          (save-excursion
                            (goto-char (point-min))
                            (re-search-forward "^\\* Other")
                            (zwanenzang-pull))))
                (zwanenzang-test-pull)
                (pull-b)
                (with-current-buffer third (zwanenzang-test-pull))
                (zwanenzang-test-cli trk "comment" a "Comment in A")
                (zwanenzang-test-cli other "comment" b "Comment in B")
                (zwanenzang-test-pull)
                (with-current-buffer third (zwanenzang-test-pull))
                (pull-b)
                (should (equal '("Comment in A" "Comment in B")
                               (zwanenzang-test--new-comment-texts)))
                ;; A new set for B leaves A's alone.
                (zwanenzang-test-cli other "comment" b "Again in B")
                (pull-b)
                (should (equal '("Comment in A" "Again in B")
                               (zwanenzang-test--new-comment-texts)))
                (should (equal (sort (list a b) #'string<) (zwanenzang-test--marked-headings)))
                ;; Clearing takes this buffer only, unless prefixed.
                (zwanenzang-clear-new-comments)
                (should-not (zwanenzang-test--new-comment-texts))
                (should-not (zwanenzang-test--marked-headings))
                (with-current-buffer third
                  (should (equal '("Comment in A") (zwanenzang-test--new-comment-texts))))
                (zwanenzang-clear-new-comments t)
                (with-current-buffer third
                  (should-not (zwanenzang-test--new-comment-texts))
                  (should-not (zwanenzang-test--marked-headings))))
            (with-current-buffer third (set-buffer-modified-p nil))
            (kill-buffer third)))))))

(provide 'zwanenzang-new-comment-test)
;;; zwanenzang-new-comment-test.el ends here
