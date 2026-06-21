# ob-uv-python — Org-babel backend for Python via `uv run`

Author: Ales Nikiforov

Run Python org-babel blocks through [uv run](https://docs.astral.sh/uv/). Install packages on the fly, pin
Python versions, and use PEP 723 inline script headers — all from header args.

## Installation

### Doom Emacs

`packages.el`:

```emacs-lisp
(package! ob-uv-python
  :recipe (:host github :repo "alesnim/ob-uv-python"))
```

`config.el`:

```emacs-lisp
(after! org
  (add-to-list 'org-babel-load-languages '(uv-python . t)))
```

Run `doom sync` then restart.

### straight.el / use-package

```emacs-lisp
(use-package ob-uv-python
  :straight (:host github :repo "alesnim/ob-uv-python")
  :after org
  :config
  (add-to-list 'org-babel-load-languages '(uv-python . t)))
```

### Custom uv path

If `uv` is not on `exec-path`:

```emacs-lisp
(setq ob-uv-python-command "~/.local/bin/uv")
```

## Header args

| Arg           | Example                  | Maps to                          |
|---------------|---------------------------|-----------------------------------|
| `:python`     | `3.12`                    | `--python 3.12`                   |
| `:with`       | `"requests rich"`         | `--with requests --with rich`     |
| `:no-project` | `yes`                     | `--no-project`                    |
| `:script`     | `yes` (or auto-detected)  | `--script` (PEP 723 mode)         |
| `:isolated`   | `yes`                     | `--isolated`                      |
| `:env-file`   | `".env"`                  | `--env-file .env`                 |
| `:extra-args` | `"--offline"`             | appended verbatim to `uv run`     |
| `:uv`         | `"/opt/bin/uv"`           | overrides `ob-uv-python-command`  |

## Usage

### Basic

```python
#+begin_src uv-python :no-project yes
print("hello from uv")
#+end_src
```

### Install packages on the fly

```python
#+begin_src uv-python :with "httpx" :no-project yes
import httpx
r = httpx.get("https://httpx.io")
print(r.status_code)
#+end_src
```

### Pin Python version

```python
#+begin_src uv-python :python 3.11 :no-project yes
import sys
print(sys.version_info[:2])
#+end_src
```

### Capture a value (`:results value`)

The last *expression* in the block is captured automatically.
Assignments and statements (`if`, `for`, etc.) are not captured.

```python
#+begin_src uv-python :results value :no-project yes
x = [1, 2, 3, 4, 5]
sum(x)
#+end_src
```

```
#+RESULTS:
: 15
```

Return a table:

```python
#+begin_src uv-python :results value :no-project yes
[(i, i**2) for i in range(5)]
#+end_src
```

```
#+RESULTS:
| 0 | 0  |
| 1 | 1  |
| 2 | 4  |
| 3 | 9  |
| 4 | 16 |
```

### PEP 723 inline script (auto-detected)

The `# /// script` header is detected automatically — no `:script yes` needed.

```python
#+begin_src uv-python
# /// script
# dependencies = ["rich", "httpx"]
# ///
from rich import print as rprint
import httpx
rprint("[bold green]ok[/bold green]")
#+end_src
```

### Pass data between blocks with `:var`

```python
#+name: my-data
#+begin_src uv-python :results value :no-project yes
[1, 2, 3, 4, 5]
#+end_src

#+begin_src uv-python :var data=my-data :with "statistics" :no-project yes
import statistics
print(statistics.mean(data))
print(statistics.stdev(data))
#+end_src
```

### Org table as variable

```
#+name: scores
| name  | score |
|-------+-------|
| Alice |    95 |
| Bob   |    82 |
| Carol |    91 |
```

```python
#+begin_src uv-python :var tbl=scores :results value :no-project yes
[(row[0], int(row[1])) for row in tbl]
#+end_src
```

## Notes

- **Sessions** are not supported. Each block is a fresh `uv run` process.
  Use `:var` to pass data between blocks.
- **`:results value`** auto-detects the last expression via Python's `ast` module.
  If the last statement is an assignment or a compound statement (`if`, `for`, etc.),
  the result is empty. Wrap in an explicit expression if needed.
- Packages installed via `:with` are cached by uv — repeat runs are fast.
