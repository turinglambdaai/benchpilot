# ADR 0001: Use .NET/C# for the hardware runtime; keep GUI technology decoupled

- Status: Accepted
- Date: 2026-09-20

## Context

BenchPilot is expected to integrate with automotive and embedded hardware through a mixture of:

- vendor C/C++ SDKs and native DLLs;
- Windows device APIs and Linux SocketCAN;
- USB/serial devices;
- J-Link/OpenOCD/probe tooling;
- SCPI instruments;
- asynchronous, long-lived hardware sessions;
- CAN/UDS/DoIP protocol stacks;
- CLI, MCP, CI and GUI clients.

The project author also maintains Racket GUI/framework work and would like that investment to be useful in commercial products.

Technology choice must optimize total product risk rather than serve as a referendum on a preferred language.

## Decision

BenchPilot's hardware-facing product core will use **.NET/C#** for:

- `Benchpilot.Core`;
- the resident Runtime;
- native/vendor driver adapters;
- CLI;
- MCP adapter;
- protocol and flashing engines unless a specific component has a better implementation reason.

The GUI is intentionally **not coupled to the runtime implementation language**. `Benchpilot.Studio` will communicate with the resident runtime through a stable local API/IPC boundary.

This permits two rational GUI paths:

1. an Avalonia/.NET Studio when fastest integration and packaging are the priority;
2. a Racket/Glaze-based Studio or experimental frontend when the Racket stack provides a measurable product advantage.

The runtime must not require the GUI to be present.

## Why .NET for the runtime

The difficult engineering risk in BenchPilot is not syntax or UI composition. It is reliable integration with hardware and vendor ecosystems.

.NET/C# gives the project a low-friction path for:

- P/Invoke and native vendor DLLs;
- mature async/cancellation primitives;
- long-running services;
- Windows-first automotive tooling while remaining cross-platform;
- vendor SDK samples that frequently include C# bindings;
- predictable packaging, diagnostics and testing;
- one implementation shared by CLI, MCP and service layers.

This reduces integration risk in the exact layer where BenchPilot must be boring and dependable.

## Why this is not a rejection of Racket

Racket remains attractive for:

- language-oriented tooling and future DSL experimentation;
- rapid UI iteration where the existing GUI stack is strong enough;
- developer tools whose value is dominated by transformation, visualization or workflow rather than native hardware SDK coverage;
- alternative BenchPilot clients because the runtime boundary is language-neutral.

A commercial product is not validated by forcing every existing library into it. An existing library becomes commercially useful when it lowers cost, improves differentiation, or speeds iteration for a specific product.

The correct question is therefore not "Can Racket make a product?" but:

> Does Racket reduce the risk or create a meaningful advantage in this particular layer of this particular product?

For BenchPilot's hardware runtime, the current answer is no. For a Studio frontend or another product, the answer can still be yes.

## Consequences

Positive:

- hardware integration risk is concentrated in an ecosystem well suited to it;
- the runtime can be headless and CI-friendly from day one;
- Agent/CLI/GUI surfaces share one implementation;
- the project can experiment with Racket UI without betting the hardware core on that experiment.

Costs:

- some GUI/framework work may not be reused directly in the first commercial BenchPilot release;
- a language-neutral IPC/API boundary becomes an architectural requirement;
- if both Avalonia and Racket frontends are maintained, duplicated UI work must be justified by product value.

## Revisit criteria

Revisit this decision if one of the following becomes true:

- the Racket stack obtains first-class, maintained bindings for the required hardware/vendor ecosystem;
- a Racket frontend demonstrates materially faster product iteration or a unique UX advantage;
- BenchPilot's dominant complexity shifts away from hardware integration toward language/workflow tooling;
- a stable service boundary makes the implementation language of a subsystem irrelevant enough to choose another language for that subsystem.
