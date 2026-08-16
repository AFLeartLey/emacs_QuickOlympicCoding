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
  ;; not run -> nil
  (let ((t9 (make-quickolympic-test :input "1")))
    (should (null (quickolympic--test-status t9)))))

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

(provide 'quickolympic-test)

;;; quickolympic-test.el ends here
