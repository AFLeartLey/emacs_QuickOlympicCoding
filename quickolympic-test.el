;;; quickolympic-test.el --- Unit tests for QuickOlympic -*- lexical-binding: t; -*-

;;; Commentary:
;; Run: emacs -batch -l quickolympic.el -l quickolympic-test.el \
;;      -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'quickolympic)

;; ---------------------------------------------------------------------------
;; Command template
;; ---------------------------------------------------------------------------

(ert-deftest quickolympic-format-cmd-test ()
  (should
   (equal (quickolympic--format-cmd
           "g++ \"{source_file}\" -o \"{file_name}.exe\" {args}"
           "/tmp/a/A.cpp" "-O2")
          "g++ \"/tmp/a/A.cpp\" -o \"A.exe\" -O2"))
  (should
   (equal (quickolympic--format-cmd
           "cd {source_file_dir} && {file}"
           "/tmp/a/A.cpp")
          "cd /tmp/a/ && A.cpp")))

;; ---------------------------------------------------------------------------
;; Verdict
;; ---------------------------------------------------------------------------

(ert-deftest quickolympic-status-test ()
  ;; accepted output -> Accepted
  (let ((t1 (make-quickolympic-test :input "1" :rtcode 0 :output "3"
                                    :correct-answer "3")))
    (should (equal (quickolympic--test-status t1) "Accepted")))
  ;; non-zero exit -> Runtime Error
  (let ((t2 (make-quickolympic-test :input "1" :rtcode 1 :output "")))
    (should (equal (quickolympic--test-status t2) "Runtime Error")))
  ;; timeout -> Time Limit
  (let ((t3 (make-quickolympic-test :input "1" :rtcode 'timeout :output "")))
    (should (equal (quickolympic--test-status t3) "Time Limit")))
  ;; rejected output -> Rejected
  (let ((t4 (make-quickolympic-test :input "1" :rtcode 0 :output "7"
                                    :wrong-answers '("7"))))
    (should (equal (quickolympic--test-status t4) "Rejected")))
  ;; signal -> Runtime Error
  (let ((t5 (make-quickolympic-test :input "1" :rtcode 'signal :output "")))
    (should (equal (quickolympic--test-status t5) "Runtime Error")))
  ;; correct answer exists but output differs -> Rejected
  (let ((t6 (make-quickolympic-test :input "1" :rtcode 0 :output "7"
                                    :correct-answer "5")))
    (should (equal (quickolympic--test-status t6) "Rejected")))
  ;; correct answer exists and output matches -> Accepted
  (let ((t7 (make-quickolympic-test :input "1" :rtcode 0 :output "5"
                                    :correct-answer "5")))
    (should (equal (quickolympic--test-status t7) "Accepted")))
  ;; empty output with a correct answer -> not judged (nil)
  (let ((t8 (make-quickolympic-test :input "1" :rtcode 0 :output ""
                                    :correct-answer "5")))
    (should (null (quickolympic--test-status t8))))
  ;; empty correct answer -> treated as not accepted -> nil
  (let ((t9 (make-quickolympic-test :input "1" :rtcode 0 :output "5"
                                    :correct-answer "")))
    (should (null (quickolympic--test-status t9))))
  ;; not run -> nil
  (let ((t10 (make-quickolympic-test :input "1")))
    (should (null (quickolympic--test-status t10)))))

(ert-deftest quickolympic-run-failed-test ()
  (should (quickolympic--run-failed-p 1))
  (should (quickolympic--run-failed-p 'signal))
  (should (quickolympic--run-failed-p 'timeout))
  (should-not (quickolympic--run-failed-p 0))
  (should-not (quickolympic--run-failed-p nil)))

;; ---------------------------------------------------------------------------
;; Runtime formatting
;; ---------------------------------------------------------------------------

(ert-deftest quickolympic-format-runtime-test ()
  (should (equal (quickolympic--format-runtime 3) "3ms"))
  (should (equal (quickolympic--format-runtime 1500) "1.5s")))

;; ---------------------------------------------------------------------------
;; Output normalization
;; ---------------------------------------------------------------------------

(ert-deftest quickolympic-normalize-output-test ()
  (should (equal (quickolympic--normalize-output "a\r\nb\rc") "a\nbc"))
  (should (equal (quickolympic--normalize-output "5\r\n") "5\n"))
  (should (equal (quickolympic--normalize-output "5\n") "5\n"))
  (should (equal (quickolympic--normalize-output nil) "")))

;; ---------------------------------------------------------------------------
;; Persistence round-trip
;; ---------------------------------------------------------------------------

(ert-deftest quickolympic-persist-test ()
  (let* ((src (make-temp-file "quickolympic-test" nil ".cpp"))
         (session (make-quickolympic-session :source-file src)))
    (setf (quickolympic-session-tests session)
          (list (make-quickolympic-test :input "1 2\n"
                                        :correct-answer "3"
                                        :wrong-answers '("4"))))
    (quickolympic--save-tests session)
    (setf (quickolympic-session-tests session) nil)
    (quickolympic--load-tests session)
    (let ((tests (quickolympic-session-tests session)))
      (should (= (length tests) 1))
      (should (equal (quickolympic-test-input (car tests)) "1 2\n"))
      (should (equal (quickolympic-test-correct-answer (car tests)) "3"))
      (should (equal (quickolympic-test-wrong-answers (car tests)) '("4"))))
    ;; Empty/whitespace input must survive reload (it is the intermediate
    ;; state of a newly created, not-yet-edited test).
    (setf (quickolympic-session-tests session)
          (list (make-quickolympic-test :input "   \n")))
    (quickolympic--save-tests session)
    (setf (quickolympic-session-tests session) nil)
    (quickolympic--load-tests session)
    (should (= (length (quickolympic-session-tests session)) 1))
    (delete-file (quickolympic--tests-file src))
    (delete-file src)))

(ert-deftest quickolympic-old-format-test ()
  ;; Old plural "correct-answers" key is read as the single correct answer.
  (let* ((src (make-temp-file "quickolympic-old" nil ".cpp"))
         (session (make-quickolympic-session :source-file src))
         (tf (quickolympic--tests-file src)))
    (with-temp-file tf
      (insert "[{\"input\":\"1\\n\",\"correct-answers\":[\"5\"]}]"))
    (quickolympic--load-tests session)
    (let ((tests (quickolympic-session-tests session)))
      (should (= (length tests) 1))
      (should (equal (quickolympic-test-correct-answer (car tests)) "5")))
    (delete-file tf)
    (delete-file src)))

(ert-deftest quickolympic-no-clobber-test ()
  ;; A fresh session must load persisted tests before the first mutating
  ;; command (C-c M-q n), otherwise it would overwrite them.
  (let* ((src (make-temp-file "quickolympic-clobber" nil ".cpp"))
         (s1 (make-quickolympic-session :source-file src)))
    (setf (quickolympic-session-tests s1)
          (list (make-quickolympic-test :input "1\n")))
    (quickolympic--save-tests s1)
    (clrhash quickolympic--sessions)   ; simulate a fresh session
    (with-temp-buffer
      (setq buffer-file-name src)
      (quickolympic-new-test))
    (let ((tests (quickolympic-session-tests
                  (quickolympic--get-session src))))
      (should (= (length tests) 2)))
    (delete-file (quickolympic--tests-file src))
    (delete-file src)))

(ert-deftest quickolympic-edit-save-clears-verdict-on-input-change-test ()
  ;; Saving a substantively changed input must clear verdicts/run results.
  (let* ((src (make-temp-file "quickolympic-edit" nil ".cpp"))
         (session (make-quickolympic-session :source-file src)))
    (setf (quickolympic-session-tests session)
          (list (make-quickolympic-test :input "2 3\n" :correct-answer "5"
                                        :wrong-answers '("7") :rtcode 0
                                        :output "5\n" :runtime "10ms")))
    (let ((buf (get-buffer-create "*qo-edit-save-test*")))
      (with-current-buffer buf
        (quickolympic-test-edit-mode)
        (setq-local quickolympic--current-session session)
        (setq-local quickolympic--edit-index 0)
        (insert "5 7\n"))
      (with-current-buffer buf (quickolympic--edit-save))
      (let ((t0 (nth 0 (quickolympic-session-tests session))))
        (should (equal (quickolympic-test-input t0) "5 7\n"))
        (should (null (quickolympic-test-correct-answer t0)))
        (should (null (quickolympic-test-wrong-answers t0)))
        (should (null (quickolympic-test-rtcode t0)))
        (should (string-empty-p (quickolympic-test-output t0)))))
    (delete-file (quickolympic--tests-file src))
    (delete-file src)))

(ert-deftest quickolympic-edit-save-keeps-verdict-on-unchanged-test ()
  ;; Saving an unchanged input must keep the correct answer.
  (let* ((src (make-temp-file "quickolympic-edit2" nil ".cpp"))
         (session (make-quickolympic-session :source-file src)))
    (setf (quickolympic-session-tests session)
          (list (make-quickolympic-test :input "2 3\n" :correct-answer "5")))
    (let ((buf (get-buffer-create "*qo-edit-keep-test*")))
      (with-current-buffer buf
        (quickolympic-test-edit-mode)
        (setq-local quickolympic--current-session session)
        (setq-local quickolympic--edit-index 0)
        (insert "2 3\n"))   ; unchanged
      (with-current-buffer buf (quickolympic--edit-save))
      (let ((t0 (nth 0 (quickolympic-session-tests session))))
        (should (equal (quickolympic-test-input t0) "2 3\n"))
        (should (equal (quickolympic-test-correct-answer t0) "5"))))
    (delete-file (quickolympic--tests-file src))
    (delete-file src)))

(ert-deftest quickolympic-fold-moves-point-to-header-test ()
  ;; Folding a test must move point to its [Test N] header.
  (let* ((src (make-temp-file "quickolympic-fold" nil ".cpp"))
         (session (make-quickolympic-session :source-file src)))
    (setf (quickolympic-session-tests session)
          (list (make-quickolympic-test :input (make-string 200 ?a) :folded nil)))
    (let ((buf (quickolympic--panel-buffer session)))
      (quickolympic--render session nil)
      (with-current-buffer buf
        (goto-char (point-max))     ; cursor far from the header
        (quickolympic--toggle-fold session 0)
        (let ((header-pos (save-excursion
                            (goto-char (point-min))
                            (search-forward "[Test 1]" nil t)
                            (match-beginning 0))))
          (should (= (point) header-pos)))))
    (delete-file src)))

(provide 'quickolympic-test)

;;; quickolympic-test.el ends here
