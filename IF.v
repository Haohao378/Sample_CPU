// IF.v - 指令取指阶段模块
// 功能：负责从指令存储器中读取指令，处理程序计数器（PC）的更新

`include "lib/defines.vh"  // 包含定义文件，里面有各种常量和参数定义

module IF(  // IF模块定义，这是流水线的第一个阶段 - 取指阶段
    // 时钟和复位信号
    input wire clk,                    // 时钟信号，上升沿触发
    input wire rst,                    // 复位信号，高电平有效
    input wire [`StallBus-1:0] stall,  // 流水线暂停控制信号总线，来自控制单元

    // 以下是被注释掉的信号，可能在后续版本中使用
    // input wire flush,                 // 流水线刷新信号
    // input wire [31:0] new_pc,         // 新的PC值（用于跳转）

    // 分支相关信号输入
    input wire [`BR_WD-1:0] br_bus,    // 分支总线，包含分支使能信号和目标地址

    // 输出到下一个阶段（ID阶段）的总线
    output wire [`IF_TO_ID_WD-1:0] if_to_id_bus,  // 传递到ID阶段的信息总线

    // 指令存储器接口
    output wire inst_sram_en,          // 指令存储器使能信号
    output wire [3:0] inst_sram_wen,   // 指令存储器写使能信号（4位字节使能）
    output wire [31:0] inst_sram_addr, // 指令存储器地址，32位地址总线
    output wire [31:0] inst_sram_wdata // 指令存储器写入数据（通常为0，因为只读）
);
    // 内部寄存器和连线定义
    reg [31:0] pc_reg;     // 程序计数器寄存器，32位，存储当前指令地址
    reg ce_reg;            // 芯片使能寄存器，控制是否允许取指令
    wire [31:0] next_pc;   // 连线，存储计算得到的下一条指令地址
    wire br_e;             // 连线，分支使能信号
    wire [31:0] br_addr;   // 连线，分支目标地址

    // 从分支总线中提取信号
    // br_bus的格式：{br_e, br_addr}，br_e占1位，br_addr占32位
    assign {
        br_e,      // 分支使能信号，1位
        br_addr    // 分支目标地址，32位
    } = br_bus;


    // PC寄存器更新逻辑 - 在时钟上升沿触发
    always @ (posedge clk) begin  // 当clk从0变到1时执行
        if (rst) begin  // 如果复位信号有效（高电平）
            pc_reg <= 32'hbfbf_fffc;  // 将PC设置为复位向量地址0xBFBFFFFC
        end
        else if (stall[0]==`NoStop) begin  // 如果流水线第0级不需要暂停
            pc_reg <= next_pc;  // 将PC更新为计算得到的下一条指令地址
        end
        // 如果stall[0]为`Stop，则保持当前PC值不变（暂停取指）
    end

    // 芯片使能寄存器更新逻辑 - 控制是否允许访问指令存储器
    always @ (posedge clk) begin  // 在时钟上升沿触发
        if (rst) begin  // 如果复位信号有效
            ce_reg <= 1'b0;  // 复位时禁用芯片（ce_reg = 0）
        end
        else if (stall[0]==`NoStop) begin  // 如果流水线第0级不需要暂停
            ce_reg <= 1'b1;  // 使能芯片，允许取指令（ce_reg = 1）
        end
        // 如果stall[0]为`Stop，保持当前的ce_reg值不变
    end


    // 计算下一条指令的PC值
    // 这是一个组合逻辑，不依赖于时钟
    assign next_pc = br_e ? br_addr   // 如果有分支且分支有效，跳转到分支目标地址
                   : pc_reg + 32'h4;   // 否则PC加4（下一条指令地址，每条指令4字节）

    
    // 指令存储器接口信号赋值
    assign inst_sram_en = ce_reg;      // 使用芯片使能寄存器的值作为存储器使能
    assign inst_sram_wen = 4'b0;        // 指令存储器只读，写使能始终为0
    assign inst_sram_addr = pc_reg;     // 将PC值作为指令存储器地址
    assign inst_sram_wdata = 32'b0;     // 指令存储器只读，写入数据始终为0
    
    // 构建传递到ID阶段的总线信号
    // if_to_id_bus格式：{ce_reg, pc_reg}
    // ce_reg占1位，pc_reg占32位，总共33位
    assign if_to_id_bus = {
        ce_reg,    // 1位：芯片使能信号
        pc_reg     // 32位：当前指令地址
    };

endmodule  // IF模块结束