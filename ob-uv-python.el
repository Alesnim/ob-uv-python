;;; ob-uv-python.el --- Org-babel backend for Python via uv run  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Ales Nim

;; Author: Ales Nim <alesnim@gmail.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (org "9.6"))
;; Keywords: outlines, literate programming, tools, processes, python, uv
;; URL: https://github.com/alesnim/ob-uv-python
;; Homepage: https://github.com/alesnim/ob-uv-python

;; This file is NOT part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; ob-uv-python lets you run Python org-babel source blocks through
;; `uv run' instead of a bare interpreter.  This gives every code block
;; access to uv's package management: install dependencies on the fly
;; with `:with', pin a Python version with `:python', or run PEP 723
;; inline-script blocks (auto-detected from a `# /// script' header)
;; with per-block dependencies and no shared environment.
;;
;; Header args:
;;   :python  VERSION   - Python version, e.g. "3.12"
;;   :with    PKGS      - Extra packages, space/comma separated, e.g. "requests rich"
;;   :no-project yes    - Pass --no-project to uv (ignore project deps)
;;   :script  yes       - PEP 723 inline script mode (auto-detected from body)
;;   :isolated yes      - Pass --isolated to uv
;;   :env-file PATH     - Pass --env-file PATH to uv
;;   :extra-args STR    - Raw extra arguments appended verbatim to uv run
;;   :uv      PATH      - Path to uv binary (overrides ob-uv-python-command)
;;
;; See the README for full usage examples.

;;; Code:

(require 'ob)
(require 'ob-eval)
(require 'json)

(defgroup ob-uv-python nil
  "Org-babel integration for Python via uv run."
  :group 'org-babel
  :prefix "ob-uv-python-")

(defcustom ob-uv-python-command
  (or (executable-find "uv")
      (let ((h (expand-file-name "~/.local/bin/uv")))
        (when (file-executable-p h) h))
      "uv")
  "Path to the uv executable."
  :type 'string
  :group 'ob-uv-python)

(add-to-list 'org-src-lang-modes '("uv-python" . python))

(defvar org-babel-default-header-args:uv-python
  '((:results . "output replace")
    (:exports . "both"))
  "Default header args for uv-python source blocks.")

(defconst org-babel-header-args:uv-python
  '((python     . :any)  ; Python version to run, e.g. "3.12" -> --python 3.12
    (with       . :any)  ; extra packages to install, space/comma separated -> --with PKG (repeated)
    (no-project . ((yes no)))  ; ignore the current project's dependencies -> --no-project
    (script     . ((yes no))) ; force PEP 723 inline-script mode -> --script (auto-detected otherwise)
    (isolated   . ((yes no)))  ; run in an isolated venv, ignoring any active one -> --isolated
    (env-file   . :any)  ; path to a dotenv file to load -> --env-file PATH
    (extra-args . :any)  ; raw string appended verbatim after the built `uv run' command
    (uv         . :any))  ; path to the uv binary for this block, overriding `ob-uv-python-command'
  "Header args specific to uv-python blocks.")

;; Preamble injected before user body for :results value mode.
;; Reads the script file itself at runtime, uses Python AST to detect
;; whether the last statement is an expression, and prints its repr.
;; Falls back to plain exec if the last statement is not an expression
;; (e.g. an assignment or a loop) — result is empty in that case.
(defconst ob-uv-python--value-preamble
  "import ast as __ob_ast, sys as __ob_sys


def __ob_run__():
    with open(__ob_sys.argv[0]) as __ob_f:
        __ob_lines = __ob_f.readlines()
    __ob_start = next(
        (i + 1 for i, l in enumerate(__ob_lines)
         if l.rstrip('\\r\\n') == '# __OB_BODY__'),
        None)
    if __ob_start is None:
        raise RuntimeError('ob-uv-python: missing body marker')
    __ob_src = ''.join(__ob_lines[__ob_start:])
    __ob_tree = __ob_ast.parse(__ob_src)
    if not __ob_tree.body:
        return
    __ob_last = __ob_tree.body[-1]
    __ob_ns = {}
    if isinstance(__ob_last, __ob_ast.Expr):
        __ob_rest = __ob_ast.Module(body=__ob_tree.body[:-1], type_ignores=[])
        __ob_ast.fix_missing_locations(__ob_rest)
        exec(compile(__ob_rest, __ob_sys.argv[0], 'exec'), __ob_ns)
        __ob_expr = __ob_ast.Expression(body=__ob_last.value)
        __ob_ast.fix_missing_locations(__ob_expr)
        __ob_result = eval(compile(__ob_expr, __ob_sys.argv[0], 'eval'), __ob_ns)
        if __ob_result is not None:
            print(repr(__ob_result))
    else:
        exec(compile(__ob_tree, __ob_sys.argv[0], 'exec'), __ob_ns)


__ob_run__()
# __OB_BODY__
"
  "Python preamble written before user code for :results value mode.")

;;; Internal helpers

(defun ob-uv-python--flag-p (val)
  "Return non-nil if VAL is a truthy babel flag."
  ;; org-babel may give us a string or a symbol depending on header arg type
  (not (member val '(nil no "" "no" "nil" "false"))))

(defun ob-uv-python--val-to-python (val)
  "Convert elisp VAL to a Python literal string."
  (cond
   ((null val)      "None")
   ((eq val t)      "True")
   ((eq val 'hline) "'hline'")
   ((numberp val)   (number-to-string val))
   ((stringp val)   (json-encode-string val))   ; JSON strings are valid Python literals
   ((listp val)
    (format "[%s]" (mapconcat #'ob-uv-python--val-to-python val ", ")))
   (t (json-encode-string (format "%s" val)))))

(defun org-babel-variable-assignments:uv-python (params)
  "Return list of Python variable assignment strings from PARAMS."
  (mapcar (lambda (pair)
            (format "%s = %s"
                    (car pair)
                    (ob-uv-python--val-to-python (cdr pair))))
          (org-babel--get-vars params)))

(defun ob-uv-python--to-string (val)
  "Coerce VAL to a string, or return nil.
Header args without quotes (e.g. `:python 3.8') are read by Org as
numbers or symbols rather than strings."
  (and val (if (stringp val) val (format "%s" val))))

