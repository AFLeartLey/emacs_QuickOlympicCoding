;;; smoke-test.el --- End-to-end smoke test (temporary) -*- lexical-binding: t; -*-
;; Usage: emacs -batch -Q -L . -l smoke-test.el -f quickolympic-smoke

(require 'quickolympic)

(defun quickolympic-smoke--sum-cpp (dir)
  "Write a C++ program that sums two integers into DIR."
  (let ((f (expand-file-name "A.cpp" dir)))
    (with-temp-file f
      (insert "#include <iostream>\nint main(){int a,b;std::cin>>a>>b;std::cout<<(a+b);return 0;}\n"))
    f))

(defun quickolympic-smoke--wait (sec)
  "Wait for async processes (sentinels fire during sleep-for in batch)."
  (sleep-for sec))

(defun quickolympic-smoke ()
  "Run the smoke test."
  (let* ((dir (make-temp-file "qo-smoke" t))
         (src (quickolympic-smoke--sum-cpp dir))
         (session (quickolympic--get-session src))
         (fail 0))
    (unwind-protect
        (progn
          ;; 1) Persistence write
          (setf (quickolympic-session-tests session)
                (list (make-quickolympic-test :input "2 3\n" :folded nil)
                      (make-quickolympic-test :input "10 20\n" :folded nil)))
          (quickolympic--save-tests session)
          (princ "[1] persist write OK\n")

          ;; 2) Compile + run all
          (quickolympic--compile-then
           session
           (lambda ()
             (quickolympic--run-from session 0)))
          (quickolympic-smoke--wait 8)

          (let ((tests (quickolympic-session-tests session)))
            (cond
             ((and (= (length tests) 2)
                   (string-equal (quickolympic-test-output (nth 0 tests)) "5")
                   (string-equal (quickolympic-test-output (nth 1 tests)) "30")
                   (eq (quickolympic-test-rtcode (nth 0 tests)) 0)
                   (eq (quickolympic-test-rtcode (nth 1 tests)) 0))
              (princ "[2] compile + run all OK\n"))
             (t
              (setq fail (1+ fail))
              (princ (format "[2] run result abnormal: %S\n" tests)))))

          ;; 3) Panel rendering (no window in batch; check buffer content)
          (let ((buf (quickolympic--panel-buffer session)))
            (quickolympic--render session)
            (let ((content (with-current-buffer buf (buffer-string))))
              (cond
               ((and (string-match "Test 1" content)
                     (string-match "Test 2" content)
                     (string-match "5" content)
                     (string-match "30" content)
                     (string-match "Input" content)
                     (string-match "Output" content))
                (princ "[3] panel render OK\n"))
               (t
                (setq fail (1+ fail))
                (princ (format "[3] panel content abnormal: %S\n" content))))))

          ;; 4) Manual verdict: accept the first test (in panel buffer context)
          (with-current-buffer (quickolympic--panel-buffer session)
            (quickolympic-accept-output 0))
          (let ((t0 (nth 0 (quickolympic-session-tests session))))
            (cond
             ((equal "5" (quickolympic-test-correct-answer t0))
              (princ "[4] accept verdict OK\n"))
             (t
              (setq fail (1+ fail))
              (princ "[4] accept verdict failed\n"))))

          ;; 5) Reload sidecar to verify persistence
          (let ((session2 (quickolympic--get-session src)))
            (setf (quickolympic-session-tests session2) nil)
            (quickolympic--load-tests session2)
            (let ((tests2 (quickolympic-session-tests session2)))
              (cond
               ((and (= (length tests2) 2)
                     (equal "5" (quickolympic-test-correct-answer (nth 0 tests2))))
                (princ "[5] reload persistence OK\n"))
               (t
                (setq fail (1+ fail))
                (princ (format "[5] reload abnormal: %S\n" tests2)))))))
      ;; cleanup
      (ignore-errors (delete-file (quickolympic--tests-file src)))
      (ignore-errors (delete-directory dir t)))
    (if (= fail 0)
        (princ "SMOKE: ALL PASS\n")
      (princ (format "SMOKE: %d FAILURES\n" fail)))
    (kill-emacs (if (= fail 0) 0 1))))
