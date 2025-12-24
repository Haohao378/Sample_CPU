// ID.v - 指令译码阶段模块
// 功能：解析指令，读取寄存器，生成控制信号，检测分支，传递到执行阶段

`include "lib/defines.vh"  // 包含定义文件，里面有各种常量和参数定义

module ID(  // ID模块定义，这是流水线的第二个阶段 - 译码阶段
    // 时钟和复位信号
    input wire clk,                    // 时钟信号，上升沿触发
    input wire rst,                    // 复位信号，高电平有效
    // input wire flush,                // 流水线刷新信号（被注释掉）
    input wire [`StallBus-1:0] stall,  // 流水线暂停控制信号总线，来自控制单元
    
    output wire stallreq,              // 暂停请求信号，ID阶段向控制单元请求暂停

    // 来自IF阶段的输入总线
    input wire [`IF_TO_ID_WD-1:0] if_to_id_bus,  // 包含PC值和芯片使能信号

    // 来自指令存储器的输入
    input wire [31:0] inst_sram_rdata,  // 从指令存储器读取的32位指令

    // 来自WB阶段的写回总线（用于数据前递）
    input wire [`WB_TO_RF_WD-1:0] wb_to_rf_bus,  // 写回寄存器文件的信息

    // 输出到EX阶段的总线
    output wire [`ID_TO_EX_WD-1:0] id_to_ex_bus,  // 包含译码结果和操作数等信息

    // 分支相关输出
    output wire [`BR_WD-1:0] br_bus              // 分支使能信号和目标地址
);

    // 内部寄存器和连线定义
    reg [`IF_TO_ID_WD-1:0] if_to_id_bus_r;  // 寄存器，存储来自IF阶段的信息(33bit)
    wire [31:0] inst;                        // 连线，存储当前指令
    wire [31:0] id_pc;                      // 连线，存储当前指令的PC地址
    wire ce;                                 // 连线，芯片使能信号

    // 来自WB阶段的写回信号
    wire wb_rf_we;                          // 写回使能信号
    wire [4:0] wb_rf_waddr;                // 写回寄存器地址（5位，支持32个寄存器）
    wire [31:0] wb_rf_wdata;                // 写回数据

    // IF到ID阶段寄存器更新逻辑 - 在时钟上升沿触发
    always @ (posedge clk) begin  // 当clk从0变到1时执行
        if (rst) begin  // 如果复位信号有效
            if_to_id_bus_r <= `IF_TO_ID_WD'b0;  // 将寄存器清零（全0）
        end
        // else if (flush) begin  // 以下代码被注释掉，可能在后续版本使用
        //     ic_to_id_bus <= `IC_TO_ID_WD'b0;
        // end
        else if (stall[1]==`Stop && stall[2]==`NoStop) begin  // 如果ID阶段需要暂停但EX阶段不需要
            if_to_id_bus_r <= `IF_TO_ID_WD'b0;  // 插入气泡（bubble），传递空指令
        end
        else if (stall[1]==`NoStop) begin  // 如果ID阶段不需要暂停
            if_to_id_bus_r <= if_to_id_bus;  // 正常接收来自IF阶段的信息
        end
        // 如果stall[1]为`Stop且stall[2]也为`Stop，保持当前值不变（暂停）
    end
    
    // 指令赋值 - 直接使用从指令存储器读取的数据
    assign inst = inst_sram_rdata;  // 将32位指令数据赋给inst变量
    
    // 从IF到ID阶段寄存器中提取信号
    // if_to_id_bus格式：{ce, id_pc}，ce占1位，id_pc占32位
    assign {
        ce,      // 1位：芯片使能信号
        id_pc    // 32位：当前指令的PC地址
    } = if_to_id_bus_r;
    
    // 从WB阶段写回总线中提取信号
    // wb_to_rf_bus格式：{wb_rf_we, wb_rf_waddr, wb_rf_wdata}
    assign {
        wb_rf_we,     // 1位：写回使能信号
        wb_rf_waddr,  // 5位：写回寄存器地址
        wb_rf_wdata   // 32位：写回数据
    } = wb_to_rf_bus;

    // 指令字段定义 - 从32位指令中提取各个字段
    wire [5:0] opcode;      // 操作码，6位，指令[31:26]
    wire [4:0] rs,rt,rd,sa; // 寄存器编号，各5位。rs:指令[25:21], rt:指令[20:16], rd:指令[15:11], sa:指令[10:6]
    wire [5:0] func;        // 功能码，6位，指令[5:0]，用于R型指令
    wire [15:0] imm;        // 立即数，16位，指令[15:0]
    wire [25:0] instr_index; // 指令索引，26位，指令[25:0]，用于J型指令
    wire [19:0] code;       // 代码字段，20位，指令[25:6]
    wire [4:0] base;        // 基址寄存器，5位，指令[25:21]，用于加载/存储指令
    wire [15:0] offset;     // 偏移量，16位，指令[15:0]，用于加载/存储指令
    wire [2:0] sel;         // 选择字段，3位，指令[2:0]，用于特殊指令

    // 译码器输出信号定义
    wire [63:0] op_d, func_d;     // 操作码和功能码的译码结果，64位宽
    wire [31:0] rs_d, rt_d, rd_d, sa_d;  // 寄存器地址的译码结果，各32位宽

    // ALU控制信号
    wire [2:0] sel_alu_src1;  // ALU第一个操作数的选择信号，3位
    wire [3:0] sel_alu_src2;  // ALU第二个操作数的选择信号，4位
    wire [11:0] alu_op;      // ALU操作类型，12位

    // 数据存储器控制信号
    wire data_ram_en;        // 数据存储器使能信号
    wire [3:0] data_ram_wen; // 数据存储器写使能信号，4位字节使能
    
    // 寄存器文件控制信号
    wire rf_we;              // 寄存器写使能信号
    wire [4:0] rf_waddr;     // 要写入的寄存器地址，5位
    wire sel_rf_res;         // 寄存器写入数据源选择（0:ALU结果，1:内存数据）
    wire [2:0] sel_rf_dst;   // 目标寄存器选择信号，3位

    // 寄存器读取数据
    wire [31:0] rdata1, rdata2;  // 从寄存器文件读取的两个32位数据

    // 寄存器文件实例化 - 存储32个32位寄存器
    // 功能：提供寄存器读写功能，支持两个读端口和一个写端口
    regfile u_regfile(
    	.clk    (clk    ),           // 时钟信号
        .raddr1 (rs ),              // 第一个读端口地址（源寄存器1）
        .rdata1 (rdata1 ),          // 第一个读端口数据输出
        .raddr2 (rt ),              // 第二个读端口地址（源寄存器2）
        .rdata2 (rdata2 ),          // 第二个读端口数据输出
        .we     (wb_rf_we     ),    // 写使能信号
        .waddr  (wb_rf_waddr  ),    // 写端口地址（目标寄存器）
        .wdata  (wb_rf_wdata  )     // 写端口数据输入
    );

    // 指令字段提取 - 从32位指令中提取各个字段
    // MIPS指令格式：R型、I型、J型
    assign opcode = inst[31:26];      // 操作码，6位，指令的最高6位
    assign rs = inst[25:21];          // 源寄存器1，5位
    assign rt = inst[20:16];          // 源寄存器2，5位
    assign rd = inst[15:11];          // 目标寄存器，5位
    assign sa = inst[10:6];           // 移位量，5位，用于移位指令
    assign func = inst[5:0];           // 功能码，6位，R型指令的最低6位
    assign imm = inst[15:0];          // 立即数，16位，I型指令的低位
    assign instr_index = inst[25:0];  // 指令索引，26位，J型指令的低位
    assign code = inst[25:6];         // 代码字段，20位
    assign base = inst[25:21];        // 基址寄存器，5位，加载/存储指令使用
    assign offset = inst[15:0];       // 偏移量，16位，加载/存储指令使用
    assign sel = inst[2:0];           // 选择字段，3位

    // 指令类型识别信号
    wire inst_ori, inst_lui, inst_addiu, inst_beq;  // 具体的指令类型
    /*
    inst_ori: "我是 ORI" (Or Immediate)。

    意思：我要做“或运算”，而且是跟一个立即数做。

    inst_lui: "我是 LUI" (Load Upper Immediate)。

    意思：我要把一个数加载到寄存器的高 16 位。

    inst_addiu: "我是 ADDIU" (Add Immediate Unsigned)。

    意思：我要做加法，跟立即数加，别管符号位。

    inst_beq: "我是 BEQ" (Branch if Equal)。

    意思：如果两个数相等，我就跳转。
    */

    // ALU操作类型信号
    wire op_add, op_sub, op_slt, op_sltu;  // 算术运算
    /*
    op_add (加法)功能：$A + B$。不仅是做加法：除了 add 指令，所有的内存读写（lw, sw）其实也是加法。因为计算内存地址时，需要用 基地址 + 偏移量。
    op_sub (减法)功能：$A - B$。隐形用途：beq (相等跳转) 和 bne (不等跳转) 也是用减法。如果 $A - B = 0$，CPU 就知道它俩相等了。
    op_slt (Set on Less Than - 有符号比较)功能：如果是负数 $-5$ 和正数 $3$ 比，它知道 $-5$ 更小。结果：如果 $A < B$，结果置 1；否则置 0。
    op_sltu (Set on Less Than Unsigned - 无符号比较)功能：把所有数都当正数。比如地址比较时，或者处理超大整数时用。区别：在这里，0xFFFFFFFF (在有符号里是 -1) 会被当成很大的正数，比 0x00000001 大。
    */
    wire op_and, op_nor, op_or, op_xor;  // 逻辑运算
    /*
    op_and (与)
    逻辑：全是 1 才是 1。
    用途：“清零”。比如你想把一个数的低 8 位保留，高位全抹掉，就 AND 0x000000FF。
    op_or (或)
    逻辑：只要有 1 就是 1。
    用途：“拼凑”。比如把两个半字节拼成一个整字节。
    op_nor (或非)
    逻辑：全不是 1 才是 1（先 OR 再取反）。
    用途：MIPS 只有 NOR，没有 NOT。如果你想取反一个数（把 0 变 1，1 变 0），就用 NOR A, 0。
    op_xor (异或)
    逻辑：不一样就是 1，一样就是 0。
    用途：“找不同” 或者 “翻转”。如果你想把某一位反转一下，就异或 1。
    */
    wire op_sll, op_srl, op_sra, op_lui; // 移位和加载高位运算
    /*
    op_sll (Shift Left Logical - 逻辑左移)
    动作：往左推，右边补 0。
    数学含义：相当于 乘以 2 的 N 次方。
    op_srl (Shift Right Logical - 逻辑右移)
    动作：往右推，左边补 0。
    数学含义：相当于 除以 2 的 N 次方（针对无符号数）。
    op_sra (Shift Right Arithmetic - 算术右移)
    动作：往右推，但左边补符号位（原来最高位是 1 就补 1，是 0 就补 0）。
    作用：这是为了带符号数设计的。比如 -8 (1111...1000) 右移变成 -4 (1111...1100)，必须补 1 才能保持它是负数。
    op_lui (Load Upper Immediate - 加载高位)
    动作：把一个 16 位的数字，直接搬到 32 位寄存器的 上半部分 ([31:16])，下半部分清零。
    作用：MIPS 一条指令只能存 16 位常数。如果你想要个 32 位的大常数，必须分两步：先 LUI 搬一半到楼上，再用 OR 搬一半到楼下。
    */

    /*
    独热码就是：“一群人里，永远只有一个人举手。”
    */
    // 操作码译码器 - 将6位操作码译码为64位独热码
    decoder_6_64 u0_decoder_6_64(
    	.in  (opcode  ),  // 输入：6位操作码
        .out (op_d )      // 输出：64位译码结果，每一位对应一个操作码
    );

    // 功能码译码器 - 将6位功能码译码为64位独热码（用于R型指令）
    decoder_6_64 u1_decoder_6_64(
    	.in  (func  ),    // 输入：6位功能码
        .out (func_d )    // 输出：64位译码结果
    );
    
    // 寄存器地址译码器1 - 将5位寄存器地址译码为32位独热码
    decoder_5_32 u0_decoder_5_32(
    	.in  (rs  ),      // 输入：5位源寄存器1地址
        .out (rs_d )      // 输出：32位译码结果
    );

    // 寄存器地址译码器2 - 将5位寄存器地址译码为32位独热码
    decoder_5_32 u1_decoder_5_32(
    	.in  (rt  ),      // 输入：5位源寄存器2地址
        .out (rt_d )      // 输出：32位译码结果
    );

    
    // 指令类型识别 - 根据操作码判断当前是什么指令
    // 使用操作码的数值作为索引，从译码器输出中选择对应的位
    assign inst_ori     = op_d[6'b00_1101];  // ori指令，操作码为0x0D（13）
    assign inst_lui     = op_d[6'b00_1111];  // lui指令，操作码为0x0F（15）
    assign inst_addiu   = op_d[6'b00_1001];  // addiu指令，操作码为0x09（9）
    assign inst_beq     = op_d[6'b00_0100];  // beq指令，操作码为0x04（4）



    // ALU第一个操作数源选择逻辑 - 3位选择信号
    // sel_alu_src1格式：[2:0]，选择ALU的第一个输入操作数
    assign sel_alu_src1[0] = inst_ori | inst_addiu;  // 位0：选择rs寄存器作为源1（ori或addiu指令）

    assign sel_alu_src1[1] = 1'b0;  // 位1：选择PC作为源1（当前未使用）

    assign sel_alu_src1[2] = 1'b0;  // 位2：选择移位量作为源1（当前未使用）

    
    // ALU第二个操作数源选择逻辑 - 4位选择信号
    // sel_alu_src2格式：[3:0]，选择ALU的第二个输入操作数
    assign sel_alu_src2[0] = 1'b0;  // 位0：选择rt寄存器作为源2（当前未使用）
    
    assign sel_alu_src2[1] = inst_lui | inst_addiu;  // 位1：选择符号扩展立即数（lui或addiu指令）

    assign sel_alu_src2[2] = 1'b0;  // 位2：选择常数8作为源2（当前未使用，可能用于调整栈指针）

    assign sel_alu_src2[3] = inst_ori;  // 位3：选择零扩展立即数（ori指令）



    // ALU操作类型赋值 - 根据指令类型设置相应的ALU操作
    assign op_add = inst_addiu;  // addiu指令需要加法操作
    assign op_sub = 1'b0;        // 减法操作（当前未使用）
    assign op_slt = 1'b0;        // 小于置位操作（当前未使用）
    assign op_sltu = 1'b0;       // 无符号小于置位操作（当前未使用）
    assign op_and = 1'b0;        // 与操作（当前未使用）
    assign op_nor = 1'b0;        // 或非操作（当前未使用）
    assign op_or = inst_ori;     // ori指令需要或操作
    assign op_xor = 1'b0;        // 异或操作（当前未使用）
    assign op_sll = 1'b0;        // 逻辑左移操作（当前未使用）
    assign op_srl = 1'b0;        // 逻辑右移操作（当前未使用）
    assign op_sra = 1'b0;        // 算术右移操作（当前未使用）
    assign op_lui = inst_lui;    // lui指令需要加载高位操作

    // 构建12位ALU操作控制信号
    // alu_op格式：{op_add, op_sub, op_slt, op_sltu, op_and, op_nor, op_or, op_xor, op_sll, op_srl, op_sra, op_lui}
    assign alu_op = {op_add, op_sub, op_slt, op_sltu,
                     op_and, op_nor, op_or, op_xor,
                     op_sll, op_srl, op_sra, op_lui};



    // 数据存储器控制信号赋值
    // load and store enable
    assign data_ram_en = 1'b0;   // 数据存储器使能信号，当前未使用加载/存储指令，设为0

    // write enable
    assign data_ram_wen = 1'b0;  // 数据存储器写使能信号，当前未使用存储指令，设为0



    // 寄存器文件写使能信号 - 判断哪些指令需要写回寄存器
    // regfile store enable
    assign rf_we = inst_ori | inst_lui | inst_addiu;  // ori、lui、addiu指令需要写回结果到寄存器



    // 目标寄存器选择逻辑 - 决定将结果写入哪个寄存器
    // sel_rf_dst格式：[2:0]，3位选择信号
    // store in [rd] - R型指令的目标寄存器
    assign sel_rf_dst[0] = 1'b0;  // 当前未使用R型指令，设为0
    
    // store in [rt] - I型指令的目标寄存器
    assign sel_rf_dst[1] = inst_ori | inst_lui | inst_addiu;  // ori、lui、addiu指令使用rt作为目标寄存器
    
    // store in [31] - 寄存器31（通常用于链接寄存器）
    assign sel_rf_dst[2] = 1'b0;  // 当前未使用链接指令，设为0

    // 目标寄存器地址计算 - 根据选择信号决定最终写入哪个寄存器
    // sel for regfile address
    assign rf_waddr = {5{sel_rf_dst[0]}} & rd   // 如果选择rd，则使用rd字段
                    | {5{sel_rf_dst[1]}} & rt   // 如果选择rt，则使用rt字段
                    | {5{sel_rf_dst[2]}} & 32'd31;  // 如果选择31号寄存器，则使用31

    // 寄存器写入数据源选择 - 决定写入寄存器的数据来源
    // 0 from alu_res ; 1 from ld_res
    assign sel_rf_res = 1'b0;  // 0: 来自ALU结果，1: 来自内存加载结果。当前只使用ALU结果 

    // ID到EX阶段总线信号构建 - 将ID阶段的所有控制信号和数据打包
    // id_to_ex_bus总线格式（159位）：
    assign id_to_ex_bus = {
        id_pc,          // 158:127 - 当前指令的PC值（32位）
        inst,           // 126:95  - 当前指令（32位）
        rf_we,          // 94      - 寄存器写使能信号（1位）
        rf_waddr,       // 93:89   - 目标寄存器地址（5位）
        rdata1,         // 88:57   - 源寄存器1的数据（32位）
        rdata2,         // 56:25   - 源寄存器2的数据（32位）
        alu_op,         // 24:13   - ALU操作类型（12位）
        sel_alu_src1,   // 12:10   - ALU第一个操作数源选择（3位）
        sel_alu_src2,   // 9:7     - ALU第二个操作数源选择（3位）
        data_ram_en,    // 6       - 数据存储器使能信号（1位）
        data_ram_wen,   // 5:2     - 数据存储器写使能信号（4位）
        sel_rf_res      // 1:0     - 寄存器写入数据源选择（2位）
    };


    wire br_e;
    wire [31:0] br_addr;
    wire rs_eq_rt;
    wire rs_ge_z;
    wire rs_gt_z;
    wire rs_le_z;
    wire rs_lt_z;
    wire [31:0] pc_plus_4;
    assign pc_plus_4 = id_pc + 32'h4;

    assign rs_eq_rt = (rdata1 == rdata2);

    assign br_e = inst_beq & rs_eq_rt;
    assign br_addr = inst_beq ? (pc_plus_4 + {{14{inst[15]}},inst[15:0],2'b0}) : 32'b0;

    assign br_bus = {
        br_e,
        br_addr
    };
    


endmodule  // ID模块结束