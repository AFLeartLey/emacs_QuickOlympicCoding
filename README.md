# QuickOlympic

An Emacs clone of [FastOlympicCoding](https://github.com/Jatana/FastOlympicCoding) —
a **competitive-programming test manager**: manage sample tests, compile & run them,
and judge results, all inside Emacs with a fully asynchronous, non-blocking UI.

Works on **Windows / Linux** (tested on Emacs 30.1 + Windows + Git Bash + mingw g++).

Built with Deepseek v4 Flash.

> 中文版：[readme_zh.md](readme_zh.md)

---

## Feature Status

| Feature | Status | Notes |
|---|---|---|
| Test side panel (right) | ✅ Done | `special-mode` read-only panel, clickable buttons, fold/unfold |
| Sample test management | ✅ Done | add / edit / delete / swap / fold |
| Compile & run all tests | ✅ Done | fully async `make-process`, runs tests one by one |
| Run a single test | ✅ Done | run just the test at point |
| Verdict | ✅ Done | each test has a **single** `correct-answer`; matching → Accepted & folded; differing → Rejected; otherwise manual `a`/`x` |
| Compile error display | ✅ Done | shown in red at the top of the panel |
| Per-test timeout | ✅ Done | controlled by `quickolympic-test-timeout` |
| Test persistence | ✅ Done | JSON sidecar `<source>.tests`, restored on restart |
| Kill running process | ✅ Done | `C-c q k`, platform-aware (Windows/Linux) |
| Interactive problems (comint) | ⏳ Planned | not yet implemented |
| Stress testing | ⏳ Planned | not yet implemented |
| Real-time lint (flymake) | ⏳ Planned | not yet implemented |
| Type alias / template completion | ⏳ Planned | not yet implemented |

---

## Requirements

- **Emacs ≥ 27.1** (tested on 30.1)
- Tools needed for compiling/running (as needed):
  - C++: `g++` (mingw / MSYS2 / WSL on Windows)
  - Python: `python`
  - Other languages: define your own compile/run commands via `quickolympic-run-settings`

---

## Installation

```elisp
;; 1. Add the directory containing quickolympic.el to load-path
(add-to-list 'load-path "/path/to/quickolympic/")

;; 2. Load and enable globally (.cpp/.py/.java buffers activate automatically)
(require 'quickolympic)
(quickolympic-global-mode 1)
```

> Not on MELPA yet. You can also load only when needed with
> `M-x quickolympic-mode`.
>
> **Quick try**: `M-x load-file RET /path/to/quickolympic/quickolympic.el`
> works directly (the file bootstraps by adding its own directory to
> load-path), then `M-x quickolympic-global-mode`.

---

## Quick Start (3 steps)

Assume you have `A.cpp` open:

1. **Add a test**: `C-c q n` → an edit buffer opens; paste the sample input and
   press `C-c C-c`. Repeat to add more tests. Tests are stored in `A.cpp.tests`.
2. **Compile & run**: `C-c q r` → the test panel appears on the right and all
   tests are compiled and run one by one.
3. **Judge**: look at each test's output in the panel — if it matches the test's
   `correct-answer` it is automatically **Accepted** and folded; if a
   `correct-answer` exists but the output differs it is **Rejected**; otherwise
   press `a` to accept / `x` to reject (accept **replaces** the old
   correct-answer, decline clears it).

---

## Key Bindings

### Source buffer (`quickolympic-mode`, prefix `C-c q`)

| Key | Command | Action |
|---|---|---|
| `C-c q r` | `quickolympic-run` | compile & run all tests |
| `C-c q R` | `quickolympic-run-current-test` | run only the current test |
| `C-c q p` | `quickolympic-toggle-panel` | show / hide the test panel |
| `C-c q n` | `quickolympic-new-test` | add a new test (then edit its input) |
| `C-c q e` | `quickolympic-edit-test` | edit the current test |
| `C-c q k` | `quickolympic-kill-process` | kill the running process |

### Test panel (`quickolympic-test-mode`)

| Key | Action |
|---|---|
| `n` | add a new test |
| `e` | edit the test at point |
| `d` | delete the test at point |
| `s` / `S` | swap with the one above / below |
| `t` | fold / unfold the test at point |
| `r` | run only the test at point |
| `R` | run all tests |
| `a` | accept the current output (✓) |
| `x` | reject the current output (✗) |
| `k` | kill the running process |
| `g` | re-render the panel |
| `q` | close the panel (data is kept) |
| `TAB` / `S-TAB` | move between buttons |
| `RET` / mouse | trigger the button at point |

### Edit buffer (`quickolympic-test-edit-mode`)

| Key | Action |
|---|---|
| `C-c C-c` | save the test input and close |
| `C-c C-k` | cancel and close |

---

## Test Case Format

Tests are persisted to a JSON sidecar file next to the source: `<source path>.tests`

```json
[{"input": "2 3\n", "correct-answer": "5", "wrong-answers": []}]
```

- `input`: the test input.
- `correct-answer`: the **single** correct output for this test. Set by
  accepting an output; accepting a new output **replaces** the old value (so a
  stale wrong answer is never kept as correct). Declining the current
  correct-answer clears it. The old plural `correct-answers` key is also read
  (its first element is used).
- `wrong-answers`: outputs you explicitly rejected (added by decline).
- The file can be hand-edited; it follows FastOlympicCoding field semantics
  (rename `A.cpp:tests` to `A.cpp.tests`, since `:` is illegal in Windows
  filenames).

---

## Configuration

All options are `defcustom`s — use `M-x customize-group RET quickolympic` or `setq`.

```elisp
;; Compile/run commands. Placeholders:
;;   {file} {source_file} {source_file_dir} {file_name} {args}
;; Cross-platform notes:
;;   * :run must reference the binary by an absolute path ({source_file_dir}…),
;;     otherwise bash (Git Bash) cannot find the executable;
;;   * a uniform .exe suffix is safest (mingw's g++ appends .exe; on Linux a
;;     file named A.exe is just an ordinary executable and runs fine).
(setq quickolympic-run-settings
      '((:lang "C++" :extensions ("cpp" "cc" "cxx")
         :compile "g++ \"{source_file}\" -std=c++17 -O2 -o \"{source_file_dir}{file_name}.exe\""
         :run "\"{source_file_dir}{file_name}.exe\" {args}")
        (:lang "Python" :extensions ("py")
         :compile nil
         :run "python \"{source_file}\"")))

;; Stop running remaining tests after a crash/TLE/non-zero exit
(setq quickolympic-stop-on-fail t)

;; Per-test timeout in seconds (nil = no timeout)
(setq quickolympic-test-timeout 2)

;; Panel width (fraction of the frame)
(setq quickolympic-panel-width 0.32)
```

> On Windows the default `:compile` produces `<name>.exe` and `:run` points to
> it; on Linux it produces an extension-less `<name>`. The defaults are already
> platform-adapted, so usually nothing needs changing.

---

## Running the Tests

The package ships unit tests and smoke tests:

```bash
# Unit tests (6 cases)
emacs -batch -Q -L . -l quickolympic.el -l quickolympic-test.el \
      -f ert-run-tests-batch-and-exit

# End-to-end smoke: compile + run + panel + verdict + persistence
emacs -batch -Q -L . -l smoke-test.el -f quickolympic-smoke

# Edge cases: Python (no compile) / compile errors / timeout
emacs -batch -Q -L . -l smoke2-test.el -f quickolympic-smoke2
```

All should print `ALL PASS` / `6 results as expected`.

---

## Project Layout

```
quickolympic.el            ; entry: config, test manager, panel, render, run, verdict
quickolympic-process.el    ; async process layer: compile/run/kill/timeout
quickolympic-test.el       ; ert unit tests
quickolympic-pkg.el        ; package metadata
smoke-test.el / smoke2-test.el  ; end-to-end smoke scripts
DESIGN.md                  ; architecture design doc
reference/FastOlympicCoding/    ; upstream reference source (read-only)
```

---

## Known Limitations

- **Semi-automatic verdict against the single `correct-answer`**: matching →
  Accepted & auto-folded; differing → auto-Rejected (red); no correct-answer →
  judged manually with `a`/`x`. Problem-provided "standard answers" are **not**
  compared automatically.
- **Interactive problems (typed stdin)** not yet implemented (planned via comint).
- **Stress testing / lint / completion** not yet implemented.
- Tests are folded by default (header only); they **auto-unfold after a run** to
  show input/output; press `t` or click `[Test n]` to toggle.
- On Windows, if Emacs's `shell-file-name` is Git Bash's bash, run commands must
  use `{source_file_dir}` absolute paths (the defaults already do).
