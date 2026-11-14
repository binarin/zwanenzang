;;; zwanenzang-document-test.el --- Named-document codec regressions -*- lexical-binding: t; -*-

(require 'ert)
(require 'org-src)
(require 'ox-html)
(require 'zwanenzang-pull-test)
(require 'zwanenzang-push-integration-test)

(defconst zwanenzang-test--document-prose
  (concat "* TODO Literal heading\n** Child\n"
          ":PROPERTIES:\n:ZWANENZANG: /not-a-tracker\n:ZWANENZANG_ID: fake\n:END:\n"
          ":ZWANENZANG_CONFLICT:\nHuman drawer\n:END:\n"
          "#+begin_src org\n,* comma heading\n,,#+end_src\n#+end_src\n"
          "  #+END_SRC\n,#+TITLE: literal\n,,* commas\n"
          "\tindented\n  spaces  \nλ 🦢 [[file:relative.org][link]]\n"))

(defun zwanenzang-test--document (text)
  "Install TEXT in the document heading at point, as earlier versions did."
  (zwanenzang-test-write-inline-doc text))

(ert-deftest zwanenzang-document-codec-roundtrip ()
  (dolist (text (list zwanenzang-test--document-prose "" "no newline" "\n\n* H\n\n"
                      " ,,,* x\n\t,,#+end_src\n:END:\n"))
    (zwanenzang-test-with-org "* plan\n:PROPERTIES:\n:ZWANENZANG_DOC: plan\n:END:\n"
                              (zwanenzang-test--document text)
                              (should (equal (zwanenzang--document-text) (zwanenzang--normalize-text text)))
                              (should (equal (org-entry-get nil "ZWANENZANG_DOC_FORMAT") "org-src-v1"))
                              (let ((before (buffer-string)))
                                (zwanenzang-test--document text)
                                (should (equal before (buffer-string))))
                              (should (= 1 (length (org-element-map (org-element-parse-buffer) 'src-block #'identity))))
                              (should (= 1 (length (org-element-map (org-element-parse-buffer) 'headline #'identity)))))))

(ert-deftest zwanenzang-document-legacy-migration-is-not-source-detection ()
  (zwanenzang-test-with-org
   (concat "* plan\n:PROPERTIES:\n:ZWANENZANG_DOC: plan\n:END:\n"
           (zwanenzang--escape-text zwanenzang-test--document-prose))
   (should (equal zwanenzang-test--document-prose (zwanenzang--document-text)))
   (zwanenzang-test--document (zwanenzang--document-text))
   (should (equal zwanenzang-test--document-prose (zwanenzang--document-text)))))

(ert-deftest zwanenzang-document-malformed-wrapper-refused ()
  (dolist (body '("#+begin_src org\nmissing close\n"
                  "#+begin_src org -i :eval never :exports code :noweb no\nx\n#+end_src\nextra\n"
                  "#+begin_src org -i :eval never :exports code :noweb no\nx\n#+end_src\n:NOTES:\ntruncated prose\n:END:\n"
                  "plain prose\n"))
    (zwanenzang-test-with-org
     (concat "* plan\n:PROPERTIES:\n:ZWANENZANG_DOC: plan\n"
             ":ZWANENZANG_DOC_FORMAT: org-src-v1\n:END:\n" body)
     (should-error (zwanenzang--document-text) :type 'user-error)))
  (zwanenzang-test-with-org
   "* plan\n:PROPERTIES:\n:ZWANENZANG_DOC_FORMAT: future\n:END:\n"
   (should-error (zwanenzang--document-text) :type 'user-error)))

(ert-deftest zwanenzang-document-structure-move-fold-and-undo ()
  (zwanenzang-test-with-org
   "* Scope\n:PROPERTIES:\n:ZWANENZANG: /synthetic\n:END:\n** Destination\n** TODO Ticket\n:PROPERTIES:\n:ZWANENZANG_ID: owner\n:END:\n*** plan\n:PROPERTIES:\n:ZWANENZANG_DOC: plan\n:END:\n"
   (search-forward "*** plan") (beginning-of-line)
   (buffer-enable-undo)
   (let ((before (buffer-string)))
     (zwanenzang--one-undo-step (zwanenzang-test--document zwanenzang-test--document-prose))
     (undo-boundary) (undo)
     (should (equal before (buffer-string))))
   (zwanenzang-test--document zwanenzang-test--document-prose)
   (org-fold-subtree t)
   (zwanenzang-test--document zwanenzang-test--document-prose)
   (search-forward "Literal heading")
   (should (invisible-p (1- (point))))
   (goto-char (point-min))
   (let ((root (point-marker)))
     (should (equal '("owner")
                    (mapcar (lambda (h) (plist-get h :id))
                            (plist-get (zwanenzang--scan-all root) :headings)))))
   (search-forward "Destination") (beginning-of-line)
   (let ((to (point-marker)))
     (search-forward "TODO Ticket") (beginning-of-line)
     (zwanenzang--move-subtree (point-marker) to))
   (search-forward "plan") (beginning-of-line)
   (should (equal zwanenzang-test--document-prose (zwanenzang--document-text)))
   ;; Ordinary Org cut/paste refile must not relevel source prose either.
   (org-up-heading-safe) (org-cut-subtree)
   (goto-char (point-max)) (org-paste-subtree 2)
   (goto-char (point-max))
   (search-backward ":ZWANENZANG_DOC:") (org-back-to-heading t)
   (should (equal zwanenzang-test--document-prose (zwanenzang--document-text)))))

(ert-deftest zwanenzang-document-cleanup-keeps-payload ()
  (dolist (operation '(zwanenzang--detach-entry zwanenzang--clear-foreign-state))
    (zwanenzang-test-with-org
     "* plan\n:PROPERTIES:\n:ZWANENZANG_DOC: plan\n:END:\n:NOTES:\nHost drawer\n#+begin_src sh\nexisting host code\n#+end_src\n:END:\n"
     (zwanenzang-test--document zwanenzang-test--document-prose)
     (if (eq operation 'zwanenzang--clear-foreign-state)
         (progn (funcall operation t)
                (should (equal zwanenzang-test--document-prose (zwanenzang--document-text))))
       (funcall operation)
       (should (equal zwanenzang-test--document-prose
                      (org-element-property :value
                                            (car (org-element-map (org-element-parse-buffer)
                                                                  'src-block
                                                                  (lambda (block)
                                                                    (and (equal (org-element-property :language block) "org")
                                                                         block))))))))
     (should (string-match-p "Host drawer" (buffer-string))))))

(ert-deftest zwanenzang-document-source-editor-real-headings-and-safety ()
  (save-window-excursion
    (let ((host (generate-new-buffer " *document-host*")) edit)
      (unwind-protect
          (progn
            (switch-to-buffer host) (org-mode)
            (insert "* Scope\n:PROPERTIES:\n:ZWANENZANG: /synthetic\n:END:\n** plan\n:PROPERTIES:\n:ZWANENZANG_DOC: plan\n:END:\n")
            (search-backward "** plan")
            (zwanenzang-test--document zwanenzang-test--document-prose)
            (search-forward "#+begin_src") (beginning-of-line)
            (let ((org-src-window-setup 'current-window)) (org-edit-src-code))
            (setq edit (current-buffer))
            (should (derived-mode-p 'org-mode))
            (should (equal (buffer-string) zwanenzang-test--document-prose))
            (should-error (zwanenzang--scope-root) :type 'user-error)
            (goto-char (point-max)) (insert "* New heading\n")
            (let ((draft (buffer-string)) (before (with-current-buffer host (buffer-string))))
              (with-current-buffer host
                (goto-char (point-min))
                (should-error (zwanenzang-push) :type 'user-error)
                (should-error (zwanenzang-pull) :type 'user-error)
                (should-error (zwanenzang--move-subtree (point-marker) (point-marker)) :type 'user-error)
                (should (equal before (buffer-string))))
              (should (equal draft (buffer-string))))
            (org-edit-src-exit) (setq edit nil)
            ;; The host keeps Org's own source quoting, which the editor
            ;; strips and restores; the client adds no quoting of its own.
            (should (string-match-p "^,\\* New heading$" (buffer-string)))
            (should (string-match-p "^,\\* TODO Literal heading$" (buffer-string)))
            (should (string-match-p "^,,\\* comma heading$" (buffer-string)))
            (search-backward "** plan")
            (should (equal (concat zwanenzang-test--document-prose "* New heading\n")
                           (zwanenzang--document-text))))
        (when (buffer-live-p edit)
          (with-current-buffer edit (set-buffer-modified-p nil)) (kill-buffer edit))
        (when (buffer-live-p host)
          (with-current-buffer host (set-buffer-modified-p nil)) (kill-buffer host))))))

(ert-deftest zwanenzang-document-export-does-not-interpret-payload ()
  (zwanenzang-test-with-org "* plan\n:PROPERTIES:\n:ZWANENZANG_DOC: plan\n:END:\n"
                            (zwanenzang-test--document
                             (concat zwanenzang-test--document-prose
                                     "#+include: \"/does-not-exist/synthetic-only\" src org\n"))
                            (let* ((org-html-htmlize-output-type nil)
                                   (html (org-export-as 'html nil nil t '(:with-toc nil))))
                              (should (string-match-p "src src-org" html))
                              (should (string-match-p "does-not-exist/synthetic-only" html))
                              (should-not (string-match-p "href=.*relative.org" html))
                              (should-not (string-match-p ">TODO Literal heading</h" html)))))

(defun zwanenzang-test--doc-heading (id name)
  "A marker at ticket ID's inline document heading NAME, or nil."
  (save-excursion
    (zwanenzang-test-goto id)
    (cdr (assoc name (zwanenzang--doc-headings)))))

(ert-deftest zwanenzang-document-migration-noop-and-edited-version ()
  (zwanenzang-test-with-remote-scope (net trk buf zwanenzang-test--push-org)
    (let ((id (zwanenzang-test-create trk "Owner" "--status" "next")))
      (zwanenzang-test-set-doc trk id "plan" zwanenzang-test--document-prose)
      (zwanenzang-test-pull)
      ;; A synced pre-upgrade copy, legacy escaping included, goes away
      ;; without writing a version.
      (zwanenzang-test-inline-doc trk id "plan" zwanenzang-test--document-prose t)
      (zwanenzang-test-pull)
      (should-not (zwanenzang-test--doc-heading id "plan"))
      (should (= 1 (length (zwanenzang-test--doc-versions trk id "plan"))))
      (should (string-match-p "^- \\[\\[zwanenzang:[0-9A-Z]+/plan\\]\\[plan\\]\\]"
                              (zwanenzang-test-entry id)))
      ;; An unsynced legacy edit survives and creates one version only.
      (let ((edited (concat zwanenzang-test--document-prose "* Edited\n")))
        (zwanenzang-test-inline-doc trk id "plan" edited t)
        (zwanenzang-test-pull)
        (should (zwanenzang-test--doc-heading id "plan"))
        (should (member "zz_conflict" (zwanenzang-test-tags id)))
        (should (string-match-p "document plan: the inline copy has edits"
                                (zwanenzang-test-entry id)))
        (save-excursion
          (goto-char (zwanenzang-test--doc-heading id "plan"))
          (should (equal edited (zwanenzang--document-text))))
        (zwanenzang-test-at-root #'zwanenzang-push)
        (should (equal edited (zwanenzang-test--doc-text trk id "plan")))
        (should (= 2 (length (zwanenzang-test--doc-versions trk id "plan"))))
        (should-not (zwanenzang-test--doc-heading id "plan"))
        (should-not (member "zz_conflict" (zwanenzang-test-tags id)))
        (zwanenzang-test-at-root #'zwanenzang-push)
        (should (= 2 (length (zwanenzang-test--doc-versions trk id "plan"))))))))

(ert-deftest zwanenzang-document-migration-keeps-what-it-would-lose ()
  (zwanenzang-test-with-remote-scope (net trk buf zwanenzang-test--push-org)
    (let ((id (zwanenzang-test-create trk "Owner" "--status" "next")))
      (zwanenzang-test-set-doc trk id "plan" "Plan\n")
      (zwanenzang-test-set-doc trk id "notes" "Notes\n")
      (zwanenzang-test-pull)
      (save-excursion
        (goto-char (zwanenzang-test-inline-doc trk id "plan" "Plan\n"))
        (let ((level (org-current-level)))
          (goto-char (zwanenzang--subtree-end (point)))
          (insert (make-string (1+ level) ?*) " Human child\nMine\n")))
      (save-excursion
        (goto-char (zwanenzang-test-inline-doc trk id "notes" "Notes\n"))
        (org-end-of-meta-data t)
        (insert ":MYDRAWER:\nMine too\n:END:\n"))
      (zwanenzang-test-pull)
      (should (zwanenzang-test--doc-heading id "plan"))
      (should (zwanenzang-test--doc-heading id "notes"))
      (should (string-match-p "Human child" (buffer-string)))
      (should (string-match-p "Mine too" (buffer-string)))
      (should (string-match-p "document plan: the inline heading holds subheadings"
                              (zwanenzang-test-entry id)))
      (should (string-match-p "document notes: the inline heading holds"
                              (zwanenzang-test-entry id))))))

(ert-deftest zwanenzang-document-source-edit-publishes-one-decoded-version ()
  (save-window-excursion
    (zwanenzang-test-with-remote-scope (net trk buf zwanenzang-test--push-org)
      (let ((id (zwanenzang-test-create trk "Owner" "--status" "next")) edit)
        (zwanenzang-test-set-doc trk id "plan" zwanenzang-test--document-prose)
        (zwanenzang-test-pull)
        (switch-to-buffer buf)
        (goto-char (zwanenzang-test-inline-doc trk id "plan" zwanenzang-test--document-prose))
        (search-forward "#+begin_src") (beginning-of-line)
        (unwind-protect
            (progn
              (let ((org-src-window-setup 'current-window)) (org-edit-src-code))
              (setq edit (current-buffer))
              (should (equal (buffer-string) zwanenzang-test--document-prose))
              ;; Even fake scope properties remain prose in the source editor.
              (search-forward ":ZWANENZANG:")
              (should-error (zwanenzang--scope-root) :type 'user-error)
              (goto-char (point-max)) (insert "* Written from source editor\n")
              (org-edit-src-exit) (setq edit nil)
              (zwanenzang-test-at-root #'zwanenzang-push)
              (should (equal (concat zwanenzang-test--document-prose
                                     "* Written from source editor\n")
                             (zwanenzang-test--doc-text trk id "plan")))
              (should (= 2 (length (zwanenzang-test--doc-versions trk id "plan"))))
              (should-not (zwanenzang-test--doc-heading id "plan"))
              (let ((before (buffer-string)))
                (zwanenzang-test-at-root #'zwanenzang-sync)
                (should (equal before (buffer-string))))
              (should (= 2 (length (zwanenzang-test--doc-versions trk id "plan"))))
              (should (= 1 (hash-table-count (zwanenzang--known-tickets trk)))))
          (when (buffer-live-p edit)
            (with-current-buffer edit (set-buffer-modified-p nil)) (kill-buffer edit)))))))

(ert-deftest zwanenzang-document-malformed-fence-cannot-create-fake-ticket ()
  (zwanenzang-test-with-remote-scope (net trk buf zwanenzang-test--push-org)
    (let ((id (zwanenzang-test-create trk "Owner" "--status" "next")))
      (zwanenzang-test-set-doc trk id "plan" "* TODO Fake ticket\n")
      (zwanenzang-test-pull)
      (goto-char (zwanenzang-test-inline-doc trk id "plan" "* TODO Fake ticket\n"))
      ;; Remove source escaping, exposing what would otherwise be a create.
      (search-forward ",* TODO") (replace-match "* TODO")
      (let ((before (buffer-string)) (head (zwanenzang-test-head trk)))
        (should-error (zwanenzang-test-at-root #'zwanenzang-push) :type 'user-error)
        (should-error (zwanenzang-test-pull) :type 'user-error)
        (should (equal before (buffer-string)))
        (should (equal head (zwanenzang-test-head trk)))))))

(ert-deftest zwanenzang-document-adoption-and-archive-see-decoded-prose ()
  (zwanenzang-test-with-remote-scope (net trk buf zwanenzang-test--push-org)
    (zwanenzang-test-append
     "** TODO Imported\n:PROPERTIES:\n:ZWANENZANG_ID: foreign\n:END:\n*** plan\n:PROPERTIES:\n:ZWANENZANG_DOC: plan\n:END:\n")
    (goto-char (point-max)) (search-backward "*** plan")
    (zwanenzang-test--document zwanenzang-test--document-prose)
    (zwanenzang-test--goto-title "Imported")
    (zwanenzang-adopt-foreign)
    (let* ((id (zwanenzang-test-id-of "Imported"))
           (root (save-excursion (goto-char (point-min)) (outline-next-heading) (point-marker))))
      (should (equal zwanenzang-test--document-prose (zwanenzang-test--doc-text trk id "plan")))
      ;; The final pull of the adoption removed the synced inline copy.
      (should-not (zwanenzang-test--doc-heading id "plan"))
      (zwanenzang-test-inline-doc trk id "plan" zwanenzang-test--document-prose)
      (zwanenzang-test-goto id)
      (should (zwanenzang--prose-synced-p (point-marker)))
      (let ((h (car (plist-get (zwanenzang--scan-all root) :headings))))
        (should-not (member "document plan" (zwanenzang--archive-unpushed h)))
        (goto-char (zwanenzang-test--doc-heading id "plan"))
        (zwanenzang-test--document (concat zwanenzang-test--document-prose "edit\n"))
        (goto-char (plist-get h :marker))
        (should-not (zwanenzang--prose-synced-p (point-marker)))
        (should (member "document plan" (zwanenzang--archive-unpushed h)))))))

(ert-deftest zwanenzang-document-legacy-conflict-keeps-local-prose-and-base ()
  (zwanenzang-test-with-remote-scope (net trk buf zwanenzang-test--push-org)
    (let ((id (zwanenzang-test-create trk "Owner" "--status" "next"))
          (local (concat zwanenzang-test--document-prose "* Local edit\n")))
      (zwanenzang-test-set-doc trk id "plan" "* Base\n")
      (zwanenzang-test-pull)
      (goto-char (zwanenzang-test-inline-doc trk id "plan" local t))
      (let ((base (org-entry-get nil "ZWANENZANG_VERSION"))
            (hash (org-entry-get nil "ZWANENZANG_HASH")))
        (zwanenzang-test-set-doc trk id "plan" "* Agent edit\n")
        (zwanenzang-test-pull)
        (should (member "zz_conflict" (zwanenzang-test-tags id)))
        (goto-char (zwanenzang-test--doc-heading id "plan"))
        (should (equal local (zwanenzang--document-text)))
        (should (equal base (org-entry-get nil "ZWANENZANG_VERSION")))
        (should (equal hash (org-entry-get nil "ZWANENZANG_HASH")))
        (zwanenzang-test-at-root #'zwanenzang-push)
        (should (equal local (zwanenzang-test--doc-text trk id "plan")))
        (should (= 3 (length (zwanenzang-test--doc-versions trk id "plan"))))
        (should-not (zwanenzang-test--doc-heading id "plan"))
        (should-not (member "zz_conflict" (zwanenzang-test-tags id)))))))

;;;; Document buffers

(defun zwanenzang-test--open-doc (id name)
  "Follow ticket ID's documents-drawer link to NAME; return the buffer."
  (zwanenzang-test-goto id)
  (search-forward (format "[[zwanenzang:%s/%s]" id name))
  (backward-char 2)
  (zwanenzang-open))

(defmacro zwanenzang-test--with-doc-buffer (spec &rest body)
  "Bind (VAR) to the result of FORM in SPEC (VAR FORM), killing it after BODY."
  (declare (indent 1))
  `(save-window-excursion
     (let ((,(car spec) ,(cadr spec)))
       (unwind-protect (progn ,@body)
         (when (buffer-live-p ,(car spec))
           (with-current-buffer ,(car spec) (set-buffer-modified-p nil))
           (kill-buffer ,(car spec)))))))

(ert-deftest zwanenzang-document-buffer-saves-with-base-and-pulls ()
  (zwanenzang-test-with-remote-scope (net trk buf zwanenzang-test--push-org)
    (let ((id (zwanenzang-test-create trk "Owner")))
      (zwanenzang-test-set-doc trk id "plan" zwanenzang-test--document-prose)
      (zwanenzang-test-pull)
      (should-not (string-match-p "Literal heading" (buffer-string)))
      (zwanenzang-test--with-doc-buffer (doc (zwanenzang-test--open-doc id "plan"))
        (with-current-buffer doc
          (should (derived-mode-p 'zwanenzang-document-mode))
          (should-not buffer-read-only)
          (should (equal (buffer-string) zwanenzang-test--document-prose))
          (should (equal (buffer-name) "*zwanenzang ZZ-1 plan*"))
          ;; Its prose is not a scope, fake properties and all.
          (search-forward ":ZWANENZANG:")
          (should-error (zwanenzang-pull) :type 'user-error)
          (should-not (zwanenzang--comment-heading))
          (goto-char (point-max))
          (insert "* Added in the buffer\n")
          (let ((head (zwanenzang-test-head trk)))
            (with-current-buffer buf
              (should (equal head (zwanenzang-test-head trk)))))
          (should (stringp (zwanenzang-document-save))))
        (should-not (buffer-live-p doc))
        (should (equal (concat zwanenzang-test--document-prose "* Added in the buffer\n")
                       (zwanenzang-test--doc-text trk id "plan")))
        (let ((versions (zwanenzang-test--doc-versions trk id "plan")))
          (should (= 2 (length versions)))
          (should (equal (alist-get 'base (cadr versions)) (alist-get 'id (car versions)))))
        ;; Nothing went into the Org file, and the scope was pulled.
        (should-not (string-match-p "Added in the buffer" (buffer-string)))
        (should (string-match-p "document saved in Project" (zwanenzang-test-report)))))))

(ert-deftest zwanenzang-document-buffer-refuses-a-concurrent-version-then-replaces ()
  (zwanenzang-test-with-remote-scope (net trk buf zwanenzang-test--push-org)
    (let ((id (zwanenzang-test-create trk "Owner")))
      (zwanenzang-test-set-doc trk id "plan" "Base\n")
      (zwanenzang-test-pull)
      (zwanenzang-test--with-doc-buffer (doc (zwanenzang-test--open-doc id "plan"))
        (with-current-buffer doc
          (erase-buffer) (insert "Mine\n")
          (zwanenzang-test-set-doc trk id "plan" "Agent\n")
          (let ((err (should-error (zwanenzang-document-save) :type 'user-error)))
            (should (string-match-p "tester wrote a version of plan since" (cadr err))))
          (should (equal (buffer-string) "Mine\n"))
          (should (string-match-p "newer version by tester" header-line-format))
          (should (equal "Agent\n" (zwanenzang-test--doc-text trk id "plan")))
          ;; Declining keeps the text and writes nothing.
          (cl-letf (((symbol-function 'y-or-n-p)
                     (lambda (prompt)
                       (should (equal prompt "Replace version by tester? "))
                       nil)))
            (should-error (zwanenzang-document-save) :type 'user-error))
          (should (equal (buffer-string) "Mine\n"))
          (should (= 2 (length (zwanenzang-test--doc-versions trk id "plan"))))
          (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) t)))
            (zwanenzang-document-save)))
        (should-not (buffer-live-p doc))
        (should (equal "Mine\n" (zwanenzang-test--doc-text trk id "plan")))
        (let ((versions (zwanenzang-test--doc-versions trk id "plan")))
          (should (= 3 (length versions)))
          (should (equal (alist-get 'base (nth 2 versions)) (alist-get 'id (nth 1 versions)))))))))

(ert-deftest zwanenzang-document-buffer-abort-and-unchanged-write-nothing ()
  (zwanenzang-test-with-remote-scope (net trk buf zwanenzang-test--push-org)
    (let ((id (zwanenzang-test-create trk "Owner")))
      (zwanenzang-test-set-doc trk id "plan" "Base\n")
      (zwanenzang-test-pull)
      (let ((head (zwanenzang-test-head trk)))
        (zwanenzang-test--with-doc-buffer (doc (zwanenzang-test--open-doc id "plan"))
          (with-current-buffer doc
            (insert "Discarded ")
            (zwanenzang-document-abort))
          (should-not (buffer-live-p doc)))
        (zwanenzang-test--with-doc-buffer (doc (zwanenzang-test--open-doc id "plan"))
          (with-current-buffer doc
            (should (equal (buffer-string) "Base\n"))
            (goto-char (point-max)) (insert "\n\n")
            (should-not (zwanenzang-document-save)))
          (should-not (buffer-live-p doc)))
        (should (equal head (zwanenzang-test-head trk)))
        (should (= 1 (length (zwanenzang-test--doc-versions trk id "plan"))))))))

(ert-deftest zwanenzang-document-buffer-reopening-keeps-unsaved-edits ()
  (zwanenzang-test-with-remote-scope (net trk buf zwanenzang-test--push-org)
    (let ((id (zwanenzang-test-create trk "Owner")))
      (zwanenzang-test-set-doc trk id "plan" "Base\n")
      (zwanenzang-test-pull)
      (zwanenzang-test--with-doc-buffer (doc (zwanenzang-test--open-doc id "plan"))
        (with-current-buffer doc (goto-char (point-max)) (insert "Draft\n"))
        (zwanenzang-test-set-doc trk id "plan" "Agent\n")
        (with-current-buffer buf
          (should (eq doc (zwanenzang-test--open-doc id "plan"))))
        (with-current-buffer doc
          (should (equal (buffer-string) "Base\nDraft\n"))
          (set-buffer-modified-p nil))
        ;; Without edits it is refreshed from the tracker.
        (with-current-buffer buf
          (should (eq doc (zwanenzang-test--open-doc id "plan"))))
        (with-current-buffer doc
          (should (equal (buffer-string) "Agent\n")))))))

(ert-deftest zwanenzang-document-ediff-compares-with-the-tracker ()
  (zwanenzang-test-with-remote-scope (net trk buf zwanenzang-test--push-org)
    (let ((id (zwanenzang-test-create trk "Owner")) compared)
      (zwanenzang-test-set-doc trk id "plan" "Base\n")
      (zwanenzang-test-pull)
      (zwanenzang-test--with-doc-buffer (doc (zwanenzang-test--open-doc id "plan"))
        (zwanenzang-test-set-doc trk id "plan" "Agent\n")
        (with-current-buffer doc
          (cl-letf (((symbol-function 'ediff-buffers)
                     (lambda (a b) (setq compared (list a b)))))
            (zwanenzang-document-ediff)))
        (should (eq (car compared) doc))
        (with-current-buffer (cadr compared)
          (should (equal (buffer-string) "Agent\n"))
          (should buffer-read-only))
        (kill-buffer (cadr compared))))))

(ert-deftest zwanenzang-new-document-creates-a-first-version ()
  (zwanenzang-test-with-remote-scope (net trk buf zwanenzang-test--push-org)
    (let ((id (zwanenzang-test-create trk "Owner")))
      (zwanenzang-test-set-doc trk id "plan" "Plan\n")
      (zwanenzang-test-pull)
      (zwanenzang-test-goto id)
      (should-error (zwanenzang-new-document "description") :type 'user-error)
      (should-error (zwanenzang-new-document "no/slash") :type 'user-error)
      (should-error (zwanenzang-new-document "") :type 'user-error)
      ;; An existing name opens that document.
      (zwanenzang-test--with-doc-buffer (doc (save-excursion (zwanenzang-new-document "plan")))
        (with-current-buffer doc (should (equal (buffer-string) "Plan\n"))))
      (with-current-buffer buf (zwanenzang-test-goto id))
      (zwanenzang-test--with-doc-buffer (doc (save-excursion (zwanenzang-new-document "notes")))
        (with-current-buffer doc
          (should (derived-mode-p 'zwanenzang-document-mode))
          (should (equal (buffer-string) ""))
          (should-error (zwanenzang-document-save) :type 'user-error)
          (insert "First notes\n")
          (zwanenzang-document-save))
        (should-not (buffer-live-p doc)))
      (should (equal "First notes\n" (zwanenzang-test--doc-text trk id "notes")))
      (should (eq :null (alist-get 'base (car (zwanenzang-test--doc-versions trk id "notes")))))
      (should (string-match-p (regexp-quote (format "[[zwanenzang:%s/notes][notes]]" id))
                              (zwanenzang-test-entry id))))))

(ert-deftest zwanenzang-document-buffer-from-a-show-buffer ()
  ;; A ticket without a heading in the scope: its documents are reachable
  ;; through the show buffer, and saving still pulls the scope.
  (zwanenzang-test-with-remote-scope (net trk buf zwanenzang-test--push-org)
    (let ((pre (zwanenzang-test-create trk "Prerequisite"))
          (main (zwanenzang-test-create trk "Main")))
      (zwanenzang-test-cli trk "depend" main pre)
      (zwanenzang-test-set-doc trk pre "plan" "Base\n")
      (zwanenzang-test-pull)
      (zwanenzang-test-goto pre)
      (org-cut-subtree)
      (zwanenzang-test-goto main)
      (search-forward (concat "[[zwanenzang:" pre))
      (zwanenzang-test--with-doc-buffer (shown (zwanenzang-open))
        (with-current-buffer shown
          (should (string-match-p "\n\\*\\* Documents\n- \\[\\[zwanenzang:.*/plan\\]\\[plan\\]\\]"
                                  (buffer-string)))
          (goto-char (point-min))
          (search-forward "/plan]")
          (zwanenzang-test--with-doc-buffer (doc (zwanenzang-open))
            (with-current-buffer doc
              (erase-buffer) (insert "From the show buffer\n")
              (zwanenzang-document-save))))
        (should (equal "From the show buffer\n" (zwanenzang-test--doc-text trk pre "plan")))))))

(ert-deftest zwanenzang-document-migration-keeps-human-metadata ()
  ;; Properties, planning, keyword, priority and tags on an inline heading
  ;; are not in the document; such a heading stays, flagged, even when its
  ;; text is synced.
  (dolist (extra '((":CUSTOM_ID: human-link-target\n:MY_NOTE: Do not lose this\n" . "")
                   (":ID: 11111111-2222-3333-4444-555555555555\n" . "")
                   ("" . "SCHEDULED: <2026-11-20 Fri>\n")
                   ("" . "DEADLINE: <2026-11-21 Sat>\n")
                   ("" . :tags)
                   ("" . :keyword)))
    (zwanenzang-test-with-org
        (concat "#+TODO: TODO | DONE\n* TODO Owner\n:PROPERTIES:\n:ZWANENZANG_ID: owner\n:END:\n"
                "** " (if (eq (cdr extra) :keyword) "TODO " "") "plan"
                (if (eq (cdr extra) :tags) " :mine:" "") "\n"
                (if (stringp (cdr extra)) (cdr extra) "")
                ":PROPERTIES:\n:ZWANENZANG_DOC: plan\n" (car extra) ":END:\nPlan\n")
      (search-forward "TODO Owner")
      (let ((before (buffer-string))
            (conflicts (zwanenzang--migrate-docs '((plan . "Plan\n")))))
        (should (equal before (buffer-string)))
        (should (equal (mapcar #'car conflicts) '("document plan")))
        (should (string-match-p "properties, planning, tags" (nth 1 (car conflicts))))))))

(ert-deftest zwanenzang-document-migration-removes-a-bare-synced-heading ()
  (zwanenzang-test-with-org
      (concat "#+CATEGORY: work\n* TODO Owner\n:PROPERTIES:\n:ZWANENZANG_ID: owner\n:END:\n"
              "** plan\n:PROPERTIES:\n:ZWANENZANG_DOC: plan\n:ZWANENZANG_VERSION: V1\n:END:\nPlan\n"
              "** Kept sibling\n")
    (search-forward "TODO Owner")
    (should-not (zwanenzang--migrate-docs '((plan . "Plan\n"))))
    (should (equal (buffer-string)
                   (concat "#+CATEGORY: work\n* TODO Owner\n:PROPERTIES:\n:ZWANENZANG_ID: owner\n:END:\n"
                           "** Kept sibling\n")))))

(ert-deftest zwanenzang-document-buffer-saves-the-whole-document-when-narrowed ()
  (zwanenzang-test-with-remote-scope (net trk buf zwanenzang-test--push-org)
    (let ((id (zwanenzang-test-create trk "Owner"))
          (text "* First\nOne\n* Second\nTwo\n"))
      (zwanenzang-test-set-doc trk id "plan" text)
      (zwanenzang-test-pull)
      ;; Narrowing alone is no edit: nothing is written.
      (zwanenzang-test--with-doc-buffer (doc (zwanenzang-test--open-doc id "plan"))
        (with-current-buffer doc
          (goto-char (point-min))
          (org-narrow-to-subtree)
          (should-not (zwanenzang-document-save))))
      (should (= 1 (length (zwanenzang-test--doc-versions trk id "plan"))))
      (should (equal text (zwanenzang-test--doc-text trk id "plan")))
      ;; An edit while narrowed keeps the sections outside the restriction.
      (with-current-buffer buf
        (zwanenzang-test--with-doc-buffer (doc (zwanenzang-test--open-doc id "plan"))
          (with-current-buffer doc
            (goto-char (point-min))
            (org-narrow-to-subtree)
            (search-forward "One") (insert " more")
            (zwanenzang-document-save))))
      (should (equal "* First\nOne more\n* Second\nTwo\n"
                     (zwanenzang-test--doc-text trk id "plan"))))))

(provide 'zwanenzang-document-test)
;;; zwanenzang-document-test.el ends here
