# gpac-vul

gpac 的 ARVO 漏洞集：一个基线 commit、27 条崩溃案例，每条案例带一个**独立**补丁和一个
PoC，容器内可验证"基线崩、打补丁不崩"。规约见 [`SPECIFICATION.md`](SPECIFICATION.md)，
字段与报告格式和 `imagemagick-vul`、`ffmpeg-vul` 一致。

```bash
docker build -f image/Dockerfile -t gpac-vul:b890f1c .   # 约 40 分钟，17.6 GB
docker run --rm gpac-vul:b890f1c verify.sh                          # 27 条都应 CRASH
docker run --rm gpac-vul:b890f1c verify-one.sh 42531304             # 基线：pass=false
docker run --rm gpac-vul:b890f1c verify-one.sh 42531304 --patched   # 打补丁：pass=true
docker run --rm gpac-vul:b890f1c verify-one-by-one.sh               # 27 条归属全跑
```

## 为什么是 gpac、这个节点

| 指标 | 值 |
| --- | --- |
| 基线 | `b890f1c443`（2024-01-17，修复窗口前一个提交） |
| 案例 | 27 |
| 修复提交 | 27 个不同提交（1 案例 : 1 提交） |
| 修复窗口 | 2024-01-17 … 2024-03-12（约 2 个月） |
| fuzz 目标 | `fuzz_probe_analyze`、`fuzz_parse` |
| sanitizer | ASan 20 / UBSan 7 |
| 崩溃类型 | 13 种 |

选它的理由：同一窗口内的修复各自独立（不同提交、绝大多数只动一个文件），所以每条案例
的补丁不需要牵扯别人的改动；同期案例足够多，可以撑起一个有体量的集合。对比 openh264
（22 条案例共用 1 个提交，拆不出独立补丁），这是"补丁独立性"更好的样本。

实测收缩过程：39 条候选 → 33 条（3 条基线不崩、3 条补丁落不到基线）→ **27 条**
（6 条双端验证不成立：补丁应用后 PoC 仍崩，说明记录的 fix commit 不在该 PoC 的代码路径上）。

## 目录

```
src/gpac-readonly/              基线纯拷贝（无 .git）
payload/cases.tsv               案例表（localId/fuzzer/sanitizer/alert/expect_frame/poc/patch/fix_commit）
payload/pocs/<localId>/poc      PoC（来自 OSS-Fuzz testcase，原样）
payload/patches/<fix_commit>.patch  每条案例一个补丁，以修复提交命名
payload/patch-index.json        以修复提交为键：影响文件、主题、日期
payload/vulnerabilities.json    位置 / 调用栈 / 代码片段 / 描述 / 补丁
scripts/                        lib.sh、build.sh、verify*.sh、fuzzer 源码
image/Dockerfile                可复现环境
reports/verify.json             基线全量（27 条全 CRASH）
reports/verify-one.json         最近一次单条验证
reports/verify-one-by-one.json  全量归属（27 条全 PASS）
```

## 数据来源

- 案例元数据：ARVO `raw/all-records.json`（`crash_output` 用于提取位置与调用栈）；
- PoC：ARVO `source/ARVO/arvo/NewTracker/metadata.jsonl` 里每条案例的 `reproducer`
  直链（`https://oss-fuzz.com/download?testcase_id=...`），免登录，KB 级；
- 补丁：各案例 `fix_commit` 的 upstream 提交，导出成只含本案例改动的补丁；
- fuzzer 源码：`gpac/testsuite@8693a5a2f248814909915b301e0e742956d27150`
  （2023-12-20，窗口前后仍在用的版本）的 `oss-fuzzers/fuzz_probe_analyze.c` 与
  `fuzz_parse.c`，原样放在 `scripts/`。

## 构建注意

- 基础镜像 `n132/arvo@sha256:95cd4fad…`（OSS-Fuzz builder，clang 5.0.0 + zlib 头文件）。
- 镜像里有 SDL 1.2 / pulse / alsa / freetype / GL 的**头文件**，但多数没有对应库，
  而 gpac 的 `--disable-<pkg>` 对这几个是"特性"不是"包"，configure 会重新探测覆盖。
  所以 configure 之后把 `config.mak` 里对应 `CONFIG_*=yes` 翻成 `no`（`lib.sh`），
  链接时用各模块自己的 `*_ldflags` 补齐（freetype/png），GL 单独补 `-lGL -lGLU`。
- 快照统一为 LF：Windows 上 `git archive` 会把 LF 展开成 CRLF，容器里所有补丁都会
  报 "patch does not apply"。同理 `verify*.sh` 用 GNU `patch` 而不是 `git apply`——
  Windows 绑定挂载还会丢执行位，`git apply` 会因此拒绝每一个补丁。
- `MAKE_JOBS` 默认 4：并行度过高时容器内存吃紧，make 会失败。
- `verify-one.sh` 默认走增量构建：从基线构建目录 `cp -a` 一份、把补丁打进副本、
  `make` 只重编受影响的目标（一条案例约 1 分钟）。`GPDT_COLD=1` 可强制全量重建
  做交叉验证。全量 `verify-one-by-one.sh` 27 条实测 23 分钟。
- 有 3 个补丁应用到基线时带行偏移（`offset -7 … -10 lines`，`Hunk succeeded`），
  是 cherry-pick 导出带来的上下文移动，不影响被修改的行。
