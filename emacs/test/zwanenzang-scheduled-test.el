;;; zwanenzang-scheduled-test.el --- SCHEDULED dates, parsed and synced  -*- lexical-binding: t; -*-

;;; Commentary:

;; The tracker's `scheduled' field against the heading's SCHEDULED: date:
;; reading and normalising Org timestamps, writing the planning line
;; without touching DEADLINE or CLOSED, and pull and push against the real
;; CLI on disposable trackers.

;;; Code:

(require 'ert)
(require 'zwanenzang)
(require 'zwanenzang-test-helpers)
(require 'zwanenzang-pull-test)

(defconst zwanenzang-test--scheduled-org
  (concat "#+TODO: TODO NEXT WAIT | DONE CNCL\n"
          "* Project\n"
          ":PROPERTIES:\n"
          ":ZWANENZANG: %s\n"
          ":ZWANENZANG_KEYWORDS: TODO=next,todo NEXT=agnt,revw WAIT=wait"
          " DONE=done CNCL=cncl\n"
          ":END:\n")
  "An Org file with one scope; %s is the tracker.")

(defun zwanenzang-test--weekday (year month day)
  "The weekday Org writes for YEAR-MONTH-DAY in the running locale."
  (format-time-string "%a" (org-encode-time 0 0 0 day month year)))

(defun zwanenzang-test--planning-line (id)
  "The planning line of ticket ID's heading, or nil when it has none."
  (save-excursion
    (zwanenzang-test-goto id)
    (forward-line)
    (and (looking-at-p org-planning-line-re)
         (buffer-substring-no-properties (point) (line-end-position)))))

(defun zwanenzang-test--set-planning-line (id line)
  "Make LINE the planning line of ticket ID's heading, as a human types it.
Nil removes the line."
  (save-excursion
    (zwanenzang-test-goto id)
    (forward-line)
    (when (looking-at-p org-planning-line-re)
      (delete-region (point) (line-beginning-position 2)))
    (when line (insert line "\n"))))

(defun zwanenzang-test--scheduled (dir id)
  "The tracker's scheduled value of ticket ID in DIR, nil for none."
  (zwanenzang--null (alist-get 'scheduled (zwanenzang-test-show dir id))))

(defun zwanenzang-test--set-planning-line-here (line)
  "Make LINE the planning line of the heading at point."
  (save-excursion
    (org-back-to-heading t)
    (forward-line)
    (when (looking-at-p org-planning-line-re)
      (delete-region (point) (line-beginning-position 2)))
    (insert line "\n")))

;;;; Without the CLI

(ert-deftest zwanenzang-scheduled-normalize-matches-the-cli-form ()
  (dolist (case '(("2026-12-03" . "2026-12-03")
                  ("2026-12-03 Thu" . "2026-12-03")
                  ("2026-12-03 do 9:05" . "2026-12-03 09:05")
                  ("2026-12-03 jeu. 10:00-11:30" . "2026-12-03 10:00-11:30")
                  ("2026-12-03 Thu 10:00 +1w" . "2026-12-03 10:00 +1w")
                  ("2026-12-03 Thu -2d .+1m" . "2026-12-03 .+1m -2d")
                  ("2026-12-03 ++1y --3d" . "2026-12-03 ++1y --3d")
                  ("2026-12-03 .+1d/3d" . "2026-12-03 .+1d/3d")
                  ("2024-02-29" . "2024-02-29")
                  ;; glibc's %a for Thursday and Monday in vi_VN, he_IL,
                  ;; sm_WS, hi_IN and am_ET (with its trailing blank).
                  ("2026-12-03 T5 10:00 +1w" . "2026-12-03 10:00 +1w")
                  ("2026-12-03 ה' 10:00 +1w" . "2026-12-03 10:00 +1w")
                  ("2026-12-03 Aso Tof 10:00 +1w" . "2026-12-03 10:00 +1w")
                  ("2026-12-03 Aso To' -2d" . "2026-12-03 -2d")
                  ("2026-12-07 सोम: 9:00" . "2026-12-07 09:00")
                  ("2026-12-07 ሰኞ  .+1d" . "2026-12-07 .+1d")
                  ("2026-12-03 suno esun #4 ++1m" . "2026-12-03 ++1m")
                  ("2026-12-03 Thu 10:00 Fri")
                  ("2026-12-03 T<5")
                  ("2026-12-03 .5")
                  ("2026-12-03 +1é")
                  ("2026-12-03 -日")
                  ;; Org reads these as a repeater, delay or time on the
                  ;; weekday; the word must not be dropped with them.
                  ("2026-12-03 Thu+1w")
                  ("2026-12-03 Thu.+1d")
                  ("2026-12-03 Thu-2d")
                  ("2026-12-03 Thu10:00")
                  ("2026-12-03 Aso Tof+1w")
                  ;; Any white space separates words, so none hides a time.
                  ("2026-12-03 C\u00a0 10:00" . "2026-12-03 10:00")
                  ("2026-12-03 Thu\u00a010:00 +1w" . "2026-12-03 10:00 +1w")
                  ("2026-12-03 Thu\n10:00" . "2026-12-03 10:00")
                  ("2026-12-03\u3000Thu\u2009-2d" . "2026-12-03 -2d")
                  ("2026-02-29")
                  ("2026-04-31")
                  ("2026-13-01")
                  ("2026-12-03 24:00")
                  ("2026-12-03 10:60")
                  ("2026-12-03 10:00-25:00")
                  ("2026-12-03 +1w +2w")
                  ("2026-12-03 -1d -2d")
                  ("2026-12-03 10:00 11:00")
                  ("2026-12-03 +1x")
                  ("%%(diary-float t 4 2)")
                  ("tomorrow")
                  ("")))
    (should (equal (zwanenzang--planning-normalize (car case)) (cdr case)))))

(ert-deftest zwanenzang-scheduled-reads-only-its-planning-keyword ()
  (zwanenzang-test-with-org
      (concat "* TODO A\nCLOSED: [2026-11-01 Sun 10:00] SCHEDULED: <2026-12-03 Thu 9:00 +1w>"
              " DEADLINE: <2026-12-05 Sat>\nbody SCHEDULED: <2027-01-01 Fri>\n"
              "* TODO Range\nSCHEDULED: <2026-12-03 Thu>--<2026-12-05 Sat>\n"
              "* TODO Inactive\nSCHEDULED: [2026-12-03 Thu]\n"
              "* TODO Sexp\nSCHEDULED: <%%(diary-float t 4 2)>\n"
              "* TODO Impossible\nSCHEDULED: <2026-02-30 Mon>\n"
              "* TODO Deadline only\nDEADLINE: <2026-12-05 Sat>\n"
              "* TODO In the body\ntext\nSCHEDULED: <2026-12-03 Thu>\n")
    (let (seen)
      (while (re-search-forward org-heading-regexp nil t)
        (push (cons (plist-get (zwanenzang--heading) :title)
                    (zwanenzang--planning-local "SCHEDULED"))
              seen))
      (should (equal (nreverse seen)
                     '(("A" . "2026-12-03 09:00 +1w")
                       ("Range" :unrepresentable . "<2026-12-03 Thu>--<2026-12-05 Sat>")
                       ("Inactive" :unrepresentable . "[2026-12-03 Thu]")
                       ("Sexp" :unrepresentable . "<%%(diary-float t 4 2)>")
                       ("Impossible" :unrepresentable . "<2026-02-30 Mon>")
                       ("Deadline only")
                       ("In the body")))))))

(ert-deftest zwanenzang-scheduled-write-keeps-deadline-closed-and-body ()
  (zwanenzang-test-with-org
      (concat "* TODO A\nCLOSED: [2026-11-01 Sun 10:00] DEADLINE: <2026-12-05 Sat -1d>\n"
              ":PROPERTIES:\n:X: 1\n:END:\nThe description.\n"
              "* TODO B\nBody of B.\n")
    (zwanenzang--set-planning 'scheduled "2026-12-03 10:00-11:00 +1w -2d")
    (let ((line (buffer-substring-no-properties (line-beginning-position 2)
                                                (save-excursion (forward-line) (line-end-position)))))
      (should (string-match-p (regexp-quote
                               (format "SCHEDULED: <2026-12-03 %s 10:00-11:00 +1w -2d>"
                                       (zwanenzang-test--weekday 2026 12 3)))
                              line))
      (should (string-match-p (regexp-quote "CLOSED: [2026-11-01 Sun 10:00]") line))
      (should (string-match-p (regexp-quote "DEADLINE: <2026-12-05 Sat -1d>") line)))
    (should (equal (zwanenzang--planning-local "SCHEDULED") "2026-12-03 10:00-11:00 +1w -2d"))
    (should (equal (zwanenzang--body-description (zwanenzang--body)) "The description.\n"))
    (should (equal (org-entry-get nil "X") "1"))
    (zwanenzang--set-planning 'scheduled "2027-01-04")
    (should (equal (zwanenzang--planning-local "SCHEDULED") "2027-01-04"))
    (zwanenzang--set-planning 'scheduled nil)
    (should-not (zwanenzang--planning-raw "SCHEDULED"))
    (should (equal (zwanenzang--planning-raw "DEADLINE") "<2026-12-05 Sat -1d>"))
    (should (equal (zwanenzang--planning-raw "CLOSED") "[2026-11-01 Sun 10:00]"))
    ;; A heading without a planning line gets one in Org's place, and
    ;; loses it again when its only keyword goes.
    (outline-next-heading)
    (zwanenzang--set-planning 'scheduled "2026-12-03")
    (should (equal (buffer-substring-no-properties (point) (point-max))
                   (format "* TODO B\nSCHEDULED: <2026-12-03 %s>\nBody of B.\n"
                           (zwanenzang-test--weekday 2026 12 3))))
    (zwanenzang--set-planning 'scheduled nil)
    (should (equal (buffer-substring-no-properties (point) (point-max))
                   "* TODO B\nBody of B.\n"))))

(ert-deftest zwanenzang-scheduled-write-stays-inside-a-folded-heading ()
  (dolist (org-fold-core-style '(overlays text-properties))
    (let ((text "* Parent\n** TODO A\n:PROPERTIES:\n:X: 1\n:END:\nText\n** Next\n"))
      (zwanenzang-test-with-org text
        (org-fold-subtree t)
        (search-forward "TODO A")
        (org-back-to-heading t)
        (zwanenzang--set-planning 'scheduled "2026-12-03 10:00")
        (save-excursion
          (forward-line)
          (should (looking-at-p "SCHEDULED: <2026-12-03 [^ ]+ 10:00>$"))
          (should (invisible-p (point))))
        (zwanenzang--set-planning 'scheduled nil)
        (should (equal (buffer-substring-no-properties (point-min) (point-max)) text))))))

(ert-deftest zwanenzang-scheduled-sync-key-round-trips ()
  (let ((alist `((status . "todo") (priority . "-1")
                 (scheduled . ,(zwanenzang--planning-key "2026-12-03 10:00 +1w")))))
    (should (equal (zwanenzang--format-sync alist)
                   "status=todo priority=-1 scheduled=2026-12-03_10:00_+1w"))
    (let ((parsed (zwanenzang--parse-sync (zwanenzang--format-sync alist))))
      (should (equal (zwanenzang--planning-base parsed 'scheduled) "2026-12-03 10:00 +1w"))))
  (should (equal (zwanenzang--format-sync '((status . "todo") (scheduled)))
                 "status=todo scheduled=-"))
  (should-not (zwanenzang--planning-base (zwanenzang--parse-sync "status=todo scheduled=-")
                                         'scheduled))
  ;; Written before the field existed: no date as last synced.
  (should-not (zwanenzang--planning-base (zwanenzang--parse-sync "status=todo") 'scheduled)))

(ert-deftest zwanenzang-scheduled-edit-is-listed-as-unpushed-on-archive ()
  (zwanenzang-test-with-org
      (concat "* TODO A\nSCHEDULED: <2026-12-04 Fri>\n:PROPERTIES:\n"
              ":ZWANENZANG_SYNC: status=todo title=" (zwanenzang--hash "A")
              " priority=-1 scheduled=2026-12-03 tags=" (zwanenzang--tags-hash nil)
              " depends=" (zwanenzang--tags-hash nil) " parent=- nest=-\n"
              ":ZWANENZANG_DESC_HASH: " (zwanenzang--hash "") "\n:END:\n")
    (should (equal (zwanenzang--archive-unpushed '(:nest nil)) '("scheduled")))
    (zwanenzang-test--set-planning-line-here "SCHEDULED: <2026-12-03 Thu>")
    (should-not (zwanenzang--archive-unpushed '(:nest nil)))))

;;;; Org's own timestamps in other locales

(defconst zwanenzang-test--locale-weekdays
  '("Thu" "do" "jeu." "T5" "ה'" "Aso Tof" "Aso To'" "सोम:" "ሰኞ " "suno esun #4"
    "جۆمعه آخشامی" "ሰ/ን" "木"
    "C\u00a0")
  "Weekdays as glibc's %a writes them in various locales.")

(defun zwanenzang-test--with-weekday (weekday fn)
  "Call FN while `format-time-string' writes WEEKDAY for %a, as a locale would.
The weekday goes in after formatting, so it stays text in any locale the
tests run in, the C locale of a build sandbox included."
  (let ((real (symbol-function 'format-time-string)))
    (cl-letf (((symbol-function 'format-time-string)
               (lambda (format &rest args)
                 (string-replace "\x1" weekday
                                 (apply real (string-replace "%a" "\x1" format) args)))))
      (funcall fn))))

(ert-deftest zwanenzang-scheduled-org-written-locale-timestamps-round-trip ()
  (dolist (weekday zwanenzang-test--locale-weekdays)
    (zwanenzang-test-with-org "* TODO A\nBody.\n"
      (zwanenzang-test--with-weekday
       weekday
       (lambda ()
         (dolist (value '("2026-12-03" "2026-12-03 10:00 +1w" "2026-12-03 09:30-10:00 .+1d -2d"))
           (zwanenzang--set-planning 'scheduled value)
           (should (string-search weekday (zwanenzang--planning-raw "SCHEDULED")))
           (should (equal (cons weekday (zwanenzang--planning-local "SCHEDULED"))
                          (cons weekday value))))
         ;; Org's own change of date, as `org-schedule' makes it.
         (org-add-planning-info 'scheduled (org-encode-time 0 0 0 4 12 2026))
         (should (equal (cons weekday (zwanenzang--planning-local "SCHEDULED"))
                        (cons weekday "2026-12-04"))))))))

(ert-deftest zwanenzang-scheduled-real-locales-round-trip ()
  (let (ran)
    (dolist (locale '("vi_VN.utf8" "he_IL.utf8" "sm_WS.utf8" "am_ET.utf8" "lv_LV.utf8"))
      (let ((system-time-locale locale))
        ;; Only where the locale is installed; elsewhere %a stays English.
        (unless (equal (format-time-string "%a" (org-encode-time 0 0 0 3 12 2026)) "Thu")
          (setq ran t)
          (zwanenzang-test-with-org "* TODO A\n"
            (zwanenzang--set-planning 'scheduled "2026-12-03 10:00 +1w")
            (should (equal (cons locale (zwanenzang--planning-local "SCHEDULED"))
                           (cons locale "2026-12-03 10:00 +1w")))))))
    (unless ran (ert-skip "no non-English locale installed"))))

;;;; Against the CLI

(ert-deftest zwanenzang-scheduled-pull-writes-and-clears-without-touching-deadline ()
  (zwanenzang-test-with-scope (trk buf zwanenzang-test--scheduled-org)
    (let ((id (zwanenzang-test-create trk "Check back")))
      (zwanenzang-test-pull)
      (should-not (zwanenzang-test--planning-line id))
      (should (string-match-p "scheduled=-" (zwanenzang-test-property id "ZWANENZANG_SYNC")))
      ;; The human's own DEADLINE, CLOSED and text stay as they are.
      (zwanenzang-test--set-planning-line
       id "DEADLINE: <2026-12-10 Thu> CLOSED: [2026-11-20 Fri 08:00]")
      (save-excursion
        (zwanenzang-test-goto id)
        (zwanenzang--write-body
         (zwanenzang--compose-body (zwanenzang--body) nil "Human text.\n")))
      (zwanenzang-test-cli trk "schedule" id "2026-12-03" "10:00" "+1w")
      (zwanenzang-test-pull)
      (let ((line (zwanenzang-test--planning-line id)))
        (should (string-match-p
                 (regexp-quote (format "SCHEDULED: <2026-12-03 %s 10:00 +1w>"
                                       (zwanenzang-test--weekday 2026 12 3)))
                 line))
        (should (string-match-p (regexp-quote "DEADLINE: <2026-12-10 Thu>") line))
        (should (string-match-p (regexp-quote "CLOSED: [2026-11-20 Fri 08:00]") line)))
      (should (string-match-p "scheduled=2026-12-03_10:00_\\+1w"
                              (zwanenzang-test-property id "ZWANENZANG_SYNC")))
      (should (string-match-p "Human text\\." (zwanenzang-test-entry id)))
      (should-not (member zwanenzang-conflict-tag (zwanenzang-test-tags id)))
      ;; Org's own spelling of the same value is no edit, and a pull
      ;; writes nothing over it.
      (zwanenzang-test--set-planning-line
       id "DEADLINE: <2026-12-10 Thu> SCHEDULED: <2026-12-03 Thursday 10:00 +1w>")
      (zwanenzang-test-pull)
      (should (equal (zwanenzang-test--planning-line id)
                     "DEADLINE: <2026-12-10 Thu> SCHEDULED: <2026-12-03 Thursday 10:00 +1w>"))
      (zwanenzang-test-cli trk "schedule" id "--clear")
      (zwanenzang-test-pull)
      (should (equal (zwanenzang-test--planning-line id) "DEADLINE: <2026-12-10 Thu>"))
      (should (string-match-p "scheduled=-" (zwanenzang-test-property id "ZWANENZANG_SYNC")))
      (should (string-match-p "Human text\\." (zwanenzang-test-entry id))))))

(ert-deftest zwanenzang-scheduled-push-sends-org-edits-and-clearing ()
  (zwanenzang-test-with-remote-scope (net trk buf zwanenzang-test--scheduled-org)
    (zwanenzang-test-append "** TODO New with a date\nSCHEDULED: <2026-12-03 Thu 9:00 -1d>\n")
    (zwanenzang-test-at-root #'zwanenzang-push)
    (let ((id (zwanenzang-test-id-of "New with a date")))
      (should (equal (zwanenzang-test--scheduled trk id) "2026-12-03 09:00 -1d"))
      ;; The pull ending the push left the human's spelling alone.
      (should (equal (zwanenzang-test--planning-line id)
                     "SCHEDULED: <2026-12-03 Thu 9:00 -1d>"))
      (zwanenzang-test--set-planning-line id "SCHEDULED: <2026-12-04 Fri .+1w>")
      (zwanenzang-test-at-root #'zwanenzang-push)
      (should (equal (zwanenzang-test--scheduled trk id) "2026-12-04 .+1w"))
      (zwanenzang-test--set-planning-line id nil)
      (zwanenzang-test-at-root #'zwanenzang-push)
      (should-not (zwanenzang-test--scheduled trk id))
      ;; Nothing changed in Org: nothing to send.
      (let ((head (zwanenzang-test-head trk)))
        (zwanenzang-test-at-root #'zwanenzang-push)
        (should (equal head (zwanenzang-test-head trk)))))))

(ert-deftest zwanenzang-scheduled-both-changed-is-a-conflict-org-wins-on-push ()
  (zwanenzang-test-with-remote-scope (net trk buf zwanenzang-test--scheduled-org)
    (let ((id (zwanenzang-test-create trk "Contested")))
      (zwanenzang-test-cli trk "schedule" id "2026-12-03")
      (zwanenzang-test-pull)
      (zwanenzang-test--set-planning-line id "SCHEDULED: <2026-12-07 Mon>")
      (zwanenzang-test-cli trk "schedule" id "2026-12-10")
      (zwanenzang-test-pull)
      (should (member zwanenzang-conflict-tag (zwanenzang-test-tags id)))
      (should (string-match-p "- scheduled: tracker scheduled date skipped; Org SCHEDULED kept"
                              (zwanenzang-test-entry id)))
      (should (string-match-p ": 2026-12-10" (zwanenzang-test-entry id)))
      (should (equal (zwanenzang-test--planning-line id) "SCHEDULED: <2026-12-07 Mon>"))
      (zwanenzang-test-at-root #'zwanenzang-push)
      (should (equal (zwanenzang-test--scheduled trk id) "2026-12-07"))
      (should-not (member zwanenzang-conflict-tag (zwanenzang-test-tags id)))
      (should-not (string-match-p "ZWANENZANG_CONFLICT" (zwanenzang-test-entry id))))))

(ert-deftest zwanenzang-scheduled-first-sync-after-upgrade-pushes-local-date ()
  (zwanenzang-test-with-remote-scope (net trk buf zwanenzang-test--scheduled-org)
    (let ((kept (zwanenzang-test-create trk "Dated before the upgrade"))
          (taken (zwanenzang-test-create trk "Dated by an agent")))
      (zwanenzang-test-pull)
      ;; As an older client left them: no scheduled= in the sync state.
      (dolist (id (list kept taken))
        (save-excursion
          (zwanenzang-test-goto id)
          (zwanenzang--put "ZWANENZANG_SYNC"
                           (zwanenzang--format-sync
                            (assq-delete-all 'scheduled
                                             (zwanenzang--parse-sync
                                              (org-entry-get nil "ZWANENZANG_SYNC")))))))
      (should-not (string-match-p "scheduled=" (zwanenzang-test-property kept "ZWANENZANG_SYNC")))
      (zwanenzang-test--set-planning-line kept "SCHEDULED: <2026-12-03 Thu>")
      (zwanenzang-test-cli trk "schedule" taken "2026-12-08")
      (zwanenzang-test-at-root #'zwanenzang-sync)
      (should (equal (zwanenzang-test--scheduled trk kept) "2026-12-03"))
      (should (string-match-p "SCHEDULED: <2026-12-08 "
                              (zwanenzang-test--planning-line taken)))
      (should (equal (zwanenzang-test--scheduled trk taken) "2026-12-08"))
      (dolist (id (list kept taken))
        (should-not (member zwanenzang-conflict-tag (zwanenzang-test-tags id)))))))

(ert-deftest zwanenzang-scheduled-unrepresentable-is-skipped-with-a-warning ()
  (zwanenzang-test-with-remote-scope (net trk buf zwanenzang-test--scheduled-org)
    (let ((id (zwanenzang-test-create trk "Ranged")))
      (zwanenzang-test-pull)
      (cl-loop
       for line in '("SCHEDULED: <2026-12-03 Thu>--<2026-12-05 Sat> DEADLINE: <2026-12-06 Sun>"
                     "SCHEDULED: [2026-12-03 Thu]"
                     "SCHEDULED: <%%(diary-float t 4 2)>"
                     "SCHEDULED: <2026-02-30 Mon>")
       for n from 1
       do
        (zwanenzang-test--set-planning-line id line)
        (save-excursion
          (zwanenzang-test-goto id)
          (org-edit-headline (format "Ranged %d" n)))
        (zwanenzang-test-clear-report)
        (zwanenzang-test-at-root #'zwanenzang-push)
        ;; The other fields still went; the date did not, and Org's line
        ;; is exactly as the human left it.
        (should (equal (alist-get 'title (zwanenzang-test-show trk id))
                       (format "Ranged %d" n)))
        (should-not (zwanenzang-test--scheduled trk id))
        (should (equal (zwanenzang-test--planning-line id) line))
        (should (string-match-p "scheduled not pushed: SCHEDULED .* is a range, inactive or diary"
                                (zwanenzang-test-report)))
        (should (string-match-p "scheduled=-" (zwanenzang-test-property id "ZWANENZANG_SYNC"))))
      ;; A tracker date does not overwrite such a line either.
      (zwanenzang-test-cli trk "schedule" id "2026-12-09")
      (zwanenzang-test-clear-report)
      (zwanenzang-test-pull)
      (should (equal (zwanenzang-test--planning-line id) "SCHEDULED: <2026-02-30 Mon>"))
      (should (string-match-p "SCHEDULED <2026-02-30 Mon> not synced" (zwanenzang-test-report)))
      (should-not (member zwanenzang-conflict-tag (zwanenzang-test-tags id))))))

(ert-deftest zwanenzang-scheduled-attached-repeater-is-skipped-never-dropped ()
  (zwanenzang-test-with-remote-scope (net trk buf zwanenzang-test--scheduled-org)
    (let ((id (zwanenzang-test-create trk "Attached repeater"))
          (line "SCHEDULED: <2026-12-03 Thu+1w> DEADLINE: <2026-12-06 Sun>"))
      (zwanenzang-test-pull)
      ;; Org itself reads the word as a weekday with a repeater.
      (zwanenzang-test--set-planning-line id line)
      (save-excursion
        (zwanenzang-test-goto id)
        (search-forward "<")
        (backward-char)
        (should (eq (org-element-property :repeater-type (org-element-timestamp-parser))
                    'cumulate)))
      (zwanenzang-test-clear-report)
      (zwanenzang-test-at-root #'zwanenzang-push)
      ;; Not sent as a plain date, and not recorded as synced.
      (should-not (zwanenzang-test--scheduled trk id))
      (should (string-match-p "scheduled not pushed: SCHEDULED <2026-12-03 Thu\\+1w>"
                              (zwanenzang-test-report)))
      (should (string-match-p "scheduled=-" (zwanenzang-test-property id "ZWANENZANG_SYNC")))
      ;; A tracker date leaves the line, repeater included, as it is.
      (zwanenzang-test-cli trk "schedule" id "2026-12-04")
      (zwanenzang-test-pull)
      (should (equal (zwanenzang-test--planning-line id) line)))))

(provide 'zwanenzang-scheduled-test)
;;; zwanenzang-scheduled-test.el ends here
