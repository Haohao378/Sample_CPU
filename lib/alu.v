`include "defines.vh" // 包含头文件，通常定义了各种常量（如操作码宏定义）

module alu(
    // ------ 输入信号 ------
    input wire [11:0] alu_control, // ALU 控制信号。每一位对应一种操作（独热码设计），例如第0位高电平代表加法。
    input wire [31:0] alu_src1,    // 源操作数 1 (Source Operand 1)，通常来自 rs 寄存器
    input wire [31:0] alu_src2,    // 源操作数 2 (Source Operand 2)，来自 rt 寄存器或立即数扩展
    
    // ------ 输出信号 ------
    output wire [31:0] alu_result  // ALU 最终计算结果
);

    // ------ 操作类型解码信号 ------
    // 这些信号将 alu_control 的 12 个位拆解开，每一根线代表一种特定的运算。
    // 当对应的线为 1 时，表示当前需要执行该运算。
    wire op_add;  // 加法操作 (ADD, ADDI, ADDU...)
    wire op_sub;  // 减法操作 (SUB, SUBU)
    wire op_slt;  // 有符号比较，小于置1 (SLT, SLTI)
    wire op_sltu; // 无符号比较，小于置1 (SLTU, SLTIU)
    wire op_and;  // 按位与 (AND, ANDI)
    wire op_nor;  // 按位或非 (NOR)
    wire op_or;   // 按位或 (OR, ORI)
    wire op_xor;  // 按位异或 (XOR, XORI)
    wire op_sll;  // 逻辑左移 (SLL, SLLV)
    wire op_srl;  // 逻辑右移 (SRL, SRLV)
    wire op_sra;  // 算术右移 (SRA, SRAV)
    wire op_lui;  // 加载高位立即数 (LUI)

    // 将 12 位的输入总线 alu_control 拆解赋值给上面的单个信号线
    assign {op_add, op_sub, op_slt, op_sltu,
            op_and, op_nor, op_or, op_xor,
            op_sll, op_srl, op_sra, op_lui} = alu_control;
    
    // ------ 中间结果信号 ------
    // 这些 wire 用来存储每一种运算逻辑计算出的“临时结果”。
    // 无论当前指令是什么，硬件电路通常会并行计算所有这些结果，最后再选一个输出。
    wire [31:0] add_sub_result; // 加减法的结果
    wire [31:0] slt_result;     // 有符号比较的结果（0 或 1）
    wire [31:0] sltu_result;    // 无符号比较的结果（0 或 1）
    wire [31:0] and_result;     // 与运算结果
    wire [31:0] nor_result;     // 或非运算结果
    wire [31:0] or_result;      // 或运算结果
    wire [31:0] xor_result;     // 异或运算结果
    wire [31:0] sll_result;     // 逻辑左移结果
    wire [31:0] srl_result;     // 逻辑右移结果
    wire [31:0] sra_result;     // 算术右移结果
    wire [31:0] lui_result;     // LUI 操作结果
    

    // ------ 逻辑运算实现 ------
    assign and_result = alu_src1 & alu_src2;       // 按位与
    assign or_result  = alu_src1 | alu_src2;       // 按位或
    assign nor_result = ~or_result;                // 或非：先或后取反
    assign xor_result = alu_src1 ^ alu_src2;       // 按位异或
    // LUI 实现：将操作数2的低16位（通常是立即数）放到高16位，低16位补0
    assign lui_result = {alu_src2[15:0], 16'b0};   

    // ------ 加法器/减法器实现 ------
    // 为了节省硬件资源，加法、减法和比较操作都共用这一个加法器逻辑。
    wire [31:0] adder_a;      // 加法器输入 A
    wire [31:0] adder_b;      // 加法器输入 B
    wire        adder_cin;    // 进位输入 (Carry In)
    wire [31:0] adder_result; // 加法器输出结果
    wire        adder_cout;   // 进位输出 (Carry Out)

    assign adder_a = alu_src1; // 输入 A 总是源操作数 1

    // 输入 B 的选择逻辑：
    // 如果是减法(sub)或比较(slt/sltu)，我们需要做 A - B。
    // 在计算机中，A - B 等价于 A + (~B) + 1 (补码运算)。
    // 所以这里如果需要减法，就将 alu_src2 取反。
    assign adder_b = (op_sub | op_slt | op_sltu) ? ~alu_src2 : alu_src2;

    // 进位输入的选择逻辑：
    // 同样，如果是减法类操作，进位设为 1（配合上面的取反，完成补码转换）。
    // 如果是加法，进位为 0。
    assign adder_cin = (op_sub | op_slt | op_sltu) ? 1'b1 : 1'b0;

    // 执行加法运算，拼接 {adder_cout, adder_result} 以捕获进位输出
    assign {adder_cout, adder_result} = adder_a + adder_b + adder_cin;

    // 加减法指令的最终结果直接取自加法器
    assign add_sub_result = adder_result;

    // ------ 比较指令 (Set Less Than) 实现 ------
    // SLT: 有符号比较。如果 src1 < src2，则结果为 1，否则为 0。
    
    assign slt_result[31:1] = 31'b0; // 高 31 位全部置 0，因为比较结果只有 0 或 1

    // SLT 结果最低位的判断逻辑（核心难点）：
    // 情况1：符号不同。src1为负(1)，src2为正(0)。此时 src1 肯定小于 src2。
    //        (alu_src1[31] & ~alu_src2[31]) 捕捉这种情况。
    // 情况2：符号相同。此时看减法结果 adder_result 的符号位。
    //        如果符号相同且 (src1 - src2) 的结果为负(31位为1)，说明 src1 < src2。
    //        (~(alu_src1[31]^alu_src2[31])) 判断符号是否相同。
    assign slt_result[0] = (alu_src1[31] & ~alu_src2[31]) 
                         | (~(alu_src1[31]^alu_src2[31]) & adder_result[31]);
    
    // SLTU: 无符号比较。
    assign sltu_result[31:1] = 31'b0; // 高 31 位清零

    // 无符号减法 A - B，如果发生借位，说明 A < B。
    // 在加法器实现中 (A + ~B + 1)，如果有进位输出 (Cout=1)，说明结果没有借位(即 A >= B)。
    // 如果 Cout=0，说明发生了借位(即 A < B)。所以结果取反 adder_cout。
    assign sltu_result[0] = ~adder_cout;

    // ------ 移位运算实现 ------
    // MIPS 移位指令的移位量由 alu_src1 的低 5 位决定 (src1[4:0])，被移位的数据是 src2
    assign sll_result = alu_src2 << alu_src1[4:0];        // 逻辑左移
    assign srl_result = alu_src2 >> alu_src1[4:0];        // 逻辑右移 (补0)
    // $signed() 告诉 Verilog 这是一个有符号数，使用 >>> 进行算术右移 (补符号位)
    assign sra_result = ($signed(alu_src2)) >>> alu_src1[4:0]; 

    // ------ 结果多路选择 (MUX) ------
    // 使用“按位与+按位或”的方式实现多路选择器。
    // 前提：alu_control 是独热码，同一时刻只有一个 op_xxx 为 1。
    // 原理：将 op_xxx 扩展为 32 位全 1 的掩码 ({32{1'b1}} -> 0xFFFFFFFF)，
    //      与对应的 result 进行“与”运算。如果该 op 未被选中，结果就是 0。
    //      最后将所有结果“或”起来，选中的那个结果就会通过。
    assign alu_result = ({32{op_add|op_sub  }} & add_sub_result)
                      | ({32{op_slt         }} & slt_result)
                      | ({32{op_sltu        }} & sltu_result)
                      | ({32{op_and         }} & and_result)
                      | ({32{op_nor         }} & nor_result)
                      | ({32{op_or          }} & or_result)
                      | ({32{op_xor         }} & xor_result)
                      | ({32{op_sll         }} & sll_result)
                      | ({32{op_srl         }} & srl_result)
                      | ({32{op_sra         }} & sra_result)
                      | ({32{op_lui         }} & lui_result);
                      
endmodule