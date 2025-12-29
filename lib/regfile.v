`include "defines.vh" // 引入全局宏定义文件

// 定义寄存器堆模块
module regfile(
    input wire clk,                 // 全局时钟信号

    // --- 通用寄存器读端口 1 (Port 1) ---
    input wire [4:0] raddr1,        // 读地址1 (源寄存器 rs 的地址)
    output wire [31:0] rdata1,      // 读数据1 (输出 rs 的值，已包含前推逻辑)

    // --- 通用寄存器读端口 2 (Port 2) ---
    input wire [4:0] raddr2,        // 读地址2 (源寄存器 rt 的地址)
    output wire [31:0] rdata2,      // 读数据2 (输出 rt 的值，已包含前推逻辑)

    // --- 数据前推 (Forwarding) 输入总线 ---
    // 为了解决数据冒险，需要从后续流水级获取最新的计算结果
    input wire [37:0] ex_to_id_bus, // 来自 EX 阶段的前推数据 (含写使能、写地址、写数据)
    input wire [37:0] mem_to_id_bus,// 来自 MEM 阶段的前推数据
    input wire [37:0] wb_to_id_bus, // 来自 WB 阶段的前推数据 (其实也是当前的写回数据)

    // --- HI/LO 寄存器前推输入总线 ---
    input wire [65:0] ex_to_id_2,   // 来自 EX 阶段的 HI/LO 前推数据
    input wire [65:0] mem_to_id_2,  // 来自 MEM 阶段的 HI/LO 前推数据
    input wire [65:0] wb_to_id_2,   // 来自 WB 阶段的 HI/LO 前推数据
    
    // --- 通用寄存器写端口 (来自 WB 阶段) ---
    input wire we,                  // 写使能 (Write Enable)
    input wire [4:0] waddr,         // 写地址 (要写入哪个寄存器)
    input wire [31:0] wdata,        // 写数据 (要写入的具体数值)
    
//    input wire we, (重复定义被注释)

      // --- HI/LO 寄存器写端口 ---
      input wire w_hi_we,           // 写 HI 寄存器使能
      input wire w_lo_we,           // 写 LO 寄存器使能
      input wire [31:0] hi_i,       // 写入 HI 的数据
      input wire [31:0] lo_i,       // 写入 LO 的数据

      // --- HI/LO 寄存器读端口 ---
      input wire r_hi_we,           // 读 HI 寄存器使能 (用于判断是否需要输出)
      input wire r_lo_we,           // 读 LO 寄存器使能
      output wire[31:0] hi_o,       // 输出 HI 寄存器的值 (已包含前推)
      output wire[31:0] lo_o,       // 输出 LO 寄存器的值 (已包含前推)

    // --- LSA 指令专用接口 ---
    input [31:0] inst,              // 当前指令码 (用于提取 LSA 的移位量字段)
    input inst_lsa                  // LSA 指令标志位 (1表示当前是LSA指令)
);

    // =========================================================================
    // 1. 物理存储单元定义
    // =========================================================================
    reg [31:0] reg_array [31:0];    // 定义 32 个 32 位的通用寄存器 ($0 - $31)
    reg [31:0] hi;                  // 定义 HI 专用寄存器
    reg [31:0] lo;                  // 定义 LO 专用寄存器

    // =========================================================================
    // 2. 写操作逻辑 (Synchronous Write)
    // =========================================================================
    // 写通用寄存器
    always @ (posedge clk) begin
        // 只有当写使能有效，且写地址不为0时才写入 (寄存器 $0 永远为0，不可写)
        if (we && waddr!=5'b0) begin
            reg_array[waddr] <= wdata;
        end
    end

    // 写 HI/LO 寄存器
    always @ (posedge clk) begin
        if (w_hi_we ) begin
            hi <= hi_i; // 更新 HI
        end
        if (w_lo_we ) begin
            lo <= lo_i; // 更新 LO
        end
    end
//        assign hi = w_hi_we ? hi_i :32'b0; (注释掉的代码)
//        assign lo = w_lo_we ? lo_i :32'b0;

    // =========================================================================
    // 3. 数据前推总线解包 (Unpacking Forwarding Busses)
    // =========================================================================
    
    // --- 解包 EX 阶段前推数据 ---
    wire [31:0] ex_result;    // EX 阶段计算结果
    wire ex_rf_we;            // EX 阶段是否有寄存器写操作
    wire [4:0] ex_rf_waddr;   // EX 阶段要写的寄存器地址
    assign {
        ex_rf_we,           // bit 37
        ex_rf_waddr,        // bit 36:32
        ex_result           // bit 31:0
    } = ex_to_id_bus;

    // --- 解包 MEM 阶段前推数据 ---
    wire [31:0] mem_rf_wdata; // MEM 阶段结果
    wire mem_rf_we;           // MEM 阶段是否有写操作
    wire [4:0] mem_rf_waddr;  // MEM 阶段写地址
    wire [31:0] bbb;          // (中间变量，用于 rdata1 的原始读取值)
    assign {
        mem_rf_we,          // bit 37
        mem_rf_waddr,       // bit 36:32
        mem_rf_wdata        // bit 31:0
    } = mem_to_id_bus;

    // --- 解包 WB 阶段前推数据 ---
    wire [31:0] wb1_rf_wdata; // WB 阶段结果
    wire wb1_rf_we;           // WB 阶段写使能
    wire [4:0] wb1_rf_waddr;  // WB 阶段写地址
    assign {
        wb1_rf_we,          // bit 37
        wb1_rf_waddr,       // bit 36:32
        wb1_rf_wdata        // bit 31:0
    } = wb_to_id_bus;
    
    // --- 解包 HI/LO 前推数据 ---
    // 从 EX 阶段
    wire hi_ex_we; wire lo_ex_we;
    wire [31:0] hi_ex; wire [31:0] lo_ex;
    assign{
        hi_ex_we, lo_ex_we, hi_ex, lo_ex
    } = ex_to_id_2;
    
    // 从 MEM 阶段
    wire hi_mem_we; wire lo_mem_we;
    wire [31:0] hi_mem; wire [31:0] lo_mem;
    assign{
        hi_mem_we, lo_mem_we, hi_mem, lo_mem
    } = mem_to_id_2;
    
    // 从 WB 阶段
    wire hi_wb_we; wire lo_wb_we;
    wire [31:0] hi_wb; wire [31:0] lo_wb;
    assign{
        hi_wb_we, lo_wb_we, hi_wb, lo_wb
    } = wb_to_id_2;
    
    
    // =========================================================================
    // 4. 读端口 1 逻辑 (包含前推优先级 & LSA 处理)
    // =========================================================================
    // 步骤 A: 获取原始数据 bbb (应用前推逻辑)
    // 优先级：寄存器0 -> EX前推 -> MEM前推 -> WB前推 -> 内部寄存器堆
    assign bbb = (raddr1 == 5'b0) ? 32'b0 :                         // 读 $0 永远返回 0
    ((raddr1 == ex_rf_waddr)&& ex_rf_we) ? ex_result :              // 命中 EX 阶段：用 EX 结果 (最新)
    ((raddr1 == mem_rf_waddr)&& mem_rf_we) ? mem_rf_wdata :         // 命中 MEM 阶段：用 MEM 结果
    ((raddr1 == wb1_rf_waddr)&& wb1_rf_we) ? wb1_rf_wdata :         // 命中 WB 阶段：用 WB 结果
    reg_array[raddr1];                                              // 均未命中：读内部存储器
    
    // 步骤 B: LSA 指令移位处理
    // LSA 指令格式中，inst[7:6] 指定移位量：00->移1位, 01->移2位, 10->移3位, 11->移4位
    wire [31:0] aaa; // 移位后的结果
    assign aaa = inst[7:6] == 2'b11 ?  ({bbb[27:0],4'b0}): // 左移 4 位
                   inst[7:6] == 2'b00 ?  ({bbb[30:0],1'b0}): // 左移 1 位
                   inst[7:6] == 2'b01 ?  ({bbb[29:0],2'b0}): // 左移 2 位
                   inst[7:6] == 2'b10 ?  ({bbb[28:0],3'b0}): // 左移 3 位
                   32'b0;

    // 步骤 C: 最终输出选择
    // 如果是 LSA 指令，输出移位后的 aaa；否则输出原始值 bbb
    assign rdata1 = inst_lsa ? aaa : bbb;
    

    // =========================================================================
    // 5. 读端口 2 逻辑 (前推优先级)
    // =========================================================================
    // 逻辑同端口 1 的 bbb 生成部分，优先级：EX > MEM > WB > RegFile
    assign rdata2 = (raddr2 == 5'b0) ? 32'b0 : 
    ((raddr2 == ex_rf_waddr)&& ex_rf_we) ? ex_result :
    ((raddr2 == mem_rf_waddr)&& mem_rf_we) ? mem_rf_wdata : 
    ((raddr2 == wb1_rf_waddr)&& wb1_rf_we) ? wb1_rf_wdata : 
    reg_array[raddr2];
    
    // =========================================================================
    // 6. HI/LO 寄存器输出逻辑 (前推优先级)
    // =========================================================================
    // 优先级：EX前推 > MEM前推 > WB前推 > 内部寄存器
    assign hi_o = hi_ex_we ? hi_ex:       // EX 阶段在写 HI？用它的
                   hi_mem_we ? hi_mem:    // MEM 阶段在写 HI？用它的
                   hi_wb_we ? hi_wb:      // WB 阶段在写 HI？用它的
                   hi;                    // 没人写，用内部存的值

    assign lo_o = lo_ex_we ? lo_ex:
                   lo_mem_we ? lo_mem:
                   lo_wb_we ? lo_wb:lo;
     
endmodule