# gpac-vul — dataset specification

一个可复现的 gpac 漏洞集：源码基线固定在一个 commit，27 条 OSS-Fuzz 崩溃案例各自带一个
独立补丁与一个 PoC，容器内可一键验证"基线崩、打补丁不崩"。

本文件是这份数据的**契约**：下面的表格、字段、命令与判定规则都是被校验的；校验结果在
`reports/`（`verify.json`、`verify-one-by-one.json`）。

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
  src/gpac-readonly/        基线的纯拷贝（无 .git），与镜像内 /src/gpac 逐字节一致
  payload/
    cases.tsv               案例表（见 §4）
    pocs/<localId>/poc      每条案例的 PoC，原样来自 OSS-Fuzz testcase
    patches/<localId>.patch 每条案例的补丁（见 §5），27 个
    patch-index.json        补丁生成方式、影响文件、是否能干净应用
    vulnerabilities.json    位置、调用栈、CWE、修复提交（见 §6）
  scripts/
    lib.sh                  共享函数（指纹、构建、回放、判定）
    build.sh                无 sanitizer 的普通构建
    verify.sh               基线全量验证：每条 PoC 都必须 CRASH
    verify-one.sh           单条：基线 CRASH + 打补丁 CLEAN
    verify-one-by-one.sh    全量归属验证，写 reports/verify-one-by-one.json
    fuzz_probe_analyze.c    从 gpac/testsuite 8693a5a2 取的 OSS-Fuzz 目标
    fuzz_parse.c            同上
    standalone_main.c       单输入驱动（替代 libFuzzer 运行时）
  image/Dockerfile          可复现环境
  reports/                  验证输出
```

镜像内固定位置：`/src/gpac`（基线树）、`/payload`、`/opt/gpdt`（脚本）、`/out`（复现器）、
`/work`（构建目录）。脚本目录必须加入 `PATH`，不设命令分发层。

## 3. 环境变量

| 变量 | 默认 | 含义 |
| --- | --- | --- |
| `GPDT_TREE` | `/src/gpac` | 基线源码树（可指向任意副本） |
| `PAYLOAD` | `/payload` | 案例数据 |
| `OUT` | `/out` | 复现器输出 |
| `WORK` | `/work` | 构建目录 |

源码指纹 `src_fp()`：git 树取 `<commit8>-<sha256(git diff)[:8]>`；无 `.git` 的纯拷贝取
`tree-<sha256(所有文件内容)[:16]>`。指纹进入构建目录名与复现器名，所以基线与每个打补丁
的副本互不覆盖。

## 4. cases.tsv

制表符分隔，`#` 开头为注释，一案例一行，8 列：

```
localId  target  sanitizer  expect  poc  patch  fix_commit  subject
```

- `expect` 恒为 `CRASH`（基线态）；
- `sanitizer` ∈ `asan|ubsan`，决定用哪套 flags 编译、哪套 `*_OPTIONS` 运行；
- `patch` 指向 `payload/patches/` 下该案例自己的补丁。

## 5. 补丁

- 每条案例一个补丁，由它的 upstream 修复提交导出，**只含本案例的改动**。
- 导出方式：优先用 `git diff <fix>^ <fix>`；当上下文在基线与修复之间移动过、直接应用
  失败时，把该提交 cherry-pick 到基线上取树差异（`patch-index.json` 的 `mode` 记
  `commit-diff` / `cherry-picked`）。
- 27 个补丁全部能对基线干净应用（`patch-index.json` 的
  `applies_to_baseline`）。
- 因为案例之间是不同提交，补丁在文件层面大多互斥；少数几个提交改同一文件的不同 hunk
  （`src/media_tools/av_parsers.c` 6 个、`src/ietf/rtsp_session.c` 3 个、
  `src/ietf/sdp.c` 3 个、`src/utils/token.c` 2 个），彼此不覆盖；31 个补丁只动一个文件。

## 6. vulnerabilities.json

```json
{
  "id": 42531304,
  "target": "fuzz_probe_analyze",
  "sanitizer": "asan",
  "crash_type": "Heap-buffer-overflow READ {*}",
  "cwe": "CWE-125",
  "location": {
    "file": "src/...",
    "line": 123,
    "function": "gf_...",
    "stack": [{"function": "gf_...", "file": "src/..."}, ...]
  },
  "fix_commit": "538b229cab...",
  "fix_subject": "...",
  "patch": "patches/42531304.patch",
  "files_touched": ["src/..."],
  "report": "https://issues.oss-fuzz.com/issues/42531304"
}
```

- `location` 是上报栈里最内层的**业务**帧（函数 + 文件 + 行号）：行号来自报告，基线树
  可能与报告版本有偏移，行号仅作定位参考。
- `stack` 只记函数与文件，不记行号；由内向外排列，去掉 fuzz 驱动帧（`LLVMFuzzerTestOneInput`、
  `main`、`fuzz_*.c`），最多 10 帧。
- `cwe` 由崩溃类型映射；未覆盖的类型给 `null` 而不是猜。
- 无法定位的案例（上报里没有带符号的帧）不进入数据集，而不是留空行。

## 7. 验证规则

- `build.sh`：无 sanitizer 的 configure/make，产出 `libgpac_static.a`。
- `verify.sh [--tree DIR] [--case ID]... [--report DIR]`：为每个 (target, sanitizer)
  组合构建复现器，逐条跑 PoC，**每条都必须 CRASH**；任一不崩即退出非 0，写 `verify.json`。
- `verify-one.sh --case ID`：同一案例跑两侧——基线必须 CRASH，打了该案例补丁的副本必须
  CLEAN；写 `reports/one-<ID>.json`。
- `verify-one-by-one.sh`：对全部案例执行上面的双端点检查，写
  `verify-one-by-one.json`，`fail` 必须为 0。
- 判定用退出码 + sanitizer 报告行（`SUMMARY: ...Sanitizer` / `==N==ERROR: ...` /
  `runtime error:`），不看崩溃地址。`ERROR`（无报告但非 0 退出）算失败，不算通过。

## 8. 已知边界

- 只覆盖"基线仍然崩"且"自己的补丁能清掉它"的案例。两轮实测剔除 12 条：
  ① 3 条（`42532225`、`42533590`、`42533608`）在基线上不崩——缺陷晚于基线引入；
  ② 3 条（`42532896`、`42532983`、`42533242`）的修复无法在不牵进别人改动的前提下落到基线上；
  ③ 6 条（`42532226`、`42532406`、`42532845`、`42533013`、`42533592`、`42533693`）补丁
  应用后 PoC 仍崩——记录的 fix commit 不在该 PoC 触发的代码路径上（多案例改同一文件的
  窗口里 ARVO 归属偏差）。清单与原因在 `payload/vulnerabilities.json` 的 `verification`。
- 补丁是"该案例的最小修复"，不是上游提交的完整还原：cherry-pick 模式下树差异可能包含
  少量上下文调整，`patch-index.json` 有标注。
- 案例集合经过两轮实测收缩：39 条候选 → 33 条（3 条基线不崩、3 条补丁落不到基线）
  → 27 条（6 条双端验证不成立）。两轮的清单与原因都在 `payload/vulnerabilities.json`
  的 `verification` 字段里。
- 构建去掉了 SDL 模块（镜像里的 SDL 头是 1.2，gpac 需要 2；OSS-Fuzz 自己的镜像也没有
  SDL），与上游 fuzzer 构建一致。
