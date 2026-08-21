`timescale 1 ns/1 ns

// ============================================================================
// testbench.v  -  Self-checking testbench for the single-cycle RISC-V CPU
//
// This DUT (main_decoder.v + alu_decoder.v) implements 13 instructions,
// but this testbench only tracks/checks the following 10 (addi, slt,
// and slti are not checked or reported on, though addi is still used
// silently in the background to set up register values):
//
//     andi  ori                 (I-type ALU)
//     add   sub   and  or       (R-type ALU)
//     lw    sw                  (load / store)
//     beq                       (branch, tested taken AND not-taken)
//     jal                       (jump-and-link)
//
// A custom 22-word program is force-loaded into instr_mem's memory array
// at time 1ns (after its own $readmemh("rv32i_book.hex",...) has already
// run), so you do NOT need to touch rv32i_book.hex or any DUT file -
// just keep rv32i_book.hex in the project (its content is irrelevant,
// it just needs to exist so the $readmemh in instr_mem.v does not error).
//
// Console output: one PASS/FAIL line per checkpoint, plus a final
// EXECUTED/NOT EXECUTED summary table for all 13 instructions.
// A results.txt file is also written (Errors / No Errors), mirroring
// the style used in this project's other testbenches.
// ============================================================================

module testbench;

// registers driven into the DUT
reg clk;
reg reset;
reg Ext_MemWrite;
reg [31:0] Ext_WriteData, Ext_DataAdr;

// wires driven out of the DUT
wire [31:0] WriteData, DataAdr, ReadData;
wire        MemWrite;
wire [31:0] PC, Result;

// Instantiate the top module under test
t1c_riscv_cpu uut (clk, reset, Ext_MemWrite, Ext_WriteData, Ext_DataAdr,
                    MemWrite, WriteData, DataAdr, ReadData, PC, Result);

integer fault_instrs = 0, i = 0, fw = 0;
integer j;

// -------------------------------------------------------------------------
// PC checkpoints for the custom test program (see comments beside each
// $readmemh-style override below for the exact instruction at each PC)
// -------------------------------------------------------------------------
localparam CP_ADDI_1   = 32'h00;  // addi x1,x0,5
localparam CP_ADDI_2   = 32'h04;  // addi x2,x0,-3
localparam CP_ANDI     = 32'h08;  // andi x3,x1,3
localparam CP_ORI      = 32'h0C;  // ori  x4,x1,8
localparam CP_SLTI     = 32'h10;  // slti x5,x2,0
localparam CP_ADD      = 32'h14;  // add  x6,x1,x2
localparam CP_SUB      = 32'h18;  // sub  x7,x1,x2
localparam CP_AND      = 32'h1C;  // and  x8,x1,x3
localparam CP_OR       = 32'h20;  // or   x9,x1,x4
localparam CP_SLT      = 32'h24;  // slt  x10,x2,x1
localparam CP_SW       = 32'h28;  // sw   x7,0(x0)
localparam CP_LW       = 32'h2C;  // lw   x11,0(x0)
localparam CP_BEQ_T    = 32'h30;  // beq  x1,x1,+8   (taken)
localparam CP_AFTER_BT = 32'h38;  // addi x13,x0,111  <- only reached if beq was taken
localparam CP_BEQ_NT   = 32'h3C;  // beq  x1,x2,+8   (not taken)
localparam CP_AFTER_BN = 32'h40;  // addi x14,x0,222  <- only reached if beq was NOT taken
localparam CP_JAL      = 32'h48;  // jal  x16,+8
localparam CP_AFTER_J  = 32'h50;  // addi x18,x0,777  <- only reached if jal jumped correctly
localparam CP_HALT     = 32'h54;  // beq  x0,x0,0  (self loop, end of test)

// -------------------------------------------------------------------------
// Instruction coverage bookkeeping (13 implemented instructions)
// -------------------------------------------------------------------------
localparam N_INSTR = 10;
localparam IDX_ANDI=0, IDX_ORI=1, IDX_ADD=2,
           IDX_SUB=3, IDX_AND=4, IDX_OR=5, IDX_LW=6,
           IDX_SW=7, IDX_BEQ=8, IDX_JAL=9;

reg [8*6-1:0] instr_names [0:N_INSTR-1];
reg           seen   [0:N_INSTR-1];
reg           passed [0:N_INSTR-1];

initial begin
    instr_names[0]  = "ANDI  ";
    instr_names[1]  = "ORI   ";
    instr_names[2]  = "ADD   ";
    instr_names[3]  = "SUB   ";
    instr_names[4]  = "AND   ";
    instr_names[5]  = "OR    ";
    instr_names[6]  = "LW    ";
    instr_names[7]  = "SW    ";
    instr_names[8]  = "BEQ   ";
    instr_names[9]  = "JAL   ";
end

// generate clock
always begin
    clk <= 1; #5; clk <= 0; #5;
end

// -------------------------------------------------------------------------
// Reset + custom instruction memory preload
// -------------------------------------------------------------------------
initial begin
    reset = 1;
    Ext_MemWrite = 0; Ext_DataAdr = 32'b0; Ext_WriteData = 32'b0;

    for (j = 0; j < N_INSTR; j = j + 1) begin
        seen[j]   = 1'b0;
        passed[j] = 1'b1;
    end

    #1; // let instr_mem's own $readmemh("rv32i_book.hex",...) finish first

    // ---- force-load our own 22-word program, overriding rv32i_book.hex ----
    uut.instrmem.instr_ram[0]  = 32'h00500093; // 00: addi x1,x0,5
    uut.instrmem.instr_ram[1]  = 32'hFFD00113; // 04: addi x2,x0,-3
    uut.instrmem.instr_ram[2]  = 32'h0030F193; // 08: andi x3,x1,3
    uut.instrmem.instr_ram[3]  = 32'h0080E213; // 0C: ori  x4,x1,8
    uut.instrmem.instr_ram[4]  = 32'h00012293; // 10: slti x5,x2,0
    uut.instrmem.instr_ram[5]  = 32'h00208333; // 14: add  x6,x1,x2
    uut.instrmem.instr_ram[6]  = 32'h402083B3; // 18: sub  x7,x1,x2
    uut.instrmem.instr_ram[7]  = 32'h0030F433; // 1C: and  x8,x1,x3
    uut.instrmem.instr_ram[8]  = 32'h0040E4B3; // 20: or   x9,x1,x4
    uut.instrmem.instr_ram[9]  = 32'h00112533; // 24: slt  x10,x2,x1
    uut.instrmem.instr_ram[10] = 32'h00702023; // 28: sw   x7,0(x0)
    uut.instrmem.instr_ram[11] = 32'h00002583; // 2C: lw   x11,0(x0)
    uut.instrmem.instr_ram[12] = 32'h00108463; // 30: beq  x1,x1,+8   (taken)
    uut.instrmem.instr_ram[13] = 32'h3E700613; // 34: addi x12,x0,999  (POISON - must be skipped)
    uut.instrmem.instr_ram[14] = 32'h06F00693; // 38: addi x13,x0,111
    uut.instrmem.instr_ram[15] = 32'h00208463; // 3C: beq  x1,x2,+8   (not taken)
    uut.instrmem.instr_ram[16] = 32'h0DE00713; // 40: addi x14,x0,222
    uut.instrmem.instr_ram[17] = 32'h14D00793; // 44: addi x15,x0,333
    uut.instrmem.instr_ram[18] = 32'h0080086F; // 48: jal  x16,+8
    uut.instrmem.instr_ram[19] = 32'h3E700893; // 4C: addi x17,x0,999  (POISON - must be skipped)
    uut.instrmem.instr_ram[20] = 32'h30900913; // 50: addi x18,x0,777
    uut.instrmem.instr_ram[21] = 32'h00000063; // 54: beq  x0,x0,0    (HALT - self loop)

    // clear data memory so the sw/lw checkpoint is deterministic
    for (j = 0; j < 64; j = j + 1)
        uut.datamem.data_ram[j] = 32'h0;

    #9;          // finish out the initial 10ns reset window
    reset = 0;
end

// -------------------------------------------------------------------------
// Checkpoint checking (runs every falling edge once reset is released)
// -------------------------------------------------------------------------
always @(negedge clk) begin
    if (!reset) begin
    case (PC)

        CP_ANDI : begin
            i = i + 1;
            seen[IDX_ANDI] = 1'b1;
            if (Result === 1) $display("1. andi implementation is correct (x3=1)");
            else begin
                $display("1. andi implementation is incorrect (got %0d, expected 1)", Result);
                fault_instrs = fault_instrs + 1;
                passed[IDX_ANDI] = 1'b0;
            end
        end

        CP_ORI : begin
            i = i + 1;
            seen[IDX_ORI] = 1'b1;
            if (Result === 13) $display("2. ori implementation is correct (x4=13)");
            else begin
                $display("2. ori implementation is incorrect (got %0d, expected 13)", Result);
                fault_instrs = fault_instrs + 1;
                passed[IDX_ORI] = 1'b0;
            end
        end

        CP_ADD : begin
            i = i + 1;
            seen[IDX_ADD] = 1'b1;
            if (Result === 2) $display("3. add implementation is correct (x6=2)");
            else begin
                $display("3. add implementation is incorrect (got %0d, expected 2)", $signed(Result));
                fault_instrs = fault_instrs + 1;
                passed[IDX_ADD] = 1'b0;
            end
        end

        CP_SUB : begin
            i = i + 1;
            seen[IDX_SUB] = 1'b1;
            if (Result === 8) $display("4. sub implementation is correct (x7=8)");
            else begin
                $display("4. sub implementation is incorrect (got %0d, expected 8)", $signed(Result));
                fault_instrs = fault_instrs + 1;
                passed[IDX_SUB] = 1'b0;
            end
        end

        CP_AND : begin
            i = i + 1;
            seen[IDX_AND] = 1'b1;
            if (Result === 1) $display("5. and implementation is correct (x8=1)");
            else begin
                $display("5. and implementation is incorrect (got %0d, expected 1)", Result);
                fault_instrs = fault_instrs + 1;
                passed[IDX_AND] = 1'b0;
            end
        end

        CP_OR : begin
            i = i + 1;
            seen[IDX_OR] = 1'b1;
            if (Result === 13) $display("6. or implementation is correct (x9=13)");
            else begin
                $display("6. or implementation is incorrect (got %0d, expected 13)", Result);
                fault_instrs = fault_instrs + 1;
                passed[IDX_OR] = 1'b0;
            end
        end

        CP_SW : begin
            i = i + 1;
            seen[IDX_SW] = 1'b1;
            if (MemWrite && DataAdr === 0 && WriteData === 8)
                $display("7. sw implementation is correct (mem[0]=8)");
            else begin
                $display("7. sw implementation is incorrect (MemWrite=%b addr=%0d data=%0d, expected MemWrite=1 addr=0 data=8)",
                          MemWrite, DataAdr, WriteData);
                fault_instrs = fault_instrs + 1;
                passed[IDX_SW] = 1'b0;
            end
        end

        CP_LW : begin
            i = i + 1;
            seen[IDX_LW] = 1'b1;
            if (Result === 8) $display("8. lw implementation is correct (x11=8)");
            else begin
                $display("8. lw implementation is incorrect (got %0d, expected 8)", Result);
                fault_instrs = fault_instrs + 1;
                passed[IDX_LW] = 1'b0;
            end
        end

        CP_BEQ_T : begin
            // just confirms we reached the branch; taken/not-taken outcome
            // is verified by which checkpoint we land on next
            seen[IDX_BEQ] = 1'b1;
            $display("9. beq (taken case) instruction fetched, checking branch target next...");
        end

        CP_AFTER_BT : begin
            i = i + 1;
            if (Result === 111) begin
                $display("9. beq implementation is correct for TAKEN branch (poison instr at 0x34 was skipped)");
            end
            else begin
                $display("9. beq implementation is incorrect for TAKEN branch (got x13=%0d, expected 111)", Result);
                fault_instrs = fault_instrs + 1;
                passed[IDX_BEQ] = 1'b0;
            end
        end

        CP_BEQ_NT : begin
            $display("10. beq (not-taken case) instruction fetched, checking fall-through next...");
        end

        CP_AFTER_BN : begin
            i = i + 1;
            if (Result === 222) begin
                $display("10. beq implementation is correct for NOT-TAKEN branch (fell through correctly)");
            end
            else begin
                $display("10. beq implementation is incorrect for NOT-TAKEN branch (got x14=%0d, expected 222)", Result);
                fault_instrs = fault_instrs + 1;
                passed[IDX_BEQ] = 1'b0;
            end
        end

        CP_JAL : begin
            i = i + 1;
            seen[IDX_JAL] = 1'b1;
            if (Result === 32'h4C) begin
                $display("11. jal implementation is correct for link register (x16=0x4C)");
            end
            else begin
                $display("11. jal implementation is incorrect for link register (got x16=0x%08h, expected 0x4C)", Result);
                fault_instrs = fault_instrs + 1;
                passed[IDX_JAL] = 1'b0;
            end
        end

        CP_AFTER_J : begin
            i = i + 1;
            if (Result === 777) begin
                $display("12. jal implementation is correct for jump target (poison instr at 0x4C was skipped)");
            end
            else begin
                $display("12. jal implementation is incorrect for jump target (got x18=%0d, expected 777)", Result);
                fault_instrs = fault_instrs + 1;
                passed[IDX_JAL] = 1'b0;
            end
        end

        CP_HALT : begin
            $display("");
            $display("Reached HALT checkpoint (0x54) - end of directed test program.");
            $display("Faulty Instructions => %0d", fault_instrs);
            $display("");
            $display("=====================================================");
            $display(" INSTRUCTION EXECUTION / COVERAGE SUMMARY");
            $display("=====================================================");
            for (j = 0; j < N_INSTR; j = j + 1) begin
                if (!seen[j])
                    $display("  %s : NOT EXECUTED", instr_names[j]);
                else if (passed[j])
                    $display("  %s : EXECUTED  -  PASS", instr_names[j]);
                else
                    $display("  %s : EXECUTED  -  FAIL", instr_names[j]);
            end
            $display("=====================================================");

            if (fault_instrs !== 0) begin
                fw = $fopen("results.txt","w");
                $fdisplay(fw, "Errors");
                $display("Error(s) encountered, please check your design!");
                $fclose(fw);
            end
            else begin
                fw = $fopen("results.txt","w");
                $fdisplay(fw, "No Errors");
                $display("No errors encountered, congratulations!");
                $fclose(fw);
            end
            $stop;
        end

    endcase
    end
end

// safety-net timeout in case the DUT never reaches the HALT checkpoint
initial begin
    #2000;
    $display("TIMEOUT: HALT checkpoint (PC=0x54) was never reached - simulation stuck.");
    $display("Faulty Instructions so far => %0d", fault_instrs);
    $stop;
end

// waveform dump for EPWave
initial begin
    $dumpfile("dump.vcd");
    $dumpvars(0, testbench);
end

endmodule
