`include "lib/defines.vh" 

module regfile(
    input wire clk,                 

    input wire [4:0] raddr1,        
    output wire [31:0] rdata1,      

    input wire [4:0] raddr2,        
    output wire [31:0] rdata2,      

    input wire [37:0] ex_to_id_bus, 
    input wire [37:0] mem_to_id_bus,
    input wire [37:0] wb_to_id_bus, 

    input wire [65:0] ex_to_id_2,   
    input wire [65:0] mem_to_id_2,  
    input wire [65:0] wb_to_id_2,   
    
    input wire we,                  
    input wire [4:0] waddr,         
    input wire [31:0] wdata,        
    
      input wire w_hi_we,           
      input wire w_lo_we,           
      input wire [31:0] hi_i,       
      input wire [31:0] lo_i,       

      input wire r_hi_we,           
      input wire r_lo_we,           
      output wire[31:0] hi_o,       
      output wire[31:0] lo_o,       

    input [31:0] inst,              
    input inst_lsa                  
);

    reg [31:0] reg_array [31:0];    
    
    always @ (posedge clk) begin
        if (we && waddr!=5'b0) begin
            reg_array[waddr] <= wdata;
        end
    end

    wire [31:0] ex_result;    
    wire ex_rf_we;            
    wire [4:0] ex_rf_waddr;   
    assign { ex_rf_we, ex_rf_waddr, ex_result } = ex_to_id_bus;

    wire [31:0] mem_rf_wdata; 
    wire mem_rf_we;           
    wire [4:0] mem_rf_waddr;  
    assign { mem_rf_we, mem_rf_waddr, mem_rf_wdata } = mem_to_id_bus;

    wire [31:0] wb1_rf_wdata; 
    wire wb1_rf_we;           
    wire [4:0] wb1_rf_waddr;  
    assign { wb1_rf_we, wb1_rf_waddr, wb1_rf_wdata } = wb_to_id_bus;
    
    wire [31:0] bbb;          
    assign bbb = (raddr1 == 5'b0) ? 32'b0 :                         
    ((raddr1 == ex_rf_waddr)&& ex_rf_we) ? ex_result :              
    ((raddr1 == mem_rf_waddr)&& mem_rf_we) ? mem_rf_wdata :         
    ((raddr1 == wb1_rf_waddr)&& wb1_rf_we) ? wb1_rf_wdata :         
    reg_array[raddr1];                                              
    
    assign rdata1 = bbb;
    
    assign rdata2 = (raddr2 == 5'b0) ? 32'b0 : 
    ((raddr2 == ex_rf_waddr)&& ex_rf_we) ? ex_result :
    ((raddr2 == mem_rf_waddr)&& mem_rf_we) ? mem_rf_wdata : 
    ((raddr2 == wb1_rf_waddr)&& wb1_rf_we) ? wb1_rf_wdata : 
    reg_array[raddr2];
    
    assign hi_o = 32'b0;
    assign lo_o = 32'b0;
     
endmodule