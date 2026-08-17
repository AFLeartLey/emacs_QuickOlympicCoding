;;; quickolympic.el --- Competitive programming test manager (FastOlympicCoding clone) -*- lexical-binding: t; -*-

;; Copyright (C) 2026 QuickOlympic

;; Author: QuickOlympic
;; Version: 0.1.0
;; Keywords: tools, languages, wp
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:
;; QuickOlympic — an Emacs clone of FastOlympicCoding.
;; Provides: sample test management (side panel), compile & run, manual
;; verdict (accept/decline), and persistence.
;;
;; Quick start:
;;   M-x quickolympic-global-mode        ; enable globally
;;   C-c C-q p                             ; toggle the test side panel
;;   C-c C-q r                             ; compile & run all tests
;;   C-c C-q n                             ; add a new test (then edit input)
;; Panel keys: n new / e edit / r run current / R run all / a accept /
;;             x reject / d delete / s up / S down / k kill / g re-render /
;;             q close panel
;;
;; Platforms: Windows / Linux.

;;; Code:

;; Bootstrap: when this file is loaded directly via `load-file' (instead of
;; through load-path), add its directory to load-path so sibling files load.
(let ((dir (and load-file-name (file-name-directory load-file-name))))
  (when (and dir (not (member dir load-path)))
    (add-to-list 'load-path dir)))

(require 'cl-lib)
(require 'button)
(require 'json)
(require 'subr-x)
(require 'quickolympic-process)

(defun quickolympic--normalize-output (s)
  "Normalize program output: CRLF -> LF and strip lone CRs.
Windows console programs often write CRLF even to a pipe, which garbles the
panel display and breaks output comparisons."
  (replace-regexp-in-string "\r\n" "\n"
    (replace-regexp-in-string "\r" "" (or s ""))))

;;; ---------------------------------------------------------------------------
;;; Customization group
;;; ---------------------------------------------------------------------------

(defgroup quickolympic nil
  "Competitive programming test manager (FastOlympicCoding clone)."
  :group 'tools
  :prefix "quickolympic-")

(defcustom quickolympic-stop-on-fail t
  "Stop running remaining tests after a crash/TLE/non-zero exit."
  :type 'boolean
  :group 'quickolympic)

(defcustom quickolympic-panel-width 0.32
  "Width of the test side panel (fraction of the frame, 0~1)."
  :type 'float
  :group 'quickolympic)

(defcustom quickolympic-test-timeout nil
  "Per-test timeout in seconds; nil means no timeout."
  :type '(choice (const :tag "No timeout" nil) (integer :tag "seconds"))
  :group 'quickolympic)

(defcustom quickolympic-algorithms-base nil
  "Directory of algorithm templates (used by `quickolympic-insert-template')."
  :type '(choice (const :tag "Not set" nil) directory)
  :group 'quickolympic)

