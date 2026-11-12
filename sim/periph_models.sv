/* File: periph_models.sv
 *
 * Simulation models of the things that are wired to the SoC pins when the
 * peripheral demos run on the Tang Nano 9K:
 *
 *   - UART0 monitor: decodes uart_tx, prints it as "[UART0] <line>" and
 *     counts lines that contain "FAIL". The simulation ends when a line
 *     contains "DEMO DONE". Bytes sent by UART1 (GPIOA[0]) are logged too.
 *   - Pull-ups: every GPIO pin reads high while the SoC does not drive it
 *     (the Gowin default), as on the board.
 *   - Jumper wires: GPIOA[0] -> GPIOA[1] (UART1 TX -> RX), GPIOB[0] ->
 *     GPIOB[3] (SPI1 MOSI -> MISO) and GPIOB[7:4] -> GPIOC[7:4]. A wire only
 *     conducts while the SoC does not drive the destination pin.
 *   - 24Cxx I2C EEPROM at address 0x50 on GPIOA[2] (SDA) / GPIOA[3] (SCL).
 *   - I2S receiver on GPIOC[2:0]: checks Philips I2S framing (LRCLK changes
 *     one BCLK before the MSB, 16-bit words) and the pattern sent by
 *     i2s_demo.c (left = 0xA500 + n, right = 0x5A00 + n).
 *
 * Tests that do not use these pins are not affected.
 */


