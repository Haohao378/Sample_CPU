`include "lib/defines.vh" // 引入宏定义文件，包含总线宽度、控制信号等的定义

module ID(
    input wire clk,                 // 时钟信号
    input wire rst,                 // 复位信号，高电平有效
    // input wire flush,            // 流水线冲刷信号（当前被注释掉）
    input wire [`StallBus-1:0] stall, // 流水线暂停信号总线，每一位对应一个流水级是否需要暂停

    output wire stallreq_for_id,    // ID阶段产生的暂停请求信号（通常用于Load-Use冒险）

    output wire stallreq,           // 通用的暂停请求信号（代码中似乎未赋值逻辑，可能是预留）
    // ------ 数据前推（Forwarding）相关输入 ------
    // 为了解决数据冒险，需要从后续流水级（EX, MEM, WB）获取最新的数据
    input wire [37:0] ex_to_id_bus, // 来自EX阶段的数据前推总线（包含EX阶段要写的寄存器地址和数据）

    input wire [37:0] mem_to_id_bus,// 来自MEM阶段的数据前推总线

    input wire [37:0] wb_to_id_bus, // 来自WB阶段的数据前推总线

    // ------ HI/LO 寄存器相关的前推输入（针对乘除法等） ------
    input wire [65:0] ex_to_id_2,   // 来自EX阶段的HI/LO寄存器前推数据

    input wire[65:0] mem_to_id_2,   // 来自MEM阶段的HI/LO寄存器前推数据

    input wire[65:0] wb_to_id_2,    // 来自WB阶段的HI/LO寄存器前推数据

    // ------ 上一级（IF）传入的数据 ------
    input wire [`IF_TO_ID_WD-1:0] if_to_id_bus, // IF阶段传来的信息总线（包含PC值等）

    input wire [31:0] inst_sram_rdata, // 从指令存储器（SRAM）读出的32位指令码

    input wire inst_is_load,        // 指示上一条指令（EX阶段）是否是加载指令（用于检测Load-Use冒险）

    input wire [`WB_TO_RF_WD-1:0] wb_to_rf_bus, // WB阶段写回寄存器堆的信息（用于正常的寄存器写回）

    // ------ 输出到下一级（EX）的数据 ------
    output wire [`ID_TO_EX_WD-1:0] id_to_ex_bus, // ID阶段解码后传给EX阶段的信息总线

//    output wire [67:0] id_to_ex_2, // (注释掉) 可能用于传递HI/LO相关的额外信息

    // ------ 分支跳转相关输出 ------
    output wire [`BR_WD-1:0] br_bus, // 分支跳转总线（包含是否跳转 br_e 和跳转地址 br_addr）

    input wire [65:0] wb_to_id_wf,   // 可能是WB阶段写回HI/LO寄存器的写标志和数据
    input wire ready_ex_to_id        // 握手信号，指示EX阶段是否准备好接收数据
);

    // =========================================================================
    // 1. 流水线寄存器与指令缓冲逻辑
    // =========================================================================
    reg [31:0] inst_stall;           // 暂存指令的寄存器，用于流水线暂停时保存当前指令
    reg inst_stall_en;               // 指示 inst_stall 是否有效
    reg [`IF_TO_ID_WD-1:0] if_to_id_bus_r; // ID阶段的流水线寄存器，保存从IF传来的PC等信息
//    reg[65:0] wb_to_id_wf_r;       // (注释掉)

    wire [31:0] inst;                // 最终用于解码的当前指令
    wire [31:0] id_pc;               // 当前指令的PC地址
    wire ce;                         // 片选/使能信号（来自IF）
    wire [31:0]inst_stall1;          // 辅助连线
    wire inst_stall_en1;             // 辅助连线

    wire wb_rf_we;                   // WB阶段传来的写寄存器使能
    wire [4:0] wb_rf_waddr;          // WB阶段传来的写寄存器地址
    wire [31:0] wb_rf_wdata;         // WB阶段传来的写寄存器数据

    // --- 流水线寄存器更新逻辑 ---
    always @ (posedge clk) begin
        if (rst) begin
            // 复位时清空流水线寄存器
            if_to_id_bus_r <= `IF_TO_ID_WD'b0;
//            wb_to_id_wf_r <= 66'b0;
        end
        // else if (flush) begin ... end // 冲刷逻辑（被注释）
        // 如果ID阶段暂停(`Stop)且EX阶段不暂停(`NoStop)，说明ID阶段被阻塞但EX继续走，
        // 此时通常需要向EX发送气泡(bubble)，并将ID寄存器清零或保持。这里选择清零（插入气泡）。
        else if (stall[1]==`Stop && stall[2]==`NoStop) begin
            if_to_id_bus_r <= `IF_TO_ID_WD'b0;
//            wb_to_id_wf_r <= 66'b0;
        end
        // 如果ID阶段不暂停，则正常接收IF阶段传来的数据
        else if (stall[1]==`NoStop) begin
            if_to_id_bus_r <= if_to_id_bus;
