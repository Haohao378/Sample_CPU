// CTRL.v - 控制单元模块
// 功能：生成流水线暂停控制信号
// 主要功能：
// 1. 根据各阶段的暂停请求生成流水线暂停信号
// 2. 控制流水线的暂停和继续执行
// 3. 目前为简化版本，所有暂停信号固定为0（不暂停）

`include "lib/defines.vh"
module CTRL(
    input wire rst,                    // 复位信号，高电平有效
    // input wire stallreq_for_ex,     // EX阶段暂停请求（当前未使用）
    // input wire stallreq_for_load,   // 加载暂停请求（当前未使用）

    // output reg flush,               // 流水线刷新信号（当前未使用）
    // output reg [31:0] new_pc,       // 新PC值（当前未使用）
    output reg [`StallBus-1:0] stall   // 流水线暂停控制信号（4位）
);  
    // 控制逻辑 - 生成暂停信号
    always @ (*) begin
        if (rst) begin
            // 复位时，所有阶段都不暂停
            stall = `StallBus'b0;
        end
        else begin
            // 简化版本：所有阶段都不暂停
            // 实际应用中需要根据各阶段的暂停请求来设置stall信号
            stall = `StallBus'b0;
        end
    end

endmodule  // CTRL模块结束