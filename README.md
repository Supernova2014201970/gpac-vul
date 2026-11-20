# gpac-vul

gpac 的 ARVO 漏洞集：一个基线 commit、27 条崩溃案例，每条案例带一个独立补丁和一个 PoC。
规约见 [`SPECIFICATION.md`](SPECIFICATION.md)，字段、目录与报告格式和同批次的
`imagemagick-vul`、`ffmpeg-vul` 一致。

## 1. 目录结构

```
gpac-vul/
├── README.md
├── MANIFEST.md                  文件清单、大小与 sha256 + 源码快照指纹
├── SPECIFICATION.md             本仓必须满足的契约
├── image/Dockerfile             可重建的运行环境
├── src/gpac-readonly/           基线 b890f1c443 的纯拷贝（无 .git，1289 文件）
├── payload/
│   ├── cases.tsv                案例索引（8 列，见 §6）
│   ├── vulnerabilities.json     位置、调用栈、代码片段、描述
│   ├── patch-index.json         以修复提交为键：影响文件、主题、日期
│   ├── patches/<fix_commit>.patch
│   └── pocs/<localId>/poc
├── scripts/
│   ├── lib.sh                   路径、sanitizer 配置、源码指纹、构建与回放
│   ├── build.sh                 普通构建（无 sanitizer，不跑 PoC）
│   ├── verify.sh                基线全量：27 条都必须 CRASH
│   ├── verify-one.sh            单条，可选 --patched
│   ├── verify-one-by-one.sh     全量归属：每条案例只打自己的补丁
│   ├── fuzz_probe_analyze.c     OSS-Fuzz 目标（取自 gpac/testsuite@8693a5a2）
│   ├── fuzz_parse.c             同上
│   └── standalone_main.c        单输入驱动，替代 libFuzzer 运行时
└── reports/
    ├── verify.json
    ├── verify-one.json
    └── verify-one-by-one.json
```

## 2. 构建与运行

需要启动支持 Linux 容器的 Docker，并能拉取指定基础镜像。以下命令在 `gpac-vul/`
目录执行（PowerShell 和 Bash 均可逐行运行）：

```bash
docker pull n132/arvo:42474806-vul@sha256:95cd4fadae89976811235d6b70b4d750c42a380845f7df27dc644333fef05052
docker build -f image/Dockerfile -t gpac-vul:b890f1c .
docker run -dit --name gpacvul gpac-vul:b890f1c
docker exec gpacvul build.sh
docker exec gpacvul verify.sh --report /tmp/report
docker exec gpacvul verify-one.sh 42531304 --report /tmp/report
docker exec gpacvul verify-one.sh 42531304 --patched --report /tmp/report
docker exec gpacvul verify-one-by-one.sh --report /tmp/report
```

`/opt/gpdt` 在镜像的 `PATH` 里，所以直接按脚本名调用；也可以写全路径
`/opt/gpdt/verify-one.sh`。`/opt/gpdt/reports/` 是镜像内自带的随包报告目录，容器的
默认工作目录是 `/opt/gpdt`，所以不加 `--report` 时报会直接覆盖它；要保留随包报告就显式
指定目录（如上例的 `/tmp/report`），或挂载一个目录，例如 `-v ${PWD}/reports:/reports`
后写 `/reports`。

`build.sh` 是**普通编译**，不是验证：它只跑 gpac 自己的 `configure` + `make`，产出
`libgpac_static.a`，不插桩、不生成复现器、不跑 PoC。验证由 `verify.sh` /
`verify-one.sh` / `verify-one-by-one.sh` 负责。

三个验证脚本都接受 `--tree DIR`，用于测试 `/src/gpac` 之外的另一份源码（默认取自
`$GPDT_TREE`，再默认 `/src/gpac`）；原始目录只读，`--patched` 只复制后再应用补丁。

导出测试报告：

```bash
docker cp gpacvul:/tmp/report/verify.json ./reports/verify.json
docker cp gpacvul:/tmp/report/verify-one-by-one.json ./reports/verify-one-by-one.json
```

可选的离线镜像导出和加载：

```bash
docker save -o gpac-vul.tar gpac-vul:b890f1c
docker load -i gpac-vul.tar
```

构建成功后镜像保存在本机 Docker 中，不要求额外保留 tar。只有基础镜像已缓存时，才可以
不依赖远端拉取来重建。

## 3. Dockerfile 做什么

- 基础镜像 `n132/arvo@sha256:95cd4fad…`：OSS-Fuzz builder，clang 5.0.0 + zlib 头文件。
- 把随包 `src/gpac-readonly` 装到 `/src/gpac`，脚本装到 `/opt/gpdt`，payload 装到
  `/payload`，并清空 `$BASE/out`、`$BASE/work` 与基础镜像自带的 fuzzing 工具。
