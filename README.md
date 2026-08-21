# RV32I Single Cycle RISC-V Processor

A single-cycle RISC-V CPU core written in Verilog, implementing a subset of the RV32I
instruction set. The design follows the classic single-cycle architecture from
*Digital Design and Computer Architecture — RISC-V Edition* (Sarah L. Harris & David
Money Harris), with a custom self-checking testbench built for verification on
EDA Playground.

Every instruction — regardless of type — completes fetch, decode, execute, memory
access, and register writeback in **exactly one clock cycle**. There is no pipelining,
no hazard handling, and no stalling: the entire datapath is combinational logic
sitting between two clocked elements (the PC register and the register file).

---

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Module Hierarchy](#module-hierarchy)
- [Supported Instruction Set](#supported-instruction-set)
- [File-by-File Explanation](#file-by-file-explanation)
- [Control Signal Reference](#control-signal-reference)
- [How an Instruction Executes](#how-an-instruction-executes)
- [Memory Model](#memory-model)
- [Testbench](#testbench)
- [Running on EDA Playground](#running-on-eda-playground)
- [Repository Structure](#repository-structure)
- [Known Limitations](#known-limitations)
- [Possible Extensions](#possible-extensions)

---

## Architecture Overview

This is a **single-cycle, Harvard-architecture** CPU:

- **Single-cycle** — one instruction fully retires per clock edge. The clock period
  must be long enough to cover the slowest instruction's entire signal path
  (typically `lw`, since it touches fetch, register read, ALU, memory, and
  writeback all in one cycle).
- **Harvard architecture** — instruction memory and data memory are two separate,
  independently addressed arrays (`instr_mem.v` and `data_mem.v`), so instruction
  fetch and data access never contend for the same memory port.

```
                ┌─────────────────────────────────────────┐
                │              riscv_cpu.v                 │
                │                                           │
   Instr ──────▶│  ┌────────────┐        ┌───────────────┐ │
                │  │ controller │───────▶│   datapath    │ │──▶ PC, Result,
                │  │            │ ctrl   │               │ │    MemWrite,
   Zero  ◀──────│  └────────────┘ sigs   └───────────────┘ │    Mem_WrAddr/Data
                │        ▲                      │           │
                └────────┼──────────────────────┼───────────┘
                         │                      │
                    op/funct3/funct7        ALU, RegFile, PC logic
```

---

## Module Hierarchy

```
t1c_riscv_cpu.v        (top-level harness / test wrapper)
 ├── riscv_cpu.v        (CPU core)
 │    ├── controller.v
 │    │    ├── main_decoder.v
 │    │    └── alu_decoder.v
 │    └── datapath.v
 │         ├── reset_ff.v       (PC register)
 │         ├── adder.v  (×2 — PC+4 and PC+branch offset)
 │         ├── mux2.v   (×2 — PC-source select, ALU-B select)
 │         ├── reg_file.v
 │         ├── imm_extend.v
 │         ├── alu.v
 │         └── mux3.v   (result select: ALU / memory / PC+4)
 ├── instr_mem.v
 └── data_mem.v
```

`mux4.v` is included in the repo as a general-purpose building block but is
**not used** anywhere in this design — no signal in this CPU needs a 4-way select.

---

## Supported Instruction Set

`main_decoder.v` and `alu_decoder.v` together only recognize the following
**13 instructions**. Any other RV32I opcode/funct3/funct7 combination (e.g. `slli`,
`xor`, `lui`, `jalr`, byte/halfword loads and stores, `bne`, `blt`, etc.) is
**not implemented** — the decoders will output `x` (don't-care/undefined) control
signals for anything outside this list.

| Category      | Instructions                        |
|---------------|--------------------------------------|
| I-type ALU    | `addi`, `andi`, `ori`, `slti`        |
| R-type ALU    | `add`, `sub`, `and`, `or`, `slt`     |
| Load / Store  | `lw`, `sw`                           |
| Branch        | `beq`                                |
| Jump          | `jal`                                |

---

## File-by-File Explanation

### `t1c_riscv_cpu.v` — Top-level test harness
Instantiates `riscv_cpu`, `instr_mem`, and `data_mem`, and wires them together.
It also exposes an **external memory-write override**: if `reset` and
`Ext_MemWrite` are both asserted, the testbench can force a value directly into
data memory via `Ext_WriteData` / `Ext_DataAdr`, bypassing the CPU's own memory
path. This is purely a debug/setup hook — normal program execution never
exercises this path.

### `riscv_cpu.v` — CPU core
The processor itself: just wires together `controller` (decides *what* should
happen) and `datapath` (does the actual work). All communication between the two
happens through combinational control signals (`ALUSrc`, `RegWrite`,
`ALUControl`, etc.) and the `Zero` flag fed back from the datapath's ALU into
the controller for branch resolution.

### `controller.v` — Control unit
Splits control-signal generation into two decoders:
- **`main_decoder.v`** looks only at the 7-bit opcode and produces a broad
  11-bit control word (register-write enable, immediate format, ALU source,
  memory write enable, result-mux select, branch flag, coarse ALU operation,
  jump flag).
- **`alu_decoder.v`** refines the coarse `ALUOp` from `main_decoder` into the
  exact 3-bit `ALUControl` signal, using `funct3` (and `funct7[5]` to
  distinguish `add` from `sub`).

It also computes the final branch/jump decision in one line:
```verilog
assign PCSrc = (Branch & Zero) | Jump;
```

### `main_decoder.v`
Combinational `case` on opcode. Full control-word table:

| Opcode      | Instruction | RegWrite | ImmSrc | ALUSrc | MemWrite | ResultSrc | Branch | ALUOp | Jump |
|-------------|-------------|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| `0000011`   | `lw`        | 1  | 00 | 1  | 0  | 01 | 0  | 00 | 0  |
| `0100011`   | `sw`        | 0  | 01 | 1  | 1  | 00 | 0  | 00 | 0  |
| `0110011`   | R-type      | 1  | xx | 0  | 0  | 00 | 0  | 10 | 0  |
| `1100011`   | `beq`       | 0  | 10 | 0  | 0  | 00 | 1  | 01 | 0  |
| `0010011`   | I-type ALU  | 1  | 00 | 1  | 0  | 00 | 0  | 10 | 0  |
| `1101111`   | `jal`       | 1  | 11 | 0  | 0  | 10 | 0  | 00 | 1  |

### `alu_decoder.v`
Takes `ALUOp` from `main_decoder` and refines it:
- `ALUOp = 00` → force **add** (used by `lw`/`sw` for address calculation)
- `ALUOp = 01` → force **subtract** (used by `beq` to compute `a - b` and check `Zero`)
- `ALUOp = 10` → look at `funct3` (and `funct7[5]` for R-type sub-vs-add) to pick
  the exact operation for R-type/I-type ALU instructions:

  | funct3 | Operation           | ALUControl |
  |--------|----------------------|:----------:|
  | `000`  | add / addi (or sub, if R-type and `funct7[5]=1`) | `000` / `001` |
  | `010`  | slt / slti           | `101`       |
  | `110`  | or / ori             | `011`       |
  | `111`  | and / andi           | `010`       |

### `alu.v`
4-operation ALU: add, subtract (two's-complement, `a + ~b + 1`), bitwise AND,
bitwise OR, and set-less-than (signed comparison, handled explicitly for
sign-bit mismatch to get correct signed behavior). Outputs a `zero` flag
(`1` when the result is `0`), used both for `slt`-style branch comparisons and
for the `beq` branch decision.

### `datapath.v`
The actual data flow of the processor:
- **PC logic**: `reset_ff` holds the current PC. Two `adder` instances compute
  `PC+4` and `PC + ImmExt` (branch/jump target) **every cycle, unconditionally**
  — a `mux2` then picks the correct one based on `PCSrc`.
- **Register file access**: reads `rs1`/`rs2` combinationally via `Instr[19:15]`
  and `Instr[24:20]`; write address comes from `Instr[11:7]`.
- **Immediate generation**: `imm_extend` sign-extends the immediate field
  according to instruction format (I/S/B/J — RISC-V scatters immediate bits
  across different positions to keep register-index fields in the same place
  across formats).
- **ALU operand select**: a `mux2` chooses between the second register value
  and the sign-extended immediate for the ALU's `B` input, based on `ALUSrc`.
- **Result select**: a `mux3` picks what gets written back to the register
  file — the ALU result, memory read data, or `PC+4` (used only by `jal`, to
  store the return address).

### `reg_file.v`
32×32-bit register file. `x0` is hardwired to return `0` regardless of what's
stored (writes to `x0` are architecturally harmless no-ops in terms of read
behavior). Two asynchronous/combinational read ports, one synchronous
(clock-edge) write port — this matches the "read same cycle, write on clock
edge" behavior needed for single-cycle execution.

### `imm_extend.v`
Produces the sign-extended 32-bit immediate for each of the four instruction
formats used here (I, S, B, J), selected by the 2-bit `ImmSrc` control signal
from `main_decoder`.

### `instr_mem.v`
512-word instruction ROM, loaded once at simulation start via
`$readmemh("rv32i_book.hex", instr_ram)`. Reads are combinational and
word-aligned (`instr_ram[instr_addr[31:2]]` — dividing the byte address by 4).

### `data_mem.v`
64-word data RAM. Combinational, word-aligned reads; synchronous
(clock-edge) writes when `wr_en` is asserted. Addresses are wrapped with
`% 64` to stay within the array bounds.

### `adder.v`, `mux2.v`, `mux3.v`, `mux4.v`, `reset_ff.v`
Small, parameterized, reusable building blocks:
- `adder` — plain combinational adder.
- `mux2` / `mux3` / `mux4` — 2/3/4-way combinational multiplexers.
- `reset_ff` — a resettable D flip-flop, used here as the PC register
  (asynchronous reset to `0`).

---

## Control Signal Reference

| Signal       | Width | Meaning                                                              |
|--------------|:-----:|------------------------------------------------------------------------|
| `RegWrite`   | 1     | Write `Result` into the register file this cycle                      |
| `ImmSrc`     | 2     | Which immediate format to sign-extend (I/S/B/J)                       |
| `ALUSrc`     | 1     | ALU's B input: register value (`0`) or immediate (`1`)                |
| `MemWrite`   | 1     | Write `WriteData` into data memory this cycle                         |
| `ResultSrc`  | 2     | What gets written back: ALU result (`00`), memory data (`01`), `PC+4` (`10`) |
| `Branch`     | 1     | This instruction is a conditional branch (`beq`)                      |
| `Jump`       | 1     | This instruction is an unconditional jump (`jal`)                     |
| `ALUOp`      | 2     | Coarse ALU category, refined by `alu_decoder` into `ALUControl`       |
| `ALUControl` | 3     | Exact ALU operation (add/sub/and/or/slt)                              |
| `PCSrc`      | 1     | `(Branch & Zero) \| Jump` — selects `PC+4` vs. branch/jump target      |

---

## How an Instruction Executes

Because it's single-cycle, there's no "stage" to describe separately —
everything below happens **combinationally, within one clock period**, and
only the PC and register-file writes actually latch on the clock edge.

**Example: `add x6, x1, x2`**
1. `PC` indexes `instr_mem` → `Instr` appears (combinational read, no clock needed).
2. `controller` decodes `opcode=0110011`, `funct3=000`, `funct7[5]=0` →
   `RegWrite=1`, `ALUSrc=0`, `ALUOp=10` → `alu_decoder` resolves `ALUControl=000` (add).
3. `reg_file` combinationally outputs `x1` and `x2` on its read ports.
4. The `SrcB` mux selects the register value (`ALUSrc=0`), not the immediate.
5. `alu` computes `x1 + x2` → `ALUResult`.
6. The result mux selects `ALUResult` (`ResultSrc=00`) → `Result`.
7. **On the clock edge**: `PC ← PC+4` and `reg_file[x6] ← Result` happen simultaneously.

**Example: `lw x11, 0(x0)`**
Same as above through step 5 (ALU computes the effective address `x0+0`), but:
`Mem_WrAddr = ALUResult` feeds `data_mem`, whose combinational `ReadData`
output is selected by the result mux (`ResultSrc=01`). On the clock edge,
`x11 ← ReadData`.

**Example: `sw x7, 0(x0)`**
`MemWrite=1`; `Mem_WrData = x7`'s value, `Mem_WrAddr = ALUResult` (the address).
On the clock edge, `data_mem` latches the write. `RegWrite=0` — no register is
touched.

**Example: `beq x1, x2, offset`**
The ALU is repurposed to compute `x1 - x2` (`ALUControl=001`) purely to derive
`Zero`. `Branch=1`, so `PCSrc = Zero`. If `x1 == x2`, `PCNext = PC + ImmExt`
(branch taken); otherwise `PCNext = PC+4` (fall through). No register or
memory write occurs either way.

**Example: `jal x16, offset`**
`Jump=1` forces `PCSrc=1` unconditionally, so `PCNext = PC + ImmExt` regardless
of `Zero`. Simultaneously, `ResultSrc=10` selects `PCPlus4` as `Result`,
which gets written into `x16` — this is the return address for the jump.

Every instruction type reuses the same physical datapath; only the control
signals (and therefore the mux selections) differ.

---

## Memory Model

- **Instruction memory**: word-addressed, 512 entries, read-only during
  execution, initialized once from a `.hex` file via `$readmemh`.
- **Data memory**: word-addressed, 64 entries, read/write, address wraps
  modulo 64. There is **no byte/halfword addressing support** — only full
  32-bit word loads/stores (`lw`/`sw`), consistent with the fact that `lb`,
  `lh`, `sb`, `sh` are not implemented by the decoders.

---

## Testbench

The included self-checking testbench (`testbench.v`) does **not** rely on
`rv32i_book.hex`'s default program. Instead, it:

1. Lets `instr_mem`'s own `$readmemh` run first (so the file must still exist
   in the project, even though its contents are irrelevant).
2. At `#1` (1ns into simulation), **force-overwrites** `instr_mem`'s internal
   array (`uut.instrmem.instr_ram[...]`) with a small, hand-assembled 22-word
   program that exercises every instruction the design actually implements.
3. Clears data memory for a deterministic starting state.
4. Steps through the program, checking each instruction's result against a
   pre-computed expected value at specific PC "checkpoints" — including
   deliberately placed **poison instructions** right after branch/jump
   targets, which must be skipped if branching/jumping works correctly.
5. Prints a PASS/FAIL line per checkpoint, then a final coverage table showing,
   for every implemented instruction, whether it was **EXECUTED–PASS**,
   **EXECUTED–FAIL**, or **NOT EXECUTED**.
6. Writes a `results.txt` file (`"No Errors"` / `"Errors"`) and dumps a
   `dump.vcd` waveform file for viewing in EPWave.

`addi`, `slt`, and `slti` are used internally in the test program (to set up
register values and as branch/jump "poison" markers) but are **not**
individually checked or reported in the coverage summary, by request.

---

## Running on EDA Playground

1. Add all design files as **Design Files**:
   `data_mem.v`, `instr_mem.v`, `riscv_cpu.v`, `t1c_riscv_cpu.v`, `adder.v`,
   `alu.v`, `alu_decoder.v`, `controller.v`, `datapath.v`, `imm_extend.v`,
   `main_decoder.v`, `mux2.v`, `mux3.v`, `mux4.v`, `reg_file.v`, `reset_ff.v`.
2. Keep `rv32i_book.hex` in the project (its content no longer matters once
   the testbench overrides it, but the file must exist so `$readmemh` doesn't
   error out).
3. Add `testbench.v` as the **Testbench** file and set the top module to
   `testbench`.
4. Check **"Open EPWave after run"** to inspect signal waveforms after simulation.
5. Run — console output will show per-instruction PASS/FAIL messages followed
   by the final coverage summary.

---

## Repository Structure

```
.
├── riscv_cpu.v         # CPU core (controller + datapath)
├── t1c_riscv_cpu.v     # Top-level harness (CPU + memories)
├── controller.v        # Control unit
├── main_decoder.v      # Opcode → control word
├── alu_decoder.v       # ALUOp/funct3/funct7 → ALUControl
├── datapath.v           # PC logic, register file, ALU, muxes
├── reg_file.v           # 32×32-bit register file
├── alu.v                 # ALU
├── imm_extend.v         # Immediate sign-extension
├── adder.v               # Generic adder
├── mux2.v / mux3.v / mux4.v   # Generic multiplexers
├── reset_ff.v           # Resettable flip-flop (used as PC register)
├── instr_mem.v          # Instruction memory
├── data_mem.v           # Data memory
├── rv32i_book.hex       # Default program (superseded by testbench override)
├── rv32i_test.hex       # Alternate/full RV32I test program (not fully supported by this design)
├── rv32i_test.s         # Source assembly for rv32i_test.hex
└── testbench.v          # Self-checking testbench
```

---

## Known Limitations

- **Not pipelined.** This is a strictly single-cycle design — one instruction
  fully completes per clock cycle, with no overlap between instructions. There
  is no forwarding, hazard detection, or branch prediction because there is no
  pipeline for hazards to occur in.
- **Only 13 of the ~47 base RV32I instructions are implemented.** Missing:
  `slli`, `srli`, `srai`, `xor`, `xori`, `sltu`, `sltiu`, `sll`, `srl`, `sra`,
  `lui`, `auipc`, `jalr`, `bne`, `blt`, `bge`, `bltu`, `bgeu`, and all
  byte/halfword loads and stores (`lb`, `lh`, `lbu`, `lhu`, `sb`, `sh`).
- **No exception/interrupt handling**, no CSR support, no privilege modes.
- Data memory is only 64 words (256 bytes) and wraps on overflow rather than
  faulting.

---

## Possible Extensions

- **Pipelining**: split the datapath into IF/ID/EX/MEM/WB stages with pipeline
  registers, then add forwarding and a hazard-detection/stall unit for data
  hazards, plus flush logic (or prediction) for control hazards — the natural
  next step this design is a direct precursor to.
- **Full RV32I support**: extend `main_decoder`/`alu_decoder` to cover the
  remaining opcodes/funct3 combinations listed above.
- **Byte/halfword memory access** for `lb`/`lh`/`sb`/`sh` support.
- **CSR + exception support** for a more complete privileged architecture.

---

## Credits

Architecture based on the single-cycle RISC-V processor design presented in
*Digital Design and Computer Architecture: RISC-V Edition* by Sarah L. Harris
and David Money Harris.
