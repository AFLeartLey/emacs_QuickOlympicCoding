;;; quickolympic-process.el --- Async process layer for QuickOlympic -*- lexical-binding: t; -*-

;; Copyright (C) 2026 QuickOlympic

;; Author: QuickOlympic
;; Version: 0.1.0
;; Keywords: tools, languages, wp
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:
;; Async process layer: compile, run, terminate, timeout, input forwarding.
;; Everything is built on `make-process'; commands are string templates run via
;; `(list shell-file-name shell-command-switch CMD)', so behaviour is identical
;; on Windows (cmdproxy/cmd) and Linux (sh -c).

;;; Code:

(require 'cl-lib)

;;; ---------------------------------------------------------------------------
;;; Command templates
;;; ---------------------------------------------------------------------------

(defun quickolympic--subst (string from to)
  "Replace literal FROM with TO in STRING."
  (replace-regexp-in-string (regexp-quote from) to string t t))

(defun quickolympic--format-cmd (template file &optional args)
  "Fill placeholders in command template TEMPLATE for FILE and ARGS.
Placeholders: {file} {source_file} {source_file_dir} {file_name} {args}."
  (let* ((dir (file-name-directory file))
         (base (file-name-nondirectory file))
         (name (file-name-sans-extension base))
         (s template))
    (setq s (quickolympic--subst s "{source_file_dir}" (or dir "")))
    (setq s (quickolympic--subst s "{source_file}" file))
    (setq s (quickolympic--subst s "{file_name}" name))
    (setq s (quickolympic--subst s "{file}" base))
    (setq s (quickolympic--subst s "{args}" (or args "")))
    s))

;;; ---------------------------------------------------------------------------
;;; Process start / kill
;;; ---------------------------------------------------------------------------

(defvar quickolympic--proc-counter 0
  "Counter used to generate unique process names.")

(defun quickolympic--make-process (cmd on-done &optional on-output timeout)
  "Run shell command CMD asynchronously.
ON-DONE is called with (CODE . OUTPUT): CODE is the exit code or the symbol
signal / timeout.  ON-OUTPUT is called with each output chunk (optional).
TIMEOUT seconds kills the process (optional).  Runs in the current
`default-directory'.  Returns the process object."
  (let* ((output "")
         (finished nil)
         (timer nil)
         (finish (lambda (code)
                   (unless finished
                     (setq finished t)
                     (when timer (cancel-timer timer))
                     (funcall on-done (cons code output)))))
         (proc (make-process
                :name (format "quickolympic-proc-%d" (cl-incf quickolympic--proc-counter))
                :buffer nil
                :connection-type 'pipe
                :noquery t
                :command (list shell-file-name shell-command-switch
                               (format "%s 2>&1" cmd))
                :filter (lambda (_p s)
                          (setq output (concat output s))
                          (when on-output (funcall on-output s)))
                :sentinel (lambda (p _ev)
                            (let ((st (process-status p)))
                              (when (memq st '(exit signal))
                                (funcall finish
                                         (if (eq st 'signal) 'signal
                                           (process-exit-status p)))))))))
    (setq timer
          (and timeout
               (run-at-time timeout nil
                            (lambda ()
                              (when (process-live-p proc)
                                (quickolympic--kill-tree proc)
                                (funcall finish 'timeout))))))
    proc))

(defun quickolympic--kill-tree (process)
  "Kill PROCESS and its descendants, platform-aware."
  (let ((pid (process-id process)))
    (when (and pid (process-live-p process))
      (cond
       ((eq system-type 'windows-nt)
        ;; Windows: taskkill recursively forces the process tree.
        (ignore-errors
          (call-process "taskkill" nil nil nil "/T" "/F" "/PID"
                        (number-to-string pid))))
       (t
        ;; Linux: SIGINT, then SIGTERM, then kill direct children.
        (ignore-errors (interrupt-process process))
        (ignore-errors (kill-process process))
        (ignore-errors
          (call-process "pkill" nil nil nil "-TERM" "-P"
                        (number-to-string pid))))))))

;;; ---------------------------------------------------------------------------
;;; Compile / run
;;; ---------------------------------------------------------------------------

(defun quickolympic--lang-for (file run-settings)
  "Find the language config plist for FILE in RUN-SETTINGS by extension."
  (cl-find-if (lambda (x)
                (member (downcase (or (file-name-extension file) ""))
                        (plist-get x :extensions)))
              run-settings))

(defun quickolympic--compile-file (file run-settings on-done)
  "Compile FILE. ON-DONE is called with (CODE . OUTPUT); CODE nil or 0 is
success.  Returns the process object, or nil when there is no compile step."
  (let* ((lang (quickolympic--lang-for file run-settings))
         (template (and lang (plist-get lang :compile))))
    (if (null template)
        (progn (funcall on-done '(0 . "")) nil)
      (let ((default-directory (file-name-directory file)))
        (quickolympic--make-process
         (quickolympic--format-cmd template file)
         on-done)))))

(defun quickolympic--run-file (file run-settings test-input on-done
                                    &optional on-output timeout args)
  "Run compiled FILE, feed TEST-INPUT then EOF.
ON-DONE is called with (CODE . OUTPUT).  Returns the process object."
  (let* ((lang (quickolympic--lang-for file run-settings))
         (template (and lang (plist-get lang :run)))
         (default-directory (file-name-directory file)))
    (unless template
      (error "No run command configured for %s" file))
    (let ((proc (quickolympic--make-process
                 (quickolympic--format-cmd template file args)
                 on-done on-output timeout)))
      (when (and test-input (not (string-empty-p test-input)))
        (process-send-string proc test-input))
      (process-send-eof proc)
      proc)))

(provide 'quickolympic-process)

;;; quickolympic-process.el ends here
