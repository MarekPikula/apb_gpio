/* Copyright (C) 2017 ETH Zurich, University of Bologna
 * All rights reserved.
 *
 * This code is under development and not yet released to the public.
 * Until it is released, the code is under the copyright of ETH Zurich and
 * the University of Bologna, and may contain confidential and/or unpublished
 * work. Any reuse/redistribution is strictly forbidden without written
 * permission from ETH Zurich.
 *
 * Bug fixes and contributions will eventually be released under the
 * SolderPad open hardware license in the context of the PULP platform
 * (http://www.pulp-platform.org), under the copyright of ETH Zurich and the
 * University of Bologna.
 */

`define REG_PADDIR      4'b0000 //BASEADDR+0x00
`define REG_PADIN       4'b0001 //BASEADDR+0x04
`define REG_PADOUT      4'b0010 //BASEADDR+0x08
`define REG_INTEN       4'b0011 //BASEADDR+0x0C
`define REG_INTTYPE0    4'b0100 //BASEADDR+0x10
`define REG_INTTYPE1    4'b0101 //BASEADDR+0x14
`define REG_INTSTATUS   4'b0110 //BASEADDR+0x18
`define REG_GPIOEN      4'b0111 //BASEADDR+0x1C

`define REG_PADCFG0     4'b1000 //BASEADDR+0x20
`define REG_PADCFG1     4'b1001 //BASEADDR+0x24
`define REG_PADCFG2     4'b1010 //BASEADDR+0x28
`define REG_PADCFG3     4'b1011 //BASEADDR+0x2C
`define REG_PADCFG4     4'b1100 //BASEADDR+0x30
`define REG_PADCFG5     4'b1101 //BASEADDR+0x34
`define REG_PADCFG6     4'b1110 //BASEADDR+0x38
`define REG_PADCFG7     4'b1111 //BASEADDR+0x3C

