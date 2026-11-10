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

(ert-deftest zwanenzang-org-id-generation-is-local-and-idempotent ()
  (zwanenzang-test-with-org
      "* Parent\n:PROPERTIES:\n:ID: parent-id\n:END:\n** Ticket\n:PROPERTIES:\n:ZWANENZANG_ID: tracker-id\n:END:\n"
    (outline-next-heading)
    (cl-letf (((symbol-function 'org-id-add-location)
               (lambda (&rest _) (ert-fail "Must not register Org IDs")))
              ((symbol-function 'org-id-find)
               (lambda (&rest _) (ert-fail "Must not look up Org IDs"))))
      (zwanenzang--ensure-org-id)
      (let ((id (org-entry-get nil "ID"))
            (before (buffer-string)))
        (should id)
        (should-not (member id '("parent-id" "tracker-id")))
        (zwanenzang--ensure-org-id)
        (should (equal before (buffer-string)))
        (should (equal (org-entry-get nil "ZWANENZANG_ID") "tracker-id"))
        (should (nth 2 (assoc "PROPERTIES" (zwanenzang--drawer-visibility))))))
    (org-entry-put nil "ID" "human-id")
    (zwanenzang--ensure-org-id)
    (should (equal (org-entry-get nil "ID") "human-id"))))

;;;; Drawer visibility

(ert-deftest zwanenzang-body-rewrite-preserves-drawer-visibility ()
  (dolist (closed '(nil t))
    (zwanenzang-test-with-org
        "* Ticket\n:PROPERTIES:\n:ZWANENZANG_ID: synthetic\n:END:\nOld text\n:ZWANENZANG_COMMENTS:\nA comment\n:END:\n\n\n* Next\n"
      (org-fold-show-all)
      (when closed
        (save-excursion
          (search-forward ":ZWANENZANG_COMMENTS:")
          (org-fold-hide-drawer-toggle t)))
      (zwanenzang--write-body
       (zwanenzang--compose-body (zwanenzang--body) nil "New text\n"))
      (let ((states (zwanenzang--drawer-visibility)))
        (should (nth 2 (assoc "PROPERTIES" states)))
        (should (eq (not (null (nth 2 (assoc "ZWANENZANG_COMMENTS" states)))) closed)))
      ;; Property updates, including no-ops, must not reveal comments.
      (zwanenzang--put "ZWANENZANG_CURSOR" "cursor")
      (zwanenzang--put "ZWANENZANG_CURSOR" "cursor")
      (should (eq (not (null (nth 2 (assoc "ZWANENZANG_COMMENTS"
                                          (zwanenzang--drawer-visibility))))) closed))
      ;; Newly received comments are visible even when the drawer was closed.
      (zwanenzang--write-body
       (zwanenzang--compose-body (zwanenzang--body)
                                '(("ZWANENZANG_COMMENTS" . "A comment\nNew comment\n"))))
      (should-not (nth 2 (assoc "ZWANENZANG_COMMENTS"
                               (zwanenzang--drawer-visibility)))))))

(ert-deftest zwanenzang-body-rewrite-stays-under-outline-fold ()
  (dolist (org-fold-core-style '(overlays text-properties))
    (dolist (fold-parent '(nil t))
      (zwanenzang-test-with-org
          "* Parent\n** Ticket\n:PROPERTIES:\n:ZWANENZANG_ID: synthetic\n:END:\nOld description\n"
        (unless fold-parent (outline-next-heading))
        (org-fold-subtree t)
        (goto-char (point-min))
        (outline-next-heading)
        (zwanenzang--write-body
         (zwanenzang--compose-body
          (zwanenzang--body) '(("ZWANENZANG_COMMENTS" . "New comment\n"))
          "New description\n"))
        (search-forward "New description")
        (should (org-fold-folded-p (1- (point)) 'outline))
        (should (invisible-p (1- (point))))
        (search-forward "New comment")
        (should (org-fold-folded-p (1- (point)) 'outline))
        (should (invisible-p (1- (point))))))))

(defconst zwanenzang-test--folded-body
  (concat "* Parent\n** Ticket\n:PROPERTIES:\n:ZWANENZANG_ID: synthetic\n:END:\n"
          "Original prose\n:ZWANENZANG_COMMENTS:\nA comment\n:END:\n"
          "*** Plan\n:PROPERTIES:\n:ZWANENZANG_DOC: plan\n:END:\nDocument prose\n"
          "** Neighbor\nNeighbor prose\n* Outside\nOutside prose\n")
  "Synthetic entries with a document and unrelated later text.")

(defun zwanenzang-test--outline-ranges ()
  "Sorted outline bounds, inspecting raw overlays on that backend.
Adjacent same-spec overlays can be skipped by Org's region enumerator."
  (sort
   (if (eq org-fold-core-style 'overlays)
       (delq nil
             (mapcar (lambda (overlay)
                       (when (eq (overlay-get overlay 'invisible) 'org-fold-outline)
                         (cons (overlay-start overlay) (overlay-end overlay))))
                     (overlays-in (point-min) (point-max))))
     (mapcar (lambda (region) (cons (nth 0 region) (nth 1 region)))
             (org-fold-core-get-regions :specs 'outline)))
   (lambda (a b) (< (car a) (car b)))))

(ert-deftest zwanenzang-write-body-noop-preserves-ancestor-outline-region ()
  (let ((org-fold-core-style 'overlays))
    (zwanenzang-test-with-org zwanenzang-test--folded-body
      (org-fold-subtree t)
      (let ((ranges (zwanenzang-test--outline-ranges))
            (text (buffer-substring-no-properties (point-min) (point-max))))
        (search-forward "Ticket") (org-back-to-heading t)
        (dotimes (_ 3) (zwanenzang--write-body (zwanenzang--body)))
        (should (equal ranges (zwanenzang-test--outline-ranges)))
        (should (equal text (buffer-substring-no-properties (point-min) (point-max))))))))

(ert-deftest zwanenzang-write-body-noop-text-properties-control ()
  (let ((org-fold-core-style 'text-properties))
    (zwanenzang-test-with-org zwanenzang-test--folded-body
      (org-fold-subtree t)
      (let ((ranges (zwanenzang-test--outline-ranges)))
        (search-forward "Ticket") (org-back-to-heading t)
        (dotimes (_ 3) (zwanenzang--write-body (zwanenzang--body)))
        (should (equal ranges (zwanenzang-test--outline-ranges)))))))

(ert-deftest zwanenzang-write-body-change-preserves-ancestor-outline-region ()
  (dolist (org-fold-core-style '(overlays text-properties))
    (dolist (fold '(ancestor subtree entry))
      (dolist (narrow '(nil t))
        (zwanenzang-test-with-org zwanenzang-test--folded-body
          (if (eq fold 'ancestor)
              (org-fold-subtree t)
            (outline-next-heading)
            (if (eq fold 'entry) (org-fold-hide-entry) (org-fold-subtree t)))
          (let ((fold-start (copy-marker (caar (zwanenzang-test--outline-ranges))))
                (fold-end (copy-marker (cdar (zwanenzang-test--outline-ranges)) t)))
            (goto-char (point-min)) (search-forward "Ticket") (org-back-to-heading t)
            (when narrow (org-narrow-to-subtree))
            (let* ((position (point-marker))
                   (minimum (copy-marker (point-min)))
                   (maximum (copy-marker (point-max) t))
                   (bounds (zwanenzang--body-bounds))
                   (new (zwanenzang--compose-body
                         (zwanenzang--body)
                         '(("ZWANENZANG_COMMENTS" . "A comment\nAnother comment\n"))
                         "Replacement prose\n"))
                   (expected (concat (buffer-substring-no-properties (point-min) (car bounds))
                                     new
                                     (buffer-substring-no-properties (cdr bounds) (point-max)))))
              (zwanenzang--write-body new)
              (should (= position (point)))
              (should (= minimum (point-min)))
              (should (= maximum (point-max)))
              (should (equal expected (buffer-substring-no-properties (point-min) (point-max))))
              ;; An entry fold ends on the newline before its document, which
              ;; was part of the replacement; other endpoints move with text.
              (let ((end (if (eq fold 'entry)
                             (1- (cdr (zwanenzang--body-bounds)))
                           (marker-position fold-end))))
                (save-restriction
                  (widen)
                  (should (equal (list (cons (marker-position fold-start) end))
                                 (zwanenzang-test--outline-ranges)))))
              (should-not (nth 2 (assoc "ZWANENZANG_COMMENTS"
                                       (zwanenzang--drawer-visibility))))
              (dotimes (_ 2) (zwanenzang--write-body new)))
            (set-marker fold-start nil)
            (set-marker fold-end nil)))))))

(ert-deftest zwanenzang-write-body-preserves-final-entry-fold ()
  (dolist (org-fold-core-style '(overlays text-properties))
    (dolist (new '("Changed prose\n" ""))
      (zwanenzang-test-with-org "* Ticket\nOriginal prose\n"
        (org-fold-subtree t)
        (zwanenzang--write-body new)
        (let ((expected (list (cons (line-end-position) (point-max)))))
          (should (equal expected (zwanenzang-test--outline-ranges))))))))

(ert-deftest zwanenzang-write-body-clears-empty-entry-fold ()
  (dolist (org-fold-core-style '(overlays text-properties))
    (zwanenzang-test-with-org "* Ticket\nOriginal prose\n** Plan\nDocument prose\n"
      (org-fold-hide-entry)
      (zwanenzang--write-body "")
      (should-not (zwanenzang-test--outline-ranges))
      (org-copy-visible (point-min) (point-max))
      (should (equal "* Ticket\n** Plan\nDocument prose\n"
                     (substring-no-properties (current-kill 0)))))))

(ert-deftest zwanenzang-write-body-visibility-roundtrip-preserves-separation ()
  (dolist (org-fold-core-style '(overlays text-properties))
    (zwanenzang-test-with-org zwanenzang-test--folded-body
      (org-fold-subtree t)
      (let ((ranges (zwanenzang-test--outline-ranges))
            (text (buffer-substring-no-properties (point-min) (point-max))))
        (search-forward "Ticket") (org-back-to-heading t)
        (zwanenzang--write-body (zwanenzang--body))
        (org-fold-core-save-visibility t nil)
        (zwanenzang--write-body (zwanenzang--body))
        (should (equal ranges (zwanenzang-test--outline-ranges)))
        (org-copy-visible (point-min) (point-max))
        (should (equal "* Parent\n* Outside\nOutside prose\n"
                       (substring-no-properties (current-kill 0))))
        (should (equal text (buffer-substring-no-properties (point-min) (point-max))))))))

(ert-deftest zwanenzang-write-body-isearch-preserves-heading-separation ()
  (require 'isearch)
  (dolist (org-fold-core-style '(overlays text-properties))
    (zwanenzang-test-with-org zwanenzang-test--folded-body
      (org-fold-subtree t)
      (search-forward "Ticket") (org-back-to-heading t)
      (let ((text (buffer-substring-no-properties (point-min) (point-max)))
            (search-invisible 'open)
            (isearch-opened-overlays nil))
        (zwanenzang--write-body (zwanenzang--body))
        (search-forward "Document prose")
        (unwind-protect
            (progn
              (isearch-range-invisible (- (point) (length "Document prose")) (point))
              (org-copy-visible (point-min) (point-max))
              (let ((visible (substring-no-properties (current-kill 0))))
                (should-not (string-match-p "Parent\\*\\*\\* Plan" visible))
                (when (eq org-fold-core-style 'overlays)
                  (should (string-match-p "\n\\*\\*\\* Plan\n" visible))))
              (should (equal text (buffer-substring-no-properties (point-min) (point-max)))))
          (isearch-clean-overlays))))))

(ert-deftest zwanenzang-move-preserves-outline-folds ()
  (dolist (org-fold-core-style '(overlays text-properties))
    (zwanenzang-test-with-org
        "* Destination\n* Ticket\nTicket description\n** Child\nChild description\n* Next\n"
      (let ((target (point-marker)))
        (outline-next-heading)
        (org-fold-subtree t)
        (zwanenzang--move-subtree (point-marker) target))
      (goto-char (point-min))
      (search-forward "Ticket description")
      (should (invisible-p (1- (point))))
      (search-forward "Child")
      (should (invisible-p (1- (point))))
      (search-forward "Child description")
      (should (invisible-p (1- (point))))))
  (zwanenzang-test-with-org
      "* Destination\nDestination body\n* Ticket\nTicket description\n"
    (org-fold-subtree t)
    (let ((target (point-marker)))
      (outline-next-heading)
      (zwanenzang--move-subtree (point-marker) target))
    (goto-char (point-min))
    (search-forward "Ticket")
    (should (invisible-p (1- (point))))
    (search-forward "Ticket description")
    (should (invisible-p (1- (point))))))

(ert-deftest zwanenzang-move-keeps-comments-closed ()
  (zwanenzang-test-with-org
      "* Parent\n* Ticket\n:PROPERTIES:\n:ZWANENZANG_ID: synthetic\n:END:\n:ZWANENZANG_COMMENTS:\nA comment\n:END:\n"
    (org-fold-hide-drawer-all)
    (let ((target (point-marker)))
      (outline-next-heading)
      (zwanenzang--move-subtree (point-marker) target))
    (goto-char (point-min))
    (outline-next-heading)
    (should (nth 2 (assoc "PROPERTIES" (zwanenzang--drawer-visibility))))
    (should (nth 2 (assoc "ZWANENZANG_COMMENTS" (zwanenzang--drawer-visibility))))))

;;;; Text

(ert-deftest zwanenzang-escape-keeps-headings-out-and-org-verbatim ()
  (let ((text (concat "* heading\n** deeper\n*bold* stays\n#+begin_src sh\nls\n#+end_src\n"
                      "[[https://example.invalid][link]]\n,* already\nplain\n*\n")))
    (should (equal (zwanenzang--escape-text text)
                   (concat ",* heading\n,** deeper\n*bold* stays\n#+begin_src sh\nls\n#+end_src\n"
                           "[[https://example.invalid][link]]\n,,* already\nplain\n,*\n")))
    (should (equal (zwanenzang--unescape-text (zwanenzang--escape-text text)) text))
    ;; A comma that escapes nothing is the human's and stays.
    (should (equal (zwanenzang--unescape-text ",plain\n") ",plain\n"))))

(ert-deftest zwanenzang-escape-covers-every-drawer-like-line ()
  ;; Whatever follows: a human may add a drawer below it later.
  (let ((text ":wip:\ntext\n  :NOTE:\nkept\n:END:\n:end:\n:ZWANENZANG_COMMENTS:\n"))
    (should (equal (zwanenzang--escape-text text)
                   ",:wip:\ntext\n,  :NOTE:\nkept\n,:END:\n,:end:\n,:ZWANENZANG_COMMENTS:\n"))
    (should (equal (zwanenzang--body-description (zwanenzang--escape-text text)) text)))
  ;; `#+' lines escaped by an earlier version read back without the comma.
  (should (equal (zwanenzang--unescape-text ",#+begin_src\n,,#+x\n") "#+begin_src\n,#+x\n"))
  (should (equal (zwanenzang--escape-text ",#+x\n") ",,#+x\n")))

(ert-deftest zwanenzang-comment-text-escapes-headings-and-drawer-ends ()
  (should (equal (zwanenzang--comment-text "one\n* two\n:END:\n  :end:\n#+begin_src\n:x:\n\n")
                 "one\n,* two\n,:END:\n,  :end:\n#+begin_src\n:x:\n"))
  (should (equal (zwanenzang--comment-text "\n") "")))

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
          ":ZWANENZANG_COMMENTS:\n[ts] a:\nhi\n:END:\n"
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
  (should (equal (zwanenzang--comment-text ":end:\n") ",:end:\n")))

(ert-deftest zwanenzang-body-segments-keep-a-lone-drawer-line-out-of-own-drawers ()
  ;; Text in front of the client's drawers: :lone: must not reach their :END:.
  (let ((body ":lone:\nText\n:ZWANENZANG_COMMENTS:\n[ts] a:\n:lone:\n:END:\n"))
    (should (equal (mapcar (lambda (s) (if (eq (car s) 'drawer) (nth 2 s) (car s)))
                           (zwanenzang--body-segments body))
                   '(text text "ZWANENZANG_COMMENTS")))
    (should (equal (zwanenzang--body-description body) ":lone:\nText\n"))))

(ert-deftest zwanenzang-body-segments-read-an-old-bare-line-before-a-drawer-as-text ()
  ;; As an earlier version wrote it, with a human's drawer added below.
  (let ((body ":PROPERTIES:\n:ZWANENZANG_ID: X\n:END:\ntext\n:B:\ntail\n:NOTES:\nmine\n:END:\n"))
    (should (equal (zwanenzang--body-description body) "text\n:B:\ntail\n"))
    ;; Writing the body keeps all of it, and it still reads the same.
    (let ((new (zwanenzang--compose-body body nil)))
      (should (equal (zwanenzang--body-description new) "text\n:B:\ntail\n"))
      (should (string-match-p ":NOTES:\nmine\n:END:\n" new))))
  ;; An empty property, and a line like it in the logbook, do not end those.
  (let ((body ":PROPERTIES:\n:EMPTY:\n:END:\n:LOGBOOK:\n:odd:\n:END:\nText\n"))
    (should (equal (mapcar (lambda (s) (if (eq (car s) 'drawer) (nth 2 s) (car s)))
                           (zwanenzang--body-segments body))
                   '("PROPERTIES" "LOGBOOK" text)))))

(ert-deftest zwanenzang-description-excludes-drawers-and-planning ()
  (should (equal (zwanenzang--body-description zwanenzang-test--body)
                 "First line\n* escaped\n:UNCLOSED:\nlast\n"))
  (should (equal (zwanenzang--body-description "") ""))
  (should (equal (zwanenzang--body-description ":PROPERTIES:\n:A: b\n:END:\n\n") "")))

(ert-deftest zwanenzang-compose-body-replaces-own-drawers-and-description ()
  (should (equal (zwanenzang--compose-body
                  zwanenzang-test--body
                  '(("ZWANENZANG_COMMENTS" . "[ts] b:\nnew\n")
                    ("ZWANENZANG_HIDDEN" . nil)
                    ("ZWANENZANG_CONFLICT" . "- x\n"))
                  "* new text\n")
                 (concat "SCHEDULED: <2026-11-07 Sat>\n"
                         ":PROPERTIES:\n:ZWANENZANG_ID: X\n:END:\n"
                         ":LOGBOOK:\n- note\n:END:\n"
                         ":ZWANENZANG_CONFLICT:\n- x\n:END:\n"
                         ",* new text\n"
                         ":ZWANENZANG_COMMENTS:\n[ts] b:\nnew\n:END:\n")))
  ;; Without a description the text stays exactly as it was.
  (let ((kept (zwanenzang--compose-body zwanenzang-test--body
                                        '(("ZWANENZANG_COMMENTS" . nil)))))
    (should (equal kept (concat "SCHEDULED: <2026-11-07 Sat>\n"
                                ":PROPERTIES:\n:ZWANENZANG_ID: X\n:END:\n"
                                ":LOGBOOK:\n- note\n:END:\n"
                                "First line\n,* escaped\n:UNCLOSED:\nlast\n")))
    (should (equal (zwanenzang--body-description kept)
                   (zwanenzang--body-description zwanenzang-test--body)))))

(ert-deftest zwanenzang-compose-body-moves-old-position-drawers-to-the-end ()
  ;; The layout of earlier versions: the client's drawers above the text.
  (let ((old (concat ":PROPERTIES:\n:ZWANENZANG_ID: X\n:END:\n"
                     ":ZWANENZANG_COMMENTS:\n[ts] a:\n  : hi\n:END:\n"
                     ":ZWANENZANG_HIDDEN:\n[[zwanenzang:X/s][s (hidden)]]\n:END:\n"
                     "Text\n")))
    (should (equal (zwanenzang--body-description old) "Text\n"))
    ;; Even when only another drawer is being written.
    (should (equal (zwanenzang--compose-body old '(("ZWANENZANG_CONFLICT" . "- x\n")))
                   (concat ":PROPERTIES:\n:ZWANENZANG_ID: X\n:END:\n"
                           ":ZWANENZANG_CONFLICT:\n- x\n:END:\n"
                           "Text\n"
                           ":ZWANENZANG_COMMENTS:\n[ts] a:\n  : hi\n:END:\n"
                           ":ZWANENZANG_HIDDEN:\n[[zwanenzang:X/s][s (hidden)]]\n:END:\n")))))

(ert-deftest zwanenzang-written-description-reads-back-unchanged ()
  (let* ((text "Intro\n* not a heading\n:END:\n#+TITLE: no\n:DRAWER:\nx\n:END:\n\nend\n")
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
                   '(:keyword "TODO" :priority 65 :title "Old title" :tags ("a" "zz_conflict"))))
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

(ert-deftest zwanenzang-comments-render-newest-first-without-changing-state ()
  (let* ((pull (zwanenzang--pull-create
                :tracker-dir "/trk/"
                :actors '((A1 . "Alice"))))
         ;; Replay order, not wall-clock timestamps, defines newest.
         (ticket '((comments ((actor . "A1") (ts . "2026-11-07T10:00:00Z")
                             (text . "first\n* line") (link . :null))
                            ((actor . "01UNDECLARED0000000000000") (ts . "2026-11-07T09:00:00Z")
                             (text . "second") (link . "docs/x.md"))
                            ((actor . "A1") (ts . "2026-11-07T12:00:00Z")
                             (text . "third") (link . "https://example.invalid/mr/1")))))
         (before (copy-tree ticket))
         (expected (concat "[2026-11-07T12:00:00Z] Alice:\nthird\n"
                           "[[https://example.invalid/mr/1]]\n"
                           "[2026-11-07T09:00:00Z] 01UNDECLAR:\nsecond\n"
                           "[[file:/trk/docs/x.md]]\n"
                           "[2026-11-07T10:00:00Z] Alice:\nfirst\n,* line\n")))
    (dotimes (_ 2)
      (should (equal (zwanenzang--comments-content pull ticket) expected))
      (should (equal ticket before)))))

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