//            wb_to_id_wf_r <= wb_to_id_wf;
        end
    end

    // --- 指令暂停缓冲逻辑 ---
    // 当流水线暂停时，指令存储器读出的数据可能会变或丢失，需要用寄存器锁存住当前指令
    always @ (posedge clk) begin
        inst_stall_en<=1'b0;
        inst_stall <=32'b0;
        // 如果ID阶段暂停(stall[1]==1) 且 下一级没准备好，则锁存当前指令
        if(stall[1] == 1'b1 & ready_ex_to_id ==1'b0)begin
            inst_stall <= inst;      // 锁存当前指令
            inst_stall_en<=1'b1;     // 标记锁存有效
        end
    end 

    assign inst_stall1 = inst_stall;
    assign inst_stall_en1 = inst_stall_en ;

    // 选择最终指令：如果处于暂停锁存状态，用锁存的指令；否则用SRAM读出的新指令
    assign inst = inst_stall_en1 ? inst_stall1  :inst_sram_rdata;

    // --- 解包 IF 传来的数据 ---
    assign {
        ce,     // Chip Enable
        id_pc   // 当前PC
    } = if_to_id_bus_r;

    // --- 解包 WB 阶段写回的数据 ---
    assign {
        wb_rf_we,
        wb_rf_waddr,
        wb_rf_wdata
    } = wb_to_rf_bus;

    // =========================================================================
    // 2. 指令字段拆解 (Instruction Decoding Fields)
    // =========================================================================
    wire [5:0] opcode;      // 操作码 (高6位)
    wire [4:0] rs,rt,rd,sa; // 源寄存器、目标寄存器、移位量
    wire [5:0] func;        // 功能码 (低6位，用于R型指令)
    wire [15:0] imm;        // 立即数
    wire [25:0] instr_index;// 26位跳转地址索引 (用于J型指令)
    wire [19:0] code;       // (通常用于syscall/break等的code字段)
    wire [4:0] base;        // 基址寄存器 (同rs)
    wire [15:0] offset;     // 偏移量 (同imm)
    wire [2:0] sel;         // (可能用于CP0指令的选择域)

    // 解码后的控制信号定义
    wire [63:0] op_d, func_d; // 独热码解码结果
    wire [31:0] rs_d, rt_d, rd_d, sa_d; // (定义了但后面似乎没完全用到)

    wire [2:0] sel_alu_src1; // ALU操作数1来源选择信号
    wire [3:0] sel_alu_src2; // ALU操作数2来源选择信号
    wire [11:0] alu_op;      // ALU操作码

    wire data_ram_en;        // 数据存储器使能
    wire [3:0] data_ram_wen; // 数据存储器写使能（按字节选通）
    wire [3:0] data_ram_read;// 数据存储器读模式（字节/半字/字）

    wire rf_we;              // ID阶段产生的寄存器堆写使能
    wire [4:0] rf_waddr;     // ID阶段产生的寄存器堆写地址
    wire sel_rf_res;         // 写回数据来源选择 (0:ALU结果, 1:内存结果)
    wire [2:0] sel_rf_dst;   // 写回目标寄存器选择 (rd, rt, 或 31号$ra)

    wire [31:0] rdata1, rdata2; // 从寄存器堆读出（或经过前推后）的源操作数

    // HI/LO 寄存器相关信号
    wire w_hi_we;            // 写HI寄存器使能
    wire w_lo_we;            // 写LO寄存器使能
    wire [31:0]hi_i;         // 写入HI的数据
    wire [31:0]lo_i;         // 写入LO的数据

    wire r_hi_we;            // 读HI寄存器使能
    wire r_lo_we;            // 读LO寄存器使能
    wire[31:0] hi_o;         // 读出的HI数据
    wire[31:0] lo_o;         // 读出的LO数据

    wire [1:0] lo_hi_r;      // HI/LO 读控制信号组合
    wire [1:0] lo_hi_w;      // HI/LO 写控制信号组合

    wire inst_lsa;           // 龙芯架构扩展指令 LSA (Load Scaled Address) 标志

    // 解包 WB 阶段传来的 HI/LO 写信号
    assign
    {
        w_hi_we,
        w_lo_we,
        hi_i,
        lo_i
    } = wb_to_id_wf;

    // =========================================================================
    // 3. 寄存器堆实例化 (Regfile Instance)
    // =========================================================================
    // 该模块负责寄存器的读写，以及核心的数据前推逻辑(Forwarding)通常也在这里处理
    regfile u_regfile(
        .inst   (inst),         // 当前指令（用于辅助判断相关性）
        .clk    (clk    ),
        // --- 读端口 ---
        .raddr1 (rs ),          // 读地址1
        .rdata1 (rdata1 ),      // 读数据1（输出，已处理前推）
        .raddr2 (rt ),          // 读地址2
        .rdata2 (rdata2 ),      // 读数据2（输出，已处理前推）
        // --- 写端口 (来自WB阶段) ---
        .we     (wb_rf_we     ),
        .waddr  (wb_rf_waddr  ),
        .wdata  (wb_rf_wdata  ),
        // --- 前推数据输入 ---
        .ex_to_id_bus(ex_to_id_bus), // EX阶段前推
        .mem_to_id_bus(mem_to_id_bus), // MEM阶段前推
        .wb_to_id_bus(wb_to_id_bus),   // WB阶段前推
        .ex_to_id_2(ex_to_id_2),       // HI/LO EX前推
        .mem_to_id_2(mem_to_id_2),     // HI/LO MEM前推
        .wb_to_id_2(wb_to_id_2),       // HI/LO WB前推
        // --- HI/LO 写端口 ---
        .w_hi_we  (w_hi_we),
        .w_lo_we  (w_lo_we),
        .hi_i(hi_i),
        .lo_i(lo_i),
        // --- HI/LO 读端口 ---
        .r_hi_we (lo_hi_r[0]),  // 读HI使能
        .r_lo_we (lo_hi_r[1]),  // 读LO使能
        .hi_o(hi_o),            // 读出的HI值
        .lo_o(lo_o),            // 读出的LO值
        .inst_lsa(inst_lsa)     // LSA指令指示
    );


    // =========================================================================
    // 4. 指令字段赋值
    // =========================================================================
    assign opcode = inst[31:26]; // MIPS指令高6位
    assign rs = inst[25:21];     // 源寄存器1
    assign rt = inst[20:16];     // 源寄存器2 或 目标寄存器
    assign rd = inst[15:11];     // 目标寄存器
    assign sa = inst[10:6];      // 移位量 (Shift Amount)
    assign func = inst[5:0];     // 功能码
    assign imm = inst[15:0];     // 16位立即数
    assign instr_index = inst[25:0]; // 26位跳转索引
    assign code = inst[25:6];    // 异常码字段
    assign base = inst[25:21];   // 基址寄存器 (同rs)
    assign offset = inst[15:0];  // 偏移量 (同imm)
    assign sel = inst[2:0];      // 选择域

    // =========================================================================
    // 5. 暂停请求逻辑 (Load-Use Hazard Detection)
    // =========================================================================
    // 如果上一条指令(在EX阶段)是加载指令(Load)，且其目标寄存器与当前指令的源寄存器(rs或rt)相同，
    // 则发生Load-Use冒险，必须暂停ID阶段一个周期，等待数据从内存读出。
    assign stallreq_for_id = (inst_is_load == 1'b1 && (rs == ex_to_id_bus[36:32] || rt == ex_to_id_bus[36:32] ));
    // assign inst_stall =  (stallreq_for_id) ? inst : 32'b0; (注释掉的代码)

    // =========================================================================
    // 6. 指令译码 (Instruction Decoding)
    // =========================================================================
    // 定义每种具体指令的标志位
    wire inst_ori, inst_lui, inst_addiu, inst_beq, inst_subu, inst_jr, inst_jal, inst_addu, inst_bne, inst_sll, inst_or,
         inst_lw, inst_sw, inst_xor ,inst_sltu, inst_slt, inst_slti, inst_sltiu, inst_j, inst_add, inst_addi ,inst_sub,
         inst_and , inst_andi, inst_nor, inst_xori, inst_sllv, inst_sra, inst_bgez, inst_bltz, inst_bgtz, inst_blez,
         inst_bgezal,inst_bltzal, inst_jalr, inst_mflo, inst_mfhi, inst_mthi, inst_mtlo, inst_div, inst_divi, inst_mult,
         inst_multu, inst_lb, inst_lbu, inst_lh, inst_lhu, inst_sb, inst_sh;

    wire op_add, op_sub, op_slt, op_sltu; // ALU操作类别标志
    wire op_and, op_nor, op_or, op_xor;
    wire op_sll, op_srl, op_sra, op_lui;

    // 实例化译码器，将6位输入转换为64位独热码输出
    decoder_6_64 u0_decoder_6_64(
        .in  (opcode  ),
        .out (op_d )    // 操作码的独热码
    );

    decoder_6_64 u1_decoder_6_64(
        .in  (func  ),
        .out (func_d )  // 功能码的独热码
    );

    // 下面两个译码器似乎将rs和rt也转成了独热码，用于辅助判断（如判断rs是否为0）
    decoder_5_32 u0_decoder_5_32(
        .in  (rs  ),
        .out (rs_d )
    );

    decoder_5_32 u1_decoder_5_32(
        .in  (rt  ),
        .out (rt_d )
    );


    // --- 具体指令判断逻辑 ---
    // 根据MIPS指令集架构定义，结合opcode和func字段判断是哪条指令
    assign inst_ori     = op_d[6'b00_1101];
    assign inst_lui     = op_d[6'b00_1111];
    assign inst_addiu   = op_d[6'b00_1001];
    assign inst_beq     = op_d[6'b00_0100];
    assign inst_subu    = op_d[6'b00_0000] & (sa==5'b0_0000) & func_d[6'b10_0011]; // R型指令
    assign inst_jr      = op_d[6'b00_0000] & (inst[20:11]==10'b0000000000) & (sa==5'b0_0000) & func_d[6'b00_1000];
    assign inst_jal     = op_d[6'b00_0011];
    assign inst_addu    = op_d[6'b00_0000] & (sa==5'b0_0000) & func_d[6'b10_0001];
    assign inst_sll     = op_d[6'b00_0000] & rs_d[5'b0_0000] & func_d[6'b00_0000]; // 移位指令通常rs为0
    assign inst_bne     = op_d[6'b00_0101];
    assign inst_or      = op_d[6'b00_0000] & (sa==5'b0_0000) & func_d[6'b10_0101];

    assign inst_lw      = op_d[6'b10_0011]; // 加载字
    assign inst_sw      = op_d[6'b10_1011]; // 存储字
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
    assign inst_bgez    = op_d[6'b00_0001] & (rt==5'b0_0001); // REGIMM类分支
    assign inst_bltz    = op_d[6'b00_0001] & (rt==5'b0_0000);
    assign inst_bgtz    = op_d[6'b00_0111] & (rt==5'b0_0000);
    assign inst_blez    = op_d[6'b00_0110] & (rt==5'b0_0000);
    assign inst_bgezal  = op_d[6'b00_0001] & (rt==5'b1_0001);
    assign inst_bltzal  = op_d[6'b00_0001] & (rt==5'b1_0000);
    assign inst_jalr    = op_d[6'b00_0000] & (rt==5'b0_0000) & (sa==5'b0_0000) & func_d[6'b00_1001];

    assign inst_mflo    = op_d[6'b00_0000] & (inst[25:16]==10'b0000000000) & (sa==5'b0_0000) & func_d[6'b01_0010]; // 移动HI/LO数据
    assign inst_mfhi    = op_d[6'b00_0000] & (inst[25:16]==10'b0000000000) & (sa==5'b0_0000) & func_d[6'b01_0000];
    assign inst_mthi    = op_d[6'b00_0000] & (inst[20:6]==10'b000000000000000)  & func_d[6'b01_0001];
    assign inst_mtlo    = op_d[6'b00_0000] & (inst[20:6]==10'b000000000000000)  & func_d[6'b01_0011];
    assign inst_div     = op_d[6'b00_0000] & (inst[15:6]==10'b0000000000) & func_d[6'b01_1010]; // 除法
    assign inst_divu    = op_d[6'b00_0000] & (inst[15:6]==10'b0000000000) & func_d[6'b01_1011];
    assign inst_mult    = op_d[6'b00_0000] & (inst[15:6]==10'b0000000000) & func_d[6'b01_1000]; // 乘法
    assign inst_multu   = op_d[6'b00_0000] & (inst[15:6]==10'b0000000000) & func_d[6'b01_1001];

    assign inst_lb      = op_d[6'b10_0000]; // 加载字节
    assign inst_lbu     = op_d[6'b10_0100]; // 加载无符号字节
    assign inst_lh      = op_d[6'b10_0001]; // 加载半字
    assign inst_lhu     = op_d[6'b10_0101];
    assign inst_sb      = op_d[6'b10_1000]; // 存储字节
    assign inst_sh      = op_d[6'b10_1001]; // 存储半字

    assign inst_lsa     = op_d[6'b01_1100] & inst[10:8]==3'b111 & inst[5:0]==6'b11_0111; // LSA指令

    // =========================================================================
    // 7. ALU 输入来源选择 (ALU MUX Control)
    // =========================================================================
    // sel_alu_src1: 选择ALU的操作数1
    // [0] = 1: 来源于寄存器 rs (大多数运算指令)
    assign sel_alu_src1[0] = inst_ori | inst_addiu | inst_subu | inst_addu | inst_or | inst_lw | inst_sw | inst_xor | inst_sltu | inst_slt
                                | inst_slti | inst_sltiu | inst_add | inst_addi | inst_sub | inst_and | inst_andi | inst_nor | inst_xori
                                | inst_sllv | inst_srav | inst_srlv | inst_mthi | inst_mtlo | inst_div | inst_divu | inst_mult | inst_multu
                                | inst_lb | inst_lbu | inst_lh | inst_lhu | inst_sb | inst_sh | inst_lsa;

    // [1] = 1: 来源于 PC (用于跳转链接指令，计算返回地址 PC+8)
    assign sel_alu_src1[1] = inst_jal | inst_bgezal |inst_bltzal | inst_jalr;

    // [2] = 1: 来源于 sa 移位量进行0扩展 (用于立即数移位指令)
    assign sel_alu_src1[2] = inst_sll | inst_sra | inst_srl;


    // sel_alu_src2: 选择ALU的操作数2
    // [0] = 1: 来源于寄存器 rt (R型指令)
    assign sel_alu_src2[0] = inst_subu | inst_addu | inst_sll | inst_or | inst_xor | inst_sltu | inst_slt | inst_add | inst_sub | inst_and |
                              inst_nor | inst_sllv | inst_sra | inst_srav | inst_srl | inst_srlv | inst_div | inst_divu | inst_mult | inst_multu | inst_lsa;

    // [1] = 1: 来源于立即数进行符号扩展 (I型算术指令、访存指令)
    assign sel_alu_src2[1] = inst_lui | inst_addiu | inst_lw | inst_sw | inst_slti | inst_sltiu | inst_addi | inst_lb | inst_lbu | inst_lh | inst_lhu | inst_sb | inst_sh;

    // [2] = 1: 来源于常数 8 (用于跳转链接指令，计算 PC+8)
    assign sel_alu_src2[2] = inst_jal | inst_bgezal | inst_bltzal | inst_jalr;

    // [3] = 1: 来源于立即数进行0扩展 (逻辑运算指令如ORI)
    assign sel_alu_src2[3] = inst_ori | inst_andi | inst_xori;

    // --- HI/LO 读写控制信号 ---
    // [0] = 1: 读 LO
    assign lo_hi_r[0] = inst_mflo;

    // [1] = 1: 读 HI
    assign lo_hi_r[1] = inst_mfhi;

    // =========================================================================
    // 8. ALU 操作码生成 (ALU Opcode)
    // =========================================================================
    // 将不同指令归类到 ALU 的具体操作上
    assign op_add = inst_addiu | inst_jal | inst_addu | inst_lw | inst_sw | inst_add | inst_addi | inst_bgezal | inst_bltzal
          | inst_jalr | inst_lb | inst_lbu | inst_lh | inst_lhu | inst_sb | inst_sh | inst_lsa;
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

    // 打包 ALU 操作码
    assign alu_op = {op_add, op_sub, op_slt, op_sltu,
                     op_and, op_nor, op_or, op_xor,
                     op_sll, op_srl, op_sra, op_lui};


    // =========================================================================
    // 9. 数据存储器控制信号 (Data RAM Control)
    // =========================================================================
    // 访存使能：Load 或 Store 指令
    assign data_ram_en = inst_lw | inst_sw | inst_lb | inst_lbu | inst_lh | inst_lhu | inst_sb | inst_sh;

    // 写使能：Store指令为全1(1111)，否则为0
    assign data_ram_wen = inst_sw ? 4'b1111 : 4'b0000;

    // 读模式控制：决定是读字节、半字还是字
    assign data_ram_read    =  inst_lw  ? 4'b1111 :
                               inst_lb  ? 4'b0001 :
                               inst_lbu ? 4'b0010 :
                               inst_lh  ? 4'b0011 :
                               inst_lhu ? 4'b0100 :
                               inst_sb  ? 4'b0101 :
                               inst_sh  ? 4'b0111 :
                               4'b0000;

    // =========================================================================
    // 10. 寄存器堆写控制 (Regfile Write Control)
    // =========================================================================
    // 寄存器写使能：所有需要写回通用寄存器的指令
    assign rf_we = inst_ori | inst_lui | inst_addiu | inst_subu | inst_jal |inst_addu | inst_sll | inst_or | inst_xor | inst_lw | inst_sltu
      | inst_slt | inst_slti | inst_sltiu | inst_add | inst_addi | inst_sub | inst_and | inst_andi | inst_nor | inst_sllv | inst_xori | inst_sra
      | inst_srav | inst_srl | inst_srlv | inst_bgezal | inst_bltzal | inst_jalr  | inst_mfhi | inst_mflo | inst_lb | inst_lbu | inst_lh | inst_lhu | inst_lsa;


    // 目标寄存器选择 (Destination Register Selection)
    // [0] = 1: 写入 rd (R型指令)
    assign sel_rf_dst[0] = inst_subu | inst_addu | inst_sll | inst_or | inst_xor | inst_sltu | inst_slt | inst_add | inst_sub | inst_and | inst_nor
                             | inst_sllv | inst_sra | inst_srav | inst_srl | inst_srlv | inst_jalr | inst_mflo | inst_mfhi | inst_lsa;
    // [1] = 1: 写入 rt (I型指令)
    assign sel_rf_dst[1] = inst_ori | inst_lui | inst_addiu | inst_lw | inst_slti | inst_sltiu | inst_addi | inst_andi | inst_xori | inst_lb | inst_lbu | inst_lh | inst_lhu;
    // [2] = 1: 写入 $31 (ra) (JAL等指令)
    assign sel_rf_dst[2] = inst_jal | inst_bgezal | inst_bltzal ;

    // HI/LO 写信号生成
    assign lo_hi_w[0] = inst_mtlo; // 写 LO
    assign lo_hi_w[1] = inst_mthi; // 写 HI

    // 确定最终的寄存器写地址 rf_waddr
    assign rf_waddr = {5{sel_rf_dst[0]}} & rd
                    | {5{sel_rf_dst[1]}} & rt
                    | {5{sel_rf_dst[2]}} & 32'd31;

    // 写回数据来源选择：1表示来自内存加载的数据(Load)，0表示来自ALU计算结果
    assign sel_rf_res = (inst_lw | inst_lb | inst_lbu) ? 1'b1 : 1'b0;

    // (被注释掉的代码块，可能用于LSA指令的逻辑)
//    wire [2:0] zuoyi;
//    assign zuoyi = inst_lsa ? (inst[7:6] + 1'b1) :  3'b0;
//    assign ...

    // =========================================================================
    // 11. ID 到 EX 总线打包 (Bus Packing)
    // =========================================================================
    assign id_to_ex_bus = {
        id_pc,          // 158:127 PC值
        inst,           // 126:95  指令码
        alu_op,         // 94:83   ALU操作码
        sel_alu_src1,   // 82:80   源操作数1选择
        sel_alu_src2,   // 79:76   源操作数2选择
        data_ram_en,    // 75      内存使能
        data_ram_wen,   // 74:71   内存写使能
        rf_we,          // 70      寄存器写使能
        rf_waddr,       // 69:65   寄存器写地址
        sel_rf_res,     // 64      写回数据来源选择
        rdata1,         // 63:32   源操作数1数据
        rdata2,         // 31:0    源操作数2数据
        lo_hi_r,        // HI/LO读信号
        lo_hi_w,        // HI/LO写信号
        lo_o,           // LO数据
        hi_o,           // HI数据
        data_ram_read   // 内存读模式
    };

//    assign id_to_ex_2 = ... (注释掉)

    // =========================================================================
    // 12. 分支跳转逻辑 (Branch Logic)
    // =========================================================================
    wire br_e;              // 分支跳转使能
    wire [31:0] br_addr;    // 分支跳转目标地址
    wire rs_eq_rt;          // rs == rt
    wire rs_ge_z;           // rs >= 0 (未完全定义)
    wire rs_gt_z;           // rs > 0 (未完全定义)
    wire rs_le_z;           // rs <= 0 (未完全定义)
    wire rs_lt_z;           // rs < 0 (未完全定义)
    wire [31:0] pc_plus_4;  // 当前PC + 4 (延迟槽之后的地址)
    wire re_bne_rt;         // rs != rt
//    wire [31:0] pc_plus_8; // (注释掉)

    assign pc_plus_4 = id_pc + 32'h4;
//    assign pc_plus_8 = id_pc + 32'h8;

    // 分支条件判断 (注意：这里直接使用有符号位的最高位判断正负)
    assign rs_eq_rt = (rdata1 == rdata2);           // 相等
    assign re_bne_rt = (rdata1 != rdata2);          // 不等
    assign re_bgez_rt = (rdata1[31] == 1'b0);       // >= 0 (符号位为0)
    assign re_bltz_rt = (rdata1[31] == 1'b1);       // < 0 (符号位为1)
    assign re_blez_rt = (rdata1[31] == 1'b1 || rdata1 == 32'b0); // <= 0
    assign re_bgtz_rt = (rdata1[31] == 1'b0 && rdata1 != 32'b0); // > 0

    // 分支使能信号生成：如果是分支指令且满足条件，或者直接跳转指令
    assign br_e = (inst_beq && rs_eq_rt) | inst_jr | inst_jal | (inst_bne && re_bne_rt) | inst_j |(inst_bgez && re_bgez_rt)
                      | (inst_bltz && re_bltz_rt) |(inst_bgtz && re_bgtz_rt) | (inst_blez && re_blez_rt) | (inst_bgezal && re_bgez_rt)
                      | (inst_bltzal && re_bltz_rt) | inst_jalr;

    // 跳转地址生成逻辑
    assign br_addr = inst_beq ? (pc_plus_4 + {{14{inst[15]}},inst[15:0],2'b0}) : // BEQ: PC+4 + offset<<2
    inst_jr ? (rdata1) :                                                          // JR: rs寄存器值
    inst_jal ? ({pc_plus_4[31:28],inst[25:0],2'b0}):                              // JAL: (PC+4)[31:28] | index<<2
    inst_bne ? (pc_plus_4 + {{14{inst[15]}},inst[15:0],2'b0}) :                   // BNE
    inst_bgez ? (pc_plus_4 + {{14{inst[15]}},inst[15:0],2'b0}) :                  // BGEZ
    inst_bgtz ? (pc_plus_4 + {{14{inst[15]}},inst[15:0],2'b0}) :                  // BGTZ
    inst_bltz ? (pc_plus_4 + {{14{inst[15]}},inst[15:0],2'b0}) :                  // BLTZ
    inst_blez ? (pc_plus_4 + {{14{inst[15]}},inst[15:0],2'b0}) :                  // BLEZ
    inst_bgezal ? (pc_plus_4 + {{14{inst[15]}},inst[15:0],2'b0}) :                // BGEZAL
    inst_bltzal ? (pc_plus_4 + {{14{inst[15]}},inst[15:0],2'b0}) :                // BLTZAL
    inst_j   ?  ({pc_plus_4[31:28],inst[25:0],2'b0}):                             // J
    inst_jalr ? (rdata1) :                                                        // JALR
    32'b0;

    // assign id_pc = inst_jal ? pc_plus_8 : id_pc; (注释掉)

    // 打包分支信息输出
    assign br_bus = {
        br_e,
        br_addr
    };

endmodule