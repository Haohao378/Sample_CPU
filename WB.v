// WB.v - 写回阶段模块
// 功能：将最终结果写回寄存器文件，提供调试信息
// 主要功能：
// 1. 从MEM阶段接收最终要写入寄存器的数据
// 2. 生成寄存器文件的写使能信号和地址
// 3. 提供调试接口，输出当前写回的PC值、寄存器地址和数据
// 4. 将写回信号传递给寄存器文件

`include "lib/defines.vh"
module WB(
    input wire clk,                    // 时钟信号
    input wire rst,                    // 复位信号，高电平有效
    // input wire flush,               // 流水线刷新信号（当前未使用）
    input wire [`StallBus-1:0] stall,  // 流水线暂停控制信号（4位）

    input wire [`MEM_TO_WB_WD-1:0] mem_to_wb_bus,  // 从MEM阶段接收的总线信号（70位）

    output wire [`WB_TO_RF_WD-1:0] wb_to_rf_bus,   // 发送到寄存器文件的写回总线（38位）

    // 调试接口 - 输出当前写回阶段的信息
    output wire [31:0] debug_wb_pc,        // 当前写回指令的PC值（32位）
    output wire [3:0] debug_wb_rf_wen,     // 寄存器写使能信号（4位，扩展为4位）
    output wire [4:0] debug_wb_rf_wnum,    // 目标寄存器地址（5位）
    output wire [31:0] debug_wb_rf_wdata   // 要写入寄存器的数据（32位）
);

    // MEM到WB阶段寄存器 - 存储从MEM阶段接收的数据
    reg [`MEM_TO_WB_WD-1:0] mem_to_wb_bus_r;

    // MEM到WB阶段寄存器更新逻辑 - 在时钟上升沿触发
    always @ (posedge clk) begin
        if (rst) begin
            // 复位时清空寄存器
            mem_to_wb_bus_r <= `MEM_TO_WB_WD'b0;
        end
        // else if (flush) begin
        //     // 流水线刷新时清空寄存器（当前未使用）
        //     mem_to_wb_bus_r <= `MEM_TO_WB_WD'b0;
        // end
        else if (stall[4]==`Stop && stall[5]==`NoStop) begin
            // 当WB阶段暂停但没有后续阶段时，插入空操作（气泡）
            mem_to_wb_bus_r <= `MEM_TO_WB_WD'b0;
        end
        else if (stall[4]==`NoStop) begin
            // 当WB阶段不暂停时，正常接收MEM阶段的数据
            mem_to_wb_bus_r <= mem_to_wb_bus;
        end
        // 当stall[4]==`Stop且stall[5]==`Stop时，保持当前值（暂停）
    end

    // 从MEM到WB总线寄存器中提取各个信号
    wire [31:0] wb_pc;               // PC值（当前未使用，主要用于调试）
    wire rf_we;                      // 寄存器写使能信号
    wire [4:0] rf_waddr;             // 目标寄存器地址
    wire [31:0] rf_wdata;            // 要写入寄存器的数据

    // 从mem_to_wb_bus_r寄存器中提取各个信号
    // 总线格式（70位）：
    assign {
        wb_pc,          // 69:38 - 当前指令的PC值（32位）
        rf_we,          // 37      - 寄存器写使能信号（1位）
        rf_waddr,       // 36:32   - 目标寄存器地址（5位）
        rf_wdata        // 31:0    - 要写入寄存器的数据（32位）
    } = mem_to_wb_bus_r;

    // WB到寄存器文件总线信号构建 - 生成最终的寄存器写回信号
    // wb_to_rf_bus总线格式（38位）：
    assign wb_to_rf_bus = {
        rf_we,      // 37      - 寄存器写使能信号（1位）
        rf_waddr,   // 36:32   - 目标寄存器地址（5位）
        rf_wdata    // 31:0    - 要写入寄存器的数据（32位）
    };

    // 调试信号输出 - 将WB阶段的信息输出到调试接口
    assign debug_wb_pc = wb_pc;                    // 当前写回指令的PC值
    assign debug_wb_rf_wen = {4{rf_we}};           // 将1位写使能信号扩展为4位
    assign debug_wb_rf_wnum = rf_waddr;          // 目标寄存器地址
    assign debug_wb_rf_wdata = rf_wdata;           // 要写入寄存器的数据

    
endmodule  // WB模块结束