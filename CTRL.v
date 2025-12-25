`include "lib/defines.vh" 

module CTRL(
    input wire rst,                 
    input wire stallreq_for_ex,     
    input wire stallreq_for_id,     
    output reg [`StallBus-1:0] stall 
);  
    
    always @ (*) begin
        stall = `StallBus'b0; 
    end

endmodule