# gpac-vul — dataset specification

一个可复现的 gpac 漏洞集：源码基线固定在一个 commit，27 条 OSS-Fuzz 崩溃案例各自带一个
独立补丁与一个 PoC，容器内可一键验证"基线崩、打补丁不崩"。

本文件是这份数据的**契约**：下面的表格、字段、命令与判定规则都是被校验的；校验结果在
`reports/`（`verify.json`、`verify-one.json`、`verify-one-by-one.json`）。

字段、目录与报告格式与同批次的 `imagemagick-vul`、`ffmpeg-vul` 保持一致，三者可以直接
并排当作同一套数据的三个实例。

## 1. 范围

| 项 | 值 |
| --- | --- |
| 项目 | gpac（`https://github.com/gpac/gpac`，C） |
| 基线 | `b890f1c443dbe1f941cd326d4473ce7ddef8e256`（2024-01-17，修复窗口前一个提交） |
| 案例 | 27 条，全部来自 ARVO（OSS-Fuzz 报告 + 已复现）；每条都在基线上实跑确认仍崩，且实跑确认自己的补丁能清掉它（§7） |
| 时间窗 | 修复提交落在 2024-01-17 … 2024-03-12 |
| 修复提交 | 每条案例一个**不同**的 upstream 提交（1:1），无多案例共用提交 |
| fuzz 目标 | `fuzz_probe_analyze`（26）、`fuzz_parse`（1） |
| sanitizer | ASan 20、UBSan 7，按上报该案例的那一套回放 |
| 崩溃类型 | 13 种（HBO-R/W、SBO-R/W、GBO、UAF、UNKNOWN、Index-out-of-bounds 等） |

时间窗与 1:1 的约束是为了"单个基线仍然包含全部缺陷"：所有修复都在基线之后，且没有一条
案例需要靠别人的修复才成立。基线是否真的对每条 PoC 都崩，由 `verify.sh` 实际跑出来判定，
不是推断。

## 2. 目录

```
gpac-vul/
  src/gpac-readonly/              基线的纯拷贝（无 .git），与镜像内 /src/gpac 逐字节一致
  payload/
    cases.tsv                     案例表（见 §4）
    pocs/<localId>/poc            每条案例的 PoC，原样来自 OSS-Fuzz testcase
    patches/<fix_commit>.patch    每条案例的补丁，以修复提交命名（见 §5）
    patch-index.json              以修复提交为键：影响文件、提交主题、日期
    vulnerabilities.json          位置、调用栈、代码片段、描述（见 §6）
  scripts/
    lib.sh                        共享函数（指纹、构建、回放、判定）
    build.sh                      无 sanitizer 的普通构建
    verify.sh                     基线全量验证：每条 PoC 都必须 CRASH
    verify-one.sh                 单条：基线 CRASH + 打补丁 CLEAN
    verify-one-by-one.sh          全量归属验证，写 reports/verify-one-by-one.json
    fuzz_probe_analyze.c          从 gpac/testsuite 8693a5a2 取的 OSS-Fuzz 目标
    fuzz_parse.c                  同上
    standalone_main.c             单输入驱动（替代 libFuzzer 运行时）
  image/Dockerfile                可复现环境
  reports/
    verify.json                   基线全量：27 条全 CRASH
    verify-one.json               最近一次单条验证
    verify-one-by-one.json        全量归属：27 条全 PASS
```

镜像内固定位置：`/src/gpac`（基线树）、`/payload`、`/opt/gpdt`（脚本）、`/out`（复现器）、
`/work`（构建目录）、`/reports`。脚本目录必须加入 `PATH`，不设命令分发层。

## 3. 环境变量

| 变量 | 默认 | 含义 |
| --- | --- | --- |
| `GPDT_TREE` | `/src/gpac` | 基线源码树（可指向任意副本） |
| `PAYLOAD` | `/payload` | 案例数据 |
| `OUT` | `/out` | 复现器输出 |
| `WORK` | `/work` | 构建目录 |
| `GPDT_COLD` | 未设 | 设为 1 时打补丁的树走全量重建，而不是复用基线构建目录做增量 |

源码指纹 `src_fp()`：git 树取 `<commit8>-<sha256(git diff)[:8]>`；无 `.git` 的纯拷贝取
`tree-<sha256(所有文件内容)[:16]>`。指纹进入构建目录名与复现器名，所以基线与每个打补丁
的副本互不覆盖。

## 4. cases.tsv

制表符分隔，`#` 开头为注释，一案例一行，8 列：

```
localId  fuzzer  sanitizer  alert  expect_frame  poc  patch  fix_commit
```

- `localId` 是 ARVO/OSS-Fuzz 的 testcase id，也是 `pocs/<localId>/` 的目录名；
- `fuzzer` ∈ `fuzz_probe_analyze|fuzz_parse`，决定链接哪个 OSS-Fuzz 目标；
- `sanitizer` ∈ `asan|ubsan`，决定用哪套 flags 编译、哪套 `*_OPTIONS` 运行；
- `alert` 是 sanitizer 的原始措辞（与 `vulnerabilities.json` 的 `type.crash_type` 一致）；
- `expect_frame` 是报告点名的帧，与 `vulnerabilities.json` 的 `location.function` 一致；
- `patch` 形如 `patches/<fix_commit>.patch`，与该行 `fix_commit` 对应。

## 5. 补丁

- 每条案例一个补丁，由它的 upstream 修复提交导出，**只含本案例的改动**，文件名为
  `<fix_commit>.patch`。
