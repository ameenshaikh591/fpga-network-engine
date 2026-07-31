`timescale 1ns/1ps

module tb_udp_axi_reader;
    localparam time CLK_PERIOD = 10ns;

    logic clk = 0;
    logic resetn = 0;

    logic request_valid;
    logic request_ready;
    logic [31:0] request_address;
    logic [15:0] request_length;

    logic data_valid;
    logic data_ready;
    logic [31:0] data;
    logic [1:0] valid_bytes;
    logic data_last;
    logic read_done;
    logic read_error;

    logic [31:0] araddr;
    logic [7:0] arlen;
    logic [2:0] arsize;
    logic [1:0] arburst;
    logic [2:0] arprot;
    logic arvalid;
    logic arready;
    logic [31:0] rdata;
    logic [1:0] rresp;
    logic rlast;
    logic rvalid;
    logic rready;

    logic burst_active;
    logic [31:0] burst_address;
    logic [8:0] beats_remaining;
    int unsigned burst_count;
    int unsigned output_count;

    always #(CLK_PERIOD/2) clk = ~clk;

    udp_axi_reader dut (
        .axi_aclk(clk), .axi_aresetn(resetn),
        .i_read_req_valid(request_valid),
        .o_read_req_ready(request_ready),
        .i_read_addr(request_address),
        .i_read_length(request_length),
        .o_read_data_valid(data_valid),
        .i_read_data_ready(data_ready),
        .o_read_data(data),
        .o_read_valid_bytes(valid_bytes),
        .o_read_last(data_last),
        .o_read_done(read_done),
        .o_read_error(read_error),
        .M_AXI_ARADDR(araddr), .M_AXI_ARLEN(arlen),
        .M_AXI_ARSIZE(arsize), .M_AXI_ARBURST(arburst),
        .M_AXI_ARPROT(arprot), .M_AXI_ARVALID(arvalid),
        .M_AXI_ARREADY(arready), .M_AXI_RDATA(rdata),
        .M_AXI_RRESP(rresp), .M_AXI_RLAST(rlast),
        .M_AXI_RVALID(rvalid), .M_AXI_RREADY(rready)
    );

    function automatic logic [31:0] word_for_address(input logic [31:0] address);
        return 32'hA500_0000 | (address >> 2);
    endfunction

    assign arready = !burst_active;

    // Zero-wait-state burst source.  Once RVALID is asserted, all response
    // signals remain stable until the reader accepts the beat.
    always @(posedge clk) begin
        if (!resetn) begin
            burst_active <= 0;
            burst_address <= 0;
            beats_remaining <= 0;
            burst_count <= 0;
            rdata <= 0;
            rresp <= 0;
            rlast <= 0;
            rvalid <= 0;
        end else begin
            if (arvalid && arready) begin
                assert (arsize == 3'b010 && arburst == 2'b01)
                    else $fatal(1, "Unexpected AXI read attributes");
                case (burst_count)
                    0: assert (araddr == 32'h0000_3FF8 && arlen == 8'd1)
                           else $fatal(1, "First burst did not stop at 4-KiB boundary");
                    1: assert (araddr == 32'h0000_4000 && arlen == 8'd3)
                           else $fatal(1, "Second burst shape was incorrect");
                    default: $fatal(1, "Unexpected extra AXI burst");
                endcase
                burst_count <= burst_count + 1;
                burst_active <= 1;
                burst_address <= araddr;
                beats_remaining <= {1'b0, arlen} + 9'd1;
                rdata <= word_for_address(araddr);
                rresp <= 2'b00;
                rlast <= (arlen == 0);
                rvalid <= 1;
            end else if (rvalid && rready) begin
                if (beats_remaining == 1) begin
                    burst_active <= 0;
                    beats_remaining <= 0;
                    rvalid <= 0;
                    rlast <= 0;
                end else begin
                    burst_address <= burst_address + 4;
                    beats_remaining <= beats_remaining - 1;
                    rdata <= word_for_address(burst_address + 4);
                    rlast <= (beats_remaining == 2);
                end
            end
        end
    end

    // Check the reader's logical output stream, including the partial final
    // word of this 21-byte request.
    always @(posedge clk) begin
        if (!resetn) begin
            output_count <= 0;
        end else if (data_valid && data_ready) begin
            assert (data == word_for_address(32'h0000_3FF8 + output_count * 4))
                else $fatal(1, "Output data mismatch at word %0d", output_count);
            assert (data_last == (output_count == 5))
                else $fatal(1, "Logical last mismatch at word %0d", output_count);
            assert (valid_bytes == ((output_count == 5) ? 2'b01 : 2'b00))
                else $fatal(1, "Valid-byte count mismatch at word %0d", output_count);
            output_count <= output_count + 1;
        end
    end

    initial begin
        request_valid = 0;
        request_address = 0;
        request_length = 0;
        data_ready = 0;

        repeat (5) @(posedge clk);
        resetn <= 1;
        repeat (2) @(posedge clk);

        request_address <= 32'h0000_3FF8;
        request_length <= 16'd21;
        request_valid <= 1;
        do @(posedge clk); while (!request_ready);
        request_valid <= 0;

        // Keep the consumer stalled until both elastic-buffer entries fill.
        wait (data_valid && !rready);
        repeat (2) @(posedge clk);
        assert (!rready) else $fatal(1, "Full elastic buffer asserted AXI RREADY");

        // Changing downstream ready must not change AXI RREADY combinationally.
        @(negedge clk);
        data_ready <= 1;
        #1ns;
        assert (!rready)
            else $fatal(1, "Combinational ready path crossed the elastic buffer");

        // Once draining begins, simultaneous push/pop must sustain one word
        // on every clock despite the registered ready boundary.
        for (int index = 0; index < 6; index++) begin
            @(posedge clk);
            assert (data_valid)
                else $fatal(1, "Elastic buffer inserted a throughput bubble");
        end

        wait (read_done);
        @(posedge clk);
        assert (!read_error) else $fatal(1, "Reader reported an unexpected error");
        assert (output_count == 6) else $fatal(1, "Incorrect output word count");
        assert (burst_count == 2) else $fatal(1, "Incorrect burst count");

        $display("SUCCESS: AXI burst splitting and two-entry elastic buffering completed");
        $finish;
    end

    initial begin
        #20us;
        $fatal(1, "Timed out");
    end
endmodule
