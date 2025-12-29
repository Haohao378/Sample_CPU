`include "lib/defines.vh" // 引入宏定义文件

module WB(
    // ====== 1. 系统与控制信号 ======
    input wire clk,                 // 系统时钟信号：驱动流水线寄存器
    input wire rst,                 // 系统复位信号：高电平有效
    // input wire flush,            // 流水线冲刷信号 (此处被注释，通常用于异常或中断)
    input wire [`StallBus-1:0] stall, // 流水线暂停信号总线。stall[4]对应WB段

    // ====== 2. 来自 MEM 阶段的输入 ======
    input wire [`MEM_TO_WB_WD-1:0] mem_to_wb_bus, // 通用寄存器写回信息总线 (含 PC, 写使能, 写地址, 写数据)
    input wire [65:0] mem_to_wb1,                 // HI/LO 寄存器写回信息总线 (含 HI/LO 写使能, 写数据)

    // ====== 3. 输出到寄存器堆 (Register File) ======
    output wire [`WB_TO_RF_WD-1:0] wb_to_rf_bus,  // 发送给寄存器堆的写端口信号 (真正去改写寄存器的信号)
    
    // ====== 4. 输出到 ID 阶段 (Forwarding & Writeback) ======
    output wire [37:0] wb_to_id_bus,              // 通用寄存器前推总线：把 WB 阶段的结果“瞬移”回 ID 阶段解决冒险
    // HI/LO 专用回写与前推
    output wire[65:0] wb_to_id_wf,                // HI/LO 写回信号：通常连接到 ID 阶段的 HI/LO 模块进行写入
    output wire[65:0] wb_to_id_2,                 // HI/LO 前推信号：功能同上，可能用于不同的逻辑判断
    
    // ====== 5. 调试接口 (Debug Interface) ======
    // 这些是 SoC 测试平台（如龙芯杯）要求的标准调试信号，用于比对 CPU 运行结果
    output wire [31:0] debug_wb_pc,       // 当前写回指令的 PC
    output wire [3:0] debug_wb_rf_wen,    // 通用寄存器写使能 (扩展为4位字节使能)
    output wire [4:0] debug_wb_rf_wnum,   // 通用寄存器写地址 (Register Number)
    output wire [31:0] debug_wb_rf_wdata  // 通用寄存器写数据
);

    // =========================================================================
    // 1. 流水线寄存器 (Pipeline Registers)
    // =========================================================================
    // 这些寄存器用于锁存上一级 (MEM) 传来的数据，隔绝时序
    reg [`MEM_TO_WB_WD-1:0] mem_to_wb_bus_r; // 锁存通用寄存器信息
    reg [65:0] mem_to_wb1_r;                 // 锁存 HI/LO 寄存器信息

    always @ (posedge clk) begin
        if (rst) begin
            // 复位时清零
            mem_to_wb_bus_r <= `MEM_TO_WB_WD'b0;
            mem_to_wb1_r <= 66'b0;
        end
        // else if (flush) begin ... end // 冲刷逻辑
        
        // 暂停策略：
        // stall[4] 是 MEM 阶段对应的暂停位（注意：不同 CPU 命名习惯不同，有时 stall[4] 指 WB）
        // 这里逻辑是：如果本阶段被要求暂停(`Stop)，但下一级(外部环境)没暂停，说明需要插入气泡
        // 但 WB 已经是最后一级，通常 stall[4] 意味着流水线要冻结在这里。
        // 代码意图：如果 WB 需要暂停处理（比如等待外部总线），则清空输出防止重复写。
        else if (stall[4]==`Stop && stall[5]==`NoStop) begin
            mem_to_wb_bus_r <= `MEM_TO_WB_WD'b0;
            mem_to_wb1_r <= 66'b0;
        end
        // 正常流动：如果不暂停，就接收 MEM 传来的数据
        else if (stall[4]==`NoStop) begin
            mem_to_wb_bus_r <= mem_to_wb_bus;
            mem_to_wb1_r <= mem_to_wb1;
        end
    end

    // =========================================================================
    // 2. 解包逻辑 (Unpacking)
    // =========================================================================
    // 定义中间变量，把总线拆解成具体含义的信号
    
    // --- 通用寄存器组信号 ---
    wire [31:0] wb_pc;     // 当前指令 PC (主要用于调试和异常跳转)
    wire rf_we;            // Register File Write Enable (寄存器写使能)
    wire [4:0] rf_waddr;   // Register File Write Address (写目标寄存器号, 0-31)
    wire [31:0] rf_wdata;  // Register File Write Data (要写入的数据)
    
    // --- HI/LO 寄存器组信号 ---
    wire w_hi_we;          // HI 寄存器写使能
    wire w_lo_we;          // LO 寄存器写使能
    wire [31:0]hi_i;       // 待写入 HI 的数据
    wire [31:0]lo_i;       // 待写入 LO 的数据
     
    // 解包通用寄存器总线
    assign {
        wb_pc,          // 取出 PC
        rf_we,          // 取出写使能
        rf_waddr,       // 取出写地址
        rf_wdata        // 取出写数据 (来自 MEM 阶段的 Load 结果或 ALU 结果)
    } = mem_to_wb_bus_r;
    
    // 解包 HI/LO 总线
    assign 
    {
        w_hi_we,        // HI 写使能
        w_lo_we,        // LO 写使能
        hi_i,           // HI 写数据
        lo_i            // LO 写数据
    } = mem_to_wb1_r;
    
    // =========================================================================
    // 3. 输出打包与转发 (Packing & Forwarding)
    // =========================================================================

    // --- HI/LO 写回信号 ---
    // 发送给 ID 阶段 (因为 HI/LO 寄存器通常物理实现在 ID 阶段或独立模块，需要在那里写入)
    assign wb_to_id_wf =
    {
        w_hi_we,
        w_lo_we,
        hi_i,
        lo_i
    };
    
    // --- HI/LO 前推信号 ---
    // 功能同上，可能是为了区分“真实写入”和“数据前推”预留了两个接口，目前逻辑一致
    assign wb_to_id_2 =
    {
        w_hi_we,
        w_lo_we,
        hi_i,
        lo_i
    };
    
    // --- 通用寄存器写回总线 (关键) ---
    // 这条总线直接连回 ID 阶段的寄存器堆 (RegFile)，完成最终的写入操作
    assign wb_to_rf_bus = {
        rf_we,          // 告诉 RegFile：我要写
        rf_waddr,       // 告诉 RegFile：写哪里
        rf_wdata        // 告诉 RegFile：写什么
    };

    // --- 通用寄存器前推总线 ---
    // 发送给 ID 阶段。如果下一条指令刚好处在 ID 阶段且需要用到这条指令的结果，
    // ID 阶段会通过旁路网络直接抓取这个 rf_wdata，而不用等写入 RegFile 后再读。
    assign wb_to_id_bus = {
        rf_we,          // 写使能 (作为前推有效标志)
        rf_waddr,       // 写地址 (用于比对源寄存器号)
        rf_wdata        // 数据 (用于直接使用)
    };

    // =========================================================================
    // 4. 调试信号输出 (Debug Output)
    // =========================================================================
    // 这些信号不参与 CPU 内部逻辑，专门连到 CPU 顶层的 Trace 接口，供仿真器比对
    assign debug_wb_pc = wb_pc;
    
    // 调试用的写使能通常要求是字节掩码格式 (4位)，所以把 1 位的 rf_we 复制 4 次
    // 如果 rf_we=1, 则是 4'b1111; 如果 rf_we=0, 则是 4'b0000
    assign debug_wb_rf_wen = {4{rf_we}}; 
    
    assign debug_wb_rf_wnum = rf_waddr;
    assign debug_wb_rf_wdata = rf_wdata;

endmodule