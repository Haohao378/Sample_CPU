// MEM.v - 存储器访问阶段模块
// 功能：处理数据存储器访问，选择写入寄存器的数据
// 主要功能：
// 1. 从EX阶段接收控制信号和运算结果
// 2. 处理数据存储器读操作（加载指令）
// 3. 选择要写入寄存器的数据来源（ALU结果或存储器读取数据）
// 4. 将结果传递给WB阶段

`include "lib/defines.vh"
module MEM(
    input wire clk,                    // 时钟信号
    input wire rst,                    // 复位信号，高电平有效
    // input wire flush,               // 流水线刷新信号（当前未使用）
    input wire [`StallBus-1:0] stall,  // 流水线暂停控制信号（4位）

    input wire [`EX_TO_MEM_WD-1:0] ex_to_mem_bus,  // 从EX阶段接收的总线信号（76位）
    input wire [31:0] data_sram_rdata,               // 从数据存储器读取的数据（32位）

    output wire [`MEM_TO_WB_WD-1:0] mem_to_wb_bus   // 发送到WB阶段的总线信号（70位）
);

    // EX到MEM阶段寄存器 - 存储从EX阶段接收的数据
    reg [`EX_TO_MEM_WD-1:0] ex_to_mem_bus_r;

    // EX到MEM阶段寄存器更新逻辑 - 在时钟上升沿触发
    always @ (posedge clk) begin
        if (rst) begin
            // 复位时清空寄存器
            ex_to_mem_bus_r <= `EX_TO_MEM_WD'b0;
        end
        // else if (flush) begin
        //     // 流水线刷新时清空寄存器（当前未使用）
        //     ex_to_mem_bus_r <= `EX_TO_MEM_WD'b0;
        // end
        else if (stall[3]==`Stop && stall[4]==`NoStop) begin
            // 当MEM阶段暂停但WB阶段不暂停时，插入空操作（气泡）
            ex_to_mem_bus_r <= `EX_TO_MEM_WD'b0;
        end
        else if (stall[3]==`NoStop) begin
            // 当MEM阶段不暂停时，正常接收EX阶段的数据
            ex_to_mem_bus_r <= ex_to_mem_bus;
        end
        // 当stall[3]==`Stop且stall[4]==`Stop时，保持当前值（暂停）
    end

    // 从EX到MEM总线寄存器中提取各个信号
    wire [31:0] mem_pc;            // PC值
    wire data_ram_en;              // 数据存储器使能信号
    wire [3:0] data_ram_wen;       // 数据存储器写使能信号
    wire sel_rf_res;               // 寄存器写入数据源选择
    wire rf_we;                    // 寄存器写使能信号
    wire [4:0] rf_waddr;           // 目标寄存器地址
    wire [31:0] rf_wdata;          // 要写入寄存器的数据
    wire [31:0] ex_result;       // ALU运算结果（来自EX阶段）
    wire [31:0] mem_result;        // 存储器读取结果（来自数据存储器）

    // 从ex_to_mem_bus_r寄存器中提取各个信号
    // 总线格式（76位）：
    assign {
        mem_pc,         // 75:44 - 当前指令的PC值（32位）
        data_ram_en,    // 43      - 数据存储器使能信号（1位）
        data_ram_wen,   // 42:39   - 数据存储器写使能信号（4位）
        sel_rf_res,     // 38      - 寄存器写入数据源选择（1位）
        rf_we,          // 37      - 寄存器写使能信号（1位）
        rf_waddr,       // 36:32   - 目标寄存器地址（5位）
        ex_result       // 31:0    - ALU运算结果（32位）
    } =  ex_to_mem_bus_r;



    // 寄存器写入数据源选择 - 根据sel_rf_res选择写入寄存器的数据
    // sel_rf_res = 0: 选择ALU运算结果（ex_result）
    // sel_rf_res = 1: 选择存储器读取结果（mem_result，当前未使用）
    assign rf_wdata = sel_rf_res ? mem_result : ex_result;

    // MEM到WB阶段总线信号构建 - 将MEM阶段的结果和控制信号打包
    // mem_to_wb_bus总线格式（70位）：
    assign mem_to_wb_bus = {
        mem_pc,     // 69:38 - 当前指令的PC值（32位）
        rf_we,      // 37      - 寄存器写使能信号（1位）
        rf_waddr,   // 36:32   - 目标寄存器地址（5位）
        rf_wdata    // 31:0    - 要写入寄存器的数据（32位）
    };




endmodule  // MEM模块结束