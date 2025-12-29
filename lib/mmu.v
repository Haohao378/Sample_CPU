`include "defines.vh" // 引入宏定义文件 (通常包含总线宽度等定义)

module mmu (
    // ====== 1. 接口定义 ======
    input wire[31:0] addr_i, // 输入地址 (Address Input)
                             // 这是 CPU 核心发出的“虚拟地址”。
                             // 例如：PC 指针的值，或者 Load/Store 指令计算出的地址。

    output wire [31:0] addr_o // 输 出地址 (Address Output)
                              // 这是转换后的“物理地址”。
                              // 这个地址会真正发送给 SRAM 控制器或总线接口去读写内存。
);

    // ====== 2. 内部信号定义 ======
    
    // 地址头部信号 (高 3 位)
    // MIPS 的内存分段是根据高 3 位 ([31:29]) 来区分的
    wire [2:0] addr_head_i; // 输入地址的高 3 位
    wire [2:0] addr_head_o; // 输出地址的高 3 位 (转换后)

    // 内存段标志位 (Segment Flags)
    wire kseg0;     // 标志位：当前地址是否属于 kseg0 段 (0x8000_0000 ~ 0x9FFF_FFFF)
    wire kseg1;     // 标志位：当前地址是否属于 kseg1 段 (0xA000_0000 ~ 0xBFFF_FFFF)
    wire other_seg; // 标志位：当前地址是否属于其他段 (如 kuseg, kseg2)

    // ====== 3. 逻辑实现 ======

    // 提取输入地址的高 3 位
    // address[31:29] 决定了虚拟地址位于哪个 512MB 的段中
    assign addr_head_i = addr_i[31:29];
    
    // 判断是否为 kseg0 段
    // kseg0 范围: 0x8000_0000 -> 二进制 1000_...
    // 高 3 位是 100 (即十进制 4)
    assign kseg0 = addr_head_i == 3'b100;

    // 判断是否为 kseg1 段
    // kseg1 范围: 0xA000_0000 -> 二进制 1010_...
    // 高 3 位是 101 (即十进制 5)
    assign kseg1 = addr_head_i == 3'b101;

    // 判断是否为其他段
    // 既不是 kseg0 也不是 kseg1
    assign other_seg = ~kseg0 & ~kseg1;

    // 计算输出地址的高 3 位 (核心映射逻辑)
    // 这是一个多路选择逻辑 (Mux)，使用位运算实现：
    // 1. 如果是 kseg0: {3{kseg0}} 变成 111, 与 000 进行与运算 -> 结果 000
    // 2. 如果是 kseg1: {3{kseg1}} 变成 111, 与 000 进行与运算 -> 结果 000
    // 3. 如果是其他段: 保持原来的高 3 位 (addr_head_i) 不变
    //
    // 结论：kseg0 和 kseg1 的高 3 位都被强行清零了，映射到了物理内存的低端 (0x000...)
    assign addr_head_o = {3{kseg0}}&3'b000 | {3{kseg1}}&3'b000 | {3{other_seg}}&addr_head_i;
    
    // 拼接最终的物理地址
    // 将计算好的高 3 位 (addr_head_o) 和 原始的低 29 位 (addr_i[28:0]) 拼回去
    assign addr_o = {addr_head_o, addr_i[28:0]};

endmodule