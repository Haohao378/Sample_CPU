`include "lib/defines.vh" 

module CTRL(
    input wire rst,                 
    input wire stallreq_for_ex,     
    input wire stallreq_for_id,     
    output reg [`StallBus-1:0] stall 
);  
    
    always @ (*) begin
        if (rst) begin
            stall = `StallBus'b0; 
        end

        // ====== 优先级 1: 处理 ID 阶段的请求 (Load-Use 冒险) ======
        // --- 恢复：响应 ID 阶段的暂停请求 ---
        else if(stallreq_for_id == `Stop) begin
            // 暂停 PC, IF, ID，保持 EX, MEM, WB 流动 (插入气泡)
            stall = 6'b000111;
        end

        // ====== 优先级 2: 处理 EX 阶段的请求 (Passpoint 36 暂不需要，但加上也不坏) ======
        // 此时除法器还是被屏蔽的，所以 stallreq_for_ex 恒为 0
        else if( stallreq_for_ex == `Stop) begin
            stall = 6'b001111;
        end

        // ====== 默认情况 ======
        else begin
            stall = `StallBus'b0; 
        end
    end

endmodule