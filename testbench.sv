`include "defines.sv"

Trace queue [$:`MAX_QUEUE_SIZE];

module testbench;

logic CPU_Clock = 1;
logic DIMM_Clock = 1;
longint unsigned clockTicksCount;

/******** Clock generators********/
always                  
begin
    /* Generating CPU Clock */
    CPU_Clock = #`CPU_CLOCK_DELAY ~CPU_Clock;
    if(CPU_Clock)
    begin
        clockTicksCount++;
    end
end

always
begin
    /* Generating DIMM Clock*/
    DIMM_Clock = #`DIMM_CLOCK_DELAY ~DIMM_Clock;
end



initial begin

integer InputFileDptr, OutputFileDptr;        // File Descriptor for input and output file
string input_file, output_file;

if ($value$plusargs ("input_file=%s", input_file))
    $display ("user entered input file name: %s", input_file);
else
    begin
        input_file = "trace.txt";
        $display("User using default input file: %s",input_file);
    end

if ($value$plusargs ("output_file=%s", output_file))
    $display ("user entered output file name: %s", output_file);
else
    begin
        output_file = "dram.txt";
        $display("using default output file: %s",output_file);
    end

InputFileDptr = ProcessFile(input_file,"r");
OutputFileDptr = ProcessFile(output_file,"w");
ParseInputFile(InputFileDptr ,OutputFileDptr, input_file, output_file);

$fclose(InputFileDptr);                                 
$fclose(OutputFileDptr);

$finish;
end



/***************************** Function definitions *******************************/

