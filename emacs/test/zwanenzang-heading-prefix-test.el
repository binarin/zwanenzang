;;; zwanenzang-heading-prefix-test.el --- The ticket number prefix on headings  -*- lexical-binding: t; -*-

;;; Commentary:

;; The client writes "[ZZ-42]" after the keyword and priority cookie of a
;; numbered ticket's heading and strips it again before the title is
;; compared, hashed or pushed.  Parsing and writing need no CLI; the
;; round trips run against the real one.

;;; Code:

(require 'ert)
(require 'zwanenzang)
(require 'zwanenzang-test-helpers)
(require 'zwanenzang-pull-test)
(require 'zwanenzang-push-integration-test)

(defun zwanenzang-test--line ()
  "The heading line at point, without text properties."
  (save-excursion
    (org-back-to-heading t)
    (buffer-substring-no-properties (line-beginning-position) (line-end-position))))

(defun zwanenzang-test--numbered (headline &optional number)
  "Org text with one ticket heading HEADLINE numbered NUMBER, or ZZ-3."
  (concat "#+TODO: TODO NEXT | DONE\n* " headline "\n:PROPERTIES:\n"
          ":ZWANENZANG_ID: synthetic\n:ZWANENZANG_NUMBER: " (or number "ZZ-3")
          "\n:END:\nBody\n"))

;;;; Parsing

(ert-deftest zwanenzang-prefix-split-recognizes-only-a-leading-token ()
  (dolist (case '(("[ZZ-3] Title" "[ZZ-3]" "Title")
                  ;; Padded, stale, malformed or retyped in lower case.
                  ("[ZZ-0003] Title" "[ZZ-0003]" "Title")
                  ("[ZZ-9] Title" "[ZZ-9]" "Title")
                  ("[ZZ-] Title" "[ZZ-]" "Title")
                  ("[ZZ-3x]  Title" "[ZZ-3x]" "Title")
                  ("[zz-3] Title" "[zz-3]" "Title")
                  ("[ZZ-3]" "[ZZ-3]" "")
                  ;; Human text: another tracker's prefix, no blank after
                  ;; the token, a statistics cookie, the token later on.
                  ("[AB-3] Title" nil "[AB-3] Title")
                  ("[ZZ-3]Title" nil "[ZZ-3]Title")
                  ("[1/2] Title" nil "[1/2] Title")
                  ("Fix [ZZ-3] later" nil "Fix [ZZ-3] later")
                  ("[ZZ 3] Title" nil "[ZZ 3] Title")))
    (should (equal (zwanenzang--split-number-prefix (car case) "ZZ-3")
                   (cons (nth 1 case) (nth 2 case)))))
  ;; Without a number nothing is a prefix.
  (should (equal (zwanenzang--split-number-prefix "[ZZ-3] Title" nil)
                 '(nil . "[ZZ-3] Title")))
  ;; A tracker prefix with a dash in it.
  (should (equal (zwanenzang--split-number-prefix "[MY-APP-7] Title" "MY-APP-12")
                 '("[MY-APP-7]" . "Title"))))

(ert-deftest zwanenzang-prefix-is-left-out-of-the-title ()
  (zwanenzang-test-with-org
      (zwanenzang-test--numbered "TODO [#A] COMMENT [ZZ-3] [1/2] Title :tag:")
    (outline-next-heading)
    (should (equal (zwanenzang--heading)
                   '(:keyword "TODO" :priority 65 :title "[1/2] Title" :tags ("tag"))))
    (should (equal (zwanenzang--shown-prefix) "[ZZ-3]")))
  ;; An unnumbered heading's title is all text.
  (zwanenzang-test-with-org "* TODO [ZZ-3] Title\n"
    (outline-next-heading)
    (should (equal (plist-get (zwanenzang--heading) :title) "[ZZ-3] Title"))))

;;;; Writing

(ert-deftest zwanenzang-set-heading-writes-the-prefix-after-the-cookie ()
  (zwanenzang-test-with-org (zwanenzang-test--numbered "TODO [#A] COMMENT Title [1/2] :a:")
    (outline-next-heading)
    (zwanenzang--set-heading "TODO" "Title [1/2]" '("a"))
    (should (string-match-p "\\`\\* TODO \\[#A\\] COMMENT \\[ZZ-3\\] Title \\[1/2\\] +:a:\\'"
                            (zwanenzang-test--line)))
    (should (equal (plist-get (zwanenzang--heading) :title) "Title [1/2]"))
    ;; Already right: no edit at all.
    (let ((tick (buffer-modified-tick)))
      (zwanenzang--set-heading "TODO" "Title [1/2]" '("a"))
      (should (= tick (buffer-modified-tick))))
    ;; Org's own statistics update leaves prefix and title alone.
    (goto-char (point-max))
    (insert "** DONE Child\n** TODO Other\n")
    (goto-char (point-min))
    (outline-next-heading)
    (org-update-statistics-cookies nil)
    (should (string-match-p "\\[ZZ-3\\] Title \\[1/2\\]" (zwanenzang-test--line)))
    (should (equal (plist-get (zwanenzang--heading) :title) "Title [1/2]"))))

(ert-deftest zwanenzang-set-heading-restores-an-edited-or-removed-prefix ()
  (dolist (headline '("TODO Title" "TODO [ZZ-9] Title" "TODO [ZZ-0003] Title"
                      "TODO [ZZ-] Title"))
    (zwanenzang-test-with-org (zwanenzang-test--numbered headline)
      (outline-next-heading)
      (should (equal (plist-get (zwanenzang--heading) :title) "Title"))
      (zwanenzang--set-heading "TODO" "Title" nil)
      (should (equal (zwanenzang-test--line) "* TODO [ZZ-3] Title")))))

(ert-deftest zwanenzang-set-heading-without-a-number-writes-no-prefix ()
  (zwanenzang-test-with-org "* TODO Title\n:PROPERTIES:\n:ZWANENZANG_ID: synthetic\n:END:\n"
    (outline-next-heading)
    (zwanenzang--set-heading "NEXT" "Title" nil)
    (should (equal (zwanenzang-test--line) "* NEXT Title"))))

(ert-deftest zwanenzang-set-heading-keeps-a-title-that-looks-like-a-prefix ()
  ;; The tracker title itself starts with a token of the same shape.
  (dolist (zwanenzang-heading-number-prefix '(t nil))
    (zwanenzang-test-with-org (zwanenzang-test--numbered "TODO Title")
      (outline-next-heading)
      (zwanenzang--set-heading "TODO" "[ZZ-5] Title" nil)
      (should (equal (zwanenzang-test--line) "* TODO [ZZ-3] [ZZ-5] Title"))
      (should (equal (plist-get (zwanenzang--heading) :title) "[ZZ-5] Title")))))

(ert-deftest zwanenzang-set-heading-turned-off-removes-the-prefix ()
  (let ((zwanenzang-heading-number-prefix nil))
    (zwanenzang-test-with-org (zwanenzang-test--numbered "TODO [ZZ-3] Title")
      (outline-next-heading)
      (zwanenzang--set-heading "TODO" "Title" nil)
      (should (equal (zwanenzang-test--line) "* TODO Title")))))

(ert-deftest zwanenzang-detached-copies-lose-the-prefix ()
  (zwanenzang-test-with-org (zwanenzang-test--numbered "TODO [ZZ-3] Title :zz_conflict:")
    (outline-next-heading)
    (zwanenzang--detach-entry)
    (should (equal (zwanenzang-test--line) "* Title")))
  ;; Adoption clears another tracker's number; its prefix goes with it.
  (zwanenzang-test-with-org (zwanenzang-test--numbered "TODO [OTHER-0042] Title"
                                                       "OTHER-0042")
    (outline-next-heading)
    (zwanenzang--clear-foreign-state)
    (should (equal (zwanenzang-test--line) "* TODO Title"))))

;;;; Round trips through the CLI

(ert-deftest zwanenzang-pull-writes-the-prefix-and-push-never-sends-it ()
  (zwanenzang-test-with-remote-scope (net trk buf zwanenzang-test--push-org)
    (let ((id (zwanenzang-test-create trk "Ticket")))
      (zwanenzang-test-cli trk "priority" id "65")
      (zwanenzang-test-pull)
      (should (equal (zwanenzang-test-heading id) "*** TODO [#A] [ZZ-1] Ticket"))
      (should (string-match-p (format "title=%s " (zwanenzang--hash "Ticket"))
                              (zwanenzang-test-property id "ZWANENZANG_SYNC")))
      ;; A new heading is created with its own title, then gets the prefix.
      (zwanenzang-test-append "** TODO New [0/0]\n")
      (zwanenzang-test-at-root #'zwanenzang-push)
      (let ((new (zwanenzang-test-id-of "New [0/0]")))
        (should (equal (alist-get 'title (zwanenzang-test-show trk new)) "New [0/0]"))
        (should (equal (zwanenzang-test-heading new) "** TODO [ZZ-2] New [0/0]")))
      ;; An Org rename behind the prefix sends only the title.
      (save-excursion
        (zwanenzang-test-goto id)
        (search-forward "Ticket")
        (replace-match "Renamed"))
      (zwanenzang-test-at-root #'zwanenzang-push)
      (should (equal (alist-get 'title (zwanenzang-test-show trk id)) "Renamed"))
      (should (equal (zwanenzang-test-heading id) "*** TODO [#A] [ZZ-1] Renamed")))))

(ert-deftest zwanenzang-an-edited-prefix-is-restored-not-pushed ()
  (zwanenzang-test-with-remote-scope (net trk buf zwanenzang-test--push-org)
    (let ((one (zwanenzang-test-create trk "One"))
          (two (zwanenzang-test-create trk "Two")))
      (zwanenzang-test-pull)
      (save-excursion
        (zwanenzang-test-goto one)
        (search-forward "[ZZ-1] ")
        (replace-match ""))
      (save-excursion
        (zwanenzang-test-goto two)
        (search-forward "[ZZ-2]")
        (replace-match "[ZZ-0007]"))
      (let ((head (zwanenzang-test-head trk)))
        (zwanenzang-test-clear-report)
        (zwanenzang-test-at-root #'zwanenzang-push)
        (should (equal head (zwanenzang-test-head trk))))
      (should (equal (zwanenzang-test-heading one) "*** TODO [ZZ-1] One"))
      (should (equal (zwanenzang-test-heading two) "*** TODO [ZZ-2] Two"))
      (should-not (member zwanenzang-conflict-tag (zwanenzang-test-tags one)))
      (should-not (string-match-p "conflict" (zwanenzang-test-report))))))

(ert-deftest zwanenzang-a-prefix-shaped-tracker-title-round-trips ()
  (zwanenzang-test-with-remote-scope (net trk buf zwanenzang-test--push-org)
    (let ((id (zwanenzang-test-create trk "[ZZ-5] Literal")))
      (zwanenzang-test-pull)
      (should (equal (zwanenzang-test-heading id) "*** TODO [ZZ-1] [ZZ-5] Literal"))
      (let ((head (zwanenzang-test-head trk)))
        (zwanenzang-test-at-root #'zwanenzang-push)
        (should (equal head (zwanenzang-test-head trk))))
      (should (equal (alist-get 'title (zwanenzang-test-show trk id)) "[ZZ-5] Literal")))))

(ert-deftest zwanenzang-an-unnumbered-ticket-gets-no-prefix ()
  (zwanenzang-test-with-remote-scope (net trk buf zwanenzang-test--push-org)
    (zwanenzang-test-delete-dir (expand-file-name "remote-test-repo" net))
    (zwanenzang-test-append "** TODO Written offline\n")
    (zwanenzang-test-at-root #'zwanenzang-push)
    (let ((id (zwanenzang-test-id-of "Written offline")))
      (should id)
      (should-not (zwanenzang-test-property id "ZWANENZANG_NUMBER"))
      (should (equal (zwanenzang-test-heading id) "** TODO Written offline")))))

(provide 'zwanenzang-heading-prefix-test)
;;; zwanenzang-heading-prefix-test.el ends here
