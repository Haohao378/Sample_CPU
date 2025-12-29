`include "lib/defines.vh" // 引入宏定义文件，包含总线宽度、控制信号等的定义

module EX(
    input wire clk,                 // 系统时钟信号
    input wire rst,                 // 系统复位信号
    // input wire flush,            // 流水线冲刷信号（当前被注释掉）
    input wire [`StallBus-1:0] stall, // 流水线暂停控制信号，位宽通常为6位，分别控制不同阶段

    // ------ 来自 ID 阶段的数据 ------
    input wire [`ID_TO_EX_WD-1:0] id_to_ex_bus, // 从译码阶段传过来的指令信息大礼包
//    input wire [67:0] id_to_ex_2, // (注释掉) 可能用于辅助信号

    // ------ 输出到 MEM 阶段的数据 ------
    output wire [`EX_TO_MEM_WD-1:0] ex_to_mem_bus, // 执行结果、访存信息传给访存阶段
    
    // ------ 前推（Forwarding）到 ID 阶段的数据 ------
    output wire [37:0] ex_to_id_bus, // 将运算结果直接回传给ID阶段，解决数据冒险

    // ------ 数据存储器（SRAM）接口信号 ------
    output wire data_sram_en,       // SRAM 片选使能（总开关）
    output wire [3:0] data_sram_wen,// SRAM 写使能（按字节选通，控制写哪几个字节）
    output wire [31:0] data_sram_addr, // SRAM 读写地址
    output wire [31:0] data_sram_wdata,// SRAM 写入的数据
    output wire inst_is_load,       // 指示当前是否为加载指令（用于后续冒险检测）
    
    // ------ 暂停请求与握手 ------
    output wire stallreq_for_ex,    // EX阶段请求暂停流水线（通常因为乘除法还没算完）
    output wire [65:0]ex_to_mem1,   // 专门传输 HI/LO 寄存器写信息的总线给 MEM
    output wire [65:0]ex_to_id_2,   // 专门前推 HI/LO 寄存器数据给 ID
    output wire ready_ex_to_id      // 握手信号，指示乘除法单元是否空闲
);

    // =========================================================================
    // 1. 流水线寄存器 (Pipeline Register)
    // =========================================================================
    reg [`ID_TO_EX_WD-1:0] id_to_ex_bus_r; // 定义寄存器，用于锁存 ID 传过来的数据
//    reg [67:0] id_to_ex_2_r;

    always @ (posedge clk) begin
        if (rst) begin
            // 复位时清空寄存器
            id_to_ex_bus_r <= `ID_TO_EX_WD'b0;
//            id_to_ex_2_r <= 68'b0;
        end
        // else if (flush) begin ... end
        // 暂停策略：
        // 如果 EX 阶段被要求暂停(`Stop)，但下一级 MEM 没有暂停(`NoStop)
        // 说明 EX 阶段的数据处理不下去了（或者需要等待），为了防止把错误/重复数据传给 MEM，
        // 需要向 MEM 发送气泡（清空当前寄存器或输出 NOP）。
        else if (stall[2]==`Stop && stall[3]==`NoStop) begin
            id_to_ex_bus_r <= `ID_TO_EX_WD'b0;
//            id_to_ex_2_r <= 68'b0;
        end
        // 正常流动：
        // 如果 EX 阶段不需要暂停，则正常接收 ID 阶段传来的新数据
        else if (stall[2]==`NoStop) begin
            id_to_ex_bus_r <= id_to_ex_bus;