task ParseInputFile (integer InputFileDptr, integer OutputFileDptr, string input_file, string output_file);
begin
    integer time_t, core, operation;
    longint unsigned address;
    Trace trace, buffer;
    static bit done = 0;

    $display("Processing requests in %s .... \n\n",input_file);

    //`ifdef DEBUG 
        $display("Requests added in queue: ");
        $display("Format: Simulated_Time (CPU clock TIcks)\t Core(0-11) \t  Operation(0,1,2)\t Bank \t BankGroup \t Row \t Column");
    //`endif

    while(!done)
    begin
        while ((!$feof(InputFileDptr)) || (buffer))
        begin
            if(CPU_Clock)
            begin

                /*
                    Process requests on every DIMM clock tick.
                    P.S - 1 DIMM Clock Cycle == 2 CPU Clock Cycle
                        i.e. On every 2 CPU Clock tick there will be 1 DIMM Clock Tick
                */
                
                if(DIMM_Clock && CPU_Clock)
                begin
                    if(queue.size() != 0)
                    begin
                        ProcessRequest(OutputFileDptr);
                        CheckCompletedRequest(); 
                    end
                end

                if(queue.size() != `MAX_QUEUE_SIZE)
                begin
                    if(buffer)
                    begin
                        /*
                            If something is stored in buffer, wait for the simulation time to reach the required request time
                            Once it reached, add it to queue and set buffer to NULL
                        */
                        if(buffer.time_t <= clockTicksCount)
                        begin
                            AddToQueue(buffer);
                            buffer = null;
                        end                            
                    end    
                    else
                    begin
                        $fscanf (InputFileDptr,"%d %d %d %h", time_t, core, operation, address);
                        trace = new (time_t, core, operation, address);

                        // Once we get the address, get CHANNEL, BA, BG, COL and ROW 
                        trace = AddressMap(trace);  
                        
                        /* 
                            Check if the current simulation time (CPU clock ticks) has reached to requied request time
                            yes - Add to queue
                            no - Store it to buffer and wait for the simulation time to reach the required request time and
                                DO NOT SCAN FURTHER FROM THE FILE till you store the buffer in queue.
                        */
                        if(trace.time_t <= clockTicksCount)
                            AddToQueue(trace);
                        else
                            buffer = trace;
                    end
                end
            end

            #`CPU_CLOCK_DELAY;
        end
        

        /*
            Once the input file read is completed. The above while loop for eof will terminate.
            But it is possible that there are still requests left in the the queue.
            So, Process the requests in the queue till it is empty.
        */
        while(queue.size())
        begin
            if(DIMM_Clock && CPU_Clock)
                begin
                    
                    ProcessRequest(OutputFileDptr);
                    CheckCompletedRequest();
                end

            #`CPU_CLOCK_DELAY;
        end

        /*
            Once the queue is completely empty - Processing of input file is completed.
        */
        if(!queue.size())
            done=1;
    end

    $display("Processing complete! Please check %s file for the scheduled commands.. ", output_file);
    $display("------------------------------------------------------------------------");
    $display("Total CPU clock ticks for processing: %d", clockTicksCount);
    $display("------------------------------------------------------------------------");
end
endtask


/*
    ProcessRequest function for CHECKPOINT 2
    Generate output in one clock tick (without timing constraints)
*/

function void ProcessRequest(integer OutputFileDptr);
begin
    static bit updateComplete = 0;

    if(!queue.size())
    return;

    // if(queue[0].queueTime == clockTicksCount)
    // return;

    if(queue[0].state == NOT_PROCESSED)
    begin
        queue[0].state = ACT0;
    end

    updateComplete = 0;

    /*
        Based on operation, change the required state(command) and update the output file
    */
    while(!updateComplete)
    begin
        case(queue[0].operation)
            DATA_READ:
                case(queue[0].state)
                    ACT0: 
                        begin
                            updateOutputTrace(queue[0], OutputFileDptr);
                            queue[0].state = ACT1;
                        end
                    ACT1: 
                        begin
                            updateOutputTrace(queue[0], OutputFileDptr);
                            queue[0].state = RD0;
                        end
                    RD0: 
                        begin
                            updateOutputTrace(queue[0], OutputFileDptr);
                            queue[0].state = RD1;
                        end
                    RD1: 
                        begin
                            updateOutputTrace(queue[0], OutputFileDptr);
                            queue[0].state = PRE;
                        end
                    PRE: 
                        begin
                            updateOutputTrace(queue[0], OutputFileDptr);
                            queue[0].state = PROCESSED;
                        end
                endcase
            DATA_WRITE:
                case(queue[0].state)
                    ACT0: 
                        begin
                            updateOutputTrace(queue[0], OutputFileDptr);
                            queue[0].state = ACT1;
                        end
                    ACT1: 
                        begin
                            updateOutputTrace(queue[0], OutputFileDptr);
                            queue[0].state = WR0;
                        end
                    WR0: 
                        begin
                            updateOutputTrace(queue[0], OutputFileDptr);
                            queue[0].state = WR1;
                        end
                    WR1: 
                        begin
                            updateOutputTrace(queue[0], OutputFileDptr);
                            queue[0].state = PRE;

                        end
                    PRE: 
                        begin
                            updateOutputTrace(queue[0], OutputFileDptr);
                            queue[0].state = PROCESSED;
                        end
            endcase
            INSTRUCTION_FETCH:
                    case(queue[0].state)
                    ACT0: 
                        begin
                            updateOutputTrace(queue[0], OutputFileDptr);
                            queue[0].state = ACT1;                        
                        end
                    ACT1: 
                        begin
                            updateOutputTrace(queue[0], OutputFileDptr);
                            queue[0].state = RD0;
                        end
                    RD0: 
                        begin
                            updateOutputTrace(queue[0], OutputFileDptr);
                            queue[0].state = RD1;
                        end
                    RD1: 
                        begin
                            updateOutputTrace(queue[0], OutputFileDptr);
                            queue[0].state = PRE;
                        end
                    PRE: 
                        begin
                            updateOutputTrace(queue[0], OutputFileDptr);
                            queue[0].state = PROCESSED;
                        end
                endcase
        endcase
        
        if(queue[0].state == PROCESSED)
            updateComplete = 1;
    end
     
end
endfunction


function void CheckCompletedRequest();
begin
    /*
        If the current request has completed the process, remove from the queue.
    */
    Trace poppedTrace;
    if(!queue.size())
    return;
    
    if(queue[0].state == PROCESSED)
    begin
        poppedTrace = queue.pop_front();
    end

end
endfunction


function Trace AddressMap(Trace trace);
begin
    trace.row = trace.address[33:18];
    trace.column = {trace.address[17:12], trace.address[5:2]};
    trace.bank = trace.address[11:10];
    trace.bankGroup = trace.address[9:7];
    trace.channel = 0;

    return trace;
end
endfunction


function void updateOutputTrace (Trace trace, integer OutputFileDptr);
begin
    string outputTrace, command;
    string clockCount, channel, state, col, row, bank, bankGroup;

    $sformat(clockCount, "%0d", clockTicksCount);
    $sformat(channel, "%0d", trace.channel);

    case(trace.state)
        PRE: state = "PRE\t";
        ACT0: state = "ACT0";
        ACT1: state = "ACT1";
        RD0: state = "RD0\t";
        RD1: state = "RD1\t";
        WR0: state = "WR0\t";
        WR1: state = "WR1\t";
    endcase
    
    $sformat(bankGroup, "%0d", trace.bankGroup);
    $sformat(bank, "%0d", trace.bank);
    $sformat(row, "%0H", trace.row);
    $sformat(col, "%0H", trace.column);

    command = {state, "\t", bankGroup, "\t", bank, "\t"};

    case(trace.state)
        ACT0, ACT1: command = {command, row.toupper()};
        RD0, RD1, WR0, WR1: command = {command, col.toupper()};
    endcase
    outputTrace = {clockCount, "\t", channel, "\t", command};

    $fdisplay(OutputFileDptr, outputTrace);
end 
endfunction


function void AddToQueue (Trace trace);
begin
    //if(queue.size() != `MAX_QUEUE_SIZE)
    //begin
        //`ifdef DEBUG
        //`endif
        trace.queueTime = clockTicksCount;
        queue.push_back(trace);
        $display("%d\t%d\t%d\t\t%d\t\t%d\t\t%h\t\t%h \t\t\t Size: %d",clockTicksCount, trace.core, trace.operation, trace.bank, trace.bankGroup, trace.row, trace.column, queue.size());  

    //end
end
endfunction


function integer ProcessFile (string file_name, string mode);
begin
    ProcessFile = $fopen(file_name,mode);
    if (!ProcessFile)
    begin
        $display("Unable to open the file!");
        $finish;
    end
    
end
endfunction






/* 
    WIP:  ProcessRequest funtion with false timing constraints
*/

`ifdef 0 
function void ProcessRequest(integer OutputFileDptr);
begin
    if(queue[0].state == NOT_PROCESSED)
    begin
        queue[0].timer = 1;
        queue[0].state = ACT0;
    end

    case(queue[0].operation)
        DATA_READ:
            case(queue[0].state)
                ACT0: 
                    begin
                        if(queue[0].timer == 0)
                        begin
                            updateOutputTrace(queue[0], OutputFileDptr);
                            queue[0].state = ACT1;
                            queue[0].timer = 1;                           
                        end
                        else
                            queue[0].timer--;
                    end
                ACT1: 
                    begin
                        if(queue[0].timer == 0)
                        begin
                            updateOutputTrace(queue[0], OutputFileDptr);
                            queue[0].state = RD0;
                            queue[0].timer = 4;
                        end
                        else
                            queue[0].timer--;
                    end
                RD0: 
                    begin
                        if(queue[0].timer == 0)
                        begin
                            updateOutputTrace(queue[0], OutputFileDptr);
                            queue[0].state = RD1;
                            queue[0].timer = 1;
                        end
                        else
                            queue[0].timer--;
                    end
                RD1: 
                    begin
                        if(queue[0].timer == 0)
                        begin
                            updateOutputTrace(queue[0], OutputFileDptr);
                            queue[0].state = PRE;
                            queue[0].timer = 4;
                        end
                        else
                            queue[0].timer--;
                    end
                PRE: 
                    begin
                        if(queue[0].timer == 0)
                        begin
                            updateOutputTrace(queue[0], OutputFileDptr);
                            queue[0].state = PROCESSED;
                            queue[0].timer = 4;
                        end
                        else
                            queue[0].timer--;
                    end

            endcase
        DATA_WRITE:
                case(queue[0].state)
                ACT0: 
                    begin
                        if(queue[0].timer == 0)
                        begin
                            updateOutputTrace(queue[0], OutputFileDptr);
                            queue[0].state = ACT1;
                            queue[0].timer = 1;
                        end
                        else
                            queue[0].timer--;
                    end
                ACT1: 
                    begin
                        if(queue[0].timer == 0)
                        begin
                            updateOutputTrace(queue[0], OutputFileDptr);
                            queue[0].state = WR0;
                            queue[0].timer = 4;
                        end
                        else
                            queue[0].timer--;
                    end
                WR0: 
                    begin
                        if(queue[0].timer == 0)
                        begin
                            updateOutputTrace(queue[0], OutputFileDptr);
                            queue[0].state = WR1;
                            queue[0].timer = 1;
                        end
                        else
                            queue[0].timer--;
                    end
                WR1: 
                    begin
                        if(queue[0].timer == 0)
                        begin
                            updateOutputTrace(queue[0], OutputFileDptr);
                            queue[0].state = PRE;
                            queue[0].timer = 4;
                        end
                        else
                            queue[0].timer--;
                    end
                PRE: 
                    begin
                        if(queue[0].timer == 0)
                        begin
                            updateOutputTrace(queue[0], OutputFileDptr);
                            queue[0].state = PROCESSED;
                            queue[0].timer = 4;
                        end
                        else
                            queue[0].timer--;
                    end

            endcase
        INSTRUCTION_FETCH:
                case(queue[0].state)
                ACT0: 
                    begin
                        if(queue[0].timer == 0)
                        begin
                            updateOutputTrace(queue[0], OutputFileDptr);
                            queue[0].state = ACT1;
                            queue[0].timer = 1;                           
                        end
                        else
                            queue[0].timer--;
                    end
                ACT1: 
                    begin
                        if(queue[0].timer == 0)
                        begin
                            updateOutputTrace(queue[0], OutputFileDptr);
                            queue[0].state = RD0;
                            queue[0].timer = 4;
                        end
                        else
                            queue[0].timer--;
                    end
                RD0: 
                    begin
                        if(queue[0].timer == 0)
                        begin
                            updateOutputTrace(queue[0], OutputFileDptr);
                            queue[0].state = RD1;
                            queue[0].timer = 1;
                        end
                        else
                            queue[0].timer--;
                    end
                RD1: 
                    begin
                        if(queue[0].timer == 0)
                        begin
                            updateOutputTrace(queue[0], OutputFileDptr);
                            queue[0].state = PRE;
                            queue[0].timer = 4;
                        end
                        else
                            queue[0].timer--;
                    end
                PRE: 
                    begin
                        if(queue[0].timer == 0)
                        begin
                            updateOutputTrace(queue[0], OutputFileDptr);
                            queue[0].state = PROCESSED;
                            queue[0].timer = 4;
                        end
                        else
                            queue[0].timer--;
                    end

            endcase
    endcase
     
end
endfunction
`endif

endmodule