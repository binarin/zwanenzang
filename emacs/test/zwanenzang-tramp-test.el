;;; zwanenzang-tramp-test.el --- Synthetic remote execution tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Intercept process-file before TRAMP can connect.  These tests never run
;; a real program or access a remote filesystem.

;;; Code:

(require 'ert)
(require 'tramp)
(require 'zwanenzang)

(defmacro zwanenzang-test-with-remote-runner (runner &rest body)
  "Run BODY with RUNNER replacing process-file and track local temporaries."
  (declare (indent 1))
  `(let ((files nil)
         (make-temp (symbol-function 'make-temp-file))
         (zwanenzang-program "/nonexistent/local-store/bin/zwanenzang"))
     (unwind-protect
         (cl-letf (((symbol-function 'process-file) ,runner)
                   ((symbol-function 'call-process-region)
                    (lambda (&rest _) (ert-fail "Local execution of remote scope")))
                   ((symbol-function 'executable-find)
                    (lambda (&rest _) (ert-fail "Local executable lookup")))
                   ((symbol-function 'make-temp-file)
                    (lambda (&rest args)
                      (let ((file (apply make-temp args)))
                        (should-not (file-remote-p file))
                        (push file files)
                        file))))
           ,@body)
       (dolist (file files)
         (let ((exists (file-exists-p file)))
           (when exists (delete-file file))
           (should-not exists))))))

(ert-deftest zwanenzang-tramp-dispatch-and-unicode-stdin ()
  (dolist (input '(nil ((title . "雪 café 🦢"))))
    (let ((calls 0))
      (zwanenzang-test-with-remote-runner
          (lambda (program infile destination display &rest args)
            (cl-incf calls)
            (should (equal program "zwanenzang"))
            (should (equal default-directory "/ssh:operator@example.invalid#2222:/tracker's dir/"))
            (should-not display)
            (should (equal args '("-C" "/tracker's dir/" "comment" "ZZ-42" "spaces ' and \"quotes\"")))
            (if input
                (with-temp-buffer
                  (insert-file-contents infile)
                  (should (equal (zwanenzang--json-parse) input)))
              (should-not infile))
            (with-temp-file (cadr destination) (insert "diagnostic 雪\n"))
            (insert "{\"title\":\"café 雪\"}")
            0)
        (let ((result (zwanenzang--run
                       "/ssh:operator@example.invalid#2222:/tracker's dir"
                       '("comment" "ZZ-42" "spaces ' and \"quotes\"") input)))
          (should (= calls 1))
          (should (equal (plist-get result :json) '((title . "café 雪"))))
          (should (equal (plist-get result :stderr) "diagnostic 雪"))
          (should (= (length files) (if input 2 1))))))))

(ert-deftest zwanenzang-tramp-json-and-exit-semantics ()
  (dolist (case '((0 "{}" "" nil)
                  (1 "{\"sync\":{\"error\":\"offline\"}}" "" nil)
                  (1 "{\"error\":{\"code\":\"stale-doc-base\",\"message\":\"changed\"}}"
                     "" zwanenzang-stale-doc-base)
                  (1 "{\"error\":{\"code\":\"not-a-tracker\",\"message\":\"missing\"}}"
                     "" user-error)
                  (2 "" "usage 雪" user-error)
                  (127 "" "command not found" user-error)
                  (1 "not JSON" "transport failed" user-error)
                  (0 "" "" user-error)))
    (pcase-let ((`(,exit ,stdout ,stderr ,error-type) case))
      (zwanenzang-test-with-remote-runner
          (lambda (_program _infile destination _display &rest _args)
            (with-temp-file (cadr destination) (insert stderr))
            (insert stdout)
            exit)
        (if error-type
            (should-error (zwanenzang-call "/ssh:example.invalid:/tracker" '("read"))
                          :type error-type)
          (should (equal (zwanenzang-call "/ssh:example.invalid:/tracker" '("read"))
                         (with-temp-buffer
                           (insert stdout) (zwanenzang--json-parse)))))))))

(ert-deftest zwanenzang-tramp-cleans-up-on-transport-error-and-quit ()
  (dolist (failure '(file-error quit))
    (zwanenzang-test-with-remote-runner
        (lambda (&rest _) (signal failure '("transport unavailable")))
      (should
       (eq (condition-case nil
               (zwanenzang--run "/ssh:example.invalid:/tracker" '("apply") '((title . "雪")))
             (user-error 'user-error)
             (quit 'quit))
           (if (eq failure 'quit) 'quit 'user-error)))
      (should (= (length files) 2)))))

(ert-deftest zwanenzang-tramp-cleans-up-on-staging-failures ()
  (dolist (failure '(allocation write))
    (zwanenzang-test-with-remote-runner
        (lambda (&rest _) (ert-fail "Process started after staging failure"))
      (let ((allocate (symbol-function 'make-temp-file))
            (write (symbol-function 'write-region)))
        (cl-letf (((symbol-function 'make-temp-file)
                   (lambda (&rest args)
                     (if (and (eq failure 'allocation) files)
                         (signal 'file-error '("cannot allocate stdin"))
                       (apply allocate args))))
                  ((symbol-function 'write-region)
                   (lambda (&rest args)
                     (if (eq failure 'write)
                         (signal 'file-error '("cannot write stdin"))
                       (apply write args)))))
          (should-error
           (zwanenzang--run "/ssh:example.invalid:/tracker" '("apply") '((title . "雪")))
           :type 'file-error))))))

(ert-deftest zwanenzang-tramp-invalid-input-has-no-side-effects ()
  (zwanenzang-test-with-remote-runner
      (lambda (&rest _) (ert-fail "Process started for invalid JSON"))
    (should-error
     (zwanenzang--run "/ssh:example.invalid:/tracker" '("apply")
                      `((title . ,(string-to-unibyte "\377"))))
     :type 'user-error)
    (should-not files)))

(ert-deftest zwanenzang-tramp-scope-directory-is-handler-aware ()
  (dolist (case '(("/ssh:user@example.invalid#2222:/tracker's dir" nil
                   "/ssh:user@example.invalid#2222:/tracker's dir")
                  ("../tracker" "/ssh:example.invalid:/home/user/org/tasks.org"
                   "/ssh:example.invalid:/home/user/tracker")
                  ("/ssh:example.invalid:~/tracker" nil
                   "/ssh:example.invalid:/home/operator/tracker")))
    (pcase-let ((`(,location ,org-file ,expected) case))
      (with-temp-buffer
        (org-mode)
        (insert "* Scope\n:PROPERTIES:\n:ZWANENZANG: " location "\n:END:\n")
        (goto-char (point-min))
        (let ((buffer-file-name org-file)
              (root (point-marker))
              (expand (symbol-function 'expand-file-name))
              checked)
          (cl-letf (((symbol-function 'expand-file-name)
                     (lambda (name &optional directory)
                       ;; Simulate TRAMP's remote home expansion without SSH.
                       (if (equal name "/ssh:example.invalid:~/tracker")
                           "/ssh:example.invalid:/home/operator/tracker"
                         (funcall expand name directory))))
                    ((symbol-function 'file-directory-p)
                     (lambda (directory) (setq checked directory) t)))
            (should (equal (zwanenzang--scope-directory root) expected))
            (should (equal checked expected)))
          (cl-letf (((symbol-function 'expand-file-name)
                     (lambda (&rest _) expected))
                    ((symbol-function 'file-directory-p) (lambda (_) nil)))
            (should-error (zwanenzang--scope-directory root) :type 'user-error)))))))

(defmacro zwanenzang-tramp-test--offline (&rest body)
  "Run BODY failing the test if anything starts a process.
TRAMP would start one to connect, so this keeps BODY off the network."
  (declare (indent 0))
  `(cl-letf (((symbol-function 'make-process)
              (lambda (&rest _) (ert-fail "Process started: TRAMP connected")))
             ((symbol-function 'process-file)
              (lambda (&rest _) (ert-fail "Remote process run"))))
     ,@body))

(ert-deftest zwanenzang-tramp-scope-location-is-on-the-org-files-machine ()
  ;; (ORG-FILE LOCATION RESOLVED DIRECTORY): RESOLVED is the scope location
  ;; as compared, DIRECTORY the expanded tracker directory.
  (dolist (case `(("/ssh:example.invalid:/home/user/org/tasks.org" "~/tracker"
                   "/ssh:example.invalid:~/tracker"
                   "/ssh:example.invalid:/home/operator/tracker")
                  ("/ssh:example.invalid:/home/user/org/tasks.org" "/srv/tracker"
                   "/ssh:example.invalid:/srv/tracker"
                   "/ssh:example.invalid:/srv/tracker")
                  ("/ssh:example.invalid:/home/user/org/tasks.org" "tracker"
                   "/ssh:example.invalid:/home/user/org/tracker"
                   "/ssh:example.invalid:/home/user/org/tracker")
                  ;; A TRAMP location is used as is, on whichever machine.
                  ("/ssh:example.invalid:/home/user/org/tasks.org"
                   "/sudo:root@other.invalid:/srv/tracker"
                   "/sudo:root@other.invalid:/srv/tracker"
                   "/sudo:root@other.invalid:/srv/tracker")
                  ;; Local files are unchanged.
                  ("/home/user/org/tasks.org" "~/tracker"
                   ,(expand-file-name "~/tracker") ,(expand-file-name "~/tracker"))
                  ("/home/user/org/tasks.org" "/srv/tracker"
                   "/srv/tracker" "/srv/tracker")
                  ("/home/user/org/tasks.org" "tracker"
                   "/home/user/org/tracker" "/home/user/org/tracker")))
    (pcase-let ((`(,org-file ,location ,resolved ,directory) case))
      (with-temp-buffer
        (org-mode)
        (insert "* Scope\n:PROPERTIES:\n:ZWANENZANG: " location "\n:END:\n")
        (goto-char (point-min))
        (let ((buffer-file-name org-file)
              (default-directory (file-name-directory org-file))
              (root (point-marker))
              (expand (symbol-function 'expand-file-name))
              checked)
          (zwanenzang-tramp-test--offline
            (cl-letf (((symbol-function 'expand-file-name)
                       (lambda (name &optional dir)
                         ;; Simulate TRAMP's remote home expansion without SSH.
                         (if (equal name "/ssh:example.invalid:~/tracker")
                             "/ssh:example.invalid:/home/operator/tracker"
                           (funcall expand name dir))))
                      ((symbol-function 'file-directory-p)
                       (lambda (dir) (setq checked dir) t)))
              (should (equal (zwanenzang--scope-directory root) directory))
              (should (equal checked directory)))
            (should (equal (zwanenzang--scope-location location) resolved))))))))

(ert-deftest zwanenzang-tramp-scope-location-keeps-every-hop ()
  ;; Unless ad-hoc proxies are shown, `file-remote-p' of a multi-hop name
  ;; gives only its last hop; the prefix a name is given keeps them all.
  (let* ((tramp-default-proxies-alist tramp-default-proxies-alist)
         (hops "/ssh:jump.invalid|sudo:root@target.invalid:"))
    (let ((tramp-show-ad-hoc-proxies nil))
      (zwanenzang-tramp-test--offline
        (should (equal (zwanenzang--file-name-on-host "~/tracker" (concat hops "/x/"))
                       (concat hops "~/tracker")))
        (should (equal (zwanenzang--file-name-on-host "/srv/tracker" (concat hops "/x/"))
                       (concat hops "/srv/tracker")))
        (should (equal (zwanenzang--comment-record
                        (zwanenzang--pull-create :tracker-dir (concat hops "/trk/"))
                        '((actor . "A1") (ts . "2026-11-07T10:00:00Z")
                          (text . "text") (link . "/srv/x.md")))
                       (concat "[2026-11-07T10:00:00Z] A1:\ntext\n[[file:" hops
                               "/srv/x.md]]\n")))))
  ;; Names TRAMP makes, such as a visited file's directory, keep the hops
  ;; only with ad-hoc proxies shown.
  (let* ((tramp-show-ad-hoc-proxies t)
         (org-file (concat hops "/home/user/org/tasks.org")))
    (dolist (case `(("~/tracker" ,(concat hops "~/tracker") ,(concat hops "/root/tracker"))
                    ("/srv/tracker" ,(concat hops "/srv/tracker") ,(concat hops "/srv/tracker"))
                    ("tracker" ,(concat hops "/home/user/org/tracker")
                     ,(concat hops "/home/user/org/tracker"))))
      (pcase-let ((`(,location ,resolved ,directory) case))
        (with-temp-buffer
          (org-mode)
          (insert "* Scope\n:PROPERTIES:\n:ZWANENZANG: " location "\n:END:\n")
          (goto-char (point-min))
          (let ((buffer-file-name org-file)
                (default-directory (file-name-directory org-file))
                (root (point-marker))
                (expand (symbol-function 'expand-file-name)))
            (zwanenzang-tramp-test--offline
              (should (equal (zwanenzang--scope-location location) resolved))
              (cl-letf (((symbol-function 'expand-file-name)
                         (lambda (name &optional dir)
                           ;; Simulate TRAMP's remote home expansion without SSH.
                           (if (equal name (concat hops "~/tracker"))
                               (concat hops "/root/tracker")
                             (funcall expand name dir))))
                        ((symbol-function 'file-directory-p) (lambda (_) t)))
                (should (equal (zwanenzang--scope-directory root) directory)))))))))))

(ert-deftest zwanenzang-tramp-comment-links-are-on-the-trackers-machine ()
  (let ((pull (zwanenzang--pull-create :tracker-dir "/ssh:example.invalid:/trk/")))
    (zwanenzang-tramp-test--offline
      (dolist (case '(("docs/x.md" "[[file:/ssh:example.invalid:/trk/docs/x.md]]")
                      ("/srv/x.md" "[[file:/ssh:example.invalid:/srv/x.md]]")
                      ("~/x.md" "[[file:/ssh:example.invalid:~/x.md]]")
                      ("/ssh:other.invalid:/x.md" "[[file:/ssh:other.invalid:/x.md]]")
                      ("https://example.invalid/mr/1" "[[https://example.invalid/mr/1]]")))
        (pcase-let ((`(,link ,rendered) case))
          (should (equal (zwanenzang--comment-record
                          pull `((actor . "A1") (ts . "2026-11-07T10:00:00Z")
                                 (text . "text") (link . ,link)))
                         (concat "[2026-11-07T10:00:00Z] A1:\ntext\n" rendered "\n"))))))))

(ert-deftest zwanenzang-tramp-dependency-snapshot-follows-the-files-machine ()
  ;; The same location text names another tracker once the buffer visits a
  ;; file on another machine, so the snapshot no longer applies.
  (with-temp-buffer
    (insert "* Scope\n:PROPERTIES:\n:ZWANENZANG: ~/tracker\n:ZWANENZANG_TRACKER: t\n:END:\n")
    (org-mode)
    (goto-char (point-min))
    (let ((root (point-marker)))
      (let ((buffer-file-name "/home/user/org/tasks.org"))
        (zwanenzang--remember-dependencies
         (zwanenzang--pull-create :root root :tracker "t"
                                  :known (make-hash-table :test #'equal)))
        (should (zwanenzang--dependency-snapshot root)))
      (let ((buffer-file-name "/ssh:example.invalid:/home/user/org/tasks.org"))
        (zwanenzang-tramp-test--offline
          (should-not (zwanenzang--dependency-snapshot root)))))))

(ert-deftest zwanenzang-tramp-pull-failure-preserves-org ()
  (with-temp-buffer
    (org-mode)
    (insert "* Scope\n:PROPERTIES:\n:ZWANENZANG: /ssh:example.invalid:/tracker\n:END:\n** TODO Human title\nHuman prose 雪\n")
    (goto-char (point-min))
    (let ((before (buffer-string))
          (directory-p (symbol-function 'file-directory-p))
          (zwanenzang--call #'zwanenzang-call))
      (zwanenzang-test-with-remote-runner
          (lambda (&rest _) (signal 'file-error '("transport unavailable")))
        (cl-letf (((symbol-function 'file-directory-p)
                   (lambda (directory)
                     (if (file-remote-p directory) t
                       (funcall directory-p directory)))))
          (should-error (zwanenzang-pull) :type 'user-error))
        (should (equal (buffer-string) before))))))

(provide 'zwanenzang-tramp-test)
;;; zwanenzang-tramp-test.el ends here