//            id_to_ex_2_r <= id_to_ex_2;
        end
    end

    // =========================================================================
    // 2. 解包逻辑 (Unpacking) - 将总线拆解为具体信号
    // =========================================================================
    wire [31:0] ex_pc, inst;        // 当前指令PC，当前指令码
    wire [11:0] alu_op;             // ALU操作码（控制加减乘除与或非等）
    wire [2:0] sel_alu_src1;        // ALU源操作数1的选择信号
    wire [3:0] sel_alu_src2;        // ALU源操作数2的选择信号
    wire data_ram_en;               // RAM使能
    wire [3:0] data_ram_wen;        // RAM写使能（来自ID的初步信号）
    wire [3:0] data_ram_read;       // 访存类型标记（注意：这里不仅包含读，也包含SB/SH等写类型）
    wire rf_we;                     // 寄存器堆写使能
    wire [4:0] rf_waddr;            // 寄存器堆写地址
    wire sel_rf_res;                // 写回数据源选择（ALU结果 vs 内存结果）
    wire [31:0] rf_rdata1, rf_rdata2; // 通用寄存器读出的数据 rs, rt
    reg is_in_delayslot;            // 是否在延迟槽中（此处定义了但似乎未从总线解包，可能在inst中隐含或未使用）
    wire [1:0] lo_hi_r;             // HI/LO 读控制
    wire [1:0] lo_hi_w;             // HI/LO 写控制 (针对 MTLO/MTHI 指令)
    wire w_hi_we;                   // 最终的 HI 写使能
    wire w_lo_we;                   // 最终的 LO 写使能
    wire w_hi_we3;                  // 类型3的 HI 写使能 (MTLO/MTHI)
    wire w_lo_we3;                  // 类型3的 LO 写使能 (MTLO/MTHI)
    wire [31:0] hi_i;               // 准备写入 HI 的数据
    wire [31:0] lo_i;               // 准备写入 LO 的数据
    wire[31:0] hi_o;                // 读出的 HI 值
    wire[31:0] lo_o;                // 读出的 LO 值

    assign {
        ex_pc,          // 158:127  PC指针
        inst,           // 126:95   指令二进制码
        alu_op,         // 94:83    ALU操作控制码
        sel_alu_src1,   // 82:80    源操作数1选择子
        sel_alu_src2,   // 79:76    源操作数2选择子
        data_ram_en,    // 75       内存使能
        data_ram_wen,   // 74:71    内存写使能（粗略）
        rf_we,          // 70       通用寄存器写使能
        rf_waddr,       // 69:65    通用寄存器写目标
        sel_rf_res,     // 64       写回数据源选择
        rf_rdata1,      // 63:32    操作数1 (rs)
        rf_rdata2,      // 31:0     操作数2 (rt)
        lo_hi_r,        //          HI/LO 读信号
        lo_hi_w,        //          HI/LO 写信号 (MTLO/MTHI)
        lo_o,           //          LO 当前值
        hi_o,           //          HI 当前值
        data_ram_read   //          访存操作具体类型 (LB, LW, SB等)
    } = id_to_ex_bus_r;
    
    
    // (注释掉的 LSA 指令逻辑 - 用于地址左移加速)