(defun ob-uv-python--pep723-p (body)
  "Return non-nil if BODY has a PEP 723 inline script header."
  (string-match-p "\\`[[:space:]]*# /// script" body))

(defun ob-uv-python--expand-tilde (path)
  "Expand a leading ~ in PATH.
`shell-quote-argument' escapes a leading ~, which stops the shell
from expanding it, so a literal ~ in PATH must be resolved here
instead."
  (and path (if (string-prefix-p "~" path) (expand-file-name path) path)))

(defun ob-uv-python--build-cmd (params body)
  "Build the uv run command string from PARAMS and BODY.
BODY is used to auto-detect PEP 723 script mode."
  (let* ((uv      (ob-uv-python--expand-tilde
                    (or (ob-uv-python--to-string (cdr (assq :uv params))) ob-uv-python-command)))
         (pyver   (ob-uv-python--to-string (cdr (assq :python params))))
         (with    (ob-uv-python--to-string (cdr (assq :with params))))
         (noproj  (ob-uv-python--flag-p (cdr (assq :no-project params))))
         (iso     (ob-uv-python--flag-p (cdr (assq :isolated params))))
         (script  (or (ob-uv-python--flag-p (cdr (assq :script params)))
                      (ob-uv-python--pep723-p body)))
         (envfile (ob-uv-python--expand-tilde
                    (ob-uv-python--to-string (cdr (assq :env-file params)))))
         (extra   (ob-uv-python--to-string (cdr (assq :extra-args params))))
         args)
    (unless (executable-find uv)
      (user-error
       "ob-uv-python: `%s' not found; install uv (https://docs.astral.sh/uv/) or set `ob-uv-python-command' or the `:uv' header arg"
       uv))
    (push uv args)
    (push "run" args)
    ;; uv prints resolver/install status (e.g. "Installed 1 package in 58ms")
    ;; to stderr even on success, which org-babel-eval treats as an error
    ;; condition and reports via a pop-up error buffer.  -q silences that
    ;; noise without touching the executed program's own stderr/exit code.
    (push "--quiet" args)
    (when (and pyver (not (string-empty-p pyver)))
      (push "--python" args)
      (push pyver args))
    (when with
      (dolist (pkg (split-string with "[ ,]+" t))
        (push "--with" args)
        (push pkg args)))
    (when noproj  (push "--no-project" args))
    (when iso     (push "--isolated" args))
    (when (and envfile (not (string-empty-p envfile)))
      (push "--env-file" args)
      (push envfile args))
    (if script
        (push "--script" args)
      (push "python" args))
    (let ((base (mapconcat #'shell-quote-argument (nreverse args) " ")))
      (if (and extra (not (string-empty-p extra)))
          (concat base " " extra)
        base))))

;;; Main entry point

;;;###autoload
(defun org-babel-execute:uv-python (body params)
  "Execute uv-python BODY with PARAMS via `uv run'."
  (let* ((result-params (cdr (assq :result-params params)))
         (result-type   (cdr (assq :result-type params)))
         (is-value      (eq result-type 'value))
         (is-script     (or (ob-uv-python--flag-p (cdr (assq :script params)))
                            (ob-uv-python--pep723-p body)))
         (expanded      (org-babel-expand-body:generic
                         body params
                         (org-babel-variable-assignments:uv-python params)))
         (full-body     (if (and is-value (not is-script))
                            (concat ob-uv-python--value-preamble expanded)
                          expanded))
         (tmp           (org-babel-temp-file "uv-python-" ".py"))
         (cmd           (concat (ob-uv-python--build-cmd params body)
                                " " (shell-quote-argument tmp))))
    (with-temp-file tmp
      (insert full-body))
    (let ((raw (org-babel-eval cmd "")))
      (org-babel-result-cond result-params
        raw
        (org-babel-script-escape (string-trim raw))))))

(provide 'ob-uv-python)
;;; ob-uv-python.el ends here
