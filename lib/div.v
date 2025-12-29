`include "defines.vh" // 引入宏定义文件，包含状态码、位宽等常量定义

module div(
    // ====== 1. 输入信号定义 ======
    input wire rst,              // 系统复位信号：高电平有效，用于重置模块状态
    input wire clk,              // 系统时钟信号：所有逻辑在时钟上升沿触发
    input wire signed_div_i,     // 有符号除法标志位：
                                 // 1 = 有符号除法（需要处理负数）
                                 // 0 = 无符号除法（直接按原码计算）
    input wire[31:0] opdata1_i,  // 被除数 (Dividend)：32位数据 input A
    input wire[31:0] opdata2_i,  // 除数 (Divisor)：32位数据 input B
    input wire start_i,          // 开始信号：高电平有效，告诉除法器开始工作
    input wire annul_i,          // 取消信号：高电平有效，用于强制终止当前的计算（例如发生异常或中断）
    
    // ====== 2. 输出信号定义 ======
    output reg[63:0] result_o,   // 最终结果输出：64位宽
                                 // 高 32 位 [63:32] = 余数 (Remainder)
                                 // 低 32 位 [31:0]  = 商 (Quotient)
    output reg ready_o           // 握手信号 / 完成标志：
                                 // 1 = 计算结束，result_o 数据有效
                                 // 0 = 正在计算中或空闲
);

    // ====== 3. 内部变量定义 ======

    // 试商减法结果 (Trial Subtraction Result)
    // 用于在每个周期尝试 "当前余数 - 除数"。
    // 它是 33 位宽，最高位 [32] 用于判断结果是否为负数（是否不够减）。
    wire [32:0] div_temp;

    // 计数器 (Counter)
    // 记录当前计算到了第几轮。因为是 32 位除法，需要迭代 32 次。
    // 范围 0~32 (二进制 100000)。
    reg [5:0] cnt;

    // 核心移位寄存器 (Main Shift Register)
    // 这是算法中最关键的寄存器，位宽 65 位。
    // 结构功能划分：
    // - 高位部分 (接近 [63:32])：用于保存 "当前的余数/被减数"。
    // - 低位部分 (接近 [31:0])： 用于保存 "原始被除数" 并逐渐移位变成 "商"。
    // 算法运行时，这个寄存器整体向左移动。
    reg[64:0] dividend;

    // 状态寄存器 (State Machine)
    // 记录除法器当前处于什么阶段（空闲、计算中、结束等）。
    // 宏定义通常在 defines.vh 中，如 2'b00, 2'b01 等。
    reg [1:0] state;

    // 除数寄存器
    // 保存输入的除数 opdata2_i 的绝对值，在整个计算过程中保持不变。
    reg[31:0] divisor;

    // 临时操作数寄存器
    // 用于在初始化阶段计算输入数据的绝对值。
    reg[31:0] temp_op1; // 被除数绝对值
    reg[31:0] temp_op2; // 除数绝对值

    // ====== 4. 组合逻辑：试商减法 ======
    // 逻辑：取出 dividend 的高 32 位（当前余数），尝试减去除数。
    // {1'b0, ...} 是为了将 32 位数扩展为 33 位，防止减法溢出导致错误的符号判断。
    // 如果 div_temp[32] 为 1，说明不够减（结果为负）；为 0 说明够减。
    assign div_temp = {1'b0, dividend[63: 32]} - {1'b0, divisor};


    // ====== 5. 时序逻辑：状态机与计算核心 ======
    always @ (posedge clk) begin
        if (rst) begin
            // ---- 复位逻辑 ----
            state <= `DivFree;              // 状态回空闲
            result_o <= {`ZeroWord,`ZeroWord}; // 清空结果
            ready_o <= `DivResultNotReady;  // 标记结果无效
        end else begin
            // ---- 状态机跳转 ----
            case(state)
            
                // [状态 1] DivFree: 空闲状态，等待 start_i 信号
                `DivFree: begin
                    if (start_i == `DivStart && annul_i == 1'b0) begin
                        // 收到开始信号，且没有取消信号
                        if(opdata2_i == `ZeroWord) begin
                            // 情况 A：除数为 0 (Div by Zero)
                            state <= `DivByZero; // 跳转到除零异常状态
                        end else begin
                            // 情况 B：正常除法
                            state <= `DivOn;     // 跳转到计算状态
                            cnt <= 6'b000000;    // 计数器清零

                            // ---- 预处理：计算被除数绝对值 ----
                            // 如果是有符号除法 且 被除数为负(最高位为1)
                            // 则取反加一（补码转原码/绝对值）
                            if(signed_div_i == 1'b1 && opdata1_i[31] == 1'b1) begin
                                temp_op1 = ~opdata1_i + 1;
                            end else begin
                                temp_op1 = opdata1_i;
                            end

                            // ---- 预处理：计算除数绝对值 ----
                            // 同理，计算除数的绝对值
                            if (signed_div_i == 1'b1 && opdata2_i[31] == 1'b1 ) begin
                                temp_op2 = ~opdata2_i + 1;
                            end else begin
                                temp_op2 = opdata2_i;
                            end

                            // ---- 初始化核心寄存器 ----
                            dividend <= {`ZeroWord, `ZeroWord}; // 先清零 65 位
                            dividend[32: 1] <= temp_op1;        // 将被除数绝对值放入中间位置
                                                                // 注意：这里放到了 [32:1]，留出了最低位 [0] 用于后续移位逻辑
                            divisor <= temp_op2;                // 锁存除数绝对值
                        end
                    end else begin
                        // 没有开始信号，保持空闲
                        ready_o <= `DivResultNotReady;
                        result_o <= {`ZeroWord, `ZeroWord};
                    end
                end
                
                // [状态 2] DivByZero: 除零处理
                `DivByZero: begin
                    dividend <= {`ZeroWord, `ZeroWord};
                    state <= `DivEnd; // 直接跳到结束状态，结果通常为 0 或异常值
                end
                
                // [状态 3] DivOn: 计算进行中 (核心循环)
                `DivOn: begin
                    if(annul_i == 1'b0) begin // 如果没有收到取消信号
                        
                        // ---- 循环体：执行 32 次迭代 ----
                        if(cnt != 6'b100000) begin // 如果 cnt != 32
                            
                            // 检查刚才算出的 div_temp (当前余数 - 除数)
                            if (div_temp[32] == 1'b1) begin
                                // 1. 不够减 (结果为负)
                                // 动作：商上 0，被除数左移 1 位。
                                // {dividend[63:0], 1'b0} 实现左移，最低位补 0。
                                dividend <= {dividend[63:0],1'b0};
                            end else begin
                                // 2. 够减 (结果为正)
                                // 动作：商上 1，更新余数，并左移 1 位。
                                // div_temp[31:0] 是减法后的新余数。
                                // dividend[31:0] 是当前的低位（包含部分商和未处理的被除数）。
                                // 拼接后赋值，实际上完成了：更新高位余数 + 整体左移 + 最低位置 1。
                                dividend <= {div_temp[31:0], dividend[31:0], 1'b1};
                            end
                            cnt <= cnt + 1; // 计数器加 1
                        end else begin
                            // ---- 计算完成：后处理符号位 ----
                            // 此时 cnt == 32，循环结束。
                            
                            // 1. 修正商的符号
                            // 逻辑：如果是有符号除法，且 (被除数符号 ^ 除数符号) == 1，说明结果应为负。
                            // opdata1_i[31] ^ opdata2_i[31] 为真表示异号。
                            // dividend[31:0] 存储的是商。
                            if ((signed_div_i == 1'b1) && ((opdata1_i[31] ^ opdata2_i[31]) == 1'b1)) begin
                                dividend[31:0] <= (~dividend[31:0] + 1); // 转回补码（负数）
                            end
                            
                            // 2. 修正余数的符号
                            // 逻辑：余数的符号应该与被除数一致。
                            // 如果被除数是负数，余数也应该是负数。
                            // dividend[64:33] 存储的是余数。
                            if ((signed_div_i == 1'b1) && ((opdata1_i[31] ^ dividend[64]) == 1'b1)) begin
                                dividend[64:33] <= (~dividend[64:33] + 1); // 转回补码
                            end
                            
                            state <= `DivEnd; // 跳转到结束状态
                            cnt <= 6'b000000; // 重置计数器
                        end
                    end else begin
                        // 如果收到取消信号 (annul_i == 1)，立即回到空闲状态
                        state <= `DivFree;
                    end
                end
                
                // [状态 4] DivEnd: 结果输出
                `DivEnd: begin
                    // 组装最终结果
                    // dividend[64:33] 是余数 (32位)
                    // dividend[31:0]  是商 (32位)
                    result_o <= {dividend[64:33], dividend[31:0]};
                    
                    ready_o <= `DivResultReady; // 拉高完成信号，通知流水线取结果
                    
                    // 等待外部的 start_i 信号变低（握手协议），然后才回空闲
                    if (start_i == `DivStop) begin
                        state <= `DivFree;
                        ready_o <= `DivResultNotReady;
                        result_o <= {`ZeroWord, `ZeroWord};
                    end
                end
                
            endcase
        end
    end

endmodule