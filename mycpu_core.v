`include "lib/defines.vh"  // 包含定义文件，包含各种常量和参数定义

// CPU核心模块 - 实现一个五级流水线MIPS处理器
// 包含IF(取指)、ID(译码)、EX(执行)、MEM(访存)、WB(写回)五个阶段
module mycpu_core(
    // 时钟和复位信号
    input wire clk,      // 系统时钟信号
    input wire rst,      // 复位信号，高电平有效：当这个信号来了（高电平），不管CPU手里在干啥（哪怕算了一半），立刻把所有东西扔掉，大脑清空，回到第一行代码（PC=0）重新开始。刚通电时必须要按一下这个，不然 CPU 不知道自己在哪。
    input wire [5:0] int, // 中断信号，6位中断向量（当前未使用）：当外部设备（比如键盘按下了、网卡来数据了）有急事找 CPU 时，就通过这根线“响铃”。CPU 听到后，会根据心情（中断逻辑）决定要不要停下手里的活去接电话。

    // 指令存储器接口 - 用于获取指令
    /*
    inst_sram (指令仓库)：专门放代码（编译后的二进制机器码）。
    */
    output wire inst_sram_en,     // 指令SRAM使能信号：如果这根线是 0，仓库管理员根本理都不理你，省电。只有它是 1，仓库才开始干活。
    output wire [3:0] inst_sram_wen, // 指令SRAM写使能信号（4位字节写使能）
    output wire [31:0] inst_sram_addr, // 指令SRAM地址，32位地址总线：货架号。
    output wire [31:0] inst_sram_wdata, // 指令SRAM写入数据：送进去的货。
    input wire [31:0] inst_sram_rdata, // 指令SRAM读取数据：从仓库拿出来的货。

    // 数据存储器接口 - 用于加载/存储数据
    /*
    data_sram (数据仓库)：专门放变量（数组、全局变量等）。
    */
    output wire data_sram_en,     // 数据SRAM使能信号
    output wire [3:0] data_sram_wen, // 数据SRAM写使能信号（4位字节写使能）
    output wire [31:0] data_sram_addr, // 数据SRAM地址，32位地址总线
    output wire [31:0] data_sram_wdata, // 数据SRAM写入数据
    input wire [31:0] data_sram_rdata, // 数据SRAM读取数据

    // 调试接口 - 用于观察写回阶段的寄存器写入信息
    /*
    唯一的“上帝视角” (调试接口)：做硬件最痛苦的是什么？是看不见。 你写 Python 可以 print(a)，但硬件烧进板子后就是个黑盒子。你不知道它死机是因为死循环了，还是算错了。
    */
    output wire [31:0] debug_wb_pc,     // 写回阶段的PC值（程序计数器）：告诉外面，CPU 刚刚执行完的那条指令的地址是多少。如果你发现它一直停在一个地方不动，就是死循环了。
    output wire [3:0] debug_wb_rf_wen,  // 写回阶段的寄存器文件写使能：这也是个 4 位的“写开关”。如果它亮了，说明刚才那条指令修改了通用寄存器。
    output wire [4:0] debug_wb_rf_wnum, // 写回阶段要写入的寄存器编号（5位，支持32个寄存器）：MIPS 有 32 个通用寄存器（R0 - R31）。这个信号告诉你是 R几 被改了。
    output wire [31:0] debug_wb_rf_wdata // 写回阶段要写入的寄存器数据：具体的数值。
);
    // 流水线级间总线定义
    /*
    全是 CPU 内部 模块之间互相传递东西用的。因为它们不露在芯片外面，所以都叫 wire（内部连线）。
    我们可以把这五级流水线（IF, ID, EX, MEM, WB）想象成工厂里的 5 个车间工人，他们排成一排坐在流水线上。这些 wire 就是连接他们办公桌的 传送带 或者 加急信封。
    */
    wire [`IF_TO_ID_WD-1:0] if_to_id_bus;  // IF到ID阶段的总线，传递取指结果
    wire [`ID_TO_EX_WD-1:0] id_to_ex_bus;  // ID到EX阶段的总线，传递译码结果
    wire [`EX_TO_MEM_WD-1:0] ex_to_mem_bus; // EX到MEM阶段的总线，传递执行结果
    wire [`MEM_TO_WB_WD-1:0] mem_to_wb_bus; // MEM到WB阶段的总线，传递访存结果
    wire [`BR_WD-1:0] br_bus;              // 分支预测/跳转相关信号总线：“紧急改道通知”：如果发现这行代码是 goto (跳转) 或者 if (a > b) 成立了，必须立刻通知最前面的 取指工人 (IF)。
    wire [`DATA_SRAM_WD-1:0] ex_dt_sram_bus; // EX阶段到数据存储器的总线（当前未使用）
    wire [`WB_TO_RF_WD-1:0] wb_to_rf_bus;   // WB阶段到寄存器文件的写回总线：写回工人 (WB) 拿着最终结果，不能自己留着，必须写回到 ID 阶段 管理的寄存器堆里。
    wire [`StallBus-1:0] stall;              // 流水线暂停控制信号总线
    
    // 未使用的信号声明（用于后续扩展）
    wire stallreq;                           // ID阶段暂停请求信号（当前未连接）

    // IF阶段实例化 - 负责指令取指
    // 功能：从指令存储器读取指令，处理分支跳转，传递指令到译码阶段
    IF u_IF(
    	.clk             (clk             ),  // 时钟信号
        .rst             (rst             ),  // 复位信号
        .stall           (stall           ),  // 流水线暂停信号
        .br_bus          (br_bus          ),  // 分支预测/跳转信号
        .if_to_id_bus    (if_to_id_bus    ),  // 传递到ID阶段的总线
        .inst_sram_en    (inst_sram_en    ),  // 指令存储器使能
        .inst_sram_wen   (inst_sram_wen   ),  // 指令存储器写使能
        .inst_sram_addr  (inst_sram_addr  ),  // 指令存储器地址
        .inst_sram_wdata (inst_sram_wdata )   // 指令存储器写入数据
    );
    

    // ID阶段实例化 - 负责指令译码
    // 功能：解析指令，读取寄存器，检测冒险，生成控制信号，传递到执行阶段
    ID u_ID(
    	.clk             (clk             ),  // 时钟信号
        .rst             (rst             ),  // 复位信号
        .stall           (stall           ),  // 流水线暂停信号
        .stallreq        (stallreq        ),  // ID阶段的暂停请求信号（当前未连接）
        .if_to_id_bus    (if_to_id_bus    ),  // 来自IF阶段的指令和数据
        .inst_sram_rdata (inst_sram_rdata ),  // 从指令存储器读取的指令数据
        .wb_to_rf_bus    (wb_to_rf_bus    ),  // 来自WB阶段的写回数据（用于数据前递）
        .id_to_ex_bus    (id_to_ex_bus    ),  // 传递到EX阶段的总线
        .br_bus          (br_bus          )   // 分支预测相关信号
    );

    // EX阶段实例化 - 负责指令执行
    // 功能：执行算术逻辑运算，计算内存地址，处理分支跳转，传递到访存阶段
    EX u_EX(
    	.clk             (clk             ),  // 时钟信号
        .rst             (rst             ),  // 复位信号
        .stall           (stall           ),  // 流水线暂停信号
        .id_to_ex_bus    (id_to_ex_bus    ),  // 来自ID阶段的译码结果
        .ex_to_mem_bus   (ex_to_mem_bus   ),  // 传递到MEM阶段的总线
        .data_sram_en    (data_sram_en    ),  // 数据存储器使能信号
        .data_sram_wen   (data_sram_wen   ),  // 数据存储器写使能信号
        .data_sram_addr  (data_sram_addr  ),  // 数据存储器地址
        .data_sram_wdata (data_sram_wdata )   // 数据存储器写入数据
    );

    // MEM阶段实例化 - 负责数据访存
    // 功能：执行加载/存储操作，处理内存访问，传递数据到写回阶段
    MEM u_MEM(
    	.clk             (clk             ),  // 时钟信号
        .rst             (rst             ),  // 复位信号
        .stall           (stall           ),  // 流水线暂停信号
        .ex_to_mem_bus   (ex_to_mem_bus   ),  // 来自EX阶段的执行结果
        .data_sram_rdata (data_sram_rdata ),  // 从数据存储器读取的数据
        .mem_to_wb_bus   (mem_to_wb_bus   )   // 传递到WB阶段的总线
    );
    
    // WB阶段实例化 - 负责结果写回
    // 功能：将最终结果写回寄存器文件，提供调试信息
    WB u_WB(
    	.clk               (clk               ),  // 时钟信号
        .rst               (rst               ),  // 复位信号
        .stall             (stall             ),  // 流水线暂停信号
        .mem_to_wb_bus     (mem_to_wb_bus     ),  // 来自MEM阶段的数据
        .wb_to_rf_bus      (wb_to_rf_bus      ),  // 写回到寄存器文件的总线
        .debug_wb_pc       (debug_wb_pc       ),  // 调试：写回阶段的PC值
        .debug_wb_rf_wen   (debug_wb_rf_wen   ),  // 调试：寄存器写使能
        .debug_wb_rf_wnum  (debug_wb_rf_wnum  ),  // 调试：寄存器编号
        .debug_wb_rf_wdata (debug_wb_rf_wdata )  // 调试：寄存器写入数据
    );

    // 控制单元实例化 - 负责流水线暂停控制
    // 功能：检测流水线冒险，生成暂停信号，保证流水线正确执行
    CTRL u_CTRL(
    	.rst   (rst   ),  // 复位信号
        .stall (stall )   // 流水线暂停控制信号
    );
    
endmodule  // mycpu_core模块结束