//    wire inst_lsa;
//    assign inst_lsa  = ...
    
    // MTLO/MTHI 指令的写使能信号解析
    assign w_lo_we3 = lo_hi_w[0]==1'b1 ? 1'b1:1'b0; // 如果 lo_hi_w[0] 为1，则是 MTLO
    assign w_hi_we3 = lo_hi_w[1]==1'b1 ? 1'b1:1'b0; // 如果 lo_hi_w[1] 为1，则是 MTHI
    
    // 判断是否为 LW (Load Word) 指令，用于后续可能的 Load-Use 冒险判断
    assign inst_is_load =  (inst[31:26] == 6'b10_0011) ? 1'b1 :1'b0;
    
    // =========================================================================
    // 3. 操作数准备 (Operand Mux)
    // =========================================================================
    wire [31:0] imm_sign_extend, imm_zero_extend, sa_zero_extend;
    assign imm_sign_extend = {{16{inst[15]}},inst[15:0]}; // 立即数符号扩展 (用于 ADDI, LW, SW 等)
    assign imm_zero_extend = {16'b0, inst[15:0]};         // 立即数零扩展 (用于 ORI, XORI 等)
    assign sa_zero_extend = {27'b0,inst[10:6]};           // 移位量 sa 零扩展 (用于 SLL, SRL 等)

    wire [31:0] alu_src1, alu_src2; // 最终送入 ALU 的两个操作数
    wire [31:0] alu_result, ex_result; // ALU计算结果，本级最终结果

    // ALU 操作数 1 选择逻辑
    assign alu_src1 = sel_alu_src1[1] ? ex_pc :           // 选 PC (用于 JAL 算返回地址)
                      sel_alu_src1[2] ? sa_zero_extend :  // 选 sa (移位量)
                      rf_rdata1;                          // 默认选 rs 寄存器值

    // ALU 操作数 2 选择逻辑
    assign alu_src2 = sel_alu_src2[1] ? imm_sign_extend : // 选符号扩展立即数 (ADDIU, LW, SW)
                      sel_alu_src2[2] ? 32'd8 :           // 选常数 8 (用于 JAL 算 PC+8)
                      sel_alu_src2[3] ? imm_zero_extend : // 选零扩展立即数 (ORI)
                      rf_rdata2;                          // 默认选 rt 寄存器值 (R型指令)
    
    // =========================================================================
    // 4. ALU 实例化 (Arithmetic Logic Unit)
    // =========================================================================
    alu u_alu(
        .alu_control (alu_op ),      // 操作码
        .alu_src1    (alu_src1    ), // 操作数1
        .alu_src2    (alu_src2    ), // 操作数2
        .alu_result  (alu_result  )  // 运算结果
    );

    // 确定 EX 阶段的最终输出结果 (ex_result)
    // 优先级：MFLO > MFHI > ALU结果
    assign ex_result =  lo_hi_r[0] ? lo_o :       // 如果是 MFLO，结果就是 LO 的值
                        lo_hi_r[1] ? hi_o :       // 如果是 MFHI，结果就是 HI 的值
                        alu_result;               // 否则就是 ALU 算出来的结果 (含地址计算结果)


    // =========================================================================
    // 5. SRAM 接口控制 (Memory Logic)
    // =========================================================================
    assign data_sram_en = data_ram_en ; // 直接传递片选信号

    // 生成 SRAM 写使能掩码 (Byte Mask)
    // 这里的 data_ram_read 其实是访存类型码。0101代表SB，0111代表SH。
    // ex_result 这里充当内存地址。根据地址的低两位 (ex_result[1:0]) 决定写哪个字节。
    assign data_sram_wen = 
        // SB 指令 (Store Byte) 的处理
        (data_ram_read==4'b0101 && ex_result[1:0] == 2'b00 )? 4'b0001: // 地址xx00，写最低字节
        (data_ram_read==4'b0101 && ex_result[1:0] == 2'b01 )? 4'b0010: // 地址xx01，写次低字节
        (data_ram_read==4'b0101 && ex_result[1:0] == 2'b10 )? 4'b0100: // ...
        (data_ram_read==4'b0101 && ex_result[1:0] == 2'b11 )? 4'b1000: // 地址xx11，写最高字节
        // SH 指令 (Store Halfword) 的处理
        (data_ram_read==4'b0111 && ex_result[1:0] == 2'b00 )? 4'b0011: // 地址xx00，写低两字节
        (data_ram_read==4'b0111 && ex_result[1:0] == 2'b10 )? 4'b1100: // 地址xx10，写高两字节
        // SW 指令或其他非 SB/SH 的写指令，直接使用 ID 传来的默认值 (通常是1111)
        data_ram_wen;

    assign data_sram_addr = ex_result ; // ALU计算出的结果即为内存地址

    // 生成 SRAM 写数据 (Data Alignment)
    // 将寄存器 rt 的数据 (rf_rdata2) 移位到对应的字节通道上，配合上面的 wen 掩码写入
    assign data_sram_wdata = 
        data_sram_wen==4'b1111 ? rf_rdata2 :                         // SW: 直接写32位
        data_sram_wen==4'b0001 ? {24'b0,rf_rdata2[7:0]} :            // SB: 移到最低字节
        data_sram_wen==4'b0010 ? {16'b0,rf_rdata2[7:0],8'b0} :       // SB: 移到次低字节
        data_sram_wen==4'b0100 ? {8'b0,rf_rdata2[7:0],16'b0} :       // ...
        data_sram_wen==4'b1000 ? {rf_rdata2[7:0],24'b0} :            // ...
        data_sram_wen==4'b0011 ? {16'b0,rf_rdata2[15:0]} :           // SH: 移到低半字
        data_sram_wen==4'b1100 ? {rf_rdata2[15:0],16'b0} :           // SH: 移到高半字
        32'b0;
    
    // =========================================================================
    // 6. 输出打包 (Bus Packing)
    // =========================================================================
    // 打包数据发送给 MEM 阶段
    assign ex_to_mem_bus = {
        ex_pc,          // 75:44
        data_ram_en,    // 43
        data_ram_wen,   // 42:39 (这里应该用修正后的 data_sram_wen 吗？通常建议传修正后的，或者在MEM再修正一次)
        sel_rf_res,     // 38
        rf_we,          // 37
        rf_waddr,       // 36:32
        ex_result,      // 31:0 (ALU结果/地址)
        data_ram_read   // 访存类型
    };
   
    // 打包数据前推给 ID 阶段 (Forwarding)
    assign ex_to_id_bus = {
        rf_we,          // 写使能
        rf_waddr,       // 写地址
        ex_result       // 写数据 (ALU结果)
    };
    
    // =========================================================================
    // 7. 乘法模块 (Multiplier Logic)
    // =========================================================================
    wire w_hi_we1; // 乘法产生的 HI 写使能
    wire w_lo_we1; // 乘法产生的 LO 写使能
    wire mult;     // 标记是否为有符号乘法指令
    wire multu;    // 标记是否为无符号乘法指令
    
    // 译码判断乘法指令 (Opcode=0, Func=0x18/0x19)
    assign mult = (inst[31:26] == 6'b00_0000) & (inst[15:6] == 10'b0000000000) & (inst[5:0] == 6'b01_1000);
    assign multu= (inst[31:26] == 6'b00_0000) & (inst[15:6] == 10'b0000000000) & (inst[5:0] == 6'b01_1001);
    
    assign w_hi_we1 = mult | multu ; // 只要是乘法，就要写 HI
    assign w_lo_we1 = mult | multu ; // 只要是乘法，就要写 LO
    
    wire [63:0] mul_result;  // 乘法结果
    wire mul_ready_i;        // 乘法器完成信号
    wire mul_begin;          // 开始乘法信号
    wire mul_signed;         // 有符号乘法标志
    
    assign mul_signed = mult;
    assign mul_begin = mult | multu ;

    // 实例化乘法器模块 (通常需要多个周期，或者单周期但路径长)
    mul_plus u_mul_plus(
        .clk          (clk            ),
        .start_i      (mul_begin),      // 开始信号
        .mul_sign     (mul_signed),     // 符号控制
        .opdata1_i    ( rf_rdata1    ), // 被乘数 (rs)
        .opdata2_i    ( rf_rdata2    ), // 乘数 (rt)
        .result_o     (mul_result     ), // 64位积
        .ready_o      (mul_ready_i    )  // 完成握手信号
    );

    // =========================================================================
    // 8. 除法模块 (Divider Logic)
    // =========================================================================
    wire [63:0] div_result; // 除法结果
    wire inst_div, inst_divu; // 除法指令标记
    wire div_ready_i;       // 除法器完成信号
    reg stallreq_for_div;   // 因为除法很慢，需要请求流水线暂停
    wire w_hi_we2;          // 除法产生的 HI 写使能
    wire w_lo_we2;          // 除法产生的 LO 写使能

    // 暂停逻辑：如果除法器正忙(start但未ready) 或者 乘法器正忙，则请求暂停流水线
    assign stallreq_for_ex = (stallreq_for_div & div_ready_i==1'b0) | (mul_begin & mul_ready_i==1'b0);
    
    // 告诉 ID 阶段：我也许暂停了，但我现在的状态是 ready 的吗？(握手用)
    assign ready_ex_to_id = div_ready_i | mul_ready_i;
    
    // 译码判断除法指令
    assign inst_div = (inst[31:26] == 6'b00_0000) & (inst[15:6] == 10'b0000000000) & (inst[5:0] == 6'b01_1010);
    assign inst_divu= (inst[31:26] == 6'b00_0000) & (inst[15:6] == 10'b0000000000) & (inst[5:0] == 6'b01_1011);
    
    assign w_hi_we2 = inst_div | inst_divu; // 除法也要写 HI/LO
    assign w_lo_we2 = inst_div | inst_divu;
    

    // 除法器输入信号的寄存器 (由状态机控制)
    reg [31:0] div_opdata1_o;
    reg [31:0] div_opdata2_o;
    reg div_start_o;
    reg signed_div_o;
    
    // 实例化除法器模块 (通常需要 32-34 个周期)
    div u_div(
        .rst          (rst          ),
        .clk          (clk          ),
        .signed_div_i (signed_div_o ), // 是否有符号
        .opdata1_i    (div_opdata1_o    ), // 被除数
        .opdata2_i    (div_opdata2_o    ), // 除数
        .start_i      (div_start_o      ), // 开始信号
        .annul_i      (1'b0      ),        // 取消信号(未用)
        .result_o     (div_result     ),   // 64位结果 {余数, 商}
        .ready_o      (div_ready_i      )  // 完成信号
    );

    // 除法控制状态机 (FSM) - 组合逻辑实现
    always @ (*) begin
        if (rst) begin
            stallreq_for_div = `NoStop;
            div_opdata1_o = `ZeroWord;
            div_opdata2_o = `ZeroWord;
            div_start_o = `DivStop;
            signed_div_o = 1'b0;
        end
        else begin
            // 默认全部置零/不暂停
            stallreq_for_div = `NoStop;
            div_opdata1_o = `ZeroWord;
            div_opdata2_o = `ZeroWord;
            div_start_o = `DivStop;
            signed_div_o = 1'b0;
            
            case ({inst_div,inst_divu})
                2'b10:begin // 有符号除法 DIV
                    if (div_ready_i == `DivResultNotReady) begin
                        // 1. 开始计算：送操作数，拉高 start，请求暂停流水线
                        div_opdata1_o = rf_rdata1;
                        div_opdata2_o = rf_rdata2;
                        div_start_o = `DivStart;
                        signed_div_o = 1'b1;
                        stallreq_for_div = `Stop; // 暂停流水线！
                    end
                    else if (div_ready_i == `DivResultReady) begin
                        // 2. 计算完成：停止 start，停止暂停，等待下一拍取走结果
                        div_opdata1_o = rf_rdata1;
                        div_opdata2_o = rf_rdata2;
                        div_start_o = `DivStop;
                        signed_div_o = 1'b1;
                        stallreq_for_div = `NoStop; // 恢复流水线
                    end
                    else begin
                        // 异常或空闲状态
                        div_opdata1_o = `ZeroWord;
                        div_opdata2_o = `ZeroWord;
                        div_start_o = `DivStop;
                        signed_div_o = 1'b0;
                        stallreq_for_div = `NoStop;
                    end
                end
                2'b01:begin // 无符号除法 DIVU (逻辑同上，只是 signed_div_o 为 0)
                    if (div_ready_i == `DivResultNotReady) begin
                        div_opdata1_o = rf_rdata1;
                        div_opdata2_o = rf_rdata2;
                        div_start_o = `DivStart;
                        signed_div_o = 1'b0;
                        stallreq_for_div = `Stop;
                    end
                    else if (div_ready_i == `DivResultReady) begin
                        div_opdata1_o = rf_rdata1;
                        div_opdata2_o = rf_rdata2;
                        div_start_o = `DivStop;
                        signed_div_o = 1'b0;
                        stallreq_for_div = `NoStop;
                    end
                    else begin
                        div_opdata1_o = `ZeroWord;
                        div_opdata2_o = `ZeroWord;
                        div_start_o = `DivStop;
                        signed_div_o = 1'b0;
                        stallreq_for_div = `NoStop;
                    end
                end
                default:begin
                end
            endcase
        end
    end
    
    // =========================================================================
    // 9. HI/LO 写数据选择 (HI/LO Write Mux)
    // =========================================================================
    // 选择 LO 寄存器的写入数据：优先级 乘法 > 除法 > 普通搬运(MTLO)
    assign lo_i = w_lo_we1 ? mul_result[31:0]: // 乘法结果低32位
                   w_lo_we2 ? div_result[31:0]: // 除法结果低32位 (商)
                   w_lo_we3 ? rf_rdata1:        // MTLO 指令的源数据
                   32'b0;
                   
    // 选择 HI 寄存器的写入数据
    assign hi_i = w_hi_we1 ? mul_result[63:32]: // 乘法结果高32位
                   w_hi_we2 ? div_result[63:32]: // 除法结果高32位 (余数)
                   w_hi_we3 ? rf_rdata1:        // MTHI 指令的源数据
                   32'b0;
                   
    // 聚合 HI/LO 的总写使能
    assign w_hi_we = w_hi_we1 | w_hi_we2 | w_hi_we3;
    assign w_lo_we = w_lo_we1 | w_lo_we2 | w_lo_we3;
    
    // 打包 HI/LO 写信息传给 MEM 阶段
    assign ex_to_mem1 =
    {
        w_hi_we,
        w_lo_we,
        hi_i,
        lo_i
    };
    
    // 打包 HI/LO 信息前推给 ID 阶段
    assign ex_to_id_2=
    {
        w_hi_we,
        w_lo_we,
        hi_i,
        lo_i
    };

endmodule