;; Verdict faces.
(defface quickolympic-status-accepted
  '((t :foreground "green"))
  "Face for the Accepted verdict."
  :group 'quickolympic)

(defface quickolympic-status-rejected
  '((t :foreground "red"))
  "Face for the Rejected verdict."
  :group 'quickolympic)

(defface quickolympic-status-time-limit
  '((t :foreground "yellow"))
  "Face for the Time Limit verdict."
  :group 'quickolympic)

(defface quickolympic-status-runtime-error
  '((t :foreground "purple"))
  "Face for the Runtime Error verdict."
  :group 'quickolympic)

(defun quickolympic--default-run-settings ()
  "Return platform-aware default run settings."
  (let ((exe-ext (if (eq system-type 'windows-nt) ".exe" ""))
        (g++ (or (executable-find "g++") "g++"))
        (python (or (executable-find "python") "python")))
    `((:lang "C++" :extensions ("cpp" "cc" "cxx")
       :compile ,(format "\"%s\" \"{source_file}\" -std=c++17 -O2 -o \"{file_name}%s\""
                         g++ exe-ext)
       ;; Run must reference the binary by absolute path: bash (Git Bash)
       ;; does not search the current directory for executables; cmd does,
       ;; but an absolute path is the safest across both.
       :run ,(format "\"{source_file_dir}{file_name}%s\" {args}" exe-ext)
       :lint ,(format "\"%s\" -std=gnu++17 -fsyntax-only \"{source_file}\"" g++))
      (:lang "Python" :extensions ("py")
       :compile nil
       :run ,(format "\"%s\" \"{source_file}\"" python)))))

(defcustom quickolympic-run-settings (quickolympic--default-run-settings)
  "Run settings. Each entry is a plist:
  (:lang NAME :extensions (EXT...) :compile CMD :run CMD [:lint CMD])
CMD supports placeholders {file} {source_file} {source_file_dir} {file_name}
{args}. A nil :compile means no compile step."
  :type 'sexp
  :group 'quickolympic)

;;; ---------------------------------------------------------------------------
;;; Data model
;;; ---------------------------------------------------------------------------

(cl-defstruct quickolympic-test
  "A single test case. Each test has at most ONE correct answer
(`correct-answer'), set by accepting an output; accepting a new output
REPLACES it, so an old wrong answer is never kept as correct.
`wrong-answers' records outputs the user explicitly rejected."
  input
  (correct-answer nil)
  (wrong-answers nil)
  (folded t)
  (runtime "-")
  (rtcode nil)
  (output ""))

(cl-defstruct quickolympic-session
  "Session state associated with one source file."
  source-file
  (tests nil)
  (panel-buffer nil)
  (process nil)
  (current-test nil)
  (interactive-p nil)
  (compile-output nil)
  (run-id 0))

(defvar quickolympic--sessions (make-hash-table :test #'equal)
  "Sessions keyed by absolute source file path.")

(defun quickolympic--get-session (file)
  "Return the session for FILE, creating it if needed."
  (let ((file (expand-file-name file)))
    (or (gethash file quickolympic--sessions)
        (puthash file (make-quickolympic-session :source-file file)
                 quickolympic--sessions))))

;;; ---------------------------------------------------------------------------
;;; Persistence
;;; ---------------------------------------------------------------------------

(defun quickolympic--tests-file (file)
  "Return the sidecar tests file path for FILE."
  (concat file ".tests"))

(defun quickolympic--json-get (item key)
  "Get KEY from json-parsed alist ITEM (accepts symbol or string keys)."
  (let ((str-key (if (stringp key) key (symbol-name key))))
    (or (cdr (assoc str-key item))
        (cdr (assoc (intern str-key) item)))))

(defun quickolympic--json-strlist (x)
  "Convert a JSON array (vector or list) to a list of strings; nil if not one."
  (cond
   ((vectorp x) (append x nil))
   ((listp x) x)
   (t nil)))

(defun quickolympic--load-tests (session)
  "Load SESSION's tests from the sidecar file (ignore if missing)."
  (let ((tf (quickolympic--tests-file (quickolympic-session-source-file session))))
    (when (file-exists-p tf)
      (condition-case nil
          (let* ((data (json-read-file tf))
                 (items (if (vectorp data) (append data nil) data))
                 (tests (cl-loop for item in items
                                 for input = (quickolympic--json-get item "input")
                                 when input
                                 collect (make-quickolympic-test
                                          :input input
                                          :correct-answer
                                          (let ((c (quickolympic--normalize-output
                                                    (or (quickolympic--json-get item "correct-answer")
                                                        ;; backward compat: old plural key
                                                        (car (quickolympic--json-strlist
                                                              (quickolympic--json-get item "correct-answers")))))))
                                            ;; An empty correct answer means "not accepted".
                                            (and (not (string-empty-p c)) c))
                                          :wrong-answers
                                          (mapcar #'quickolympic--normalize-output
                                                  (quickolympic--json-strlist
                                                   (quickolympic--json-get item "wrong-answers")))))))
            (setf (quickolympic-session-tests session) tests))
        (error (message "quickolympic: failed to parse tests file %s" tf))))))

(defun quickolympic--ensure-tests-loaded (session)
  "Load tests from disk into SESSION if it has none yet.
Prevents a fresh session from clobbering persisted testcases on the first
mutating command (e.g. `C-c C-q n' without a prior run)."
  (when (and session (null (quickolympic-session-tests session)))
    (quickolympic--load-tests session)))

(defun quickolympic--ensure-loaded-tests (session)
  "Ensure SESSION's tests are loaded from disk, then return them."
  (quickolympic--ensure-tests-loaded session)
  (and session (quickolympic-session-tests session)))

(defun quickolympic--save-tests (session)
  "Atomically write SESSION's tests to the sidecar file."
  (let ((tf (quickolympic--tests-file (quickolympic-session-source-file session)))
        (data (cl-loop for test in (quickolympic-session-tests session)
                       collect `(("input" . ,(quickolympic-test-input test))
                                 ,@(when (quickolympic-test-correct-answer test)
                                     `(("correct-answer" . ,(quickolympic-test-correct-answer test))))
                                 ,@(when (quickolympic-test-wrong-answers test)
                                     `(("wrong-answers" . ,(quickolympic-test-wrong-answers test))))))))
    (with-temp-file tf
      (insert (json-encode data))
      (insert "\n"))))

;;; ---------------------------------------------------------------------------
;;; Test panel
;;; ---------------------------------------------------------------------------

(defvar-local quickolympic--current-session nil
  "Session bound to the current panel/edit buffer.")

(define-derived-mode quickolympic-test-mode special-mode "QOly"
  "QuickOlympic test panel mode: read-only, single-key operations."
  (setq-local buffer-read-only t)
  (setq-local cursor-type nil))

;; Bindings are added at load time (not in the mode body) so they take effect
;; immediately on `load-file'/`require', even for already-open panel buffers.
(define-key quickolympic-test-mode-map "n" #'quickolympic-new-test)
(define-key quickolympic-test-mode-map "e" #'quickolympic-edit-test)
(define-key quickolympic-test-mode-map "d" #'quickolympic-delete-test)
(define-key quickolympic-test-mode-map "s" #'quickolympic-swap-test-up)
(define-key quickolympic-test-mode-map "S" #'quickolympic-swap-test-down)
(define-key quickolympic-test-mode-map "r" #'quickolympic-run-current-test)
(define-key quickolympic-test-mode-map "R" #'quickolympic-run)
(define-key quickolympic-test-mode-map "t" #'quickolympic-toggle-fold-at-point)
(define-key quickolympic-test-mode-map "a" #'quickolympic-accept-output)
(define-key quickolympic-test-mode-map "x" #'quickolympic-decline-output)
(define-key quickolympic-test-mode-map "k" #'quickolympic-kill-process)
(define-key quickolympic-test-mode-map "g" #'quickolympic-render)
(define-key quickolympic-test-mode-map "q" #'quickolympic-hide-panel)
(define-key quickolympic-test-mode-map (kbd "TAB") #'forward-button)
(define-key quickolympic-test-mode-map (kbd "<backtab>") #'backward-button)

(defun quickolympic--panel-buffer (session)
  "Get (or create) SESSION's panel buffer."
  (let ((old (quickolympic-session-panel-buffer session)))
    (if (buffer-live-p old)
        old
      (let* ((base (file-name-nondirectory (quickolympic-session-source-file session)))
             (buf (generate-new-buffer (format "*quickolympic %s -run*" base))))
        (setf (quickolympic-session-panel-buffer session) buf)
        (with-current-buffer buf
          (quickolympic-test-mode)
          (setq-local quickolympic--current-session session))
        buf))))

(defun quickolympic--panel-window (session)
  "Window displaying SESSION's panel, or nil."
  (get-buffer-window (quickolympic--panel-buffer session)))

(defun quickolympic--show-panel (session &optional limit)
  "Display and render SESSION's panel without stealing focus.
LIMIT is passed to `quickolympic--render'."
  (quickolympic--ensure-tests-loaded session)
  (let ((buf (quickolympic--panel-buffer session)))
    (quickolympic--render session limit)
    (unless (quickolympic--panel-window session)
      (display-buffer-in-side-window
       buf `((side . right)
             (window-width . ,quickolympic-panel-width)
             (window-parameters . ((no-delete-other-windows . t))))))))

(defun quickolympic--hide-panel (session)
  "Hide SESSION's panel (session data is kept)."
  (let ((win (quickolympic--panel-window session)))
    (when win (delete-window win))))

;;; ---------------------------------------------------------------------------
;;; Rendering
;;; ---------------------------------------------------------------------------

(defun quickolympic--has-correct-answer (test)
  "Non-nil if TEST has a non-empty correct answer."
  (let ((c (quickolympic-test-correct-answer test)))
    (and (stringp c) (not (string-empty-p c)))))

(defun quickolympic--test-status (test)
  "Return TEST's verdict string, or nil if not judged.
One of: Accepted / Rejected / Time Limit / Runtime Error.
A test without a (non-empty) accepted correct answer shows no verdict;
only Time Limit / Runtime Error are always shown."
  (let ((out (quickolympic-test-output test))
        (correct (quickolympic-test-correct-answer test))
        (has-correct (quickolympic--has-correct-answer test)))
    (cond
     ((eq (quickolympic-test-rtcode test) 'timeout) "Time Limit")
     ((or (and (numberp (quickolympic-test-rtcode test))
               (/= (quickolympic-test-rtcode test) 0))
          (eq (quickolympic-test-rtcode test) 'signal))
      "Runtime Error")
     ((and has-correct (equal out correct)) "Accepted")
     ((member out (quickolympic-test-wrong-answers test)) "Rejected")
     ;; A test with no output yet has no verdict; only judge a non-empty
     ;; output against a real (non-empty) correct answer.
     ((and has-correct (not (string-empty-p out))
           (not (equal out correct)))
      "Rejected")
     (t nil))))

(defun quickolympic--test-status-face (status)
  "Face used for a STATUS string."
  (pcase status
    ("Accepted" 'quickolympic-status-accepted)
    ("Rejected" 'quickolympic-status-rejected)
    ("Time Limit" 'quickolympic-status-time-limit)
    ("Runtime Error" 'quickolympic-status-runtime-error)))

(defun quickolympic--render-header (session)
  "Render the panel header: file name + compile errors (if any)."
  (insert (format "%s\n" (file-name-nondirectory
                          (quickolympic-session-source-file session))))
  (let ((co (quickolympic-session-compile-output session)))
    (when (and co (not (string-empty-p co)))
      (let ((start (point)))
        (insert co "\n")
        (put-text-property start (1- (point)) 'face 'error))))
  (insert "\n"))

(defun quickolympic--render-test (session test i &optional running)
  "Render one test block.  RUNNING non-nil suppresses the verdict and
accept/decline buttons (a running test has no verdict yet)."
  (let ((rt (quickolympic-test-runtime test))
        (block-start (point)))
    (insert-text-button (format "[Test %d]" (1+ i))
                        'action (lambda (_) (quickolympic--toggle-fold session i))
                        'follow-link t
                        'help-echo "Click to fold/unfold")
    (insert " ")
    (insert-text-button "[edit]"
                        'action (lambda (_) (quickolympic-edit-test i))
                        'follow-link t)
    (insert " ")
    (insert-text-button "[run]"
                        'action (lambda (_) (quickolympic-run-current-test i))
                        'follow-link t)
    (insert " ")
    (insert-text-button "[del]"
                        'action (lambda (_) (quickolympic-delete-test i))
                        'follow-link t)
    (insert (format "  time: %s" rt))
    (let ((status (and (not running) (quickolympic--test-status test))))
      (when status
        (insert "   ")
        (let ((start (point)))
          (insert status)
          (put-text-property start (point) 'face
                             (quickolympic--test-status-face status)))))
    (insert "\n")
    (unless (quickolympic-test-folded test)
      (insert (propertize "--- Input ---\n" 'face 'bold))
      (insert (quickolympic-test-input test))
      (unless (string-suffix-p "\n" (quickolympic-test-input test))
        (insert "\n"))
      (insert (propertize "--- Output ---\n" 'face 'bold))
      (insert (quickolympic-test-output test))
      (unless (string-suffix-p "\n" (quickolympic-test-output test))
        (insert "\n"))
      (when (and (not running)
                 (numberp (quickolympic-test-rtcode test))
                 (zerop (quickolympic-test-rtcode test))
                 (not (string-empty-p (quickolympic-test-output test))))
        (insert-text-button "[accept]"
                            'action (lambda (_) (quickolympic-accept-output i))
                            'follow-link t)
        (insert " ")
        (insert-text-button "[decline]"
                            'action (lambda (_) (quickolympic-decline-output i))
                            'follow-link t)
        (insert "\n")))
    ;; Tag the whole block with the test index so point anywhere in the
    ;; input/output area still resolves to this test.
    (put-text-property block-start (point) 'quickolympic-test-idx i)
    (insert "\n")))

(defun quickolympic--render-footer (_session)
  "Render the panel footer: new test button."
  (insert-text-button "[+ New Test]"
                      'action (lambda (_) (quickolympic-new-test))
                      'follow-link t)
  (insert "\n"))

(defun quickolympic--render (session &optional limit)
  "Rebuild the panel from the data model, preserving point.
With LIMIT non-nil, render only the header plus the first LIMIT tests
(used while running tests one by one); the footer is omitted then."
  (with-current-buffer (quickolympic--panel-buffer session)
    (let ((inhibit-read-only t)
          (saved-point (point))
          (running-idx (and (processp (quickolympic-session-process session))
                            (quickolympic-session-current-test session))))
      (erase-buffer)
      (quickolympic--render-header session)
      (cl-loop for test in (quickolympic-session-tests session)
               for i from 0
               while (or (null limit) (< i limit))
               do (let ((idx i))
                    (quickolympic--render-test
                     session test idx (and running-idx (= running-idx idx)))))
      (when (null limit)
        (quickolympic--render-footer session))
      (goto-char (min saved-point (point-max)))
      (set-buffer-modified-p nil))))

(defun quickolympic-render ()
  "Re-render the current session's panel."
  (interactive)
  (let ((session (quickolympic--current-session)))
    (when session (quickolympic--render session))))

;;; ---------------------------------------------------------------------------
;;; Session helpers
;;; ---------------------------------------------------------------------------

(defun quickolympic--current-session ()
  "Return the session associated with the current buffer."
  (cond
   ((and (boundp 'quickolympic--current-session)
         (local-variable-p 'quickolympic--current-session (current-buffer)))
    quickolympic--current-session)
   (buffer-file-name
    (quickolympic--get-session buffer-file-name))))

(defun quickolympic--test-at-point (_session)
  "Index of the test at point (default 0)."
  (or (get-text-property (point) 'quickolympic-test-idx)
      (get-text-property (line-beginning-position) 'quickolympic-test-idx)
      0))

;;; ---------------------------------------------------------------------------
;;; Panel toggle
;;; ---------------------------------------------------------------------------

;;;###autoload
(defun quickolympic-toggle-panel ()
  "Toggle the test side panel."
  (interactive)
  (let ((session (quickolympic--current-session)))
    (if (null session)
        (user-error "No file associated with the current buffer")
      (if (quickolympic--panel-window session)
          (quickolympic--hide-panel session)
        (quickolympic--show-panel session)
        (select-window (quickolympic--panel-window session))))))

(defun quickolympic-hide-panel ()
  "Close the test side panel."
  (interactive)
  (let ((session (quickolympic--current-session)))
    (when session (quickolympic--hide-panel session))))

;;; ---------------------------------------------------------------------------
;;; Running
;;; ---------------------------------------------------------------------------

(defun quickolympic--compile (session on-done)
  "Compile SESSION. ON-DONE is called with (CODE . OUTPUT)."
  (quickolympic--compile-file
   (quickolympic-session-source-file session)
   quickolympic-run-settings
   on-done))

(defun quickolympic--run-from (session idx &optional single)
  "Run tests one by one asynchronously starting at index IDX.
With SINGLE non-nil, run only the test at IDX."
  (let* ((run (quickolympic-session-run-id session))
         (tests (quickolympic-session-tests session))
         (test (nth idx tests)))
    (if (null test)
        (quickolympic--finish-run-all session)
      (setf (quickolympic-session-current-test session) idx)
      (let ((t0 (float-time)))
        (setf (quickolympic-session-process session)
              (quickolympic--run-file
               (quickolympic-session-source-file session)
               quickolympic-run-settings
               (quickolympic-test-input test)
               (lambda (result)
                 ;; Stale-callback guard: ignore if a newer run started.
                 (when (eq run (quickolympic-session-run-id session))
                   (let ((code (car result))
                         (out (cdr result)))
                     (setf (quickolympic-test-rtcode test) code)
                     (setf (quickolympic-test-output test)
                           (quickolympic--normalize-output out))
                     (setf (quickolympic-test-runtime test)
                           (quickolympic--format-runtime
                            (* 1000 (- (float-time) t0))))
                     ;; Fold when the output matches an accepted answer,
                     ;; otherwise unfold to show the result.
                     (setf (quickolympic-test-folded test)
                           (equal (quickolympic--test-status test) "Accepted"))
                     (setf (quickolympic-session-process session) nil)
                     (quickolympic--save-tests session)
                     (quickolympic--render session (1+ idx))
                     (cond
                      (single (quickolympic--finish-run-all session))
                      ((and quickolympic-stop-on-fail
                            (quickolympic--run-failed-p code))
                       (quickolympic--finish-run-all session))
                      (t (quickolympic--run-from session (1+ idx)))))))
               nil
               quickolympic-test-timeout))
        ;; Reflect the running state: the running test shows no verdict.
        (quickolympic--render session (1+ idx))))))

(defun quickolympic--format-runtime (ms)
  "Format a runtime in milliseconds for display."
  (let ((ms (round ms)))
    (if (>= ms 1000)
        (format "%gs" (/ ms 1000.0))
      (format "%dms" ms))))

(defun quickolympic--run-failed-p (code)
  "Non-nil if CODE means failure (crash/timeout/non-zero exit)."
  (or (eq code 'signal) (eq code 'timeout)
      (and (numberp code) (/= code 0))))

(defun quickolympic--clear-test-verdict (test)
  "Clear transient run results (output/rtcode/runtime) of TEST."
  (setf (quickolympic-test-output test) "")
  (setf (quickolympic-test-rtcode test) nil)
  (setf (quickolympic-test-runtime test) "-"))

(defun quickolympic--clear-verdicts (session)
  "Clear transient run results of all tests in SESSION.
Call at the start of a run so no stale verdict from a previous run is shown."
  (dolist (test (quickolympic-session-tests session))
    (quickolympic--clear-test-verdict test)))

(defun quickolympic--finish-run-all (session)
  "Finish running all tests."
  (setf (quickolympic-session-process session) nil)
  (quickolympic--render session)
  (message "quickolympic: run finished"))

(defun quickolympic--ensure-idle (session)
  "Signal an error if a test is already running."
  (let ((proc (quickolympic-session-process session)))
    (when (and (processp proc) (process-live-p proc))
      (user-error "A test is already running; kill it first (C-c C-q k)"))))

(defun quickolympic--compile-then (session on-success &optional limit)
  "Compile SESSION; call ON-SUCCESS on success, else show the error.
LIMIT is passed to `quickolympic--render'."
  (quickolympic--compile session
    (lambda (result)
      (let ((code (car result))
            (out (cdr result)))
        (if (quickolympic--run-failed-p code)
            (progn
              (setf (quickolympic-session-compile-output session)
                    (if (string-empty-p out)
                        (format "Compile failed (exit code %s)" code)
                      out))
              (quickolympic--render session limit))
          (setf (quickolympic-session-compile-output session) nil)
          (quickolympic--render session limit)
          (funcall on-success))))))

;;;###autoload
(defun quickolympic-run ()
  "Compile and run all tests."
  (interactive)
  (let ((session (quickolympic--current-session)))
    (unless session (user-error "No file associated with the current buffer"))
    (quickolympic--ensure-idle session)
    (cl-incf (quickolympic-session-run-id session))
    (quickolympic--load-tests session)
    (quickolympic--clear-verdicts session)
    ;; Drop a stale compile-error message from a previous run before
    ;; refreshing the panel.
    (setf (quickolympic-session-compile-output session) nil)
    ;; Clear the panel and show only the file name first; tests are rendered
    ;; one by one from top to bottom as they run.
    (quickolympic--show-panel session 0)
    (quickolympic--compile-then session
      (lambda ()
        (quickolympic--run-from session 0))
      0)))

(defun quickolympic-run-current-test (&optional idx)
  "Run the current (or given IDX) test."
  (interactive)
  (let* ((session (quickolympic--current-session))
         (i (or idx (quickolympic--test-at-point session))))
    (unless session (user-error "No file associated with the current buffer"))
    (quickolympic--ensure-idle session)
    (cl-incf (quickolympic-session-run-id session))
    (quickolympic--ensure-tests-loaded session)
    ;; Drop a stale compile-error message from a previous run.
    (setf (quickolympic-session-compile-output session) nil)
    ;; Only the target test is re-run; keep other tests' verdicts.
    (let ((target (nth i (quickolympic-session-tests session))))
      (when target (quickolympic--clear-test-verdict target)))
    (quickolympic--show-panel session 0)
    (quickolympic--compile-then session
      (lambda ()
        (quickolympic--run-from session i t))
      0)))

(defun quickolympic-kill-process ()
  "Kill the currently running test process."
  (interactive)
  (let* ((session (quickolympic--current-session))
         (proc (and session (quickolympic-session-process session))))
    (cond
     ((processp proc)
      (quickolympic--kill-tree proc)
      (setf (quickolympic-session-process session) nil)
      (message "Test process terminated"))
     (t (message "No running process")))))

;;; ---------------------------------------------------------------------------
;;; Test management
;;; ---------------------------------------------------------------------------

(defun quickolympic-new-test ()
  "Add an empty test and open an edit buffer for its input."
  (interactive)
  (let ((session (quickolympic--current-session)))
    (unless session (user-error "No file associated with the current buffer"))
    (quickolympic--ensure-tests-loaded session)
    (setf (quickolympic-session-tests session)
          (append (quickolympic-session-tests session)
                  (list (make-quickolympic-test :input ""))))
    (let ((i (1- (length (quickolympic-session-tests session)))))
      (quickolympic--save-tests session)
      (quickolympic--render session)
      (quickolympic-edit-test i))))

(defun quickolympic-edit-test (&optional idx)
  "Edit the input of test IDX in a separate buffer."
  (interactive)
  (let* ((session (quickolympic--current-session))
         (i (or idx (quickolympic--test-at-point session)))
         (test (and session
                    (progn (quickolympic--ensure-tests-loaded session)
                           (nth i (quickolympic-session-tests session))))))
    (unless test (user-error "Test does not exist"))
    (let ((buf (generate-new-buffer (format "*quickolympic test %d*" (1+ i)))))
      (with-current-buffer buf
        (quickolympic-test-edit-mode)
        (setq-local quickolympic--current-session session)
        (setq-local quickolympic--edit-index i)
        (insert (quickolympic-test-input test))
        (goto-char (point-min)))
      (if (window-parameter (selected-window) 'window-side)
          ;; Current window is the side panel; open the edit buffer in a
          ;; regular window.
          (pop-to-buffer buf)
        ;; Reuse the current (source) window.  After save + kill the window
        ;; returns to the source buffer instead of leaving a lingering window
        ;; (especially in terminal emacs -nw).
        (switch-to-buffer buf)))))

(defun quickolympic-delete-test (&optional idx)
  "Delete test IDX."
  (interactive)
  (let* ((session (quickolympic--current-session))
         (i (or idx (quickolympic--test-at-point session))))
    (when session (quickolympic--ensure-tests-loaded session))
    (let ((tests (quickolympic-session-tests session)))
      (when (and session (nth i tests))
        (setf (quickolympic-session-tests session)
              (append (cl-subseq tests 0 i) (cl-subseq tests (1+ i))))
        (quickolympic--save-tests session)
        (quickolympic--render session)))))

(defun quickolympic-swap-test-up (&optional idx)
  "Swap test IDX with the one above."
  (interactive)
  (quickolympic--swap-tests (or idx (quickolympic--test-at-point nil)) -1))

(defun quickolympic-swap-test-down (&optional idx)
  "Swap test IDX with the one below."
  (interactive)
  (quickolympic--swap-tests (or idx (quickolympic--test-at-point nil)) 1))

(defun quickolympic--swap-tests (i dir)
  (let* ((session (quickolympic--current-session))
         (tests (quickolympic--ensure-loaded-tests session))
         (j (+ i dir)))
    (when (and session (nth i tests) (nth j tests))
      (cl-rotatef (nth i tests) (nth j tests))
      (quickolympic--save-tests session)
      (quickolympic--render session))))

(defun quickolympic--toggle-fold (session i)
  "Fold or unfold test I."
  (let ((test (nth i (quickolympic-session-tests session))))
    (when test
      (setf (quickolympic-test-folded test)
            (not (quickolympic-test-folded test)))
      (quickolympic--render session))))

(defun quickolympic-toggle-fold-at-point ()
  "Toggle fold/unfold of the test at point (or the nearest test above)."
  (interactive)
  (let* ((session (quickolympic--current-session))
         (idx (or (get-text-property (point) 'quickolympic-test-idx)
                  (get-text-property (line-beginning-position)
                                     'quickolympic-test-idx)
                  (save-excursion
                    (let ((found nil))
                      (while (and (null found) (not (bobp)))
                        (forward-line -1)
                        (setq found (get-text-property
                                     (line-beginning-position)
                                     'quickolympic-test-idx)))
                      found)))))
    (when (and session idx)
      (quickolympic--toggle-fold session idx))))

(defun quickolympic-accept-output (&optional idx)
  "Mark the current output of test IDX as accepted."
  (interactive)
  (let* ((session (quickolympic--current-session))
         (i (or idx (quickolympic--test-at-point session)))
         (test (nth i (quickolympic--ensure-loaded-tests session))))
    (when (and session test)
      (let ((out (quickolympic-test-output test)))
        (unless (string-empty-p out)
          ;; Accepting a new output REPLACES the previous correct answer,
          ;; so an old wrong answer is never kept as correct.
          (setf (quickolympic-test-correct-answer test) out)
          (setf (quickolympic-test-wrong-answers test)
                (cl-remove out (quickolympic-test-wrong-answers test) :test #'equal))))
      ;; Accepted tests are folded automatically to declutter the panel.
      (setf (quickolympic-test-folded test) t)
      (quickolympic--save-tests session)
      (quickolympic--render session))))

(defun quickolympic-decline-output (&optional idx)
  "Mark the current output of test IDX as rejected."
  (interactive)
  (let* ((session (quickolympic--current-session))
         (i (or idx (quickolympic--test-at-point session)))
         (test (nth i (quickolympic--ensure-loaded-tests session))))
    (when (and session test)
      (let ((out (quickolympic-test-output test)))
        (unless (string-empty-p out)
          (cl-pushnew out (quickolympic-test-wrong-answers test) :test #'equal)
          ;; If the current output was previously accepted, declining it
          ;; clears the correct answer so it can be updated.
          (when (equal out (quickolympic-test-correct-answer test))
            (setf (quickolympic-test-correct-answer test) nil))))
      (quickolympic--save-tests session)
      (quickolympic--render session))))

;;; ---------------------------------------------------------------------------
;;; Test input edit buffer
;;; ---------------------------------------------------------------------------

(defvar-local quickolympic--edit-index nil
  "Test index bound to the edit buffer.")

(define-derived-mode quickolympic-test-edit-mode fundamental-mode "QOlyEdit"
  "Edit a test input. C-c C-c saves, C-c C-k cancels."
  (setq-local buffer-read-only nil)
  (define-key quickolympic-test-edit-mode-map (kbd "C-c C-c") #'quickolympic--edit-save)
  (define-key quickolympic-test-edit-mode-map (kbd "C-c C-k") #'quickolympic--edit-cancel))

(defun quickolympic--edit-save ()
  "Save the edited test input and close the buffer."
  (interactive)
  (let* ((session quickolympic--current-session)
         (idx quickolympic--edit-index)
         (buf (current-buffer))
         (test (and session idx
                    (nth idx (quickolympic-session-tests session)))))
    (unwind-protect
        (if test
            (progn
              (setf (quickolympic-test-input test)
                    (buffer-substring-no-properties (point-min) (point-max)))
              (quickolympic--save-tests session)
              (quickolympic--render session))
          (message "quickolympic: test no longer exists or changed; save aborted"))
      ;; Always close the edit buffer, even if saving/rendering above errors.
      (when (buffer-live-p buf) (kill-buffer buf)))))

(defun quickolympic--edit-cancel ()
  "Cancel editing and close the buffer."
  (interactive)
  (kill-buffer (current-buffer)))

;;; ---------------------------------------------------------------------------
;;; Minor mode and auto-enable
;;; ---------------------------------------------------------------------------

(defvar quickolympic-prefix-map
  (let ((map (make-sparse-keymap)))
    (define-key map "r" #'quickolympic-run)
    (define-key map "R" #'quickolympic-run-current-test)
    (define-key map "p" #'quickolympic-toggle-panel)
    (define-key map "k" #'quickolympic-kill-process)
    (define-key map "n" #'quickolympic-new-test)
    (define-key map "e" #'quickolympic-edit-test)
    map)
  "QuickOlympic prefix keymap (C-c C-q).")

(defvar quickolympic-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-q") quickolympic-prefix-map)
    map)
  "QuickOlympic minor mode keymap.")

;;;###autoload
(define-minor-mode quickolympic-mode
  "QuickOlympic mode: competitive programming test assistance."
  :lighter " QOly"
  :keymap quickolympic-mode-map
  :group 'quickolympic)

(defun quickolympic-mode-maybe ()
  "Enable quickolympic-mode automatically in supported source buffers."
  (when (and buffer-file-name
             (member (downcase (or (file-name-extension buffer-file-name) ""))
                     '("cpp" "cc" "cxx" "py" "java")))
    (quickolympic-mode 1)))

;;;###autoload
(define-globalized-minor-mode quickolympic-global-mode
  quickolympic-mode quickolympic-mode-maybe
  :group 'quickolympic)

(provide 'quickolympic)

;;; quickolympic.el ends here
