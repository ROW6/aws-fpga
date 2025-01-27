// Amazon FPGA Hardware Development Kit
//
// Copyright 2016 Amazon.com, Inc. or its affiliates. All Rights Reserved.
//
// Licensed under the Amazon Software License (the "License"). You may not use
// this file except in compliance with the License. A copy of the License is
// located at
//
//    http://aws.amazon.com/asl/
//
// or in the "license" file accompanying this file. This file is distributed on
// an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
// implied. See the License for the specific language governing permissions and
// limitations under the License.

// This test initiates dma and pcim traffic in parallel.

module test_host_pcim();

`define CFG_REG           64'h00
`define CNTL_REG          64'h08
`define NUM_INST          64'h10
`define MAX_RD_REQ        64'h14

`define WR_INSTR_INDEX    64'h1c
`define WR_ADDR_LOW       64'h20
`define WR_ADDR_HIGH      64'h24
`define WR_DATA           64'h28
`define WR_LEN            64'h2c

`define RD_INSTR_INDEX    64'h3c
`define RD_ADDR_LOW       64'h40
`define RD_ADDR_HIGH      64'h44
`define RD_DATA           64'h48
`define RD_LEN            64'h4c

`define RD_ERR            64'hb0
`define RD_ERR_ADDR_LOW   64'hb4
`define RD_ERR_ADDR_HIGH  64'hb8
`define RD_ERR_INDEX      64'hbc

`define WR_CYCLE_CNT_LOW  64'hf0
`define WR_CYCLE_CNT_HIGH 64'hf4
`define RD_CYCLE_CNT_LOW  64'hf8
`define RD_CYCLE_CNT_HIGH 64'hfc

