   // EX.v - 执行阶段模块
// 功能：执行算术逻辑运算、地址计算、乘法除法运算
// 主要功能：
// 1. 从ID阶段接收指令和控制信号
// 2. 执行ALU运算和地址计算
// 3. 处理乘法和除法运算
// 4. 生成数据存储器访问信号
// 5. 将结果传递给MEM阶段

`include "lib/defines.vh"
module EX(
    input wire clk,                    // 时钟信号
    input wire rst,                    // 复位信号，高电平有效
    // input wire flush,               // 流水线刷新信号（当前未使用）
    input wire [`StallBus-1:0] stall,  // 流水线暂停控制信号（4位）

    input wire [`ID_TO_EX_WD-1:0] id_to_ex_bus,  // 从ID阶段接收的总线信号（159位）

    output wire [`EX_TO_MEM_WD-1:0] ex_to_mem_bus,  // 发送到MEM阶段的总线信号（76位）

    output wire data_sram_en,         // 数据存储器使能信号
    output wire [3:0] data_sram_wen,  // 数据存储器写使能信号（4位，支持字节/半字/字写入）
    output wire [31:0] data_sram_addr, // 数据存储器地址（32位）
    output wire [31:0] data_sram_wdata // 数据存储器写入数据（32位）
);

    // ID到EX阶段寄存器 - 存储从ID阶段接收的数据
    reg [`ID_TO_EX_WD-1:0] id_to_ex_bus_r;

    // ID到EX阶段寄存器更新逻辑 - 在时钟上升沿触发
    always @ (posedge clk) begin
        if (rst) begin
            // 复位时清空寄存器
            id_to_ex_bus_r <= `ID_TO_EX_WD'b0;
        end
        // else if (flush) begin
        //     // 流水线刷新时清空寄存器（当前未使用）
        //     id_to_ex_bus_r <= `ID_TO_EX_WD'b0;
        // end
        else if (stall[2]==`Stop && stall[3]==`NoStop) begin
            // 当EX阶段暂停但MEM阶段不暂停时，插入空操作（气泡）
            id_to_ex_bus_r <= `ID_TO_EX_WD'b0;
        end
        else if (stall[2]==`NoStop) begin
            // 当EX阶段不暂停时，正常接收ID阶段的数据
            id_to_ex_bus_r <= id_to_ex_bus;
        end
        // 当stall[2]==`Stop且stall[3]==`Stop时，保持当前值（暂停）
    end

    // 从ID到EX总线寄存器中提取各个信号
    wire [31:0] ex_pc, inst;      // PC值和指令
    wire [11:0] alu_op;           // ALU操作类型
    wire [2:0] sel_alu_src1;      // ALU第一个操作数源选择
    wire [3:0] sel_alu_src2;      // ALU第二个操作数源选择
    wire data_ram_en;              // 数据存储器使能
    wire [3:0] data_ram_wen;       // 数据存储器写使能
    wire rf_we;                    // 寄存器写使能
    wire [4:0] rf_waddr;           // 目标寄存器地址
    wire sel_rf_res;               // 寄存器写入数据源选择
    wire [31:0] rf_rdata1, rf_rdata2;  // 寄存器读取数据
    reg is_in_delayslot;           // 延迟槽标志寄存器（当前未使用）

    // 从id_to_ex_bus_r寄存器中提取各个信号
    // 总线格式（159位）：
    assign {
        ex_pc,          // 158:127 - 当前指令的PC值（32位）
        inst,           // 126:95  - 当前指令（32位）
        rf_we,          // 94      - 寄存器写使能信号（1位）
        rf_waddr,       // 93:89   - 目标寄存器地址（5位）
        rf_rdata1,      // 88:57   - 源寄存器1的数据（32位）
        rf_rdata2,      // 56:25   - 源寄存器2的数据（32位）
        alu_op,         // 24:13   - ALU操作类型（12位）
        sel_alu_src1,   // 12:10   - ALU第一个操作数源选择（3位）
        sel_alu_src2,   // 9:7     - ALU第二个操作数源选择（3位）
        data_ram_en,    // 6       - 数据存储器使能信号（1位）
        data_ram_wen,   // 5:2     - 数据存储器写使能信号（4位）
        sel_rf_res      // 1:0     - 寄存器写入数据源选择（2位）
    } = id_to_ex_bus_r;

    // 立即数扩展 - 将16位立即数扩展为32位
    wire [31:0] imm_sign_extend, imm_zero_extend, sa_zero_extend;
    
    // 符号扩展 - 根据第15位进行符号扩展（用于有符号立即数）
    assign imm_sign_extend = {{16{inst[15]}},inst[15:0]};
    
    // 零扩展 - 在高位补0（用于无符号立即数）
    assign imm_zero_extend = {16'b0, inst[15:0]};
    
    // SA字段零扩展 - 将5位SA字段扩展为32位（用于移位指令）
    assign sa_zero_extend = {27'b0,inst[10:6]};

    // ALU操作数准备 - 根据选择信号准备ALU的两个操作数
    wire [31:0] alu_src1, alu_src2;
    wire [31:0] alu_result, ex_result;

    // ALU第一个操作数选择
    // sel_alu_src1格式：[2:0]，3位选择信号
    assign alu_src1 = sel_alu_src1[1] ? ex_pc :           // 1: 使用PC值（用于地址计算）
                      sel_alu_src1[2] ? sa_zero_extend :    // 2: 使用SA字段（用于移位）
                      rf_rdata1;                            // 0: 使用寄存器数据（默认）

    // ALU第二个操作数选择
    // sel_alu_src2格式：[3:0]，4位选择信号
    assign alu_src2 = sel_alu_src2[1] ? imm_sign_extend :  // 1: 使用符号扩展立即数（有符号运算）
                      sel_alu_src2[2] ? 32'd8 :             // 2: 使用常数8（用于地址偏移）
                      sel_alu_src2[3] ? imm_zero_extend :    // 3: 使用零扩展立即数（无符号运算）
                      rf_rdata2;                             // 0: 使用寄存器数据（默认）
    
    // ALU实例化 - 执行算术逻辑运算
    alu u_alu(
        .alu_control (alu_op    ),  // ALU操作控制信号（12位）
        .alu_src1    (alu_src1  ),  // ALU第一个操作数（32位）
        .alu_src2    (alu_src2  ),  // ALU第二个操作数（32位）
        .alu_result  (alu_result)   // ALU运算结果（32位）
    );

    // ALU结果赋值 - 当前阶段ALU结果就是最终执行结果
    assign ex_result = alu_result;

    // EX到MEM阶段总线信号构建 - 将EX阶段的结果和控制信号打包
    // ex_to_mem_bus总线格式（76位）：
    assign ex_to_mem_bus = {
        ex_pc,          // 75:44 - 当前指令的PC值（32位）
        data_ram_en,    // 43      - 数据存储器使能信号（1位）
        data_ram_wen,   // 42:39   - 数据存储器写使能信号（4位）
        sel_rf_res,     // 38      - 寄存器写入数据源选择（1位）
        rf_we,          // 37      - 寄存器写使能信号（1位）
        rf_waddr,       // 36:32   - 目标寄存器地址（5位）
        ex_result       // 31:0    - ALU运算结果（32位）
    };

    // 乘法运算部分 - 当前未使用（乘法器输入未连接）
    // MUL part
    wire [63:0] mul_result;      // 64位乘法结果
    wire mul_signed;             // 有符号乘法标记（当前未使用）

    mul u_mul(
        .clk        (clk            ),  // 时钟信号
        .resetn     (~rst           ),  // 复位信号（低电平有效，取反后连接）
        .mul_signed (mul_signed     ),  // 有符号乘法标记（当前未使用）
        .ina        (      ),           // 乘法源操作数1（当前未连接）
        .inb        (      ),           // 乘法源操作数2（当前未连接）
        .result     (mul_result     )   // 乘法结果 64bit
    );

    // 除法运算部分 - 当前未使用（除法指令未实现）
    // DIV part
    wire [63:0] div_result;        // 64位除法结果
    wire inst_div, inst_divu;      // 除法指令标记（当前未使用）
    wire div_ready_i;              // 除法就绪信号
    reg stallreq_for_div;          // 除法暂停请求信号
    assign stallreq_for_ex = stallreq_for_div;  // 将除法暂停请求传递给EX阶段

    reg [31:0] div_opdata1_o;      // 除法操作数1
    reg [31:0] div_opdata2_o;      // 除法操作数2
    reg div_start_o;               // 除法开始信号
    reg signed_div_o;              // 有符号除法标记

    // 除法器实例化 - 当前未使用（除法指令未实现）
    div u_div(
        .rst          (rst          ),  // 复位信号
        .clk          (clk          ),  // 时钟信号
        .signed_div_i (signed_div_o ),  // 有符号除法标记
        .opdata1_i    (div_opdata1_o    ),  // 除法操作数1
        .opdata2_i    (div_opdata2_o    ),  // 除法操作数2
        .start_i      (div_start_o      ),  // 除法开始信号
        .annul_i      (1'b0      ),       // 取消信号（当前固定为0）
        .result_o     (div_result     ),   // 除法结果 64bit
        .ready_o      (div_ready_i      )   // 除法就绪信号
    );

    // 除法控制逻辑 - 当前未使用（除法指令未实现）
    always @ (*) begin
        if (rst) begin
            // 复位时初始化所有除法相关信号
            stallreq_for_div = `NoStop;
            div_opdata1_o = `ZeroWord;
            div_opdata2_o = `ZeroWord;
            div_start_o = `DivStop;
            signed_div_o = 1'b0;
        end
        else begin
            // 默认状态：不进行除法运算
            stallreq_for_div = `NoStop;
            div_opdata1_o = `ZeroWord;
            div_opdata2_o = `ZeroWord;
            div_start_o = `DivStop;
            signed_div_o = 1'b0;
            
            // 根据指令类型进行除法运算（当前未使用）
            case ({inst_div,inst_divu})
                2'b10:begin  // 有符号除法指令
                    if (div_ready_i == `DivResultNotReady) begin
                        // 除法器未就绪，设置操作数并开始运算，请求暂停流水线
                        div_opdata1_o = rf_rdata1;
                        div_opdata2_o = rf_rdata2;
                        div_start_o = `DivStart;
                        signed_div_o = 1'b1;
                        stallreq_for_div = `Stop;
                    end
                    else if (div_ready_i == `DivResultReady) begin
                        // 除法器就绪，停止运算，允许流水线继续
                        div_opdata1_o = rf_rdata1;
                        div_opdata2_o = rf_rdata2;
                        div_start_o = `DivStop;
                        signed_div_o = 1'b1;
                        stallreq_for_div = `NoStop;
                    end
                    else begin
                        // 其他状态：保持默认
                        div_opdata1_o = `ZeroWord;
                        div_opdata2_o = `ZeroWord;
                        div_start_o = `DivStop;
                        signed_div_o = 1'b0;
                        stallreq_for_div = `NoStop;
                    end
                end
                2'b01:begin  // 无符号除法指令
                    if (div_ready_i == `DivResultNotReady) begin
                        // 除法器未就绪，设置操作数并开始运算，请求暂停流水线
                        div_opdata1_o = rf_rdata1;
                        div_opdata2_o = rf_rdata2;
                        div_start_o = `DivStart;
                        signed_div_o = 1'b0;
                        stallreq_for_div = `Stop;
                    end
                    else if (div_ready_i == `DivResultReady) begin
                        // 除法器就绪，停止运算，允许流水线继续
                        div_opdata1_o = rf_rdata1;
                        div_opdata2_o = rf_rdata2;
                        div_start_o = `DivStop;
                        signed_div_o = 1'b0;
                        stallreq_for_div = `NoStop;
                    end
                    else begin
                        // 其他状态：保持默认
                        div_opdata1_o = `ZeroWord;
                        div_opdata2_o = `ZeroWord;
                        div_start_o = `DivStop;
                        signed_div_o = 1'b0;
                        stallreq_for_div = `NoStop;
                    end
                end
                default:begin
                    // 非除法指令：保持默认状态
                end
            endcase
        end
    end

    // 乘法结果和除法结果可以直接使用（当前未使用）
    // mul_result 和 div_result 可以直接使用
    
    
endmodule  // EX模块结束