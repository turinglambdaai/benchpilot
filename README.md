# BenchPilot

> A hardware-aware MCP server that lets an AI agent run the embedded debug loop — `power → flash → observe → judge` — against a real or simulated bench.

[![.NET](https://img.shields.io/badge/.NET-10.0-512BD4)](https://dotnet.microsoft.com/)
[![MCP](https://img.shields.io/badge/MCP-server-00B4D8)](https://modelcontextprotocol.io/)
[![License](https://img.shields.io/github/license/turinglambdaai/benchpilot)](LICENSE)
[![CI](https://github.com/turinglambdaai/benchpilot/actions/workflows/ci.yml/badge.svg)](https://github.com/turinglambdaai/benchpilot/actions/workflows/ci.yml)

**中文**：BenchPilot 把硬件调试通道（电源 / 串口 / 烧录）封装成 AI agent 可调用的 MCP 工具，让 agent 能跑通「上电 → 烧录 → 观测 → 判断」的硬件闭环。本仓库是 **P0 概念验证 DEMO**，内置一个硬件模拟器——无需真机即可跑通完整闭环。

---

## Why BenchPilot?

Pure-software AI agents cannot reach a bench: they can't see the board, toggle power, or watch a UART console. Existing options each leave a gap:

| Option | Gap |
|---|---|
| **embedded-debugger-mcp** | JTAG/SWD only — no serial console, no power, single board |
| **CCS AI MCP** (TI, commercial) | Parasitic on a running IDE; no power/CAN; serial is bare passthrough, no context compression |
| **BootLoop** (commercial HIL) | Closed, MCU-focused, heavy |

BenchPilot's position: a **headless, multi-channel orchestration layer** that any MCP-capable agent can drive, decoupled from any particular IDE.

## This Demo (P0)

This repository implements the **P0 milestone** from the [product spec](https://github.com/turinglambdaai/benchpilot): the **power + serial + flash loop**, backed by a **built-in hardware simulator**. No physical hardware is required — the simulator behaves like a real board:

- A virtual bench supply with a realistic inrush → settle → steady current curve
- A virtual firmware that streams a boot log (`... → System Ready`) over a virtual console
- Flashing reboots the firmware; the serial console reflects it

An agent can autonomously run the full loop and reach a verdict, with zero hardware attached.

## Features

- **10 MCP tools** across three channels: power, flash, serial
- **Simulated bench** — power/serial/flash share state like a real board
- **Context-compression primitive**: `serial_wait_for` returns only the matched event, not the raw byte flood
- **Idempotent operations**: `power_on` is a no-op if already on
- **Unified JSON contract** on every tool (`{ ok, ...fields, error? }`)
- **Interface-driven kernel**: swap the simulator for a real SCPI supply + probe backend by changing one DI registration — tools and kernel don't change

## Requirements

| Dependency | Version |
|---|---|
| .NET SDK | 10.0 or later |
| An MCP-capable client | Claude Code, ZCode, VS Code (Copilot), Cursor, etc. |
| Git | source control |

## Quick Start

### 1. Clone & build

```bash
git clone https://github.com/turinglambdaai/benchpilot.git
cd benchpilot
dotnet build
dotnet test      # 8 tests, incl. the full P0 loop
```

### 2. Wire it into your MCP client

Add BenchPilot to your client's MCP config. For Claude Code / ZCode (`mcp.json` or equivalent):

```json
{
  "mcpServers": {
    "benchpilot": {
      "command": "dotnet",
      "args": ["run", "--project", "PATH/TO/benchpilot/src/Benchpilot.Mcp", "--no-build"]
    }
  }
}
```

For VS Code (`.vscode/mcp.json`):

```json
{
  "servers": {
    "benchpilot": {
      "type": "stdio",
      "command": "dotnet",
      "args": ["run", "--project", "src/Benchpilot.Mcp", "--no-build"]
    }
  }
}
```

### 3. Run the loop

Ask your agent:

> Power on the bench at 12V, flash `build/app.elf`, wait for the console to print `Ready`, then check that the idle current is under 100mA, and power off.

The agent will call `power_on → flash → serial_wait_for → check_current → power_off` autonomously and report the result.

## Tool Reference

| Tool | Channel | Description |
|---|---|---|
| `power_on` | power | Apply voltage, wait to settle, report current |
| `power_off` | power | Switch off the supply |
| `read_current` | power | Sample current over a window (avg/peak/samples) |
| `check_current` | power | Assert current is below/above a threshold |
| `flash` | flash | Program firmware; reboots into it |
| `reset` | flash | Software reset; re-runs boot |
| `serial_open` | serial | Open the console port |
| `serial_wait_for` | serial | Block until a pattern appears (context-compression primitive) |
| `serial_read_window` | serial | Read the last N lines, optionally filtered |
| `serial_send` | serial | Write to the console |

All tools return a flat JSON object with an `ok` flag and an optional `error`.

## Project Structure

```
benchpilot/
├── src/
│   ├── Benchpilot.Core/         # kernel: channel abstractions, profile, orchestration
│   │   ├── Abstractions/        #   IPowerSupply, ISerialChannel, IFlashTarget
│   │   ├── Profile/             #   BenchProfile schema + loader
│   │   └── Kernel/              #   BenchKernel (resident connection state)
│   ├── Benchpilot.Simulator/    # the virtual bench (implements all 3 channels)
│   └── Benchpilot.Mcp/          # stdio MCP server shell + tool definitions
│       └── Tools/               #   PowerTools, FlashTools, SerialTools
├── tests/
│   └── Benchpilot.Core.Tests/   # xUnit: the full P0 loop against the kernel
└── profiles/
    └── demo.profile.json        # zero-config simulator profile
```

## Architecture

BenchPilot follows a **valuable-kernel / replaceable-shell** split (mirroring [Taskly](https://github.com/turinglambdaai/taskly)):

```
agent (Claude Code / ZCode / Cursor)
        ↕  stdio MCP
  Benchpilot.Mcp          ← thin shell: [McpServerTool] methods
        ↕  DI
  Benchpilot.Core         ← kernel: IPowerSupply / ISerialChannel / IFlashTarget
        ↕  implements
  Benchpilot.Simulator    ← this DEMO's virtual bench
  (future) Benchpilot.Hardware  ← real SCPI supply + System.IO.Ports + probe-rs
```

The kernel and tools know only the channel **interfaces**. Swapping the simulator for real hardware is a single DI registration change in `Program.cs` — nothing above the interface seam is touched. That is the whole point: the agent's tools stay identical whether the bench is virtual or real.

## Development

```bash
dotnet build
dotnet test
dotnet run --project src/Benchpilot.Mcp      # starts the stdio MCP server
```

Set `BENCHPILOT_PROFILE` to point at a profile file, otherwise the zero-config simulator defaults are used.

## Roadmap

This repo is the **P0** milestone. The full product spec tracks further phases:

- **P0** ✅ — power + serial + flash loop (this repo, simulator-backed)
- **P1** — CAN channel (`can_send`, `can_wait_resp`, DBC signal decode)
- **P2** — sequence orchestration engine + toolchain resolver + GUI
- **P3** — UDS diagnostics + AUTOSAR toolchain fusion

Real hardware backends (SCPI power, `System.IO.Ports` console, probe-rs/DAP flashing) land behind the existing interfaces — no kernel or tool changes required.

## License

Licensed under the [Apache License 2.0](LICENSE).