module periph_models #(
    parameter int UART_BIT_CYCLES = 15
) (
    input logic clk,
    input logic uart_tx,

    inout tri [15:0] gpioa,
    inout tri [15:0] gpiob,
    inout tri [15:0] gpioc,

    input logic [15:0] gpioa_oe,
    input logic [15:0] gpiob_oe,
    input logic [15:0] gpioc_oe
);

    // --------------------------------------------------------------------------------------------
    // |                              Pull-ups and jumper wires                                   |
    // --------------------------------------------------------------------------------------------

    // Every pin has the weak pull-up that Gowin applies by default, so a pin
    // the SoC does not drive reads high. A jumper wire makes the destination
    // follow its source while the SoC does not drive the destination.

    logic sda_low;
    int   eeprom_starts, eeprom_writes, eeprom_reads;

    for (genvar i = 0; i < 16; i++) begin : gpioa_pads
        if (i == 1) begin : uart1_rx
            assign gpioa[i] = gpioa_oe[i] ? 1'bz : gpioa[0];                   // UART1 TX -> RX
        end
        else if (i == 2) begin : i2c_sda
            assign gpioa[i] = sda_low ? 1'b0 : (gpioa_oe[i] ? 1'bz : 1'b1);    // EEPROM + pull-up
        end
        else begin : pull_up
            assign gpioa[i] = gpioa_oe[i] ? 1'bz : 1'b1;
        end
    end

    for (genvar i = 0; i < 16; i++) begin : gpiob_pads
        if (i == 3) begin : spi1_miso
            assign gpiob[i] = gpiob_oe[i] ? 1'bz : gpiob[0];                   // SPI1 MOSI -> MISO
        end
        else begin : pull_up
            assign gpiob[i] = gpiob_oe[i] ? 1'bz : 1'b1;
        end
    end

    for (genvar i = 0; i < 16; i++) begin : gpioc_pads
        if (i >= 4 && i < 8) begin : gpio_loopback
            assign gpioc[i] = gpioc_oe[i] ? 1'bz : gpiob[i];                   // GPIOB[7:4] -> GPIOC[7:4]
        end
        else begin : pull_up
            assign gpioc[i] = gpioc_oe[i] ? 1'bz : 1'b1;
        end
    end

    // --------------------------------------------------------------------------------------------
    // |                                    I2C EEPROM (0x50)                                     |
    // --------------------------------------------------------------------------------------------

    i2c_eeprom_model #(.DEV_ADDR(7'h50)) eeprom (
        .scl(gpioa[3]),
        .sda(gpioa[2]),
        .sda_low(sda_low),
        .n_starts(eeprom_starts),
        .n_writes(eeprom_writes),
        .n_reads(eeprom_reads)
    );

    // --------------------------------------------------------------------------------------------
    // |                                       I2S receiver                                       |
    // --------------------------------------------------------------------------------------------

    logic [15:0] i2s_left  [$];
    logic [15:0] i2s_right [$];
    logic [15:0] i2s_word;
    logic [15:0] i2s_left_word;
    logic        i2s_ws_now;
    logic        i2s_ws_prev = 1'b0;
    bit          i2s_left_valid = 1'b0;
    bit          i2s_synced = 1'b0;
    int          i2s_cnt = 0;
    int          i2s_framing_errors = 0;

    // Philips I2S timing, 16-bit words: LRCLK (low = left) changes one BCLK
    // before the MSB of the new word and data is sampled on the BCLK rising
    // edge. The first rising edge after an LRCLK change therefore still
    // carries the LSB of the word that is ending, so that word must be
    // exactly 16 bits long. LRCLK and BCLK are only looked at while the SoC
    // drives them.
    always @(posedge gpioc[0]) begin
        if (gpioc_oe[0] && gpioc_oe[1]) begin
            i2s_ws_now = gpioc[1];

            if (i2s_ws_now != i2s_ws_prev) begin
                if (i2s_synced) begin
                    if (i2s_cnt == 15) begin
                        i2s_word = {i2s_word[14:0], gpioc[2]};

                        if (i2s_ws_prev == 1'b0) begin
                            i2s_left_word  = i2s_word;
                            i2s_left_valid = 1'b1;
                        end
                        else if (i2s_left_valid) begin
                            i2s_left.push_back(i2s_left_word);
                            i2s_right.push_back(i2s_word);
                            i2s_left_valid = 1'b0;
                        end
                    end
                    else begin
                        if (i2s_framing_errors < 3)
                            $display("[I2S] framing error: LRCLK changed after %0d bits of the word, expected 15 plus the LSB", i2s_cnt);
                        i2s_framing_errors = i2s_framing_errors + 1;
                        i2s_left_valid = 1'b0;
                    end
                end

                i2s_synced = 1'b1;
                i2s_cnt    = 0;
            end
            else if (i2s_synced) begin
                i2s_word = {i2s_word[14:0], gpioc[2]};
                i2s_cnt  = i2s_cnt + 1;
            end

            i2s_ws_prev = i2s_ws_now;
        end
    end

    // --------------------------------------------------------------------------------------------
    // |                                       UART0 monitor                                      |
    // --------------------------------------------------------------------------------------------

    int    failures   = 0;
    bit    saw_i2s    = 0;
    string line       = "";

    function automatic bit has(string s, string sub);
        int n = s.len();
        int m = sub.len();

        if (m > n)
            return 1'b0;

        for (int i = 0; i <= n - m; i++) begin
            if (s.substr(i, i + m - 1) == sub)
                return 1'b1;
        end

        return 1'b0;
    endfunction

    task automatic check_i2s();
        int n = i2s_left.size();
        int first = -1;
        bit ok = 1'b1;

        $display("[I2S] decoded %0d frames", n);
        for (int i = 0; i < n && i < 12; i++)
            $display("[I2S]   frame %0d: left=0x%04h right=0x%04h", i, i2s_left[i], i2s_right[i]);

        if (i2s_framing_errors != 0) begin
            $display("[I2S] %0d framing errors, LRCLK must change one BCLK before the MSB: FAIL", i2s_framing_errors);
            failures++;
        end

        for (int i = 0; i < n; i++) begin
            if (first < 0 && i2s_left[i] == 16'hA500 && i2s_right[i] == 16'h5A00)
                first = i;
        end

        if (first < 0 || first + 8 > n) begin
            ok = 1'b0;
        end
        else begin
            for (int k = 0; k < 8; k++) begin
                if (i2s_left[first + k] != 16'(16'hA500 + k) ||
                    i2s_right[first + k] != 16'(16'h5A00 + k))
                    ok = 1'b0;
            end
        end

        if (ok)
            $display("[I2S] test pattern received correctly: PASS");
        else begin
            $display("[I2S] test pattern NOT received correctly: FAIL");
            failures++;
        end
    endtask

    task automatic demo_done();
        if (saw_i2s)
            check_i2s();

        if (eeprom_starts != 0)
            $display("[I2C] EEPROM model saw %0d starts, %0d byte writes, %0d byte reads",
                     eeprom_starts, eeprom_writes, eeprom_reads);

        $display("");
        if (failures == 0) begin
            $display("\033[0;32m");
            $display("PERIPHERAL DEMO PASSED");
        end
        else begin
            $display("\033[0;31m");
            $display("PERIPHERAL DEMO FAILED (%0d failing checks)", failures);
        end
        $display("\033[0m");

        $finish();
    endtask

    task automatic uart_char(input logic [7:0] ch);
        if (ch == 8'h0A) begin
            $display("[UART0] %s", line);

            if (has(line, "I2S DEMO"))
                saw_i2s = 1'b1;
            if (has(line, "FAIL"))
                failures++;
            if (has(line, "DEMO DONE"))
                demo_done();

            line = "";
        end
        else if (ch != 8'h0D) begin
            line = $sformatf("%s%c", line, ch);
        end
    endtask

    initial begin
        logic [7:0] ch;

        forever begin
            @(negedge uart_tx);
            repeat (UART_BIT_CYCLES + UART_BIT_CYCLES / 2) @(posedge clk);

            for (int i = 0; i < 8; i++) begin
                ch[i] = uart_tx;
                repeat (UART_BIT_CYCLES) @(posedge clk);
            end

            uart_char(ch);
        end
    end

    // UART1 transmitter (GPIOA[0]): log every byte seen on the wire
    initial begin
        logic [7:0] ch;

        forever begin
            @(negedge gpioa[0]);
            repeat (UART_BIT_CYCLES + UART_BIT_CYCLES / 2) @(posedge clk);

            for (int i = 0; i < 8; i++) begin
                ch[i] = gpioa[0];
                repeat (UART_BIT_CYCLES) @(posedge clk);
            end

            $display("[UART1] tx byte 0x%02h", ch);
        end
    end

endmodule


/* 24Cxx style I2C EEPROM slave: byte write, "dummy write" to set the
 * address pointer, current address read and sequential read.
 * Strict about bus timing: it only reacts to real START / STOP conditions
 * (SDA edge while SCL is high) and only changes SDA while SCL is low.
 */
module i2c_eeprom_model #(
    parameter logic [6:0] DEV_ADDR = 7'h50
) (
    input  logic scl,
    input  logic sda,
    output logic sda_low,

    output int   n_starts,
    output int   n_writes,
    output int   n_reads
);

    typedef enum int {M_IDLE, M_ADDR, M_MEMADDR, M_WRITE, M_READ} mode_t;

    logic [7:0] mem [256];
    mode_t      mode;
    logic [7:0] ptr;
    logic [7:0] shreg;
    logic [7:0] txbyte;
    int         bitcnt;
    bit         ack_slot;
    bit         rack_slot;
    bit         master_nack;
    bit         ack;
    logic       scl_q;
    logic       sda_q;

    initial begin
        for (int i = 0; i < 256; i++)
            mem[i] = 8'hFF;

        mode        = M_IDLE;
        ptr         = 8'h00;
        shreg       = 8'h00;
        txbyte      = 8'h00;
        bitcnt      = 0;
        ack_slot    = 1'b0;
        rack_slot   = 1'b0;
        master_nack = 1'b0;
        scl_q       = 1'b1;
        sda_q       = 1'b1;
        sda_low     = 1'b0;
        n_starts    = 0;
        n_writes    = 0;
        n_reads     = 0;
    end

    always @(scl or sda) begin
        if (scl && scl_q && sda_q && !sda) begin
            // START (also a repeated START)
            mode      = M_ADDR;
            bitcnt    = 0;
            ack_slot  = 1'b0;
            rack_slot = 1'b0;
            sda_low   = 1'b0;
            n_starts  = n_starts + 1;
        end
        else if (scl && scl_q && !sda_q && sda) begin
            // STOP
            mode      = M_IDLE;
            bitcnt    = 0;
            ack_slot  = 1'b0;
            rack_slot = 1'b0;
            sda_low   = 1'b0;
        end
        else if (scl && !scl_q) begin
            // SCL rising: sample SDA
            if (rack_slot) begin
                master_nack = sda;
            end
            else if (!ack_slot && (mode == M_ADDR || mode == M_MEMADDR || mode == M_WRITE)) begin
                shreg  = {shreg[6:0], sda};
                bitcnt = bitcnt + 1;
            end
        end
        else if (!scl && scl_q) begin
            // SCL falling: drive SDA
            if (rack_slot) begin
                // The master's ACK/NACK clock ended
                rack_slot = 1'b0;

                if (!master_nack) begin
                    ptr     = ptr + 8'h01;
                    txbyte  = mem[ptr];
                    n_reads = n_reads + 1;
                    bitcnt  = 1;
                    sda_low = !txbyte[7];
                end
                else begin
                    mode = M_IDLE;
                end
            end
            else if (ack_slot) begin
                // Our ACK clock ended: release SDA
                ack_slot = 1'b0;
                sda_low  = 1'b0;

                if (mode == M_READ) begin
                    txbyte  = mem[ptr];
                    n_reads = n_reads + 1;
                    bitcnt  = 1;
                    sda_low = !txbyte[7];
                end
                else begin
                    bitcnt = 0;
                end
            end
            else if (mode == M_READ) begin
                if (bitcnt < 8) begin
                    sda_low = !txbyte[7 - bitcnt];
                    bitcnt  = bitcnt + 1;
                end
                else begin
                    sda_low   = 1'b0;
                    rack_slot = 1'b1;
                    bitcnt    = 0;
                end
            end
            else if ((mode == M_ADDR || mode == M_MEMADDR || mode == M_WRITE) && bitcnt == 8) begin
                // A whole byte was received
                ack = 1'b1;

                case (mode)
                    M_ADDR: begin
                        if (shreg[7:1] == DEV_ADDR)
                            mode = shreg[0] ? M_READ : M_MEMADDR;
                        else begin
                            mode = M_IDLE;
                            ack  = 1'b0;
                        end
                    end

                    M_MEMADDR: begin
                        ptr  = shreg;
                        mode = M_WRITE;
                    end

                    default: begin
                        mem[ptr] = shreg;
                        ptr      = ptr + 8'h01;
                        n_writes = n_writes + 1;
                    end
                endcase

                bitcnt = 0;

                if (ack) begin
                    sda_low  = 1'b1;
                    ack_slot = 1'b1;
                end
            end
        end

        scl_q = scl;
        sda_q = sda;
    end

endmodule
