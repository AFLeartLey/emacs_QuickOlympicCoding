# QuickOlympic

> English: [README.md](README.md)

Emacs 版 [FastOlympicCoding](https://github.com/Jatana/FastOlympicCoding)
——面向**竞赛编程**的测试管理器：在编辑器里管理样例测试、编译运行、人工判定，全程异步不卡 UI。

支持 **Windows / Linux**（已用 Emacs 30.1 + Windows + Git Bash + mingw g++ 实测通过）。
在 Deepseek v4 Flash 的协助下构建。

---

## 功能状态

| 功能 | 状态 | 说明 |
|---|---|---|
| 测试侧边栏（右侧面板） | ✅ 已实现 | `special-mode` 只读面板，`button` 可点击，折叠/展开 |
| 样例测试管理 | ✅ 已实现 | 新增 / 编辑 / 删除 / 交换 / 折叠 |
| 编译并运行全部测试 | ✅ 已实现 | 全异步 `make-process`，自动逐个推进 |
| 运行单个测试 | ✅ 已实现 | 面板内对当前测试单独运行 |
| 判定 | ✅ 已实现 | 每组样例**唯一** correct-answer；命中 → Accepted 并折叠；有 correct-answer 但结果不同 → Rejected；否则 `a`/`x` 人工判定 |
| 编译错误展示 | ✅ 已实现 | 红色显示在面板顶部 |
| 超时杀进程 | ✅ 已实现 | `quickolympic-test-timeout` 控制 |
| 测试持久化 | ✅ 已实现 | JSON 副文件 `<源码>.tests`，重启恢复 |
| 进程终止 | ✅ 已实现 | `C-c M-q k`，Windows/Linux 平台分派 |
| 交互题（comint） | ⏳ 规划 | 尚未实现 |
| 对拍 Stress | ⏳ 规划 | 尚未实现 |
| 实时 lint（flymake） | ⏳ 规划 | 尚未实现 |
| 类型别名/模板补全 | ⏳ 规划 | 尚未实现 |

---

## 环境要求

- **Emacs ≥ 27.1**（在 30.1 上实测）
- 编译/运行所需的工具（按需）：
  - C++：`g++`（Windows 可用 mingw / MSYS2 / WSL 中的编译器）
  - Python：`python`
  - 其他语言：通过 `quickolympic-run-settings` 自定编译/运行命令

---

## 安装

```elisp
;; 1. 把 quickolympic.el 所在目录加入 load-path（替换为你的实际路径）
(add-to-list 'load-path "/path/to/quickolympic/")

;; 2. 加载并全局启用（.cpp/.py/.java 缓冲区自动激活）
(require 'quickolympic)
(quickolympic-global-mode 1)
```

> 不使用包管理器（尚未发布到 MELPA）。也可手动 `(require 'quickolympic)` 后
> 在需要时 `M-x quickolympic-mode` 单独打开。
>
> **快速试一下**：`M-x load-file RET /path/to/quickolympic/quickolympic.el`
> 即可直接加载（文件内置自举，会把所在目录自动加入 load-path），随后
> `M-x quickolympic-global-mode` 启用。

---

## 快速上手（3 步）

假设你打开 `A.cpp`：

1. **新增测试**：`C-c M-q n` → 弹出编辑缓冲区，粘贴样例输入，`C-c C-c` 保存。
   重复添加多个测试。测试会存入 `A.cpp.tests`。
2. **编译并运行**：`C-c M-q r` → 右侧出现测试面板，逐个编译运行全部测试。
3. **判定**：在面板看每个测试的输出——命中该样例的 `correct-answer` → 自动 Accepted
   并折叠；有 `correct-answer` 但结果不同 → 自动 Rejected；无 `correct-answer` 时用
   `a` 接受 / `x` 拒绝（accept 会**覆盖**旧 correct-answer，decline 会清除它）。

---

## 按键绑定

### 源码缓冲区（`quickolympic-mode`，前缀 `C-c M-q`）

| 按键 | 命令 | 功能 |
|---|---|---|
| `C-c M-q r` | `quickolympic-run` | 编译并运行全部测试 |
| `C-c M-q R` | `quickolympic-run-current-test` | 只运行当前测试 |
| `C-c M-q p` | `quickolympic-toggle-panel` | 显示 / 隐藏测试侧边栏 |
| `C-c M-q n` | `quickolympic-new-test` | 新增测试（随后编辑输入） |
| `C-c M-q e` | `quickolympic-edit-test` | 编辑当前测试 |
| `C-c M-q k` | `quickolympic-kill-process` | 终止运行中的进程 |

### 测试面板（`quickolympic-test-mode`）

| 按键 | 功能 |
|---|---|
| `n` | 新增测试 |
| `e` | 编辑光标所在测试 |
| `d` | 删除光标所在测试 |
| `s` / `S` | 与上 / 下一个测试交换 |
| `t` | 折叠 / 展开光标所在测试 |
| `r` | 运行光标所在测试 |
| `R` | 运行全部测试 |
| `a` | 接受当前输出（定性为通过 ✓） |
| `x` | 拒绝当前输出（定性为失败 ✗） |
| `k` | 终止进程 |
| `g` | 手动重渲染面板 |
| `q` | 关闭面板（数据保留） |
| `TAB` / `S-TAB` | 在按钮间移动 |
| `RET` / 鼠标 | 触发光标处的按钮 |

### 编辑缓冲区（`quickolympic-test-edit-mode`）

| 按键 | 功能 |
|---|---|
| `C-c C-c` | 保存测试输入并关闭 |
| `C-c C-k` | 放弃并关闭 |

---

## 测试用例格式

测试持久化在源码旁的副文件 `<源码路径>.tests`（JSON）：

```json
[{"input": "2 3\n", "correct-answer": "5", "wrong-answers": []}]
```

- `input`：测试输入
- `correct-answer`：该样例**唯一**的正确输出。accept 时设置为当前输出；再次 accept
  新输出会**覆盖**旧值（避免把已弃用的旧答案仍当作正确）。decline 当前 correct-answer
  会清除它。可读取旧版 `correct-answers`（复数）格式并取其首项作为 correct-answer。
- `wrong-answers`：你明确拒绝过的输出集合（decline 加入）。
- 该文件可手写/由代码管理；兼容 FastOlympicCoding 的字段语义（需把文件名从
  `A.cpp:tests` 改为 `A.cpp.tests`，因冒号在 Windows 非法）。

---

## 配置

所有选项均为 `defcustom`，可用 `M-x customize-group RET quickolympic` 或直接 setq。

```elisp
;; 编译/运行命令。占位符：
;;   {file} {source_file} {source_file_dir} {file_name} {args}
;; 跨平台要点：
;;   * :run 必须用绝对路径引用二进制（{source_file_dir}…），
;;     否则在 bash（Git Bash）下找不到可执行文件；
;;   * 统一用 .exe 后缀最稳（mingw 的 g++ 会补 .exe；Linux 上创建
;;     名为 A.exe 的普通可执行文件同样可运行）。
(setq quickolympic-run-settings
      '((:lang "C++" :extensions ("cpp" "cc" "cxx")
         :compile "g++ \"{source_file}\" -std=c++17 -O2 -o \"{source_file_dir}{file_name}.exe\""
         :run "\"{source_file_dir}{file_name}.exe\" {args}")
        (:lang "Python" :extensions ("py")
         :compile nil
         :run "python \"{source_file}\"")))

;; 遇错即停：运行多个测试时遇崩溃/TLE/非零退出就停
(setq quickolympic-stop-on-fail t)

;; 单个测试超时秒数（nil = 不超时）
(setq quickolympic-test-timeout 2)

;; 侧边栏宽度（窗口相对宽度）
(setq quickolympic-panel-width 0.32)
```

> Windows 默认 `:compile` 会生成 `<name>.exe`、`:run` 指向它；Linux 生成无扩展名
> 的 `<name>`。默认值已按平台自动适配，一般无需手改。

---

## 运行测试

项目自带单元测试与冒烟测试：

```bash
# 单元测试（5 项）
emacs -batch -Q -L . -l quickolympic.el -l quickolympic-test.el \
      -f ert-run-tests-batch-and-exit

# 端到端冒烟：编译+运行+面板渲染+判定+持久化
emacs -batch -Q -L . -l smoke-test.el -f quickolympic-smoke

# 边界冒烟：Python 无编译 / 编译错误展示 / 超时杀进程
emacs -batch -Q -L . -l smoke2-test.el -f quickolympic-smoke2
```

全部应输出 `ALL PASS` / `5 results as expected`。

---

## 项目结构

```
quickolympic.el            ; 入口：配置、测试管理器、面板、渲染、运行、判定
quickolympic-process.el    ; 异步进程层：编译/运行/终止/超时
quickolympic-test.el       ; ert 单元测试
quickolympic-pkg.el        ; 包元数据
smoke-test.el / smoke2-test.el  ; 端到端冒烟脚本
DESIGN.md                  ; 架构设计文档
reference/FastOlympicCoding/    ; 上游参考源码（只读）
```

---

## 已知限制

- **唯一 correct-answer 半自动判定**：运行结果命中该样例的 correct-answer → Accepted
  并自动折叠；有 correct-answer 但结果不同 → 自动 Rejected（红色）；无 correct-answer
  时靠 `a`/`x` 人工判定。不对比题目给定的"标准答案"。
- **交互题（stdin 手输）** 尚未实现（规划用 comint）。
- **对拍 / lint / 补全** 尚未实现。
- 面板默认折叠测试（只显示标题行）；**运行结束后自动展开**展示输入/输出，
  也可点 `[Test n]` 手动切换折叠。
- Windows 下若 Emacs 的 `shell-file-name` 是 Git Bash 的 bash，运行命令必须用
  `{source_file_dir}` 绝对路径（默认值已处理）。
