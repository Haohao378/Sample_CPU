`include "lib/defines.vh" // 引入宏定义文件，包含总线宽度、指令码等定义

module MEM(
    // ====== 1. 系统信号 ======
    input wire clk,                 // 系统时钟信号
    input wire rst,                 // 系统复位信号
    // input wire flush,            // 流水线冲刷信号 (此处被注释掉)
    input wire [`StallBus-1:0] stall, // 流水线暂停信号总线，stall[3]对应MEM段，stall[4]对应WB段

    // ====== 2. 来自 EX 阶段的输入 ======
    input wire [`EX_TO_MEM_WD-1:0] ex_to_mem_bus, // 从 EX 阶段传来的主数据总线 (包含ALU结果、寄存器写地址等)
    input wire [31:0] data_sram_rdata,             // 【关键】从数据存储器(SRAM)读回来的原始 32 位数据
    // ====== 3. 输出到 ID 阶段 (前推/旁路) ======
    output wire [37:0] mem_to_id_bus,              // 将 MEM 阶段的结果前推给 ID 阶段，解决数据冒险

    // ====== 4. 输出到 WB 阶段 (流水线继续) ======
    output wire [`MEM_TO_WB_WD-1:0] mem_to_wb_bus, // 发送给写回(WB)阶段的主数据总线
    
    // ====== 5. HI/LO 寄存器专用信号 ======
    input wire [65:0] ex_to_mem1,   // 来自 EX 的 HI/LO 写信息 (写使能 + 数据)
    output wire[65:0] mem_to_wb1,   // 传递给 WB 的 HI/LO 写信息
    output wire[65:0] mem_to_id_2   // 前推给 ID 的 HI/LO 写信息
);

    // =========================================================================
    // 1. 流水线寄存器 (Pipeline Registers)
    // =========================================================================
    // 定义寄存器，用于在时钟上升沿锁存来自 EX 阶段的数据
    reg [`EX_TO_MEM_WD-1:0] ex_to_mem_bus_r; // 主总线寄存器
    reg [65:0] ex_to_mem1_r;                 // HI/LO 总线寄存器

    always @ (posedge clk) begin
        if (rst) begin
            // 复位时清空寄存器
            ex_to_mem_bus_r <= `EX_TO_MEM_WD'b0;
            ex_to_mem1_r <= 66'b0;
        end
        // else if (flush) begin ... end
        
        // 暂停策略：
        // 如果 MEM 阶段被要求暂停(`Stop)，但下一级 WB 阶段继续流动(`NoStop)
        // 这意味着 MEM 阶段被卡住了，为了防止重复发送数据给 WB，或者防止错误数据流入，
        // 需要向 WB 发送一个“气泡”（即清空当前寄存器输出）。
        else if (stall[3]==`Stop && stall[4]==`NoStop) begin
            ex_to_mem_bus_r <= `EX_TO_MEM_WD'b0;
            ex_to_mem1_r <= 65'b0;
        end
        // 正常流动：
        // 如果 MEM 阶段不需要暂停，则正常接收 EX 阶段传来的新数据
        else if (stall[3]==`NoStop) begin
            ex_to_mem_bus_r <= ex_to_mem_bus;
            ex_to_mem1_r <= ex_to_mem1;
        end
        // 如果 stall[3]==Stop 且 stall[4]==Stop，则保持寄存器值不变（Hold）
    end

    // =========================================================================
    // 2. 解包逻辑 (Unpacking)
    // =========================================================================
    // 定义中间变量，用于拆解 ex_to_mem_bus_r 寄存器中的数据
    wire [31:0] mem_pc;         // 当前指令的 PC 值
    wire data_ram_en;           // RAM 片选使能 (Load/Store 指令为1)
    wire [3:0] data_ram_wen;    // RAM 写使能 (Store指令用，但在MEM阶段主要用于传递，Load逻辑不看它)
    wire [3:0] data_ram_read;   // 【关键】访存类型码 (如 LW, LB, LHU 等的标记)
    wire sel_rf_res;            // (可能未使用的保留位，或用于选择数据源)
    wire rf_we;                 // 通用寄存器写使能 (RegFile Write Enable)
    wire [4:0] rf_waddr;        // 通用寄存器写地址 (rd 或 rt)
    wire [31:0] rf_wdata;       // 【核心计算结果】最终要写入通用寄存器的数据
    wire [31:0] ex_result;      // 来自 EX 的 ALU 计算结果 (对于 Load/Store 来说，这是内存地址)
    wire [31:0] mem_result;     // 内存读出的原始数据
    
    // HI/LO 相关信号解包
    wire w_hi_we;               // HI 寄存器写使能
    wire w_lo_we;               // LO 寄存器写使能
    wire [31:0]hi_i;            // 待写入 HI 的数据
    wire [31:0]lo_i;            // 待写入 LO 的数据
  

    // 从主总线寄存器解包
    assign {
        mem_pc,         // 75:44
        data_ram_en,    // 43
        data_ram_wen,   // 42:39
        sel_rf_res,     // 38
        rf_we,          // 37
        rf_waddr,       // 36:32
        ex_result,      // 31:0 (注意：如果是 Load 指令，这就是内存地址)
        data_ram_read   // (总线最低位部分) 指令类型标记
    } =  ex_to_mem_bus_r;
    
    // 从 HI/LO 总线寄存器解包
    assign 
    {
        w_hi_we,
        w_lo_we,
        hi_i,
        lo_i
    }=ex_to_mem1_r ;
    
    // =========================================================================
    // 3. 数据透传 (Passthrough)
    // =========================================================================
    // 直接将 HI/LO 数据传给 WB 阶段
    assign mem_to_wb1 =
    {
        w_hi_we,
        w_lo_we,
        hi_i,
        lo_i
    };
    
    // 将 HI/LO 数据前推给 ID 阶段 (用于解决 MTHI/MFHI 冒险)
    assign mem_to_id_2 =
    {
        w_hi_we,
        w_lo_we,
        hi_i,
        lo_i
    };

    // 将 SRAM 读回的数据命名为 mem_result
    assign mem_result = data_sram_rdata;

    // =========================================================================
    // 4. Load 指令数据处理 (Data Alignment & Extension)
    // =========================================================================
    // 这是 MEM 阶段的核心逻辑。
    // SRAM 每次读回 32位 (mem_result)。
    // 如果是 LB (Load Byte) 或 LH (Load Halfword)，我们需要根据地址的低两位 (ex_result[1:0])
    // 从这 32 位中截取正确的部分，并根据指令是有符号还是无符号，进行符号扩展或零扩展。
    
    assign rf_wdata = 
        // ---------------- LW (Load Word) ----------------
        // 标记: 4'b1111 (假设)
        // 逻辑: 直接取整个 32 位内存数据
        (data_ram_read==4'b1111 && data_ram_en==1'b1) ? mem_result :
        
        // ---------------- LB (Load Byte Signed) ----------------
        // 标记: 4'b0001 (假设)
        // 逻辑: 截取 8 位，并将最高位(符号位)复制填充到高 24 位 (符号扩展)
        
        // 地址末尾 00: 取 bit[7:0]，符号位是 bit[7]，扩展24个 bit[7]
        (data_ram_read==4'b0001 && data_ram_en==1'b1 && ex_result[1:0]==2'b00) ?({{24{mem_result[7]}},mem_result[7:0]}):
        // 地址末尾 01: 取 bit[15:8]，符号位是 bit[15]
        (data_ram_read==4'b0001 && data_ram_en==1'b1 && ex_result[1:0]==2'b01) ?({{24{mem_result[15]}},mem_result[15:8]}):
        // 地址末尾 10: 取 bit[23:16]
        (data_ram_read==4'b0001 && data_ram_en==1'b1 && ex_result[1:0]==2'b10) ?({{24{mem_result[23]}},mem_result[23:16]}):
        // 地址末尾 11: 取 bit[31:24]
        (data_ram_read==4'b0001 && data_ram_en==1'b1 && ex_result[1:0]==2'b11) ?({{24{mem_result[31]}},mem_result[31:24]}):
        
        // ---------------- LBU (Load Byte Unsigned) ----------------
        // 标记: 4'b0010 (假设)
        // 逻辑: 截取 8 位，高 24 位全部补 0 (零扩展)
        (data_ram_read==4'b0010 && data_ram_en==1'b1 && ex_result[1:0]==2'b00) ?({24'b0,mem_result[7:0]}):
        (data_ram_read==4'b0010 && data_ram_en==1'b1 && ex_result[1:0]==2'b01) ?({24'b0,mem_result[15:8]}):
        (data_ram_read==4'b0010 && data_ram_en==1'b1 && ex_result[1:0]==2'b10) ?({24'b0,mem_result[23:16]}):
        (data_ram_read==4'b0010 && data_ram_en==1'b1 && ex_result[1:0]==2'b11) ?({24'b0,mem_result[31:24]}):
        
        // ---------------- LH (Load Halfword Signed) ----------------
        // 标记: 4'b0011 (假设)
        // 逻辑: 截取 16 位，符号扩展高 16 位。地址必须是 2 的倍数 (00 或 10)
        (data_ram_read==4'b0011 && data_ram_en==1'b1 && ex_result[1:0]==2'b00) ?({{16{mem_result[15]}},mem_result[15:0]}):
        (data_ram_read==4'b0011 && data_ram_en==1'b1 && ex_result[1:0]==2'b10) ?({{16{mem_result[31]}},mem_result[31:16]}):
        
        // ---------------- LHU (Load Halfword Unsigned) ----------------
        // 标记: 4'b0100 (假设)
        // 逻辑: 截取 16 位，高 16 位全部补 0
        (data_ram_read==4'b0100 && data_ram_en==1'b1 && ex_result[1:0]==2'b00) ?({16'b0,mem_result[15:0]}):
        (data_ram_read==4'b0100 && data_ram_en==1'b1 && ex_result[1:0]==2'b10) ?({16'b0,mem_result[31:16]}):
        
        // ---------------- 非 Load 指令 (如 ADD, SUB) ----------------
        // 如果不是访存指令，或者 enable 为 0，
        // 则直接将 EX 阶段计算的 ALU 结果 (ex_result) 作为最终结果
        ex_result;

    // =========================================================================
    // 5. 输出打包 (Bus Packing)
    // =========================================================================
    
    // 打包数据发送给 WB 阶段
    assign mem_to_wb_bus = {
        mem_pc,     // 传递 PC (用于Debug或异常处理)
        rf_we,      // 写使能传递
        rf_waddr,   // 写地址传递
        rf_wdata    // 【最终数据】(可能是内存读出的值，也可能是ALU结果)
    };
    
    // 打包数据前推给 ID 阶段 (Forwarding)
    // 这样如果下一条指令需要用到刚才 Load 或 ALU 的结果，ID 阶段可以直接拿去用，不用等 WB
    assign mem_to_id_bus = {
        rf_we,      
        rf_waddr,   
        rf_wdata    
    };

endmodule