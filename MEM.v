`include "lib/defines.vh" 

module MEM(
    input wire clk,                 
    input wire rst,                 
    // input wire flush,            
    input wire [`StallBus-1:0] stall, 

    input wire [`EX_TO_MEM_WD-1:0] ex_to_mem_bus, 
    input wire [31:0] data_sram_rdata,             

    output wire [37:0] mem_to_id_bus,              
    output wire [`MEM_TO_WB_WD-1:0] mem_to_wb_bus, 
    
    input wire [65:0] ex_to_mem1,   
    output wire[65:0] mem_to_wb1,   
    output wire[65:0] mem_to_id_2   
);

    reg [`EX_TO_MEM_WD-1:0] ex_to_mem_bus_r; 

    always @ (posedge clk) begin
        if (rst) begin
            ex_to_mem_bus_r <= `EX_TO_MEM_WD'b0;
        end
        else if (stall[3]==`Stop && stall[4]==`NoStop) begin
            ex_to_mem_bus_r <= `EX_TO_MEM_WD'b0;
        end
        else if (stall[3]==`NoStop) begin
            ex_to_mem_bus_r <= ex_to_mem_bus;
        end
    end

    wire [31:0] mem_pc;         
    wire data_ram_en;           
    wire [3:0] data_ram_wen;    
    wire [3:0] data_ram_read;   
    wire sel_rf_res;            
    wire rf_we;                 
    wire [4:0] rf_waddr;        
    wire [31:0] rf_wdata;       
    wire [31:0] ex_result;      
    wire [31:0] mem_result;     
    
    wire w_hi_we;               
    wire w_lo_we;               
    wire [31:0]hi_i;            
    wire [31:0]lo_i;            
  
    assign {
        mem_pc,         
        data_ram_en,    
        data_ram_wen,   
        sel_rf_res,     
        rf_we,          
        rf_waddr,       
        ex_result,      
        data_ram_read   
    } =  ex_to_mem_bus_r;
    
    assign w_hi_we = 1'b0;
    assign w_lo_we = 1'b0;
    assign hi_i = 32'b0;
    assign lo_i = 32'b0;
    
    assign mem_to_wb1 = { w_hi_we, w_lo_we, hi_i, lo_i };
    assign mem_to_id_2 = { w_hi_we, w_lo_we, hi_i, lo_i };

    assign mem_result = data_sram_rdata;

    // --- 修改：强制 rf_wdata 等于 ex_result (不读内存) ---
    assign rf_wdata = ex_result;
        
    assign mem_to_wb_bus = {
        mem_pc,     
        rf_we,      
        rf_waddr,   
        rf_wdata    
    };
    
    assign mem_to_id_bus = {
        rf_we,      
        rf_waddr,   
        rf_wdata    
    };

endmodule