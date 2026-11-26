;;; zwanenzang-queue.el --- Human attention through org-ql -*- lexical-binding: t; -*-

;;; Commentary:
;; A narrow org-ql adapter: local projected metadata, native Org priorities,
;; and interactive activity/waiting age selection.  Rendering never runs a CLI.

;;; Code:

(require 'zwanenzang)
(require 'org-ql-search)

(declare-function org-ql--normalize-query "org-ql" t t)

(defcustom zwanenzang-queue-attention-tag "needs_human"
  "Local ticket tag identifying the human-attention queue."
  :type 'string :group 'zwanenzang)

(defcustom zwanenzang-queue-query '(todo)
  "Additional org-ql query for the attention queue.
The default selects unfinished headings.  Local attention tag, tracker
scope, ticket identity, and active-ticket constraints are always added."
  :type 'sexp :group 'zwanenzang)

(defvar-local zwanenzang-queue-age-mode 'activity)
(defvar-local zwanenzang-queue--sources nil)

(defun zwanenzang-queue--eligible-p ()
  "Whether point is an actual active tracker ticket, not a document."
  (and (org-entry-get nil "ZWANENZANG" t)
       (org-entry-get nil "ZWANENZANG_ID")
       (not (org-entry-get nil "ZWANENZANG_DOC"))
       (not (org-entry-get nil "ZWANENZANG_INACTIVE"))
       (not (org-in-archived-heading-p))))

(defun zwanenzang-queue--timestamp (mode tag)
  "Selected projected timestamp at point, for MODE and attention TAG."
  (if (eq mode 'activity)
      (org-entry-get nil "ZWANENZANG_ACTIVITY")
    (when-let* ((json (org-entry-get nil "ZWANENZANG_TAG_SINCE"))
                (intervals (ignore-errors
                             (json-parse-string json :object-type 'alist))))
      (alist-get 'ts (alist-get (intern tag) intervals)))))

(defun zwanenzang-queue--seconds (timestamp)
  "Parse event TIMESTAMP, returning nil for missing or invalid wall time."
  (and timestamp
       (string-match-p "\\`[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}T" timestamp)
       (ignore-errors (float-time (date-to-time timestamp)))))

(defun zwanenzang-queue--location ()
  "The scope location of the heading at point, or nil outside every scope.
A queue result refiled out of its scope since the view was built has none."
  (when-let* ((location (org-entry-get nil "ZWANENZANG" t)))
    (zwanenzang--scope-location location)))

(defun zwanenzang-queue--key (element mode tag)
  "Sort key for org-ql ELEMENT using MODE and TAG.
Use native Org's configured default for an absent cookie, not org-ql's
missing-cookie fallback.  All keys come from buffers, never the CLI."
  (org-with-point-at (org-element-property :org-hd-marker element)
    (list (or (plist-get (zwanenzang--heading) :priority) org-priority-default)
          (zwanenzang-queue--seconds (zwanenzang-queue--timestamp mode tag))
          (org-entry-get nil "ZWANENZANG_ID")
          (zwanenzang-queue--location))))

(defun zwanenzang-queue--less-p (mode tag a b)
  "Compare org-ql elements A and B using MODE and TAG."
  (pcase-let ((`(,ap ,at ,ai ,as) (zwanenzang-queue--key a mode tag))
              (`(,bp ,bt ,bi ,bs) (zwanenzang-queue--key b mode tag)))
    (cond ((/= ap bp) (< ap bp))
          ((and at bt (/= at bt)) (< at bt))
          ((and at (not bt)) t)
          ((and bt (not at)) nil)
          ((not (equal ai bi)) (string< ai bi))
          (t (string< as bs)))))

(defun zwanenzang-queue--age (timestamp)
  "Honest age label for TIMESTAMP, including unknown/future clocks."
  (if-let* ((seconds (zwanenzang-queue--seconds timestamp)))
      (let ((age (- (float-time) seconds)))
        (if (< age 0) "future clock"
          (format "%dd" (floor (/ age 86400)))))
    "unknown"))

(defun zwanenzang-queue--identity ()
  "Identity of the result at point, including its tracker location."
  (when-let* ((marker (get-text-property (line-beginning-position) 'org-hd-marker)))
    (org-with-point-at marker
      (cons (zwanenzang-queue--location)
            (org-entry-get nil "ZWANENZANG_ID")))))

(defvar-keymap zwanenzang-queue-mode-map
  :doc "Keys for the zwanenzang org-ql adapter."
  "a" #'zwanenzang-queue-select-age
  "g" #'zwanenzang-queue-refresh)

(define-minor-mode zwanenzang-queue-mode
  "Show projected tracker ages in an org-ql view.
Use a to select age mode and g to rebuild from local Org buffers.  Sync
explicitly in the source scope for remote freshness; g never fetches."
  :lighter " ZZ-queue" :keymap zwanenzang-queue-mode-map)

(defun zwanenzang-queue--format-element (formatter element)
  "Use FORMATTER on ELEMENT, correcting older org-ql numeric-cookie display."
  (let ((text (funcall formatter element))
        (value (org-element-property :priority element)))
    (if (and value (org-priority-number-p value))
        (replace-regexp-in-string (regexp-quote (format "[#%c]" value))
                                  (format "[#%d]" value) text t t)
      text)))

(defun zwanenzang-queue--render (sources mode &optional selected)
  "Render SOURCES with age MODE, retaining SELECTED identity if possible."
  (let ((tag zwanenzang-queue-attention-tag)
        (org-agenda-dim-blocked-tasks nil)
        (org-agenda-skip-archived-trees t))
    (cl-letf (((symbol-function 'org-ql-view--format-element)
               (apply-partially #'zwanenzang-queue--format-element
                                (symbol-function 'org-ql-view--format-element))))
      (org-ql-search sources
      `(and ,zwanenzang-queue-query (tags-local ,tag)
            (zwanenzang-queue--eligible-p))
      :sort (apply-partially #'zwanenzang-queue--less-p mode tag)
      :super-groups nil :buffer "*zwanenzang queue*"
      :title (format "Human attention — %s (a: age; g: local refresh; sync sources explicitly)"
                     (if (eq mode 'activity) "last activity" "waiting for human"))))
    (pop-to-buffer "*zwanenzang queue*")
    (setq-local zwanenzang-queue--sources sources
                zwanenzang-queue-age-mode mode)
    (zwanenzang-queue-mode 1)
    ;; Keep org-ql's navigation properties.  No global advice or upstream
    ;; changes are needed to display ages and local-read freshness.
    (let ((inhibit-read-only t) target)
      (goto-char (point-min))
      (while (not (eobp))
        (when-let* ((marker (get-text-property (point) 'org-hd-marker)))
          (let* ((props (text-properties-at (point)))
                 (prefix
                  (org-with-point-at marker
                    (format "[%s; snapshot read %s] "
                            (zwanenzang-queue--age (zwanenzang-queue--timestamp mode tag))
                            (or (org-entry-get nil "ZWANENZANG_READ_AT") "unknown")))))
            (insert (apply #'propertize prefix props))
            (when (equal selected (zwanenzang-queue--identity))
              (setq target (line-beginning-position)))))
        (forward-line 1))
      (goto-char (or target (point-min))))))

;;;###autoload
(defun zwanenzang-queue ()
  "Open an org-ql human-attention queue over `zwanenzang-org-files'.
Uses the existing local Org projections, including unsynced human edits.
Nothing is fetched or written.  Press a to switch between activity and
waiting age, without changing tags, TODO states or priority cookies."
  (interactive)
  (zwanenzang-queue--render (zwanenzang--org-files) 'activity))

(defun zwanenzang-queue-refresh ()
  "Rebuild the queue from local buffers, retaining the selected ticket."
  (interactive)
  (unless zwanenzang-queue-mode (user-error "Not a zwanenzang queue"))
  (zwanenzang-queue--render zwanenzang-queue--sources zwanenzang-queue-age-mode
                          (zwanenzang-queue--identity)))

(defun zwanenzang-queue-select-age (mode)
  "Interactively select activity or waiting age MODE for this view only."
  (interactive
   (list (if (equal (completing-read "Age: " '("Last activity" "Waiting for human") nil t)
                    "Last activity") 'activity 'waiting)))
  (unless zwanenzang-queue-mode (user-error "Not a zwanenzang queue"))
  (unless (memq mode '(activity waiting)) (user-error "Unknown age mode"))
  (zwanenzang-queue--render zwanenzang-queue--sources mode (zwanenzang-queue--identity)))

(provide 'zwanenzang-queue)
;;; zwanenzang-queue.el ends here
