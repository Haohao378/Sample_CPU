`include "lib/defines.vh"

module EX(
    input wire clk,                 
    input wire rst,                 
    input wire [`StallBus-1:0] stall, 

    input wire [`ID_TO_EX_WD-1:0] id_to_ex_bus, 

    output wire [`EX_TO_MEM_WD-1:0] ex_to_mem_bus, 
    output wire [37:0] ex_to_id_bus, 

    output wire data_sram_en,       
    output wire [3:0] data_sram_wen,
    output wire [31:0] data_sram_addr, 
    output wire [31:0] data_sram_wdata,
    output wire inst_is_load,       
    
    output wire stallreq_for_ex,    
    output wire [65:0]ex_to_mem1,   
    output wire [65:0]ex_to_id_2,   
    output wire ready_ex_to_id      
);

    reg [`ID_TO_EX_WD-1:0] id_to_ex_bus_r; 

    always @ (posedge clk) begin
        if (rst) begin
            id_to_ex_bus_r <= `ID_TO_EX_WD'b0;
        end
        else if (stall[2]==`Stop && stall[3]==`NoStop) begin
            id_to_ex_bus_r <= `ID_TO_EX_WD'b0;
        end
        else if (stall[2]==`NoStop) begin
            id_to_ex_bus_r <= id_to_ex_bus;
        end
    end

    wire [31:0] ex_pc, inst;        
    wire [11:0] alu_op;             
    wire [2:0] sel_alu_src1;        
    wire [3:0] sel_alu_src2;        
    wire data_ram_en;               
    wire [3:0] data_ram_wen;        
    wire [3:0] data_ram_read;       
    wire rf_we;                     
    wire [4:0] rf_waddr;            
    wire sel_rf_res;                
    wire [31:0] rf_rdata1, rf_rdata2; 
    reg is_in_delayslot;            
    wire [1:0] lo_hi_r;             
    wire [1:0] lo_hi_w;             
    wire w_hi_we;                   
    wire w_lo_we;                   
    wire w_hi_we3;                  
    wire w_lo_we3;                  
    wire [31:0] hi_i;               
    wire [31:0] lo_i;               
    wire[31:0] hi_o;                
    wire[31:0] lo_o;                

    assign {
        ex_pc,          
        inst,           
        alu_op,         
        sel_alu_src1,   
        sel_alu_src2,   
        data_ram_en,    
        data_ram_wen,   
        rf_we,          
        rf_waddr,       
        sel_rf_res,     
        rf_rdata1,      
        rf_rdata2,      
        lo_hi_r,        
        lo_hi_w,        
        lo_o,           
        hi_o,           
        data_ram_read   
    } = id_to_ex_bus_r;
    
    assign w_lo_we3 = 1'b0; 
    assign w_hi_we3 = 1'b0; 
    assign inst_is_load = 1'b0; 
    
    wire [31:0] imm_sign_extend, imm_zero_extend, sa_zero_extend;
    assign imm_sign_extend = {{16{inst[15]}},inst[15:0]}; 
    assign imm_zero_extend = {16'b0, inst[15:0]};         
    assign sa_zero_extend = {27'b0,inst[10:6]};           

    wire [31:0] alu_src1, alu_src2; 
    wire [31:0] alu_result, ex_result; 

    // --- ALU 输入选择逻辑 ---
    assign alu_src1 = sel_alu_src1[1] ? ex_pc :           
                      sel_alu_src1[2] ? sa_zero_extend :  
                      rf_rdata1;                          

    assign alu_src2 = sel_alu_src2[1] ? imm_sign_extend : 
                      sel_alu_src2[2] ? 32'd8 :           
                      sel_alu_src2[3] ? imm_zero_extend : 
                      rf_rdata2;                          
    
    alu u_alu(
        .alu_control (alu_op ),      
        .alu_src1    (alu_src1    ), 
        .alu_src2    (alu_src2    ), 
        .alu_result  (alu_result  )  
    );

    assign ex_result = alu_result;

    assign data_sram_en = 1'b0; 
    assign data_sram_wen = 4'b0000;
    assign data_sram_addr = ex_result ; 
    assign data_sram_wdata = 32'b0;

    assign ex_to_mem_bus = {
        ex_pc,          
        data_ram_en,    
        data_ram_wen,   
        sel_rf_res,     
        rf_we,          
        rf_waddr,       
        ex_result,      
        data_ram_read   
    };
   
    assign ex_to_id_bus = {
        rf_we,          
        rf_waddr,       
        ex_result       
    };
    
    wire w_hi_we1, w_lo_we1, w_hi_we2, w_lo_we2;

    assign w_hi_we1 = 1'b0; 
    assign w_lo_we1 = 1'b0; 
    assign stallreq_for_ex = 1'b0; 
    assign ready_ex_to_id = 1'b1; 
    assign w_hi_we2 = 1'b0; 
    assign w_lo_we2 = 1'b0; 

    assign lo_i = 32'b0; 
    assign hi_i = 32'b0;
    assign w_hi_we = 1'b0;
    assign w_lo_we = 1'b0;
    
    assign ex_to_mem1 = { w_hi_we, w_lo_we, hi_i, lo_i };
    assign ex_to_id_2 = { w_hi_we, w_lo_we, hi_i, lo_i };

endmodule