- 构建期自检：基线快照指纹 `tree-3fb52327008566a2`、27 个 PoC、27 个补丁、`cases.tsv`
  27 行、每个补丁的 hunk 上下文都在树里。
- 构建期跑一次 `verify.sh --report /reports`：27 条必须全 CRASH，否则镜像构建失败。
  这一次运行同时把两个插桩后的基线复现器预热进 `/out`，并把 `/work` 清空。

镜像最终 17.6 GB：其中包含两次完整 gpac 插桩构建的中间层。

## 4. scripts/ 的分工

| 文件 | 职责与产物 |
| --- | --- |
| `build.sh` | 普通编译指定目录，生成 `libgpac_static.a`，不加 sanitizer，不运行 PoC |
| `lib.sh` | 共用路径、sanitizer 配置、源码指纹、构建（`ensure_libs` / 增量 `ensure_libs_incr`）、插桩链接（`ensure_repro`）、单次执行（`run_poc`） |
| `verify-one.sh` | 查找一个案例，选择原始源码或补丁副本，编译/复用复现器，运行 PoC，写单案例报告 |
| `verify.sh` | 遍历案例，调用不带 `--patched` 的 `verify-one.sh`，汇总基线报告 |
| `verify-one-by-one.sh` | 遍历案例，每次调用 `verify-one.sh --patched`，汇总各自补丁的验证报告 |
| `fuzz_probe_analyze.c`、`fuzz_parse.c` | OSS-Fuzz 的 fuzzer 入口，原样取自固定提交 |
| `standalone_main.c` | 单输入驱动：把文件喂给 `LLVMFuzzerTestOneInput` 一次 |

```text
build.sh → configure + make（普通编译）
verify.sh → verify-one.sh --tree DIR
verify-one-by-one.sh → verify-one.sh --patched --tree DIR
verify-one.sh → lib.sh / ensure_repro → libgpac_static.a + fuzzer 入口 + standalone_main.c
              → lib.sh / run_poc → 执行、判定
```

### 4.1 普通编译

```bash
build.sh [--tree DIR]
```

默认 `DIR=/src/gpac`（或 `$GPDT_TREE`），输出目录固定为 `$WORK/plain-<源码指纹>`，重跑
从头编译。脚本先把源码树复制到输出目录（基线不被修改），再用与验证脚本**同一份**
headless 配置构建：
`--static-build --disable-x11 --disable-sdl --disable-pulseaudio --disable-alsa
--disable-oss --disable-jack --disable-directfb --disable-libcaca`，随后把 `config.mak` 里
`CONFIG_SDL/X11/PULSEAUDIO/ALSA/JACK/OSS/DIRECTFB/LIBCACA/...` 翻成 `no`（镜像里有这些
头文件但没有对应库），然后 `make -j${MAKE_JOBS:-4}`，检查 `bin/gcc/libgpac_static.a`。
实测 132 秒产出 19.1 MB 静态库。

这一步只是"能编译"，不产生复现器、不跑 PoC。PoC 验证使用另外复制出来的插桩构建，
不使用这个普通构建的产物。

## 5. 结果、报告和退出码

三份报告由脚本直接生成，顶层固定为 `pass`、`fail`、`results`：

| 文件 | 生成者 | 随包数值 |
| --- | --- | --- |
| `reports/verify.json` | `verify.sh` | `pass=0`、`fail=27`、27 条结果 |
| `reports/verify-one.json` | `verify-one.sh` | `pass=0`、`fail=1`、1 条结果（42531304 基线） |
| `reports/verify-one-by-one.json` | `verify-one-by-one.sh` | `pass=27`、`fail=0`、27 条结果 |

判定只有一个维度：`pass=true` 表示该 PoC 没有打崩被测源码树。因此基线的 `pass` 恒为 0，
`--patched` 侧应当全为 true。退出码：`verify.sh` 在全 CRASH 时返回 0；`verify-one.sh <id>`
在该案例 CRASH 时返回 0、CLEAN 时非 0；`verify-one.sh <id> --patched` 相反；`verify-one-by-one.sh`
在 `fail=0` 时返回 0。

## 6. 数据与已有报告

`cases.tsv` 的列为 `localId fuzzer sanitizer alert expect_frame poc patch fix_commit`。
27 个案例对应 27 个 PoC、27 个补丁，每个补丁只对应 1 条案例。补丁按 fix commit 命名；
其中至少 2 个补丁（`42531500`、`42532224`）应用到基线时带行偏移（`offset -7 … -10 lines`，
`Hunk succeeded`），是 cherry-pick 导出带来的上下文移动，不影响被修改的行。

