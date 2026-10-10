# BenchPilot

**面向嵌入式编码 agent 的硬件运行时——用一个有状态接口给真实 ECU 上电、烧录、观察、诊断和验证。**
人类、CI 任务和 AI 编码 agent 共享同一个带安全边界的常驻运行时；agent 通过版本化的本地 API、CLI 和 MCP 原生地说 JSON。

[![CI](https://github.com/turinglambdaai/benchpilot/actions/workflows/ci.yml/badge.svg)](https://github.com/turinglambdaai/benchpilot/actions/workflows/ci.yml) [![release](https://img.shields.io/github/v/release/turinglambdaai/benchpilot)](https://github.com/turinglambdaai/benchpilot/releases/latest) ![platform](https://img.shields.io/badge/platform-Windows_%7C_Linux_%7C_macOS-lightgrey) [![built with](https://img.shields.io/badge/built%20with-Racket-9F1D35)](https://racket-lang.org/) [![License](https://img.shields.io/badge/license-AGPL--3.0-blue)](LICENSE)

[English](README.md) · **中文**

BenchPilot 给人类、CI 任务和 AI 编码 agent 一个面向真实嵌入式目标的有状态接口：上电、烧录、观察、诊断、验证行为。

产品闭环刻意收窄：

```text
Build -> Flash -> Run -> Observe -> Diagnose -> Fix
```

BenchPilot **不是** CANoe 克隆。它不追求复刻整车网络仿真、CAPL、ADAS 仿真或几百个分析窗口。CAN/CAN FD、DBC、ISO-TP、UDS 和 DoIP 只在有助于补完 ECU 开发闭环时才加入。

> 当前状态：**v0.1.0 —— 版本纪元重置后的首个发布：Racket 运行时达到完全契约对等，BenchPilot Studio 同车，进入 0.x 功能验证阶段。** ISO-TP/CAN 与 DoIP 上的 UDS 诊断与烧录、无需硬件端到端运行的内置模拟 ECU、SocketCAN/PCAN 适配器、system-serial/J-Link/SCPI 电源驱动，全部收在一个就绪门后面。持久化证据/产物存储、设备错误分类法、HEX/S-record 镜像模型、UDS DTC、安全 provider、CAN 抓包 + DBC 信号解码、带审计的团队租约、烧录加固（指纹门、编程中电源保护、恢复策略）均已就位。**BenchPilot Studio**——Rivet 线第一个原生桌面 app——已交付 macOS（Apple Silicon 与 Intel）与 Windows（便携 zip），Linux 宿主为开发预览。下一道门是对真实 ECU + J-Link + 串口 + 台架电源做物理验证，而不是增加更多协议。

## 为什么做 BenchPilot？

编码 agent 能改固件、能编译固件，但一台真实 ECU 周围围着一堆碎片化工具：

```text
J-Link / OpenOCD
+ serial terminal
+ CAN adapter
+ SCPI power supply
+ UDS tool
+ scripts
```

这些工具暴露的是以设备为中心的原语和彼此独立的状态。BenchPilot 在上面加一层以 ECU 为中心的抽象：

```text
Target: radar
  power  -> psu.main
  flash  -> probe.radar
  serial -> uart.radar
  can    -> can.vehicle
```

调用方只说 `radar` 这个目标和一个语义操作。运行时解析出真实硬件资源，并在驱动调用前强制校验与安全检查。

这就是 agent 友好操作的地基，例如：

```text
flash(radar)
wait_boot(radar)
wait_signal(radar, "RadarStatus", RUNNING)
assert_current(radar, < 100 mA)
capture_failure_window(radar)
```

而不是逼语言模型去吞无限的原始串口/CAN 流。

## 运行时模型

BenchPilot 对活跃硬件状态只有一个所有者：

```text
                  Human / CI / Agent
                         |
              +----------+----------+
              |          |          |
             CLI        MCP       Studio
              |          |          |
              +----------+----------+
                         |
                  Benchpilot.Client
                         |
                  local /api/v1
                         |
                    benchpilotd
                  state + safety
                         |
        +----------------+----------------+
        |                |                |
      Power            Probe           Networks
        |                |                |
      SCPI             J-Link       SocketCAN / PCAN
                         |
                        ECU
```

`benchpilotd` 是常驻进程。CLI、MCP 和未来的 GUI 客户端**不得各自独立打开硬件**。这保证了共享的设备状态、唯一的安全边界，以及资源锁、观察和证据的唯一存放处。

基础传输是只绑定环回的 HTTP JSON。在存在带认证的远程台架传输之前，`benchpilotd` 拒绝绑定非环回地址。

## 当前模拟器

模拟器的行为像一张小 physical bench：

- 虚拟台架电源，带 inrush -> settle -> idle 电流曲线；
- 虚拟固件启动日志，按时间逐行可见；
- 烧录/复位行为；
- 电源、串口、烧录共享同一份状态；
- 上下文压缩的串口等待观察；
- 运行时安全校验；
- CLI 和 MCP 客户端跑在同一个常驻状态上。

模拟器路径不需要任何物理硬件。

### 环境要求

- 运行发布版无需任何东西；从源码构建需要 Racket 9.3+（CS）
- Git
- Agent 使用时需要一个支持 MCP 的客户端（可选）
- 物理台架：所选 profile 引用的厂商/OS 工具，例如 SEGGER J-Link Commander

### 构建与测试

```bash
git clone https://github.com/turinglambdaai/benchpilot.git
cd benchpilot
raco pkg install --auto --name benchpilot --link racket
raco test racket/benchpilot
```

## 快速开始

### 0. 安装

每个平台一行命令（下载最新发布、校验 SHA256、把三个可执行文件装到 `~/.benchpilot/bin`）：

```bash
# macOS / Linux
curl -fsSL https://raw.githubusercontent.com/turinglambdaai/benchpilot/main/scripts/install.sh | bash
```

```powershell
# Windows PowerShell
irm https://raw.githubusercontent.com/turinglambdaai/benchpilot/main/scripts/install.ps1 | iex
```

每个发布包含的内容（全部由发布自带的 `SHA256SUMS` 校验清单覆盖）：

| 平台 | CLI（便携） | CLI（安装器） | Studio（桌面 app） |
| --- | --- | --- | --- |
| macOS Apple Silicon | `benchpilot-<version>-osx-arm64.tar.gz` | — | `benchpilot-studio-<version>-macos-arm64.dmg` + 便携 `.zip` |
| macOS Intel | `benchpilot-<version>-osx-x64.tar.gz` | — | `benchpilot-studio-<version>-macos-x64.dmg` + 便携 `.zip` |
| Windows x64 | `benchpilot-<version>-win-x64.zip` | — | `benchpilot-studio-<version>-windows-x64.zip`（便携） |
| Linux x64 | `benchpilot-<version>-linux-x64.tar.gz` | `benchpilot-<version>-linux-x64.deb` | 计划中（宿主为开发预览） |
| Linux arm64 | `benchpilot-<version>-linux-arm64.tar.gz` | — | 计划中 |

包管理器路线：每个发布还带生成的 Homebrew formula（`benchpilot.rb`）和 scoop manifest（`benchpilot.scoop.json`）——复制进你的 tap/bucket，或者从
[最新发布](https://github.com/turinglambdaai/benchpilot/releases/latest)
手动安装（`benchpilot-<version>-<platform>.zip/.tar.gz`）并把三个可执行文件放进 `PATH`：

| 可执行文件 | 角色 |
| --- | --- |
| `benchpilotd` | 持有硬件状态的常驻运行时 |
| `benchpilot` | 面向人类、CI 和 agent 的 CLI |
| `benchpilot-mcp` | 面向 agent 客户端的 stdio MCP 适配器 |

桌面 app：从[最新发布](https://github.com/turinglambdaai/benchpilot/releases/latest)下载
`benchpilot-studio-<version>-macos-<arch>.dmg`（macOS 14+，Apple Silicon 或 Intel），把 **BenchPilot Studio**
拖进 Applications 启动。Windows 上解包 `benchpilot-studio-<version>-windows-x64.zip` 运行
`RivetHost.exe`。Studio 是同一个常驻运行时的客户端——先让 `benchpilotd`
跑起来（任意 CLI/MCP 命令会自动拉起），app 即自动连接；运行时不在时显示可达性
诊断态而不是空白。Windows 宿主覆盖台架基本操作（状态、电源、DTC 读取、历史）；
Linux 宿主为开发预览，暂不打包。

也可以从源码：

```bash
git clone https://github.com/turinglambdaai/benchpilot.git
cd benchpilot
raco pkg install --auto --name benchpilot --link racket
racket packaging/launchers/benchpilot.rkt status --json
```

### 0.5. 保持更新

```bash
benchpilot update --check   # 与最新发布比较
benchpilot update           # 下载、校验 SHA256、优雅停掉守护进程、
                            # 原地替换，autostart 会把它拉起来
```

硬件操作进行期间更新器拒绝运行，并在被替换的可执行文件旁边留下 `.old` 备份。如果 agent 宿主了 `benchpilot-mcp`，更新后请重启那个 MCP server。

范围如实说明：CLI 自更新器覆盖三个可执行文件——feed 是本仓库的 GitHub
releases，完整性校验用发布自带的 `SHA256SUMS` 清单。Studio（桌面 app）在
macOS 上支持应用内更新：app 菜单「Check for Updates…」，静默检查至多每 4
小时一次；feed 是发布自带的 Ed25519 签名 `update-manifest.json`（覆盖便携
zip），app 内先验签再原子换装（仅 /Applications 下的副本可自更新）。Windows
宿主暂无应用内更新器：从[最新发布](https://github.com/turinglambdaai/benchpilot/releases/latest)重新下载即可。

### 1. 直接跑命令

日常和 agent 使用没有单独的「启动运行时」步骤：第一条 `benchpilot` 命令会自动启动 `benchpilotd`（分离运行，日志在 `~/.benchpilot/logs/`），之后每条命令都复用这个常驻进程及其状态。

```bash
benchpilot status --json
```

如果你想自己运行 `benchpilotd`，例如用指定 profile：

```bash
BENCHPILOT_PROFILE=profiles/real-ecu.example.json benchpilotd
```

`benchpilot doctor --json` 检查安装（运行时可达性、版本、token、守护进程发现），不做任何改动。

### 2. 驱动台架

第一条有用的模拟 ECU 闭环：

```bash
benchpilot power on --voltage 12 --json
benchpilot flash write build/app.elf --json
benchpilot serial wait Ready --timeout-ms 5000 --json
benchpilot power check --lt-ma 100 --json
benchpilot power off --json
```

从源码安装时，把命令前缀换成 `racket packaging/launchers/benchpilot.rkt`。

长时间变更和串口观察还可以携带运行时执行预算：

```bash
racket packaging/launchers/benchpilot.rkt -- \
  flash write build/app.elf --deadline-ms 30000 --json

racket packaging/launchers/benchpilot.rkt -- \
  serial wait Ready --timeout-ms 5000 --deadline-ms 7000 --json
```

`--deadline-ms` 刻意区别于设备/协议超时和 `serial wait --timeout-ms`。串口超时是语义等待窗口：正常到达它会产生一个未匹配断言。运行时 deadline 是 CLI/MCP/Agent 工作流共享的外层执行预算：到期时运行时把 `deadline_exceeded` 记入历史和证据，并且即使驱动无视取消、迟到的成功也会被拒绝。

### 3. 在碰 ECU 之前先验证物理台架

从仓库内的示例 profile 出发，把每个 `CHANGE_ME` 换成你的真实台架信息：

```text
profiles/real-ecu.example.json
```

然后在**任何**上电/复位/烧录之前跑就绪报告：

```bash
BENCHPILOT_PROFILE=profiles/real-ecu.example.json benchpilotd

# 另开一个终端（或者直接用 benchpilot，autostart 指向同一端点）：
benchpilot bench validate --target ecu --json
```

`bench validate` 刻意无破坏。它检查：

- 必需的 `power`、`serial`、`flash` 绑定；
- 这些能力由真实硬件驱动而非模拟器支撑；
- `maxVoltage` / `maxCurrentMa` 安全上限；
- 显式目标与破坏性操作的确认策略；
- 未解析的 `CHANGE_ME` 占位符；
- 无破坏的串口/J-Link/SCPI 预检结果。

每个失败检查都带稳定的机器可读代码和可执行的 `remediation` 字段。因此报告可以直接被人类、CI 任务或 Agent 消费，不用猜下一步改什么。

只有报告包含以下内容时，物理目标才算为第一条真实 ECU 闭环就绪：

```json
{
  "ok": true,
  "readyForRealEcuLoop": true,
  "mode": "hardware"
}
```

然后才进入破坏性路径：

```text
preflight
  -> power on
  -> serial open
  -> flash / reset
  -> wait for Ready
  -> current check
  -> normal power off
```

### 4. 运行 MCP 适配器

```bash
benchpilot-mcp
```

MCP 进程只是一个 stdio 协议适配器。它也会按需启动常驻运行时，所以 Agent 和终端看到的是同一份 ECU/台架状态。MCP 的 `BenchValidate` 工具暴露与 CLI 相同的无破坏就绪报告。长时间电源/烧录/串口工具同样暴露可选的 `deadlineMs`，由运行时而非 MCP 进程强制并审计。

### 5. 接上 agent skill

`integrations/agent/SKILL.md` 是给编码 agent 的现成 skill 包（安全操作台架、重试前先读证据、尊重安全门）。把 agent 指向该文件，或复制进你的 skills 目录。`benchpilot doctor` 和 `benchpilot status --json` 刻意就是 agent 友好的入口。

Agent 任务示例：

> 验证 `ecu` 目标是否达到真实台架就绪。不要上电、复位或烧录任何东西。如果未就绪，准确告诉我哪些检查失败、怎么修。

目标就绪后，Agent 可以执行一条受约束的台架闭环，例如：

> 以 12 V 给 ECU 上电，烧录选定的固件，等待控制台打印 `Ready`，确认空闲电流低于配置阈值，然后断电。

### 6. 附上台架报告

一个静态、自包含的 HTML 产物，覆盖台架状态、就绪结论、操作/观察历史和最新证据——贴进台架会话日志或 ECU 发布说明：

```bash
benchpilot report --out bench-report.html
```

## CLI 退出码

CLI 退出码刻意稳定且机器友好：

```text
0 success / readiness passed
1 operation, assertion or readiness failure; cancellation
2 validation error
3 target/resource/operation/observation/evidence not found
4 runtime unreachable, unauthorized, or device/preflight error
5 target/resource busy because another mutating operation is active
6 Runtime execution deadline exceeded
```

`bench validate` 退出码为 `1` **不是**就绪 API 失败。它表示报告本身执行成功，但一个或多个阻塞性就绪检查未通过；请查看 JSON 的 checks 和 remediation 字段。

deadline 失败以 `code=deadline_exceeded` 返回，带 `deadlineMs` 和 `deadlineAtUtc`；活跃与历史记录同样暴露 deadline 元数据。紧急断电在接受之后刻意不受运行时 deadline 约束——安全关停不能因为 shell 预算到期就被放弃。

## UDS 诊断与烧录（CAN 与 DoIP）

BenchPilot 内置完整的 UDS（ISO 14229）诊断栈：SocketCAN/PCAN 上的 ISO-TP（ISO 15765-2），以太网上的 DoIP（ISO 13400-2）。同一个烧录引擎驱动两种传输。

```bash
# 在网络上发现 DoIP 实体（一个 100BASE-T1 介质转换器加一根
# 接笔记本的 RJ45 网线就够触达真实 ECU）：
benchpilot doip discover --json

# 进入编程会话并读一个版本 DID：
benchpilot uds session programming --target ecu --json
benchpilot uds read-did 0xF195 --target ecu --json

# 原始 UDS 逃生口（专家）：
benchpilot uds request "10 03" --target ecu --json

# 通过绑定的诊断通道做破坏性 UDS 烧录：
benchpilot uds flash build/app.bin --address 0x08020000   --confirm-target ecu --target ecu --deadline-ms 300000 --json
```

多段镜像使用声明式烧录计划：

```json
{
  "segments": [
    { "address": 134217728, "file": "bootloader.bin" },
    { "address": 134480896, "file": "application.bin" }
  ],
  "session": 2,
  "securityLevel": 1,
  "keyDeriver": "xor0x5a",
  "maxBlockPayload": 1024
}
```

```bash
benchpilot uds flash build/app.bin --plan flash.plan.json --confirm-target ecu --json
```

烧录的每一步（session、security access、erase、逐段 download、verify、reset）都审计在操作证据里，所以一次失败的编程会话能自我解释：先 `benchpilot history`，再 `benchpilot evidence <id>`。

没有硬件时，内置模拟器在真实协议栈后面带了一台虚拟 UDS ECU：对默认 `demo` 目标执行 `benchpilot uds read-did 0xF195` 会经模拟 CAN 总线上的 ISO-TP 应答，同一套烧录工作流也可以在碰真实台架之前完整演练。

## 本地安全模型

`benchpilotd` 只绑定环回，拒绝非环回端点。在共享机器上只有环回并不构成认证边界，所以 API 还要求每用户 token：

- 首次启动时守护进程在 `~/.benchpilot/token` 生成随机 token（Unix 上仅用户可读）；
- CLI、MCP 和 `Benchpilot.Client` 自动附带；`BENCHPILOT_TOKEN` 可覆盖文件；
- `/healthz` 刻意开放，让 autostart、监控和 `doctor` 无凭据探测存活；
- 同一台机器上另一个用户账户的第二个守护进程读不到这个用户的 token 文件，也驱动不了这个用户的台架。

远程/团队访问（认证传输、租约、调度）刻意不在范围内，直到本地单台架体验在硬件上验证完毕。

## 资源 / 目标 profile

BenchPilot 不假设真实台架只有一个整块 `hardware` 驱动。一个目标可以组合独立的厂商资源：

```json
{
  "schemaVersion": 1,
  "defaultTarget": "radar",
  "resources": {
    "psu.main": {
      "driver": "scpi-power",
      "capabilities": ["power"]
    },
    "probe.radar": {
      "driver": "jlink",
      "capabilities": ["flash"]
    },
    "uart.radar": {
      "driver": "system-serial",
      "capabilities": ["serial"]
    }
  },
  "targets": {
    "radar": {
      "mcu": "TC397",
      "bindings": {
        "power": "psu.main",
        "flash": "probe.radar",
        "serial": "uart.radar"
      }
    }
  },
  "safety": {
    "maxVoltage": 14.5,
    "maxCurrentMa": 2500,
    "requireExplicitTarget": true,
    "requireDestructiveConfirmation": true
  }
}
```

旧版 P0 profile 会自动归一化，模拟器 demo 保持兼容。

## 项目结构

```text
benchpilot/
├── src/
│   ├── Benchpilot.Core/              # vendor-neutral domain/profile contracts
│   ├── Benchpilot.Protocol/          # versioned local API contracts
│   ├── Benchpilot.Runtime/           # target operations, safety, evidence/readiness
│   ├── Benchpilot.RuntimeHost/       # benchpilotd resident loopback API process
│   ├── Benchpilot.Client/            # shared IPC client for every shell
│   ├── Benchpilot.Cli/               # stable commands, JSON and exit codes
│   ├── Benchpilot.Mcp/               # thin stdio MCP -> Runtime proxy
│   ├── Benchpilot.Simulator/         # deterministic virtual bench
│   ├── Benchpilot.Drivers.Serial/    # system serial backend
│   ├── Benchpilot.Drivers.JLink/     # SEGGER J-Link Commander adapter
│   └── Benchpilot.Drivers.ScpiPower/ # TCP SCPI power-supply adapter
├── tests/
│   └── Benchpilot.Core.Tests/
├── racket/
│   └── benchpilot/core/              # Racket port (ADR 0002): profiles + readiness
├── profiles/
│   ├── demo.profile.json
│   └── real-ecu.example.json
├── scripts/
│   ├── smoke-runtime.sh
│   └── smoke-shutdown.sh
├── docs/
│   ├── ARCHITECTURE.md
│   └── adr/
└── ROADMAP.md
```

未来的 CAN/协议/Flash/Studio 项目接入这些边界，而不是另开平行的硬件栈。

## 产品优先级

近期工作仍是纵向切片，而非铺协议覆盖面：

1. 用 `system-serial` + J-Link + SCPI 电源对一台物理 ECU 完成验证，并提交一份可复现的 known-good profile；
2. 在真实 ECU 上验证 CAN 与 DoIP 的 UDS 烧录工作流；
3. CAN/CAN FD 抓包 + DBC 解码与信号观察；
4. 更丰富的 vendor-neutral 设备/运行时错误分类法和生产级证据/产物引用；
5. ~~跑在同一个运行时 API 上的 Studio GUI。~~ 已交付：BenchPilot Studio 覆盖 macOS 上的电源、烧录、串口、UDS 诊断与 DoIP 发现。

见 [ROADMAP.md](ROADMAP.md)。

## 实现语言

运行时用 **Racket**（Racket CS）实现
（[ADR 0002](docs/adr/0002-racket-port.md)，取代
[ADR 0001](docs/adr/0001-runtime-language.md)）。0.5.x 线的 C#/.NET 代码树在移植达到完全契约对等后退役：同一套冻结的 JSON API、同样的 CLI 退出码、同样的 E2E 套件。GUI 技术与运行时保持解耦：BenchPilot Studio 说的是同一套版本化本地 API，而不是自己持有设备。

## 长期烧录方向

专业烧录是一等的产品能力，不是三条裸 UDS 命令。目标架构分层如下：

```text
Flash workflow
      |
Flash Engine
      |
UDS client
      |
ISO-TP / DoIP
      |
CAN FD / Ethernet
```

未来的可视化工作流编辑器和文本 DSL 会编译到同一套 typed 执行计划。安全、目标指纹、电压/电流监测、Security Provider 集成、校验和恢复都属于 Agent 表面之下的部分。

## 许可证

GNU Affero General Public License v3.0。见 [LICENSE](LICENSE)。
