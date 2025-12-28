`include "lib/defines.vh"

module EX(
    input wire clk,                 
    input wire rst,                 
    input wire [`StallBus-1:0] stall, 

    input wire [`ID_TO_EX_WD-1:0] id_to_ex_bus, 

    output wire [`EX_TO_MEM_WD-1:0] ex_to_mem_bus, 
    output wire [37:0] ex_to_id_bus, 

    // ------ 恢复：SRAM 接口 ------
    output wire data_sram_en,       
    output wire [3:0] data_sram_wen,
    output wire [31:0] data_sram_addr, 
    output wire [31:0] data_sram_wdata,
    
    // ------ 恢复：Load 标记 (给 ID 用) ------
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
    
    // LW 的 opcode 是 100011 (0x23)
    assign inst_is_load = (inst[31:26] == 6'b10_0011) ? 1'b1 : 1'b0;
    
    wire [31:0] imm_sign_extend, imm_zero_extend, sa_zero_extend;
    assign imm_sign_extend = {{16{inst[15]}},inst[15:0]}; 
    assign imm_zero_extend = {16'b0, inst[15:0]};         
    assign sa_zero_extend = {27'b0,inst[10:6]};           

    wire [31:0] alu_src1, alu_src2; 
    wire [31:0] alu_result, ex_result; 

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

    // --- 【修改点1】 乘法与除法器实例化与控制 ---
    wire [63:0] mul_result;
    wire [63:0] div_result;
    wire div_ready;

    // 判断指令类型
    wire inst_mult  = (inst[31:26] == 6'b000000) & (inst[5:0] == 6'b011000);
    wire inst_multu = (inst[31:26] == 6'b000000) & (inst[5:0] == 6'b011001);
    wire inst_div   = (inst[31:26] == 6'b000000) & (inst[5:0] == 6'b011010);
    wire inst_divu  = (inst[31:26] == 6'b000000) & (inst[5:0] == 6'b011011);

    // 实例化乘法器
    mul_plus u_mul(
        .mul_clk(clk),
        .resetn(~rst), 
        .mul_signed(inst_mult), 
        .x(rf_rdata1), 
        .y(rf_rdata2), 
        .result(mul_result)
    );

    // 实例化除法器
    div u_div(
        .clk(clk),
        .rst(rst),
        .signed_div_i(inst_div),
        .opdata1_i(rf_rdata1),
        .opdata2_i(rf_rdata2),
        .start_i(inst_div | inst_divu),
        .cancel_i(1'b0),
        .result_o(div_result),
        .ready_o(div_ready)
    );

    // 暂停流水线：如果是除法且没准备好
    assign stallreq_for_ex = (inst_div | inst_divu) & ~div_ready;
    assign ready_ex_to_id = ~stallreq_for_ex;

    // --- 【修改点2】 HI/LO 写数据选择 ---
    // 写 HI/LO 信号来自 ID 阶段解码 (MTHI/MTLO/MULT/DIV)
    assign w_hi_we = lo_hi_w[0];
    assign w_lo_we = lo_hi_w[1];

    // HI/LO 输入数据选择：乘法结果 vs 除法结果 vs 通用寄存器(MTLO/MTHI)
    assign hi_i = (inst_mult | inst_multu) ? mul_result[63:32] :
                  (inst_div | inst_divu)   ? div_result[63:32] :
                  rf_rdata1; // MTHI

    assign lo_i = (inst_mult | inst_multu) ? mul_result[31: 0] :
                  (inst_div | inst_divu)   ? div_result[31: 0] :
                  rf_rdata1; // MTLO

    // --- 【修改点3】 通用寄存器写回数据选择 (MFHI/MFLO) ---
    // 如果是 MFHI，结果取 hi_o；如果是 MFLO，结果取 lo_o；否则取 ALU 结果
    // 注意：hi_o/lo_o 是 ID 阶段从 Regfile 读出并通过流水线传过来的
    assign ex_result = lo_hi_r[0] ? hi_o :
                       lo_hi_r[1] ? lo_o :
                       alu_result;

    assign data_sram_en = data_ram_en; 
    assign data_sram_wen = data_ram_wen;
    assign data_sram_addr = ex_result;
    assign data_sram_wdata = rf_rdata2;

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
    
    // --- 将 HI/LO 写信息打包传给 MEM/WB 阶段 ---
    assign ex_to_mem1 = { w_hi_we, w_lo_we, hi_i, lo_i };
    assign ex_to_id_2 = { w_hi_we, w_lo_we, hi_i, lo_i };

endmodule