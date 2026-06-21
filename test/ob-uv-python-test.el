;;; ob-uv-python-test.el --- Tests for ob-uv-python  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Ales Nikiforov

;;; Commentary:

;; Unit tests for the pure helper functions run unconditionally.
;; Integration tests that shell out to `uv run' are skipped when
;; `uv' is not on `exec-path'.

;;; Code:

(require 'ert)
(require 'org)
(require 'ob)
(require 'ob-uv-python)

;;; Pure helpers

(ert-deftest ob-uv-python-test-flag-p ()
  (should (ob-uv-python--flag-p "yes"))
  (should (ob-uv-python--flag-p t))
  (should-not (ob-uv-python--flag-p "no"))
  (should-not (ob-uv-python--flag-p nil))
  (should-not (ob-uv-python--flag-p ""))
  (should-not (ob-uv-python--flag-p "false")))

(ert-deftest ob-uv-python-test-pep723-p ()
  (should (ob-uv-python--pep723-p "# /// script\nfoo"))
  (should (ob-uv-python--pep723-p "   # /// script\nfoo"))
  (should-not (ob-uv-python--pep723-p "print(1)")))

(ert-deftest ob-uv-python-test-val-to-python ()
  (should (equal (ob-uv-python--val-to-python nil) "None"))
  (should (equal (ob-uv-python--val-to-python t) "True"))
  (should (equal (ob-uv-python--val-to-python 'hline) "'hline'"))
  (should (equal (ob-uv-python--val-to-python 42) "42"))
  (should (equal (ob-uv-python--val-to-python "hi") "\"hi\""))
  (should (equal (ob-uv-python--val-to-python '(1 2 3)) "[1, 2, 3]")))

(ert-deftest ob-uv-python-test-build-cmd-basic ()
  (let ((cmd (ob-uv-python--build-cmd '((:python . "3.12")) "print(1)")))
    (should (string-match-p "--python 3\\.12" cmd))
    (should (string-match-p "\\bpython\\b" cmd))))

(ert-deftest ob-uv-python-test-build-cmd-always-quiet ()
  ;; uv prints resolver/install status to stderr even on success, which
  ;; org-babel-eval mistakes for an error condition; -q silences it.
  (let ((cmd (ob-uv-python--build-cmd nil "print(1)")))
    (should (string-match-p "--quiet" cmd))))

(ert-deftest ob-uv-python-test-build-cmd-unquoted-python-version ()
  ;; Org reads an unquoted ":python 3.8" header arg as a Lisp float,
  ;; not a string -- regression test for the resulting wrong-type-argument.
  (let* ((raw (org-babel-parse-header-arguments ":python 3.8"))
         (cmd (ob-uv-python--build-cmd raw "print(1)")))
    (should (string-match-p "--python 3\\.8\\b" cmd))))

(ert-deftest ob-uv-python-test-build-cmd-with-packages ()
  (let ((cmd (ob-uv-python--build-cmd '((:with . "rich httpx")) "print(1)")))
    (should (string-match-p "--with rich" cmd))
    (should (string-match-p "--with httpx" cmd))))

(ert-deftest ob-uv-python-test-build-cmd-script-mode ()
  (let ((cmd (ob-uv-python--build-cmd nil "# /// script\nfoo")))
    (should (string-match-p "--script" cmd))))

(ert-deftest ob-uv-python-test-build-cmd-no-project-isolated ()
  (let ((cmd (ob-uv-python--build-cmd '((:no-project . "yes") (:isolated . "yes")) "print(1)")))
    (should (string-match-p "--no-project" cmd))
    (should (string-match-p "--isolated" cmd))))

(ert-deftest ob-uv-python-test-build-cmd-extra-args ()
  (let ((cmd (ob-uv-python--build-cmd '((:extra-args . "--offline")) "print(1)")))
    (should (string-match-p "--offline\\'" cmd))))

(ert-deftest ob-uv-python-test-build-cmd-missing-uv-signals-user-error ()
  (let ((err (should-error
              (ob-uv-python--build-cmd '((:uv . "totally-not-a-real-binary-xyz")) "print(1)")
              :type 'user-error)))
    (should (string-match-p "totally-not-a-real-binary-xyz" (cadr err)))))

(ert-deftest ob-uv-python-test-expand-tilde ()
  (should (equal (ob-uv-python--expand-tilde "/abs/path") "/abs/path"))
  (should (equal (ob-uv-python--expand-tilde "bare-name") "bare-name"))
  (should (equal (ob-uv-python--expand-tilde nil) nil))
  (should (equal (ob-uv-python--expand-tilde "~/.local/bin/uv")
                  (expand-file-name "~/.local/bin/uv"))))

;;; Integration (requires a real `uv' binary)

(ert-deftest ob-uv-python-test-execute-output ()
  (skip-unless (executable-find "uv"))
  (let* ((params (org-babel-process-params
                  '((:no-project . "yes") (:result-params "replace" "output") (:result-type . output))))
         (out (org-babel-execute:uv-python "print('hello')" params)))
    (should (equal out "hello\n"))))

(ert-deftest ob-uv-python-test-execute-with-package-no-stderr-noise ()
  ;; uv's own "Installed N packages..." status line goes to stderr on
  ;; success; without -q this trips org-babel-eval's error reporting.
  (skip-unless (executable-find "uv"))
  (ignore-errors (kill-buffer org-babel-error-buffer-name))
  (let* ((params (org-babel-process-params
                  '((:no-project . "yes") (:with . "six")
                    (:result-params "replace" "output") (:result-type . output))))
         (out (org-babel-execute:uv-python "print('hi')" params)))
    (should (equal out "hi\n"))
    (should-not (get-buffer org-babel-error-buffer-name))))

(ert-deftest ob-uv-python-test-execute-value-expression ()
  (skip-unless (executable-find "uv"))
  (let* ((params (org-babel-process-params
                  '((:no-project . "yes") (:result-params "replace" "value") (:result-type . value))))
         (out (org-babel-execute:uv-python "x = [1, 2, 3, 4, 5]\nsum(x)" params)))
    (should (equal out 15))))

(ert-deftest ob-uv-python-test-execute-value-assignment-is-empty ()
  (skip-unless (executable-find "uv"))
  (let* ((params (org-babel-process-params
                  '((:no-project . "yes") (:result-params "replace" "value") (:result-type . value))))
         (out (org-babel-execute:uv-python "x = 5" params)))
    (should (equal out ""))))

(ert-deftest ob-uv-python-test-execute-pep723-auto-detect ()
  (skip-unless (executable-find "uv"))
  (let* ((params (org-babel-process-params
                  '((:result-params "replace" "output") (:result-type . output))))
         (body "# /// script\n# dependencies = [\"rich\"]\n# ///\nfrom rich import print as rprint\nrprint('ok')")
         (out (org-babel-execute:uv-python body params)))
    (should (equal out "ok\n"))))

(ert-deftest ob-uv-python-test-execute-var ()
  (skip-unless (executable-find "uv"))
  (let* ((params (org-babel-process-params
                  (list '(:no-project . "yes")
                        (cons :var (cons 'data '(1 2 3 4 5)))
                        '(:result-params "replace" "output")
                        '(:result-type . output))))
         (out (org-babel-execute:uv-python "print(sum(data))" params)))
    (should (equal out "15\n"))))

(provide 'ob-uv-python-test)
;;; ob-uv-python-test.el ends here
