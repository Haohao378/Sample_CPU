`timescale 1ns / 1ps
module mul_plus(
    input clk,               // 时钟信号：用于同步所有的寄存器状态更新
    input start_i,           // 启动信号：高电平有效。ID/EX 阶段发出的“开始干活”指令
    input mul_sign,          // 符号控制信号：1=有符号乘法(mult)，0=无符号乘法(multu)
    input [31:0] opdata1_i,  // 输入操作数1：被乘数 (Multiplicand)
    input [31:0] opdata2_i,  // 输入操作数2：乘数 (Multiplier)
    output [63:0] result_o,  // 输出结果：64位乘积 (32位 x 32位 = 64位)
    output        ready_o    // 完成握手信号：高电平表示计算结束，结果有效
    );
    // ------ 内部状态寄存器 ------
    reg judge;               // 状态标志位 (State Flag)
                             // 0: 空闲状态 (Idle) - 等待任务
                             // 1: 工作状态 (Busy) - 正在进行移位累加
                             
    reg [31:0] multiplier;   // 乘数寄存器 (存放剩余未处理的乘数)
                             // 随着计算进行，它会不断右移，直到变成 0

    wire [63:0] temporary_value; // 组合逻辑生成的“当前位部分积”
                                 // 如果乘数最低位是1，它等于当前被乘数；否则为0
                                 
    reg [63:0] mul_temporary;    // 累加器 (Accumulator)
                                 // 存放每一次加法后的中间结果，最终变成 result_o
                                 
    reg result_sign;             // 结果符号寄存器
                                 // 0: 最终结果为正; 1: 最终结果为负

    // ------ 状态机控制逻辑 ------
    always @(posedge clk) begin
        // 结束或重置条件：
        // 1. !start_i: 如果外部撤销了开始信号，强制回空闲
        // 2. ready_o:  如果已经算完了(ready变高)，自动回空闲
        if (!start_i || ready_o) begin
            judge <= 1'b0;       // 标记为“空闲”
        end
        // 启动条件：
        // 外部给了 start_i 且还没算完
        else begin
            judge <= 1'b1;       // 标记为“忙碌/计算中”
        end
    end

    // ------ 预处理：取绝对值 ------
    // 为了简化核心算法，我们把所有数都当正数算，最后再根据符号位还原
    wire op1_sign;           // 操作数1的符号 (1代表负数)
    wire op2_sign;           // 操作数2的符号 (1代表负数)
    wire [31:0] op1_absolute;// 操作数1的绝对值
    wire [31:0] op2_absolute;// 操作数2的绝对值

    // 只有在“有符号模式(mul_sign=1)”下，才看最高位(bit 31)；否则视为正数(0)
    assign op1_sign = mul_sign & opdata1_i[31];
    assign op2_sign = mul_sign & opdata2_i[31];

    // 绝对值转换逻辑：
    // 如果是负数(sign=1)：按位取反再加1 (~op + 1) -> 补码转原码/绝对值
    // 如果是正数(sign=0)：直接用原值
    assign op1_absolute = op1_sign ? (~opdata1_i+1) : opdata1_i;
    assign op2_absolute = op2_sign ? (~opdata2_i+1) : opdata2_i;

    // ------ 被乘数移位逻辑 (Multiplicand Shifting) ------
    reg  [63:0] multiplicand; // 被乘数寄存器 (注意是64位！)
                              // 因为被乘数需要不断左移，最大移位32次，所以需要64位空间防止溢出
                              
    always @ (posedge clk) begin 
        if (judge) begin
            // 工作状态：左移一位 (Logic Left Shift)
            // 对应竖式乘法中，每算一位，被乘数就要往左错一位
            multiplicand <= {multiplicand[62:0],1'b0};
        end
        else if (start_i) begin
            // 初始化状态：载入被乘数的绝对值
            // 放到低32位，高32位补0
            multiplicand <= {32'd0,op1_absolute};
        end
    end
    
    // ------ 乘数移位逻辑 (Multiplier Shifting) ------
    always @ (posedge clk) begin 
        if(judge) begin
            // 工作状态：右移一位 (Logic Right Shift)
            // 把刚刚处理过的最低位移出去，让下一位来到 bit[0] 供判断
            multiplier <= {1'b0,multiplier[31:1]};
        end
        else if(start_i) begin
            // 初始化状态：载入乘数的绝对值
            multiplier <= op2_absolute;
        end
    end

    // ------ 部分积生成 (Partial Product) ------
    // 组合逻辑：根据当前乘数的最低位 (LSB) 决定加什么
    // multiplier[0] == 1: 说明这一位需要加被乘数
    // multiplier[0] == 0: 说明这一位是0，加0即可
    assign temporary_value = multiplier[0] ? multiplicand : 64'd0;
    
    // ------ 累加器逻辑 (Accumulation) ------
    always @ (posedge clk) begin
        if (judge) begin
            // 工作状态：将“部分积”加到“总和”里
            mul_temporary <= mul_temporary + temporary_value;
        end      
        else if (start_i) begin
            // 初始化状态：清空累加器
            mul_temporary <= 64'd0;
        end
     end
     
    // ------ 结果符号计算 ------
    always @ (posedge clk) begin
        if (judge) begin
             // 异或运算决定最终符号：
             // 同号为正 (0^0=0, 1^1=0)
             // 异号为负 (0^1=1, 1^0=1)
             result_sign <= op1_sign ^ op2_sign;
        end
    end 

    // ------ 输出逻辑 ------
    
    // 1. 结果修正
    // 如果 result_sign 为 1 (结果应为负)，将无符号计算出的 mul_temporary 取反加1 (变回补码)
    // 如果 result_sign 为 0 (结果应为正)，直接输出 mul_temporary
    assign result_o = result_sign ? (~mul_temporary+1) : mul_temporary;

    // 2. 完成信号 (Ready) 优化
    // 这里的判断条件非常巧妙： judge & (multiplier == 32'b0)
    // 意思是：如果不处于空闲状态(judge=1)，而且 乘数已经移位变成0了。
    // 乘数变成0意味着：后面全是0了，再乘也是加0，没意义了。
    // 所以可以提前结束 (Early Termination)，不需要傻等到固定的 32 个周期。
    assign ready_o  = judge & multiplier == 32'b0;
    
endmodule