`vulnerabilities.json` 包含 `project`、`repo`、`baseline`、`paths`、`vulnerabilities`；
每个漏洞给出 `id`、`type`、`location`、`code_snippet`、`description` 和 `patch` 路径。

- `location` 是崩溃报告位置（sanitizer 栈顶的业务帧），行号来自报告，基线可能与报告版本
  有偏移。
- `location.stack` 由内向外、最多 10 帧，每帧只有函数与文件（不记行号），已去掉
  `LLVMFuzzerTestOneInput` 与 `tools/target_dec_*` 一类 fuzz 驱动帧。
- `code_snippet` 只含 `before`、`after`、`fix_summary`，片段出自补丁第一个 hunk，位置
  可以与 `location` 不同；这种情况写在 `description` 里。

当前随包报告是 2026-11-20 用本目录脚本在 `gpac-vul:b890f1c` 镜像内重跑的结果
（`--tree /src/gpac`）：基线 27/27 CRASH（17 秒，构建期与镜像内各一次），归属验证
27/27 PASS（1408 秒，增量构建）。报告本身不记录运行日期、耗时和实际 sanitizer 摘要。

## 7. 漏洞分布

统计依据为 `payload/vulnerabilities.json` 与 `payload/cases.tsv`；统计单位是案例 ID，
共 27 个案例、27 个 PoC、27 个唯一补丁。案例数不等于独立漏洞根因数，但本包恰好是
1 案例 : 1 补丁 : 1 提交。

### 7.1 按 CWE 类型

每个案例按元数据中的主 CWE 计一次；占比以 27 个案例为分母，四舍五入至一位小数。

| CWE | 类型 | 案例数 | 占比 |
| --- | --- | --- | --- |
| CWE-125 | Out-of-bounds Read | 11 | 40.7% |
| CWE-129 | Improper Validation of Array Index | 6 | 22.2% |
| CWE-121 | Stack-based Buffer Overflow | 6 | 22.2% |
| CWE-787 | Out-of-bounds Write | 2 | 7.4% |
| CWE-119 | Improper Restriction of Operations within the Bounds of a Memory Buffer | 1 | 3.7% |
| CWE-416 | Use After Free | 1 | 3.7% |
| 合计 | — | 27 | 100.0% |

### 7.2 按检测方式

按 ARVO 记录的上报 sanitizer 分组，每个案例计一次。

| sanitizer | 案例数 | 占比 |
| --- | --- | --- |
| `address`（ASan） | 21 | 77.8% |
| `undefined`（UBSan） | 6 | 22.2% |
| 合计 | 27 | 100.0% |

### 7.3 按源码模块

按 `location.file` 的首两级目录统计，每个案例计一次。这是元数据记录**崩溃报告位置**的
分布，不代表补丁修改文件或根因位置的分布。

| 模块 | 案例数 | 占比 |
| --- | --- | --- |
| `src/media_tools` | 7 | 25.9% |
| `src/utils` | 7 | 25.9% |
| `src/filters` | 6 | 22.2% |
| `src/ietf` | 4 | 14.8% |
| `src/filter_core` | 3 | 11.1% |
| 合计 | 27 | 99.9% |

### 7.4 按功能入口

按 `location.stack` 最外层业务帧所在目录统计，每个案例计一次；它近似表示 PoC 进入
gpac 的入口模块（解析/解复用 → 过滤链 → 核心）。PoC 是二进制文件，元数据里没有输入
格式标注，因此本包不按容器格式分组。

| 入口 | 案例数 | 占比 |
| --- | --- | --- |
| `src/filter_core`（`gf_fs_run` → 过滤器调度） | 15 | 55.6% |
| `src/filters`（各 demux/reframe 过滤器） | 6 | 22.2% |
| `src/utils` | 2 | 7.4% |
| `src/media_tools` | 2 | 7.4% |
| `src/ietf` | 1 | 3.7% |
| `src/isomedia` | 1 | 3.7% |
| 合计 | 27 | 100.0% |

### 7.5 案例与补丁对应分布

| 每个补丁对应的案例数 | 补丁数 | 覆盖案例数 |
| --- | --- | --- |
| 1 | 27 | 27 |
| 合计 | 27 | 27 |

没有共享补丁：27 条案例来自 27 个不同的 upstream 修复提交。所以本包不存在"一个补丁
清掉多条案例"的情况，7.1–7.4 的每个案例都对应一次独立的源码修改。
