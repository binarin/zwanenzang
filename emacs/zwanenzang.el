;;; zwanenzang.el --- Org client for the zwanenzang tracker  -*- lexical-binding: t; -*-

;; Author: Alexey Lebedeff
;; Version: 0.1.0
;; Package-Requires: ((emacs "31.1"))
;; Keywords: outlines, tools

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Two-way sync between Org subtrees and zwanenzang trackers.  A heading
;; with a ZWANENZANG property naming a tracker location is a scope root;
;; the ticket headings beneath it sync with that tracker through the
;; `zwanenzang' CLI and its JSON contract.
;;
;; Everything happens through explicit interactive commands: there is no
;; minor mode, hook or timer.  CLI calls are synchronous.
;;
;; The design is in docs/design/03-org-client.md and the CLI contract in
;; docs/cli-json.md of the zwanenzang repository.

;;; Code:

(require 'org)

(defgroup zwanenzang nil
  "Sync Org subtrees with zwanenzang trackers."
  :group 'org
  :prefix "zwanenzang-")

;; The Nix build replaces this default with the store path of the CLI built
;; from the same flake; keep the form on one line so the substitution finds it.
(defcustom zwanenzang-program "zwanenzang"
  "The zwanenzang CLI: an absolute file name, or a name looked up on `exec-path'."
  :type 'string)

(defcustom zwanenzang-org-files 'agenda
  "Org files scanned for scope roots by commands acting on every scope.
The symbol `agenda' means the files of `org-agenda-files'."
  :type '(choice (const :tag "Same as `org-agenda-files'" agenda)
                 (repeat :tag "These files" file)))

(defun zwanenzang--org-files ()
  "The files `zwanenzang-org-files' names, as absolute file names."
  (if (eq zwanenzang-org-files 'agenda)
      (org-agenda-files t)
    (mapcar #'expand-file-name zwanenzang-org-files)))

;;;; Calling the CLI

;; JSON null and false stay distinct from nil, which is the empty object or
;; list: a null cursor and an absent one mean different things to the CLI.
;; The converse does not hold: a parsed empty array or object is nil too,
;; so a parsed value must not be sent back in a request as it stands.

(defun zwanenzang--json-parse ()
  "Parse the JSON value in the current buffer."
  (goto-char (point-min))
  (json-parse-buffer :object-type 'alist :array-type 'list
                     :null-object :null :false-object :false))

(defun zwanenzang--json-encode (value)
  "Encode VALUE, built like the output of `zwanenzang--json-parse', as JSON.
A value that has no JSON form, such as a string holding raw bytes,
signals `user-error'."
  (condition-case err
      (json-serialize value :null-object :null :false-object :false)
    ((wrong-type-argument json-error)
     (user-error "zwanenzang: cannot encode the request as JSON: %s"
                 (error-message-string err)))))

(defun zwanenzang--run (directory args &optional input)
  "Run `zwanenzang-program' on the tracker at or above DIRECTORY with ARGS.
INPUT, when non-nil, is encoded as JSON and given on stdin.  Return a
plist with :exit (the exit status), :parsed (whether stdout is one JSON
value), :json (that value) and :stderr.  This signals only when the
program cannot be run or INPUT cannot be encoded; a failed command is
for `zwanenzang-call' to judge."
  (let* ((default-directory (file-name-as-directory (expand-file-name directory)))
         (stdin (if input (zwanenzang--json-encode input) ""))
         (stderr-file (make-temp-file "zwanenzang-stderr-"))
         (coding-system-for-read 'utf-8)
         (coding-system-for-write 'utf-8))
    (unwind-protect
        (with-temp-buffer
          (let* ((exit (condition-case err
                           (apply #'call-process-region stdin nil zwanenzang-program
                                  nil (list t stderr-file) nil
                                  "-C" (file-local-name default-directory) args)
                         (file-error
                          (user-error "zwanenzang: cannot run %s (%s); see `zwanenzang-program'"
                                      zwanenzang-program (error-message-string err)))))
                 (parsed t)
                 (json (and (> (buffer-size) 0)
                            (condition-case nil (zwanenzang--json-parse)
                              (json-error (setq parsed nil))))))
            (list :exit exit
                  :parsed (and parsed (> (buffer-size) 0))
                  :json json
                  :stderr (with-temp-buffer
                            (insert-file-contents stderr-file)
                            (string-trim (buffer-string))))))
      (delete-file stderr-file))))

(defun zwanenzang--error-object (json)
  "The error object in JSON, a parsed CLI output, or nil."
  (let ((err (and (consp json) (alist-get 'error json))))
    (and (consp err) err)))

(defun zwanenzang--command-name (args)
  "The subcommand in ARGS, skipping global options and their values."
  (let (name)
    (while (and args (not name))
      (let ((a (pop args)))
        (cond ((member a '("-C" "--tracker" "--actor-name")) (pop args))
              ((string-prefix-p "-" a))
              (t (setq name a)))))
    (or name "zwanenzang")))

(defun zwanenzang-call (directory args &optional input)
  "Run the CLI on the tracker at or above DIRECTORY with ARGS; return its JSON.
INPUT, when non-nil, is encoded as JSON on stdin.  A failed command
signals `user-error' naming the error code and message: a JSON error
object, a usage error (exit status 2), or a non-zero exit with no JSON.
Any other JSON is returned whatever the exit status, because some
commands exit 1 with a full result: `sync' when publication failed,
`lint' when it found issues.  Callers judge those from the JSON."
  (let* ((result (zwanenzang--run directory args input))
         (exit (plist-get result :exit))
         (json (plist-get result :json))
         (err (zwanenzang--error-object json))
         (command (zwanenzang--command-name args)))
    (cond
     (err
      (user-error "zwanenzang: %s: %s"
                  (alist-get 'code err) (alist-get 'message err)))
     ((eql exit 2)
      (user-error "zwanenzang: usage: %s" (plist-get result :stderr)))
     ((plist-get result :parsed) json)
     ((eql exit 0)
      (user-error "zwanenzang: %s printed no JSON" command))
     (t
      (user-error "zwanenzang: %s exited with %s: %s"
                  command exit (plist-get result :stderr))))))

;;;; Reports

(defconst zwanenzang-report-buffer "*zwanenzang*"
  "Buffer collecting readable reports of publication errors and skips.")

(defun zwanenzang-report (summary &optional details)
  "Echo SUMMARY and append it with DETAILS to the `*zwanenzang*' buffer.
DETAILS is a list of strings, one line each.  This is for outcomes that
are not failures, such as a sync that could not publish; the report keeps
what the one-line echo cannot hold."
  (with-current-buffer (get-buffer-create zwanenzang-report-buffer)
    (unless (derived-mode-p 'special-mode)
      (special-mode))
    (let ((inhibit-read-only t))
      (save-excursion
        (goto-char (point-max))
        (unless (bobp) (insert "\n"))
        (insert (format-time-string "[%F %T] ") summary "\n")
        (dolist (line details)
          (insert "  " line "\n")))))
  (message "%s%s" summary
           (if details (format " (see %s)" zwanenzang-report-buffer) "")))

(provide 'zwanenzang)
;;; zwanenzang.el ends here