module apb_gpio
#(
    parameter APB_ADDR_WIDTH = 12  //APB slaves are 4KB by default
)
(
    input  logic                      HCLK,
    input  logic                      HRESETn,

    input  logic                      dft_cg_enable_i,

    input  logic [APB_ADDR_WIDTH-1:0] PADDR,
    input  logic               [31:0] PWDATA,
    input  logic                      PWRITE,
    input  logic                      PSEL,
    input  logic                      PENABLE,
    output logic               [31:0] PRDATA,
    output logic                      PREADY,
    output logic                      PSLVERR,

    input  logic               [31:0] gpio_in,
    output logic               [31:0] gpio_in_sync,
    output logic               [31:0] gpio_out,
    output logic               [31:0] gpio_dir,
    output logic      [31:0]    [5:0] gpio_padcfg,
    output logic                      interrupt
);

    logic [31:0] r_gpio_inten;
    logic [31:0] r_gpio_inttype0;
    logic [31:0] s_gpio_inttype0;
    logic [31:0] r_gpio_inttype1;
    logic [31:0] s_gpio_inttype1;
    logic [31:0] r_gpio_out;
    logic [31:0] r_gpio_dir;
    logic [31:0] r_gpio_sync0;
    logic [31:0] r_gpio_sync1;
    logic [31:0] r_gpio_in;
    logic [31:0] r_gpio_en;
    logic [31:0] s_gpio_rise;
    logic [31:0] s_gpio_fall;
    logic [31:0] s_is_int_rise;
    logic [31:0] s_is_int_rifa;
    logic [31:0] s_is_int_fall;
    logic [31:0] s_is_int_all;
    logic        s_rise_int;

    logic  [3:0] s_apb_addr;

    logic [31:0] r_status;

    logic [7:0] s_clk_en;
    logic [7:0] s_clkg;    

    genvar i;

    assign s_apb_addr = PADDR[5:2];

    assign gpio_in_sync = r_gpio_sync1;

    assign s_gpio_rise =  r_gpio_sync1 & ~r_gpio_in; //foreach input check if rising edge
    assign s_gpio_fall = ~r_gpio_sync1 &  r_gpio_in; //foreach input check if falling edge

    assign s_is_int_fall =  ~s_gpio_inttype1 & ~s_gpio_inttype0 & s_gpio_fall;                 // inttype 00 fall
    assign s_is_int_rise =  ~s_gpio_inttype1 &  s_gpio_inttype0 & s_gpio_rise;                 // inttype 01 rise
    assign s_is_int_rifa =   s_gpio_inttype1 & ~s_gpio_inttype0 & (s_gpio_rise | s_gpio_fall); // inttype 10 rise

    //check if bit if interrupt is enable and if interrupt specified by inttype occurred
    assign s_is_int_all  = r_gpio_inten & r_gpio_en & (s_is_int_rise | s_is_int_fall | s_is_int_rifa);

    //is any bit enabled and specified interrupt happened?
    assign s_rise_int = |s_is_int_all;

    assign interrupt = s_rise_int;

    always_comb begin
        for (int i=0;i<16;i++)
        begin
            s_gpio_inttype0[i]    = r_gpio_inttype0[i*2];
            s_gpio_inttype0[16+i] = r_gpio_inttype1[i*2];
            s_gpio_inttype1[i]    = r_gpio_inttype0[i*2+1];
            s_gpio_inttype1[16+i] = r_gpio_inttype1[i*2+1];
        end    
    end

    always_ff @(posedge HCLK, negedge HRESETn)
    begin
        if(~HRESETn)
        begin
            r_status  <=  'h0;
        end
        else
        begin
            if (s_rise_int ) //rise interrupt if not already rise
            begin
                r_status  <= r_status | s_is_int_all;
            end
            else if (PSEL && PENABLE && !PWRITE && (s_apb_addr == `REG_INTSTATUS)) //clears int if status is read
            begin
               r_status  <=  'h0;
            end
        end
    end

    generate
        for(i=0;i<8;i++)
            pulp_clock_gating i_clk_gate
            (
                .clk_i(HCLK),
                .en_i(s_clk_en[i]),
                .test_en_i(dft_cg_enable_i),
                .clk_o(s_clkg[i])
            );
    endgenerate

    always_comb begin : proc_clk_en
        for (int i=0;i<8;i++)
            s_clk_en[i] = r_gpio_en[i*4] | r_gpio_en[i*4+1] | r_gpio_en[i*4+2] | r_gpio_en[i*4+3];
    end


    always_ff @(posedge s_clkg[0], negedge HRESETn)
    begin
        if(~HRESETn)
        begin
            r_gpio_sync0[3:0]    <= 'h0;
            r_gpio_sync1[3:0]    <= 'h0;
            r_gpio_in[3:0]       <= 'h0;
        end
        else 
        begin
            r_gpio_sync0[3:0]    <= gpio_in[3:0];      //first 2 sync for metastability resolving
            r_gpio_sync1[3:0]    <= r_gpio_sync0[3:0];
            r_gpio_in[3:0]       <= r_gpio_sync1[3:0]; //last reg used for edge detection
        end
    end //always

    always_ff @(posedge s_clkg[1], negedge HRESETn)
    begin
        if(~HRESETn)
        begin
            r_gpio_sync0[7:4]    <= 'h0;
            r_gpio_sync1[7:4]    <= 'h0;
            r_gpio_in[7:4]       <= 'h0;
        end
        else 
        begin
            r_gpio_sync0[7:4]    <= gpio_in[7:4];      //first 2 sync for metastability resolving
            r_gpio_sync1[7:4]    <= r_gpio_sync0[7:4];
            r_gpio_in[7:4]       <= r_gpio_sync1[7:4]; //last reg used for edge detection
        end
    end //always

    always_ff @(posedge s_clkg[2], negedge HRESETn)
    begin
        if(~HRESETn)
        begin
            r_gpio_sync0[11:8]    <= 'h0;
            r_gpio_sync1[11:8]    <= 'h0;
            r_gpio_in[11:8]       <= 'h0;
        end
        else 
        begin
            r_gpio_sync0[11:8]    <= gpio_in[11:8];      //first 2 sync for metastability resolving
            r_gpio_sync1[11:8]    <= r_gpio_sync0[11:8];
            r_gpio_in[11:8]       <= r_gpio_sync1[11:8]; //last reg used for edge detection
        end
    end //always

    always_ff @(posedge s_clkg[3], negedge HRESETn)
    begin
        if(~HRESETn)
        begin
            r_gpio_sync0[15:12]    <= 'h0;
            r_gpio_sync1[15:12]    <= 'h0;
            r_gpio_in[15:12]       <= 'h0;
        end
        else 
        begin
            r_gpio_sync0[15:12]    <= gpio_in[15:12];      //first 2 sync for metastability resolving
            r_gpio_sync1[15:12]    <= r_gpio_sync0[15:12];
            r_gpio_in[15:12]       <= r_gpio_sync1[15:12]; //last reg used for edge detection
        end
    end //always

    always_ff @(posedge s_clkg[4], negedge HRESETn)
    begin
        if(~HRESETn)
        begin
            r_gpio_sync0[19:16]    <= 'h0;
            r_gpio_sync1[19:16]    <= 'h0;
            r_gpio_in[19:16]       <= 'h0;
        end
        else 
        begin
            r_gpio_sync0[19:16]    <= gpio_in[19:16];      //first 2 sync for metastability resolving
            r_gpio_sync1[19:16]    <= r_gpio_sync0[19:16];
            r_gpio_in[19:16]       <= r_gpio_sync1[19:16]; //last reg used for edge detection
        end
    end //always

    always_ff @(posedge s_clkg[5], negedge HRESETn)
    begin
        if(~HRESETn)
        begin
            r_gpio_sync0[23:20]    <= 'h0;
            r_gpio_sync1[23:20]    <= 'h0;
            r_gpio_in[23:20]       <= 'h0;
        end
        else 
        begin
            r_gpio_sync0[23:20]    <= gpio_in[23:20];      //first 2 sync for metastability resolving
            r_gpio_sync1[23:20]    <= r_gpio_sync0[23:20];
            r_gpio_in[23:20]       <= r_gpio_sync1[23:20]; //last reg used for edge detection
        end
    end //always

    always_ff @(posedge s_clkg[6], negedge HRESETn)
    begin
        if(~HRESETn)
        begin
            r_gpio_sync0[27:24]    <= 'h0;
            r_gpio_sync1[27:24]    <= 'h0;
            r_gpio_in[27:24]       <= 'h0;
        end
        else 
        begin
            r_gpio_sync0[27:24]    <= gpio_in[27:24];      //first 2 sync for metastability resolving
            r_gpio_sync1[27:24]    <= r_gpio_sync0[27:24];
            r_gpio_in[27:24]       <= r_gpio_sync1[27:24]; //last reg used for edge detection
        end
    end //always

    always_ff @(posedge s_clkg[7], negedge HRESETn)
    begin
        if(~HRESETn)
        begin
            r_gpio_sync0[31:28]    <= 'h0;
            r_gpio_sync1[31:28]    <= 'h0;
            r_gpio_in[31:28]       <= 'h0;
        end
        else 
        begin
            r_gpio_sync0[31:28]    <= gpio_in[31:28];      //first 2 sync for metastability resolving
            r_gpio_sync1[31:28]    <= r_gpio_sync0[31:28];
            r_gpio_in[31:28]       <= r_gpio_sync1[31:28]; //last reg used for edge detection
        end
    end //always

    always_ff @(posedge HCLK, negedge HRESETn) 
    begin
        if(~HRESETn) 
        begin
            r_gpio_inten    <=  '0;
            r_gpio_inttype0 <=  '0;
            r_gpio_inttype1 <=  '0;
            r_gpio_out      <=  '0;
            r_gpio_dir      <=  '0;
            r_gpio_en       <=  '0;
            for (int i=0;i<32;i++)
                gpio_padcfg[i]  <=  6'b000010; // DS=high, PE=disabled
        end
        else
        begin
            if (PSEL && PENABLE && PWRITE)
            begin
                case (s_apb_addr)
                `REG_PADDIR:
                    r_gpio_dir      <= PWDATA;
                `REG_PADOUT:
                    r_gpio_out      <= PWDATA;
                `REG_INTEN:
                    r_gpio_inten    <= PWDATA;
                `REG_INTTYPE0:
                    r_gpio_inttype0 <= PWDATA;
                `REG_INTTYPE1:
                    r_gpio_inttype1 <= PWDATA;
                `REG_GPIOEN:
                    r_gpio_en       <= PWDATA;
                `REG_PADCFG0:
                begin
                    gpio_padcfg[0]  <= PWDATA[5:0]  ;
                    gpio_padcfg[1]  <= PWDATA[13:8] ;
                    gpio_padcfg[2]  <= PWDATA[21:16];
                    gpio_padcfg[3]  <= PWDATA[29:24];
                end
                `REG_PADCFG1:
                begin
                    gpio_padcfg[4]  <= PWDATA[5:0]  ;
                    gpio_padcfg[5]  <= PWDATA[13:8] ;
                    gpio_padcfg[6]  <= PWDATA[21:16];
                    gpio_padcfg[7]  <= PWDATA[29:24];
                end
                `REG_PADCFG2:
                begin
                    gpio_padcfg[8]  <= PWDATA[5:0]  ;
                    gpio_padcfg[9]  <= PWDATA[13:8] ;
                    gpio_padcfg[10] <= PWDATA[21:16];
                    gpio_padcfg[11] <= PWDATA[29:24];
                end
                `REG_PADCFG3:
                begin
                    gpio_padcfg[12] <= PWDATA[5:0]  ;
                    gpio_padcfg[13] <= PWDATA[13:8] ;
                    gpio_padcfg[14] <= PWDATA[21:16];
                    gpio_padcfg[15] <= PWDATA[29:24];
                end
                `REG_PADCFG4:
                begin
                    gpio_padcfg[16] <= PWDATA[5:0]  ;
                    gpio_padcfg[17] <= PWDATA[13:8] ;
                    gpio_padcfg[18] <= PWDATA[21:16];
                    gpio_padcfg[19] <= PWDATA[29:24];
                end
                `REG_PADCFG5:
                begin
                    gpio_padcfg[20] <= PWDATA[5:0]  ;
                    gpio_padcfg[21] <= PWDATA[13:8] ;
                    gpio_padcfg[22] <= PWDATA[21:16];
                    gpio_padcfg[23] <= PWDATA[29:24];
                end
                `REG_PADCFG6:
                begin
                    gpio_padcfg[24] <= PWDATA[5:0]  ;
                    gpio_padcfg[25] <= PWDATA[13:8] ;
                    gpio_padcfg[26] <= PWDATA[21:16];
                    gpio_padcfg[27] <= PWDATA[29:24];
                end
                `REG_PADCFG7:
                begin
                    gpio_padcfg[28]  <= PWDATA[5:0]  ;
                    gpio_padcfg[29]  <= PWDATA[13:8] ;
                    gpio_padcfg[30]  <= PWDATA[21:16];
                    gpio_padcfg[31]  <= PWDATA[29:24];
                end
                endcase
            end
        end
    end //always

    always_comb
    begin
        case (s_apb_addr)
        `REG_PADDIR:
            PRDATA = r_gpio_dir;
        `REG_PADIN:
            PRDATA = r_gpio_in;
        `REG_PADOUT:
            PRDATA = r_gpio_out;
        `REG_INTEN:
            PRDATA = r_gpio_inten;
        `REG_INTTYPE0:
            PRDATA = r_gpio_inttype0;
        `REG_INTTYPE1:
            PRDATA = r_gpio_inttype1;
        `REG_INTSTATUS:
            PRDATA = r_status;
        `REG_GPIOEN:
            PRDATA = r_gpio_en;
        `REG_PADCFG0:
            PRDATA = {2'b00,gpio_padcfg[3],2'b00,gpio_padcfg[2],2'b00,gpio_padcfg[1],2'b00,gpio_padcfg[0]};
        `REG_PADCFG1:
            PRDATA = {2'b00,gpio_padcfg[7],2'b00,gpio_padcfg[6],2'b00,gpio_padcfg[5],2'b00,gpio_padcfg[4]};
        `REG_PADCFG2:
            PRDATA = {2'b00,gpio_padcfg[11],2'b00,gpio_padcfg[10],2'b00,gpio_padcfg[9],2'b00,gpio_padcfg[8]};
        `REG_PADCFG3:
            PRDATA = {2'b00,gpio_padcfg[15],2'b00,gpio_padcfg[14],2'b00,gpio_padcfg[13],2'b00,gpio_padcfg[12]};
        `REG_PADCFG4:
            PRDATA = {2'b00,gpio_padcfg[19],2'b00,gpio_padcfg[18],2'b00,gpio_padcfg[17],2'b00,gpio_padcfg[16]};
        `REG_PADCFG5:
            PRDATA = {2'b00,gpio_padcfg[23],2'b00,gpio_padcfg[22],2'b00,gpio_padcfg[21],2'b00,gpio_padcfg[20]};
        `REG_PADCFG6:
            PRDATA = {2'b00,gpio_padcfg[27],2'b00,gpio_padcfg[26],2'b00,gpio_padcfg[25],2'b00,gpio_padcfg[24]};
        `REG_PADCFG7:
            PRDATA = {2'b00,gpio_padcfg[31],2'b00,gpio_padcfg[30],2'b00,gpio_padcfg[29],2'b00,gpio_padcfg[28]};
        default:
            PRDATA = 'h0;
        endcase
    end

    assign gpio_out = r_gpio_out;
    assign gpio_dir = r_gpio_dir;

    assign PREADY  = 1'b1;
    assign PSLVERR = 1'b0;

endmodule

