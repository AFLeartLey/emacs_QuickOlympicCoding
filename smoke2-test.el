;;; smoke2-test.el --- Edge-case smoke test (temporary) -*- lexical-binding: t; -*-
;; Usage: emacs -batch -Q -L . -l smoke2-test.el -f quickolympic-smoke2

(require 'quickolympic)

(defun quickolympic-smoke2--wait (sec)
  (sleep-for sec))

(defun quickolympic-smoke2 ()
  (let ((fail 0)
        (dir (make-temp-file "qo-smoke2" t)))
    (unwind-protect
        (progn
          ;; A) Python: no compile step
          (let* ((py (expand-file-name "sum.py" dir))
                 (session (quickolympic--get-session py)))
            (with-temp-file py
              (insert "a,b=map(int,input().split())\nprint(a+b)\n"))
            (setf (quickolympic-session-tests session)
                  (list (make-quickolympic-test :input "2 3\n" :folded nil)))
            (quickolympic--compile-then
             session (lambda () (quickolympic--run-from session 0)))
            (quickolympic-smoke2--wait 6)
            (let ((t0 (nth 0 (quickolympic-session-tests session))))
              (if (string-equal (string-trim (quickolympic-test-output t0)) "5")
                  (princ "[A] Python run OK\n")
                (progn
                  (setq fail (1+ fail))
                  (princ (format "[A] Python abnormal: %S\n" t0))))))

          ;; B) Compile error display
          (let* ((bad (expand-file-name "bad.cpp" dir))
                 (session (quickolympic--get-session bad)))
            (with-temp-file bad
              (insert "int main( { return 0; }\n")) ; syntax error
            (quickolympic--compile-then
             session (lambda () (princ "[B] should not succeed\n")))
            (quickolympic-smoke2--wait 6)
            (let ((co (quickolympic-session-compile-output session)))
              (if (and co (string-match "error" co))
                  (princ "[B] compile error display OK\n")
                (progn
                  (setq fail (1+ fail))
                  (princ (format "[B] compile error not shown: %S\n" co))))))

          ;; C) Timeout kills process
          (let* ((hang (expand-file-name "hang.cpp" dir))
                 (session (quickolympic--get-session hang)))
            (with-temp-file hang
              (insert "#include <cstdio>\nint main(){while(true){}return 0;}\n"))
            (setf (quickolympic-session-tests session)
                  (list (make-quickolympic-test :input "" :folded nil)))
            (let ((quickolympic-test-timeout 1))
              (quickolympic--compile-then
               session (lambda () (quickolympic--run-from session 0)))
              (quickolympic-smoke2--wait 6))
            (let ((t0 (nth 0 (quickolympic-session-tests session))))
              (if (eq (quickolympic-test-rtcode t0) 'timeout)
                  (princ "[C] timeout kill OK\n")
                (progn
                  (setq fail (1+ fail))
                  (princ (format "[C] timeout abnormal: %S\n" t0)))))))
      (ignore-errors (delete-directory dir t)))
    (if (= fail 0)
        (princ "SMOKE2: ALL PASS\n")
      (princ (format "SMOKE2: %d FAILURES\n" fail)))
    (kill-emacs (if (= fail 0) 0 1))))