- 导出方式：优先用 `git diff <fix>^ <fix>`；当上下文在基线与修复之间移动过时，把该提交
  cherry-pick 到基线上取树差异。两种情况都保证补丁能落到基线上，代价是个别补丁应用时带
  行偏移（`patch` 报 `offset -7 … -10 lines`，`Hunk succeeded`），不影响被修改的行。
- 27 个补丁都能对基线应用（`check_package.py` 逐个核对每个 hunk 的上下文仍存在于基线）。
- 因为案例之间是不同提交，补丁在文件层面大多互斥；少数几个提交改同一文件的不同 hunk
  （`src/media_tools/av_parsers.c` 6 个、`src/ietf/rtsp_session.c` 3 个、
  `src/ietf/sdp.c` 3 个、`src/utils/token.c` 2 个），彼此不覆盖；31 个补丁只动一个文件。

## 6. vulnerabilities.json

```json
{
  "project": "gpac",
  "repo": "https://github.com/gpac/gpac",
  "baseline": {"commit": "...", "describe": "...", "date": "...", "note": "..."},
  "paths": {"cases": "cases.tsv", "pocs": "pocs/<localId>/poc",
            "patches": "patches/<fix_commit>.patch"},
  "vulnerabilities": [
    {
      "id": "42531304",
      "type": {"crash_type": "Heap-buffer-overflow READ {*}",
               "cwe": "CWE-125", "cwe_name": "Out-of-bounds Read"},
      "location": {
        "file": "src/utils/xml_parser.c",
        "line": 977,
        "function": "xml_sax_append_string",
        "stack": [{"function": "xml_sax_append_string", "file": "src/utils/xml_parser.c"}, ...]
      },
      "code_snippet": {"before": "...", "after": "...", "fix_summary": "..."},
      "description": "`src/utils/xml_parser.c:977`（`xml_sax_append_string`）：……",
      "patch": "patches/538b229cab5e6317053c15c66417a9d053681ad0.patch"
    }
  ]
}
```

- `type.crash_type` 与 cases.tsv 的 `alert` 逐字一致；`cwe_name` 是 `cwe` 的英文名。
- `location` 是上报栈里最内层的**业务**帧（函数 + 文件 + 行号）：行号来自报告，基线树
  可能与报告版本有偏移，行号仅作定位参考。
- `stack` 只记函数与文件，不记行号；由内向外排列，去掉 fuzz 驱动帧（`LLVMFuzzerTestOneInput`、
  `main`、`fuzz_*.c`），最多 10 帧。`location.function` 恒等于 `stack[0].function`。
- `code_snippet.before`/`after` 是补丁第一个 hunk 的改前/改后文本（上下文 + 增删行），
  `fix_summary` 是一句话概括（函数、提交主题、增删行数）。
- `description` 说明位置、触发路径与修复动作。

## 7. 验证规则

- `build.sh`：无 sanitizer 的 configure/make，产出 `libgpac_static.a`。
- `verify.sh [--tree DIR] [--report DIR]`：对基线逐条跑 PoC，**每条都必须 CRASH**；任一不崩
  即退出非 0。写 `verify.json`：`{"pass": 0, "fail": 27, "results": [{"poc", "pass", "alert"}]}`。
- `verify-one.sh <pocId> [--patched] [--tree DIR] [--report DIR] [--keep]`：单条。默认跑基线
  （期望 CRASH / `pass: false`）；`--patched` 时把该案例的补丁单独应用到基线副本再跑
  （期望 CLEAN / `pass: true`）。写 `verify-one.json`。
- `verify-one-by-one.sh [--tree DIR] [--report DIR]`：对全部案例执行上面的 `--patched` 检查，
  写 `verify-one-by-one.json`：`{"pass": 27, "fail": 0, "results": [{"poc", "patch", "pass", "alert"}]}`，
  `fail` 必须为 0。
- 三份报告里 `pass` 的含义统一为"**PoC 没有让被测树崩**"，所以基线是 0、打补丁侧是全量。
- 判定用退出码 + sanitizer 报告行（`SUMMARY: ...Sanitizer` / `==N==ERROR: ...` /
  `runtime error:`），不看崩溃地址。`ERROR`（无报告但非 0 退出）算失败，不算通过。

## 8. 已知边界

- 只覆盖"基线仍然崩"且"自己的补丁能清掉它"的案例。两轮实测剔除 12 条：
  ① 3 条（`42532225`、`42533590`、`42533608`）在基线上不崩——缺陷晚于基线引入；
  ② 3 条（`42532896`、`42532983`、`42533242`）的修复无法在不牵进别人改动的前提下落到基线上；
  ③ 6 条（`42532226`、`42532406`、`42532845`、`42533013`、`42533592`、`42533693`）补丁
  应用后 PoC 仍崩——记录的 fix commit 不在该 PoC 触发的代码路径上（多案例改同一文件的
  窗口里 ARVO 归属偏差）。原始候选集是 39 条，最终 27 条。
- 补丁是"该案例的最小修复"，不是上游提交的完整还原：cherry-pick 模式下树差异可能包含
  少量上下文调整，应用时可能带行偏移。
- `code_snippet` 只取第一个 hunk：多 hunk 的补丁在这里只展示主改动，完整改动看补丁文件。
- 构建去掉了 SDL/pulse/alsa/X11 等模块（镜像里有头无库；OSS-Fuzz 自己的镜像也没有），
  与上游 fuzzer 构建一致。
