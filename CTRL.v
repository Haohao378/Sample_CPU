`include "lib/defines.vh" // 引入宏定义文件，包含 `Stop`, `NoStop`, `StallBus` 等定义

module CTRL(
    // ====== 1. 输入信号 ======
    input wire rst,                 // 系统复位信号
                                    // 1: 复位中，清除所有暂停信号
                                    // 0: 正常工作

    input wire stallreq_for_ex,     // 来自 EX (执行) 阶段的暂停请求
                                    // 通常是因为长周期指令（如除法 DIV）正在计算中，
                                    // EX 阶段还没算完，请求大家等一等。

    // input wire stallreq_for_load, // (已注释) 来自访存相关的暂停请求，通常用于解决 Load-Use 冒险

    input wire stallreq_for_id,     // 来自 ID (译码) 阶段的暂停请求
                                    // 通常是因为发生了 Load-Use 数据冒险（上一条是 Load 指令，
                                    // 当前指令在 ID 阶段急需这个数据，必须等 Load 完成）。

    // output reg flush,            // (已注释) 流水线冲刷信号 (用于分支预测失败等)
    // output reg [31:0] new_pc,    // (已注释) 冲刷后新的 PC 跳转地址

    // ====== 2. 输出信号 ======
    output reg [`StallBus-1:0] stall // 最终计算出的暂停控制信号总线
                                     // 这是一个 6 位的信号 (假设 StallBus=6)
                                     // 每一位对应控制一个流水线阶段是否暂停
);  
    
    // ====== 3. 组合逻辑块 ======
    always @ (*) begin
        if (rst) begin
            // 复位时，不暂停任何阶段，流水线清空畅通
            stall = `StallBus'b0; 
        end

        // ====== 优先级 1: 处理 ID 阶段的请求 (Load-Use 冒险) ======
        else if(stallreq_for_id == `Stop) begin
            // 如果 ID 阶段请求暂停 (通常是因为需要等待 MEM 阶段的数据):
            // 赋值为 6'b000111 (假设 Stop=1)
            // 分解如下：
            // stall[0] = 1 (PC):   暂停 PC 更新 (不取新指令)
            // stall[1] = 1 (IF):   暂停 IF 阶段 (保持当前取到的指令)
            // stall[2] = 1 (ID):   暂停 ID 阶段 (保持当前译码指令，等待数据)
            // stall[3] = 0 (EX):   EX 阶段继续走 (让上一条 Load 指令继续流向 MEM)
            // stall[4] = 0 (MEM):  MEM 阶段继续走
            // stall[5] = 0 (WB):   WB 阶段继续走
            // 效果：后半段流走，前半段冻结，中间产生一个气泡。
            stall = 6'b000111;
        end

        // ====== 优先级 2: 处理 EX 阶段的请求 (长指令运算) ======
        else if( stallreq_for_ex == `Stop) begin
            // 如果 EX 阶段请求暂停 (通常是因为除法器还没算完):
            // 赋值为 6'b001111
            // 分解如下：
            // stall[0] = 1 (PC):   暂停 PC
            // stall[1] = 1 (IF):   暂停 IF
            // stall[2] = 1 (ID):   暂停 ID
            // stall[3] = 1 (EX):   暂停 EX 阶段 (保持当前除法指令，直到 ready)
            // stall[4] = 0 (MEM):  MEM 阶段继续走 (前面的指令已经走了)
            // stall[5] = 0 (WB):   WB 阶段继续走
            // 效果：EX 及其之前的所有阶段全部冻结，直到 EX 算完。
            stall = 6'b001111;
        end

        // ====== 默认情况 ======
        else begin
            // 没有任何请求，流水线全速运行
            stall = `StallBus'b0; 
        end
    end

endmodule