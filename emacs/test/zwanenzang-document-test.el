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
  "Install TEXT in the document heading at point."
  (zwanenzang--write-document text))

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
            (search-backward "** plan")
            (should (equal (concat zwanenzang-test--document-prose "* New heading\n")
                           (zwanenzang--document-text))))
        (when (buffer-live-p edit)
          (with-current-buffer edit (set-buffer-modified-p nil)) (kill-buffer edit))
        (when (buffer-live-p host)
          (with-current-buffer host (set-buffer-modified-p nil)) (kill-buffer host))))))

(ert-deftest zwanenzang-document-migration-noop-and-edited-version ()
  (zwanenzang-test-with-remote-scope (net trk buf zwanenzang-test--push-org)
                                     (let ((id (zwanenzang-test-create trk "Owner" "--status" "todo")))
                                       (zwanenzang-test-set-doc trk id "plan" zwanenzang-test--document-prose)
                                       (zwanenzang-test-pull)
                                       (zwanenzang-test-goto id)
                                       (goto-char (cdr (assoc "plan" (zwanenzang--doc-headings))))
                                       ;; Recreate a pre-upgrade file, including its original decoded baseline.
                                       (let ((host (car (zwanenzang--document-parts))))
                                         (zwanenzang--write-body
                                          (zwanenzang--compose-body host nil zwanenzang-test--document-prose)))
                                       (org-entry-delete nil "ZWANENZANG_DOC_FORMAT")
                                       (zwanenzang-test-pull)
                                       (zwanenzang-test-at-root #'zwanenzang-push)
                                       (should (= 1 (length (zwanenzang-test--doc-versions trk id "plan"))))
                                       (zwanenzang-test-goto id)
                                       (should (zwanenzang--prose-synced-p (point-marker)))
                                       (goto-char (cdr (assoc "plan" (zwanenzang--doc-headings))))
                                       (should (equal zwanenzang-test--document-prose (zwanenzang--document-text)))
                                       (should (equal "org-src-v1" (org-entry-get nil "ZWANENZANG_DOC_FORMAT")))
                                       ;; An unsynced legacy edit survives upgrade and creates one version only.
                                       (let ((host (car (zwanenzang--document-parts))))
                                         (zwanenzang--write-body
                                          (zwanenzang--compose-body host nil (concat zwanenzang-test--document-prose "* Edited\n"))))
                                       (org-entry-delete nil "ZWANENZANG_DOC_FORMAT")
                                       (zwanenzang-test-pull)
                                       (zwanenzang-test-at-root #'zwanenzang-push)
                                       (should (equal (concat zwanenzang-test--document-prose "* Edited\n")
                                                      (zwanenzang-test--doc-text trk id "plan")))
                                       (should (= 2 (length (zwanenzang-test--doc-versions trk id "plan"))))
                                       (zwanenzang-test-at-root #'zwanenzang-push)
                                       (should (= 2 (length (zwanenzang-test--doc-versions trk id "plan")))))))

(ert-deftest zwanenzang-document-source-edit-publishes-one-decoded-version ()
  (save-window-excursion
    (zwanenzang-test-with-remote-scope (net trk buf zwanenzang-test--push-org)
                                       (let ((id (zwanenzang-test-create trk "Owner" "--status" "todo")) edit)
                                         (zwanenzang-test-set-doc trk id "plan" zwanenzang-test--document-prose)
                                         (zwanenzang-test-set-doc trk id "status" "* Hidden prose\n")
                                         (zwanenzang-test-pull)
                                         (switch-to-buffer buf)
                                         (zwanenzang-test-goto id)
                                         (should-not (assoc "status" (zwanenzang--doc-headings)))
                                         (goto-char (cdr (assoc "plan" (zwanenzang--doc-headings))))
                                         (search-forward "#+begin_src") (beginning-of-line)
                                         (unwind-protect
                                             (progn
                                               (let ((org-src-window-setup 'current-window)) (org-edit-src-code))
                                               (setq edit (current-buffer))
                                               (should (equal (buffer-string) zwanenzang-test--document-prose))
                                               (should (equal default-directory
                                                              (with-current-buffer buf default-directory)))
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
                                               (let ((before (buffer-string)))
                                                 (zwanenzang-test-at-root #'zwanenzang-sync)
                                                 (should (equal before (buffer-string))))
                                               (should (= 2 (length (zwanenzang-test--doc-versions trk id "plan"))))
                                               (should (= 1 (length (zwanenzang-test--doc-versions trk id "status"))))
                                               (should (= 1 (hash-table-count (zwanenzang--known-tickets trk)))))
                                           (when (buffer-live-p edit)
                                             (with-current-buffer edit (set-buffer-modified-p nil)) (kill-buffer edit)))))))

(ert-deftest zwanenzang-document-malformed-fence-cannot-create-fake-ticket ()
  (zwanenzang-test-with-remote-scope (net trk buf zwanenzang-test--push-org)
                                     (let ((id (zwanenzang-test-create trk "Owner" "--status" "todo")))
                                       (zwanenzang-test-set-doc trk id "plan" "* TODO Fake ticket\n")
                                       (zwanenzang-test-pull)
                                       (zwanenzang-test-goto id)
                                       (goto-char (cdr (assoc "plan" (zwanenzang--doc-headings))))
                                       ;; Remove source escaping, exposing what would otherwise be a create.
                                       (search-forward ",* TODO") (replace-match "* TODO")
                                       (let ((before (buffer-string)) (head (zwanenzang-test-head trk)))
                                         (should-error (zwanenzang-test-at-root #'zwanenzang-push) :type 'user-error)
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
                                       (zwanenzang-test-goto id)
                                       (should (zwanenzang--prose-synced-p (point-marker)))
                                       (let ((h (car (plist-get (zwanenzang--scan-all root) :headings))))
                                         (should-not (member "document plan" (zwanenzang--archive-unpushed h)))
                                         (goto-char (cdr (assoc "plan" (zwanenzang--doc-headings))))
                                         (zwanenzang-test--document (concat zwanenzang-test--document-prose "edit\n"))
                                         (goto-char (plist-get h :marker))
                                         (should-not (zwanenzang--prose-synced-p (point-marker)))
                                         (should (member "document plan" (zwanenzang--archive-unpushed h)))))))

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

(ert-deftest zwanenzang-document-legacy-conflict-keeps-local-prose-and-base ()
  (zwanenzang-test-with-remote-scope (net trk buf zwanenzang-test--push-org)
                                     (let ((id (zwanenzang-test-create trk "Owner" "--status" "todo")))
                                       (zwanenzang-test-set-doc trk id "plan" "* Base\n")
                                       (zwanenzang-test-pull)
                                       (zwanenzang-test-goto id)
                                       (goto-char (cdr (assoc "plan" (zwanenzang--doc-headings))))
                                       (let ((base (org-entry-get nil "ZWANENZANG_VERSION"))
                                             (hash (org-entry-get nil "ZWANENZANG_HASH"))
                                             (local (concat zwanenzang-test--document-prose "* Local edit\n")))
                                         (zwanenzang--write-body
                                          (zwanenzang--compose-body (car (zwanenzang--document-parts)) nil local))
                                         (org-entry-delete nil "ZWANENZANG_DOC_FORMAT")
                                         (zwanenzang-test-set-doc trk id "plan" "* Agent edit\n")
                                         (zwanenzang-test-pull)
                                         (zwanenzang-test-goto id)
                                         (should (member "zz_conflict" (org-get-tags nil t)))
                                         (goto-char (cdr (assoc "plan" (zwanenzang--doc-headings))))
                                         (should (equal local (zwanenzang--document-text)))
                                         (should (equal base (org-entry-get nil "ZWANENZANG_VERSION")))
                                         (should (equal hash (org-entry-get nil "ZWANENZANG_HASH")))
                                         (zwanenzang-test-at-root #'zwanenzang-push)
                                         (should (equal local (zwanenzang-test--doc-text trk id "plan")))
                                         (should (= 3 (length (zwanenzang-test--doc-versions trk id "plan"))))
                                         (should-not (member "zz_conflict" (zwanenzang-test-tags id)))))))

(provide 'zwanenzang-document-test)
;;; zwanenzang-document-test.el ends here