`define WR_START_BIT   32'h00000001
`define RD_START_BIT   32'h00000002
   
   import tb_type_defines_pkg::*;

   int         error_count;
   int         timeout_count;

   logic [3:0] status;

   //transfer1 - length less than 64 byte.
   int         len0 = 17;
   //transfer2 - length between 64 and 256 bytes.
   int         len1 = 128;
   //transfer3 - length greater than 4k bytes.
   int         len2 = 6000;
   //transfer4 - length between 256 and 512 bytes.
   int         len3 = 300;
   
   logic       ddr_ready;
   logic       rdata;

   logic [63:0]  pcim_addr;
   logic [31:0]  pcim_data;

   logic [31:0]  read_data;

   logic [63:0]  cycle_count;
   logic [63:0]  error_addr;

   logic [3:0]   error_index;

   int           fail;

   int           wr_len;
   int           rd_len;
   
   initial begin

      logic [63:0] host_memory_buffer_address;


      tb.power_up(.clk_recipe_a(ClockRecipe::A1),
                  .clk_recipe_b(ClockRecipe::B0),
                  .clk_recipe_c(ClockRecipe::C0));

      tb.nsec_delay(1000);
      tb.poke_stat(.addr(8'h0c), .ddr_idx(0), .data(32'h0000_0000));
      tb.poke_stat(.addr(8'h0c), .ddr_idx(1), .data(32'h0000_0000));
      tb.poke_stat(.addr(8'h0c), .ddr_idx(2), .data(32'h0000_0000));

      // de-select the ATG hardware

      tb.poke_ocl(.addr(64'h130), .data(0));
      tb.poke_ocl(.addr(64'h230), .data(0));
      tb.poke_ocl(.addr(64'h330), .data(0));
      tb.poke_ocl(.addr(64'h430), .data(0));

      // AXI_MEMORY_MODEL is used to bypass DDR micron models and run with AXI memory models. More information can be found in the readme.md
      
`ifndef AXI_MEMORY_MODEL      
      // allow memory to initialize
      tb.nsec_delay(27000);
`endif
      
      $display("[%t] : Initializing buffers", $realtime);
      
      host_memory_buffer_address = 64'h0;

         #100ns;

         //PCIM test 
         
         $display("[%t] : Programming cl_tst registers for PCIe", $realtime);
         
         pcim_addr = 64'h0000_0000_1234_0000;
         pcim_data = 32'h6c93_af50;

         // Enable Incr ID mode, Sync mode, and Read Compare
         tb.poke_ocl(.addr(`CFG_REG), .data(32'h0100_0018));

         // Set the max number of read requests
         tb.poke_ocl(.addr(`MAX_RD_REQ), .data(32'h0000_000f));

         tb.poke_ocl(.addr(`WR_INSTR_INDEX), .data(32'h0000_0000));   // write index
         tb.poke_ocl(.addr(`WR_ADDR_LOW), .data(pcim_addr[31:0]));    // write address low
         tb.poke_ocl(.addr(`WR_ADDR_HIGH), .data(pcim_addr[63:32]));  // write address high
         tb.poke_ocl(.addr(`WR_DATA), .data(pcim_data[31:0]));        // write data
         tb.poke_ocl(.addr(`WR_LEN), .data(32'h0000_0001));           // write 128 bytes

         pcim_addr = 64'h0000_0000_1234_0000;
         pcim_data = 32'h6c93_af50;
         
         tb.poke_ocl(.addr(`RD_INSTR_INDEX), .data(32'h0000_0000));   // read index
         tb.poke_ocl(.addr(`RD_ADDR_LOW), .data(pcim_addr[31:0]));    // read address low
         tb.poke_ocl(.addr(`RD_ADDR_HIGH), .data(pcim_addr[63:32]));  // read address high
         tb.poke_ocl(.addr(`RD_DATA), .data(pcim_data[31:0]));        // read data
         tb.poke_ocl(.addr(`RD_LEN), .data(32'h0000_0001));           // read 128*16 bytes

         // Number of instructions, zero based ([31:16] for read, [15:0] for write)
         tb.poke_ocl(.addr(`NUM_INST), .data(32'h0000_0000));

         // Start writes and reads
         tb.poke_ocl(.addr(`CNTL_REG), .data(`WR_START_BIT));
         //Even in SYNC mode ATG doesn't wait for write response before issuing read transactions.
	 // adding 500ns wait to account for random back pressure from sh_bfm on write address & write data channels.
         $display("[%t] : Waiting for PCIe write activity to complete", $realtime);
         #500ns;
         timeout_count = 0;

         do begin
            tb.peek_ocl(.addr(`CNTL_REG), .data(read_data));
            timeout_count++;
         end while ((read_data[2:0] !== 3'b000) && (timeout_count < 100));
         
         if ((timeout_count == 100) && (read_data[2:0] !== 3'b000)) begin
            $error("[%t] : *** ERROR *** Timeout waiting for writes to complete.", $realtime);
            error_count++;
         end 
           
         tb.poke_ocl(.addr(`CNTL_REG), .data(`RD_START_BIT));
         // adding 500ns wait to account for random back pressure from sh_bfm on read request channel.
         $display("[%t] : Waiting for PCIe read activity to complete", $realtime);
         #500ns;
         
         timeout_count = 0;
         do begin
            tb.peek_ocl(.addr(`CNTL_REG), .data(read_data));
            timeout_count++;
         end while ((read_data[2:0] !== 3'b000) && (timeout_count < 100));

         if ((timeout_count == 100) && (read_data[2:0] !== 3'b000)) begin
            $error("[%t] : *** ERROR *** Timeout waiting for reads to complete.", $realtime);
            error_count++;
         end else begin
            // Stop reads and writes ([1] for reads, [0] for writes)
            tb.poke_ocl(.addr(`CNTL_REG), .data(32'h0000_0000));

            $display("[%t] : Checking some register values", $realtime);

            cycle_count = 64'h0;
            // Check that the write timer value is non-zero
            tb.peek_ocl(.addr(`WR_CYCLE_CNT_LOW), .data(read_data));
            cycle_count[31:0] = read_data;
            tb.peek_ocl(.addr(`WR_CYCLE_CNT_HIGH), .data(read_data));
            cycle_count[63:32] = read_data;
	    $display("[%t] :[INFO]:Write Timer Value is 0x%016x", $realtime, cycle_count);
            if (cycle_count == 64'h0) begin
               $error("[%t] : *** ERROR *** Write Timer value was 0x0 at end of test.", $realtime);
               error_count++;
            end

            cycle_count = 64'h0;
            // Check that the read timer value is non-zero
            tb.peek_ocl(.addr(`RD_CYCLE_CNT_LOW), .data(read_data));
            cycle_count[31:0] = read_data;
            tb.peek_ocl(.addr(`RD_CYCLE_CNT_HIGH), .data(read_data));
            cycle_count[63:32] = read_data;
	    $display("[%t] :[INFO]:Read Timer Value is 0x%016x", $realtime, cycle_count);
            if (cycle_count == 64'h0) begin
               $error("[%t] : *** ERROR *** Read Timer value was 0x0 at end of test.", $realtime);
               error_count++;
            end

            $display("[%t] : Checking for read compare errors", $realtime);

            // Check for compare error
            tb.peek_ocl(.addr(`RD_ERR), .data(read_data));
	    $display("[%t] :[INFO]:RD_ERR register is 0x%016x", $realtime, read_data);
            if (read_data != 32'h0000_0000) begin
               tb.peek_ocl(.addr(`RD_ERR_ADDR_LOW), .data(read_data));
               error_addr[31:0] = read_data;
               tb.peek_ocl(.addr(`RD_ERR_ADDR_HIGH), .data(read_data));
               error_addr[63:32] = read_data;
	       $display("[%t] :[INFO]:Error Addr Register Value is 0x%016x", $realtime, error_addr);
               tb.peek_ocl(.addr(`RD_ERR_INDEX), .data(read_data));
               error_index = read_data[3:0];
               $error("[%t] : *** ERROR *** Read compare error from address 0x%016x, index 0x%1x", $realtime, error_addr, error_index);
               error_count++;
            end
         end // else: !if((timeout_count == 100) && (read_data[2:0] !== 3'b000))
      // Power down
      #500ns;
      tb.power_down();

      //---------------------------
      // Report pass/fail status
      //---------------------------
      $display("[%t] : Checking total error count...", $realtime);
      if (error_count > 0) begin
         fail = 1;
      end
      $display("[%t] : Detected %3d errors during this test", $realtime, error_count);

      if (fail || (tb.chk_prot_err_stat())) begin
         $error("[%t] : *** TEST FAILED ***", $realtime);
      end else begin
         $display("[%t] : *** TEST PASSED ***", $realtime);
      end

      $finish;
   end // initial begin

endmodule // test_host_pcim
