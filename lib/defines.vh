// defines.vh - 全局定义文件
// 功能：定义整个CPU设计中使用的常量、参数和状态编码
// 主要包含：
// 1. 流水线级间总线宽度定义
// 2. 流水线暂停控制信号定义
// 3. 除法器状态定义
// 4. 其他常用常量定义

// 流水线级间总线宽度定义
// 各阶段总线的位宽，用于传递不同阶段间的数据和控制信号
`define IF_TO_ID_WD 33    // IF到ID阶段总线宽度（33位）
`define ID_TO_EX_WD 159   // ID到EX阶段总线宽度（159位）
`define EX_TO_MEM_WD 76   // EX到MEM阶段总线宽度（76位）
`define MEM_TO_WB_WD 70   // MEM到WB阶段总线宽度（70位）
`define BR_WD 33          // 分支相关信号总线宽度（33位）
`define DATA_SRAM_WD 69   // 数据存储器接口总线宽度（69位）
`define WB_TO_RF_WD 38    // 写回到寄存器文件总线宽度（38位）

// 流水线暂停控制信号定义
`define StallBus 6        // 暂停控制总线宽度（6位，对应5个流水线阶段+1位预留）
`define NoStop 1'b0       // 不暂停状态
`define Stop 1'b1         // 暂停状态

// 常用常量定义
`define ZeroWord 32'b0    // 32位零值常量


// 除法器状态定义
// 除法操作的各个状态编码
`define DivFree 2'b00           // 除法器空闲状态
`define DivByZero 2'b01         // 除零错误状态
`define DivOn 2'b10             // 除法进行中状态
`define DivEnd 2'b11            // 除法结束状态
`define DivResultReady 1'b1     // 除法结果就绪
`define DivResultNotReady 1'b0  // 除法结果未就绪
`define DivStart 1'b1           // 除法开始信号
`define DivStop 1'b0            // 除法停止信号