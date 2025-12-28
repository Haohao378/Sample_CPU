`include "lib/defines.vh" 

module ID(
    input wire clk,                 
    input wire rst,                 
    // input wire flush,            
    input wire [`StallBus-1:0] stall, 

    output wire stallreq_for_id,    
    output wire stallreq,           

    // ------ 数据前推 ------
    input wire [37:0] ex_to_id_bus, 
    input wire [37:0] mem_to_id_bus,
    input wire [37:0] wb_to_id_bus, 

    // ------ HI/LO 前推 ------
    input wire [65:0] ex_to_id_2,   
    input wire[65:0] mem_to_id_2,   
    input wire[65:0] wb_to_id_2,    

    // ------ IF 输入 ------
    input wire [`IF_TO_ID_WD-1:0] if_to_id_bus, 
    input wire [31:0] inst_sram_rdata, 
    input wire inst_is_load,        
    input wire [`WB_TO_RF_WD-1:0] wb_to_rf_bus, 

    // ------ 输出到 EX ------
    output wire [`ID_TO_EX_WD-1:0] id_to_ex_bus, 

    // ------ 分支跳转输出 ------
    output wire [`BR_WD-1:0] br_bus, 

    input wire [65:0] wb_to_id_wf,   
    input wire ready_ex_to_id        
);

    assign stallreq = 1'b0;

    // =========================================================================
    // 1. 流水线寄存器
    // =========================================================================
    reg [31:0] inst_stall;           
    reg inst_stall_en;               
    reg [`IF_TO_ID_WD-1:0] if_to_id_bus_r; 
    
    wire [31:0] inst;                
    wire [31:0] id_pc;               
    wire ce;                         
    wire [31:0]inst_stall1;          
    wire inst_stall_en1;             

    wire wb_rf_we;                   
    wire [4:0] wb_rf_waddr;          
    wire [31:0] wb_rf_wdata;         

    always @ (posedge clk) begin
        if (rst) begin
            if_to_id_bus_r <= `IF_TO_ID_WD'b0;
        end
        else if (stall[1]==`Stop && stall[2]==`NoStop) begin
            if_to_id_bus_r <= `IF_TO_ID_WD'b0;
        end
        else if (stall[1]==`NoStop) begin
            if_to_id_bus_r <= if_to_id_bus;
        end
    end

    always @ (posedge clk) begin
        inst_stall_en<=1'b0;
        inst_stall <=32'b0;
        if(stall[1] == 1'b1 & ready_ex_to_id ==1'b0) begin
            inst_stall <= inst;      
            inst_stall_en<=1'b1;     
        end
    end 

    assign inst_stall1 = inst_stall;
    assign inst_stall_en1 = inst_stall_en ;
    assign inst = inst_stall_en1 ? inst_stall1 : inst_sram_rdata;

    assign { ce, id_pc } = if_to_id_bus_r;
    assign { wb_rf_we, wb_rf_waddr, wb_rf_wdata } = wb_to_rf_bus;

    // =========================================================================
    // 2. 译码逻辑
    // =========================================================================
    wire [5:0] opcode;      
    wire [4:0] rs,rt,rd,sa; 
    wire [5:0] func;        
    wire [15:0] imm;        
    wire [25:0] instr_index;
    wire [19:0] code;       
    wire [4:0] base;        
    wire [15:0] offset;     
    wire [2:0] sel;         

    wire [63:0] op_d, func_d; 
    wire [31:0] rs_d, rt_d, rd_d, sa_d; 

    wire [2:0] sel_alu_src1; 
    wire [3:0] sel_alu_src2; 
    wire [11:0] alu_op;      

    wire data_ram_en;        
    wire [3:0] data_ram_wen; 
    wire [3:0] data_ram_read;

    wire rf_we;              
    wire [4:0] rf_waddr;     
    wire sel_rf_res;         
    wire [2:0] sel_rf_dst;   

    wire [31:0] rdata1, rdata2; 

    wire w_hi_we;            
    wire w_lo_we;            
    wire [31:0]hi_i;         
    wire [31:0]lo_i;         

    wire r_hi_we;            
    wire r_lo_we;            
    wire[31:0] hi_o;         
    wire[31:0] lo_o;         

    wire [1:0] lo_hi_r;      
    wire [1:0] lo_hi_w;      

    wire inst_lsa;           

    assign { w_hi_we, w_lo_we, hi_i, lo_i } = wb_to_id_wf;

    // --- 寄存器堆实例化 ---
    regfile u_regfile(
        .inst   (inst),         
        .clk    (clk    ),
        .raddr1 (rs ),          
        .rdata1 (rdata1 ),      
        .raddr2 (rt ),          
        .rdata2 (rdata2 ),      
        .we     (wb_rf_we     ),
        .waddr  (wb_rf_waddr  ),
        .wdata  (wb_rf_wdata  ),
        .ex_to_id_bus(ex_to_id_bus), 
        .mem_to_id_bus(mem_to_id_bus), 
        .wb_to_id_bus(wb_to_id_bus),   
        .ex_to_id_2(ex_to_id_2),       
        .mem_to_id_2(mem_to_id_2),     
        .wb_to_id_2(wb_to_id_2),       
        .w_hi_we  (w_hi_we),
        .w_lo_we  (w_lo_we),
        .hi_i(hi_i),
        .lo_i(lo_i),
        .r_hi_we (lo_hi_r[0]),  
        .r_lo_we (lo_hi_r[1]),  
        .hi_o(hi_o),            
        .lo_o(lo_o),            
        .inst_lsa(inst_lsa)     
    );

    assign opcode = inst[31:26]; 
    assign rs = inst[25:21];     
    assign rt = inst[20:16];     
    assign rd = inst[15:11];     
    assign sa = inst[10:6];      
    assign func = inst[5:0];     
    assign imm = inst[15:0];     
    assign instr_index = inst[25:0]; 
    assign code = inst[25:6];    
    assign base = inst[25:21];   
    assign offset = inst[15:0];  
    assign sel = inst[2:0];      

    // =========================================================================
    // 3. Load-Use 冒险检测
    // =========================================================================
    assign stallreq_for_id = (inst_is_load == 1'b1 && (rs == ex_to_id_bus[36:32] || rt == ex_to_id_bus[36:32] ));

    // --- 译码器实例化 ---
    decoder_6_64 u0_decoder_6_64( .in(opcode), .out(op_d) );
    decoder_6_64 u1_decoder_6_64( .in(func), .out(func_d) );
    decoder_5_32 u0_decoder_5_32( .in(rs), .out(rs_d) );
    decoder_5_32 u1_decoder_5_32( .in(rt), .out(rt_d) );

    // --- 指令解码信号定义 ---
    wire inst_ori, inst_lui, inst_addiu, inst_beq, inst_subu, inst_jr, inst_jal, inst_addu, inst_bne, inst_sll, inst_or,
         inst_lw, inst_sw, inst_xor ,inst_sltu, inst_slt, inst_slti, inst_sltiu, inst_j, inst_add, inst_addi ,inst_sub,
         inst_and , inst_andi, inst_nor, inst_xori, inst_sllv, inst_sra, inst_bgez, inst_bltz, inst_bgtz, inst_blez,
         inst_bgezal,inst_bltzal, inst_jalr, inst_mflo, inst_mfhi, inst_mthi, inst_mtlo, inst_div, inst_divi, inst_mult,
         inst_multu, inst_lb, inst_lbu, inst_lh, inst_lhu, inst_sb, inst_sh;

    wire op_add, op_sub, op_slt, op_sltu; 
    wire op_and, op_nor, op_or, op_xor;
    wire op_sll, op_srl, op_sra, op_lui;

    assign inst_ori     = op_d[6'b00_1101];
    assign inst_lui     = op_d[6'b00_1111];
    assign inst_addiu   = op_d[6'b00_1001];
    assign inst_beq     = op_d[6'b00_0100]; 
    assign inst_subu    = op_d[6'b00_0000] & (sa==5'b0_0000) & func_d[6'b10_0011];
    assign inst_jr      = op_d[6'b00_0000] & (inst[20:11]==10'b0000000000) & (sa==5'b0_0000) & func_d[6'b00_1000];
    assign inst_jal     = op_d[6'b00_0011];
    assign inst_addu    = op_d[6'b00_0000] & (sa==5'b0_0000) & func_d[6'b10_0001];
    assign inst_sll     = op_d[6'b00_0000] & rs_d[5'b0_0000] & func_d[6'b00_0000]; 
    assign inst_bne     = op_d[6'b00_0101];
    assign inst_or      = op_d[6'b00_0000] & (sa==5'b0_0000) & func_d[6'b10_0101];
    assign inst_lw      = op_d[6'b10_0011]; 
    assign inst_sw      = op_d[6'b10_1011]; 
    assign inst_xor     = op_d[6'b00_0000] & (sa==5'b0_0000) & func_d[6'b10_0110];
    assign inst_sltu    = op_d[6'b00_0000] & (sa==5'b0_0000) & func_d[6'b10_1011];
    assign inst_slt     = op_d[6'b00_0000] & (sa==5'b0_0000) & func_d[6'b10_1010];
    assign inst_slti    = op_d[6'b00_1010];
    assign inst_sltiu   = op_d[6'b00_1011];
    assign inst_j       = op_d[6'b00_0010];
    assign inst_add     = op_d[6'b00_0000] & (sa==5'b0_0000) & func_d[6'b10_0000];
    assign inst_addi    = op_d[6'b00_1000];
    assign inst_sub     = op_d[6'b00_0000] & (sa==5'b0_0000) & func_d[6'b10_0010];
    assign inst_and     = op_d[6'b00_0000] & (sa==5'b0_0000) & func_d[6'b10_0100];
    assign inst_andi    = op_d[6'b00_1100];
    assign inst_nor     = op_d[6'b00_0000] & (sa==5'b0_0000) & func_d[6'b10_0111];
    assign inst_xori    = op_d[6'b00_1110];
    assign inst_sllv    = op_d[6'b00_0000] & (sa==5'b0_0000) & func_d[6'b00_0100];
    assign inst_sra     = op_d[6'b00_0000] & (rs==5'b0_0000) & func_d[6'b00_0011];
    assign inst_srav    = op_d[6'b00_0000] & (sa==5'b0_0000) & func_d[6'b00_0111];
    assign inst_srl     = op_d[6'b00_0000] & (rs==5'b0_0000) & func_d[6'b00_0010];
    assign inst_srlv    = op_d[6'b00_0000] & (sa==5'b0_0000) & func_d[6'b00_0110];
    assign inst_bgez    = op_d[6'b00_0001] & (rt==5'b0_0001); 
    assign inst_bltz    = op_d[6'b00_0001] & (rt==5'b0_0000);
    assign inst_bgezal  = op_d[6'b00_0001] & (rt==5'b1_0001);
    assign inst_bltzal  = op_d[6'b00_0001] & (rt==5'b1_0000);
    assign inst_bgtz    = op_d[6'b00_0111] & (rt==5'b0_0000);
    assign inst_blez    = op_d[6'b00_0110] & (rt==5'b0_0000);
    assign inst_jalr    = op_d[6'b00_0000] & (rt==5'b0_0000) & (sa==5'b0_0000) & func_d[6'b00_1001];

    // --- 【修改点1】 解除乘除法与HI/LO指令屏蔽 ---
    assign inst_mfhi    = op_d[6'b00_0000] & (rs==5'b0) & (rt==5'b0) & (sa==5'b0) & func_d[6'b01_0000]; 
    assign inst_mflo    = op_d[6'b00_0000] & (rs==5'b0) & (rt==5'b0) & (sa==5'b0) & func_d[6'b01_0010]; 
    assign inst_mthi    = op_d[6'b00_0000] & (rt==5'b0) & (rd==5'b0) & (sa==5'b0) & func_d[6'b01_0001]; 
    assign inst_mtlo    = op_d[6'b00_0000] & (rt==5'b0) & (rd==5'b0) & (sa==5'b0) & func_d[6'b01_0011]; 
    assign inst_div     = op_d[6'b00_0000] & (rd==5'b0) & (sa==5'b0) & func_d[6'b01_1010]; 
    assign inst_divu    = op_d[6'b00_0000] & (rd==5'b0) & (sa==5'b0) & func_d[6'b01_1011]; 
    assign inst_mult    = op_d[6'b00_0000] & (rd==5'b0) & (sa==5'b0) & func_d[6'b01_1000]; 
    assign inst_multu   = op_d[6'b00_0000] & (rd==5'b0) & (sa==5'b0) & func_d[6'b01_1001]; 

    assign inst_lb      = 1'b0; 
    assign inst_lbu     = 1'b0; 
    assign inst_lh      = 1'b0; 
    assign inst_lhu     = 1'b0; 
    assign inst_sb      = 1'b0; 
    assign inst_sh      = 1'b0; 
    assign inst_lsa     = 1'b0; 

    // --- ALU 输入选择 (增加乘除法作为src) ---
    assign sel_alu_src1[0] = inst_ori | inst_addiu | inst_subu | inst_addu | inst_or | inst_lw | inst_sw | inst_xor | inst_sltu | inst_slt
                                | inst_slti | inst_sltiu | inst_add | inst_addi | inst_sub | inst_and | inst_andi | inst_nor | inst_xori
                                | inst_sllv | inst_srav | inst_srlv | inst_mthi | inst_mtlo | inst_div | inst_divu | inst_mult | inst_multu; // 添加 mult/div/mthi/mtlo
    assign sel_alu_src1[1] = inst_jal | inst_bgezal |inst_bltzal | inst_jalr;
    assign sel_alu_src1[2] = inst_sll | inst_sra | inst_srl;

    assign sel_alu_src2[0] = inst_subu | inst_addu | inst_sll | inst_or | inst_xor | inst_sltu | inst_slt | inst_add | inst_sub | inst_and |
                              inst_nor | inst_sllv | inst_sra | inst_srav | inst_srl | inst_srlv | inst_div | inst_divu | inst_mult | inst_multu; // 添加 mult/div
    assign sel_alu_src2[1] = inst_lui | inst_addiu | inst_lw | inst_sw | inst_slti | inst_sltiu | inst_addi;
    assign sel_alu_src2[2] = inst_jal | inst_bgezal | inst_bltzal | inst_jalr;
    assign sel_alu_src2[3] = inst_ori | inst_andi | inst_xori;

    // --- 【修改点2】 HI/LO 读写使能设置 ---
    assign lo_hi_r[0] = inst_mfhi; // 读 HI
    assign lo_hi_r[1] = inst_mflo; // 读 LO
    
    // 写 HI/LO (乘法/除法/MTHI/MTLO)
    assign lo_hi_w[0] = inst_mult | inst_multu | inst_div | inst_divu | inst_mthi; 
    assign lo_hi_w[1] = inst_mult | inst_multu | inst_div | inst_divu | inst_mtlo;

    assign op_add = inst_addiu | inst_jal | inst_addu | inst_lw | inst_sw | inst_add | inst_addi | inst_bgezal | inst_bltzal | inst_jalr;
    assign op_sub = inst_subu | inst_sub;
    assign op_slt = inst_slt | inst_slti;
    assign op_sltu = inst_sltu | inst_sltiu;
    assign op_and = inst_and | inst_andi;
    assign op_nor = inst_nor;
    assign op_or = inst_ori | inst_or;
    assign op_xor = inst_xor | inst_xori;
    assign op_sll = inst_sll | inst_sllv;
    assign op_srl = inst_srl | inst_srlv;
    assign op_sra = inst_sra | inst_srav ;
    assign op_lui = inst_lui;

    assign alu_op = {op_add, op_sub, op_slt, op_sltu,
                     op_and, op_nor, op_or, op_xor,
                     op_sll, op_srl, op_sra, op_lui};

    assign data_ram_en = inst_lw | inst_sw;
    assign data_ram_wen = inst_sw ? 4'b1111 : 4'b0000;
    assign data_ram_read = inst_lw ? 4'b1111 : 4'b0000;

    // --- 【修改点3】 通用寄存器写使能 ---
    // 注意：MULT/DIV/MTHI/MTLO 不写通用寄存器，只有 MFHI/MFLO 写
    assign rf_we = inst_ori | inst_lui | inst_addiu | inst_subu | inst_jal |inst_addu | inst_sll | inst_or | inst_xor | inst_lw | inst_sltu
      | inst_slt | inst_slti | inst_sltiu | inst_add | inst_addi | inst_sub | inst_and | inst_andi | inst_nor | inst_sllv | inst_xori | inst_sra
      | inst_srav | inst_srl | inst_srlv | inst_bgezal | inst_bltzal | inst_jalr 
      | inst_mfhi | inst_mflo; // 增加 MFHI, MFLO

    assign sel_rf_dst[0] = inst_subu | inst_addu | inst_sll | inst_or | inst_xor | inst_sltu | inst_slt | inst_add | inst_sub | inst_and | inst_nor
                             | inst_sllv | inst_sra | inst_srav | inst_srl | inst_srlv | inst_jalr 
                             | inst_mfhi | inst_mflo; // 增加 MFHI, MFLO
    
    assign sel_rf_dst[1] = inst_ori | inst_lui | inst_addiu | inst_lw | inst_slti | inst_sltiu | inst_addi | inst_andi | inst_xori;
    assign sel_rf_dst[2] = inst_jal | inst_bgezal | inst_bltzal;

    assign rf_waddr = {5{sel_rf_dst[0]}} & rd
                    | {5{sel_rf_dst[1]}} & rt
                    | {5{sel_rf_dst[2]}} & 32'd31;

    assign sel_rf_res = inst_lw ? 1'b1 : 1'b0;

    assign id_to_ex_bus = {
        id_pc,          
        inst,           
        alu_op,         
        sel_alu_src1,   
        sel_alu_src2,   
        data_ram_en,    
        data_ram_wen,   
        rf_we,          
        rf_waddr,       
        sel_rf_res,     
        rdata1,         
        rdata2,         
        lo_hi_r,        
        lo_hi_w,        
        lo_o,           
        hi_o,           
        data_ram_read   
    };

    wire br_e;              
    wire [31:0] br_addr;    
    wire rs_eq_rt;          
    wire [31:0] pc_plus_4;  
    wire re_bne_rt;         
    wire re_bgez_rt;
    wire re_bltz_rt;
    wire re_blez_rt;
    wire re_bgtz_rt;

    assign pc_plus_4 = id_pc + 32'h4;

    assign rs_eq_rt = (rdata1 == rdata2);           
    assign re_bne_rt = (rdata1 != rdata2);          
    assign re_bgez_rt = (rdata1[31] == 1'b0);       
    assign re_bltz_rt = (rdata1[31] == 1'b1);       
    assign re_blez_rt = (rdata1[31] == 1'b1 || rdata1 == 32'b0); 
    assign re_bgtz_rt = (rdata1[31] == 1'b0 && rdata1 != 32'b0); 

    assign br_e = (inst_beq && rs_eq_rt) | inst_jr | inst_jal | (inst_bne && re_bne_rt) | inst_j |(inst_bgez && re_bgez_rt)
                  | (inst_bltz && re_bltz_rt) |(inst_bgtz && re_bgtz_rt) | (inst_blez && re_blez_rt) | (inst_bgezal && re_bgez_rt)
                  | (inst_bltzal && re_bltz_rt) | inst_jalr;

    assign br_addr = inst_beq ? (pc_plus_4 + {{14{inst[15]}},inst[15:0],2'b0}) : 
    inst_jr ? (rdata1) :                                                          
    inst_jal ? ({pc_plus_4[31:28],inst[25:0],2'b0}):                              
    inst_bne ? (pc_plus_4 + {{14{inst[15]}},inst[15:0],2'b0}) :                   
    inst_bgez ? (pc_plus_4 + {{14{inst[15]}},inst[15:0],2'b0}) :                  
    inst_bgtz ? (pc_plus_4 + {{14{inst[15]}},inst[15:0],2'b0}) :                  
    inst_bltz ? (pc_plus_4 + {{14{inst[15]}},inst[15:0],2'b0}) :                  
    inst_blez ? (pc_plus_4 + {{14{inst[15]}},inst[15:0],2'b0}) :                  
    inst_bgezal ? (pc_plus_4 + {{14{inst[15]}},inst[15:0],2'b0}) :                
    inst_bltzal ? (pc_plus_4 + {{14{inst[15]}},inst[15:0],2'b0}) :                
    inst_j   ?  ({pc_plus_4[31:28],inst[25:0],2'b0}):                             
    inst_jalr ? (rdata1) :                                                        
    32'b0;

    assign br_bus = {
        br_e,
        br_addr
    };

endmodule