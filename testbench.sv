`include "defines.sv"

Request queue [$ : `MAX_QUEUE_SIZE];
Bank banks [0 : `MAX_BANK_GROUP][0 : `MAX_BANK_NUMBER];

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
ProcessInputRequests(InputFileDptr ,OutputFileDptr, input_file, output_file);

$fclose(InputFileDptr);                  
$fclose(OutputFileDptr);

$finish;
end



/***************************** Function definitions *******************************/

task ProcessInputRequests (integer InputFileDptr, integer OutputFileDptr, string input_file, string output_file);
begin
    integer time_t, core, operation;
    longint unsigned address;
    Request request, buffer;
    static bit done = 0;

  

    InitBanks();
    $display("Processing requests in %s .... \n\n",input_file);

    `ifdef DEBUG 
        $display("Requests added in queue: ");
        $display("Format: Simulated_Time (CPU clock TIcks)\t Core(0-11) \t  Operation(0,1,2)\t Bank \t BankGroup \t Row \t Column");
    `endif
    
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
                    ProcessRequest(OutputFileDptr);
                    CheckCompletedRequest();
                    UpdateTimers(); 
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
                        if($fscanf (InputFileDptr,"%d %d %d %h", time_t, core, operation, address) == 4)
                            request = new (time_t, core, operation, address);

                        // Once we get the address, get CHANNEL, BA, BG, COL and ROW 
                        request = AddressMap(request);  
                        
                        /* 
                            Check if the current simulation time (CPU clock ticks) has reached to requied request time
                            yes - Add to queue
                            no - Store it to buffer and wait for the simulation time to reach the required request time and
                                DO NOT SCAN FURTHER FROM THE FILE till you store the buffer in queue.
                        */
                        if(request.time_t <= clockTicksCount)
                            AddToQueue(request);
                        else
                            buffer = request;
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
                    UpdateTimers();
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


function void ProcessRequest(integer OutputFileDptr);
begin
    static bit isCommandIssued;
    if(!queue.size())
        return;

    if(queue[0].state == PROCESSED)
        return;

    if(queue[0].state == NOT_PROCESSED)
    begin
        if((banks[queue[0].bankGroup][queue[0].bank].tRP == 0) || (banks[queue[0].bankGroup][queue[0].bank].tRP >= `tRP))
        begin
            ResetBankTimings(queue[0].bankGroup , queue[0].bank);
            queue[0].state = ACT0;
            banks[queue[0].bankGroup][queue[0].bank].requestState = queue[0].state;
            banks[queue[0].bankGroup][queue[0].bank].bankState = OPEN;
            isCommandIssued = 0;
        end
        else
            return;
    end
    else
    begin
        if(queue[0].state != queue[0].nextState)
        begin
            queue[0].state = queue[0].nextState;
            banks[queue[0].bankGroup][queue[0].bank].requestState = queue[0].state;
            isCommandIssued = 0;
        end
    end


    case (queue[0].state)
        ACT0:
            begin
                if(!isCommandIssued)
                    isCommandIssued = IssueCommand(queue[0], OutputFileDptr);

                queue[0].nextState = ACT1;
            end
        ACT1:
            begin
                if(!isCommandIssued)
                    isCommandIssued = IssueCommand(queue[0], OutputFileDptr);

                if(banks[queue[0].bankGroup][queue[0].bank].tRCD == `tRCD - 1)
                begin
                    if(queue[0].operation == DATA_WRITE)
                        queue[0].nextState = WR0;
                    else
                        queue[0].nextState = RD0;
                end
            end
        RD0:
            begin
                if(!isCommandIssued)
                    isCommandIssued = IssueCommand(queue[0], OutputFileDptr);
                
                queue[0].nextState = RD1;
            end
        RD1:
            begin
                if(!isCommandIssued)
                    isCommandIssued = IssueCommand(queue[0], OutputFileDptr);

                if(banks[queue[0].bankGroup][queue[0].bank].tRAS == `tRAS - 1)
                    queue[0].nextState = PRE;
            end
        WR0:
            begin
                if(!isCommandIssued)
                    isCommandIssued = IssueCommand(queue[0], OutputFileDptr);
                
                queue[0].nextState = WR1;
            end
        WR1:
            begin
                if(!isCommandIssued)
                    isCommandIssued = IssueCommand(queue[0], OutputFileDptr);

                if(banks[queue[0].bankGroup][queue[0].bank].tWR == `tWR - 1)
                begin
                    queue[0].nextState = PRE;
                end
            end
        PRE:
            begin
                if(!isCommandIssued)
                    isCommandIssued = IssueCommand(queue[0], OutputFileDptr);
                
                if(queue[0].operation == DATA_WRITE)
                    queue[0].state = PROCESSED;
            end
    endcase
    

end
endfunction




function void ResetBankTimings (logic [3:0] bankGroup, logic [1:0] bank);
   
    banks[bankGroup][bank].tRC = 0;
    banks[bankGroup][bank].tRAS = 0;
    banks[bankGroup][bank].tRP = 0;
    banks[bankGroup][bank].tCWD = 0;
    banks[bankGroup][bank].tCL = 0;
    banks[bankGroup][bank].tRCD = 0;
    banks[bankGroup][bank].tBURST = 0;
    banks[bankGroup][bank].tWR = 0;
    banks[bankGroup][bank].tRTP = 0;

endfunction



function void UpdateTimers();
begin


    //update timers for all open banks

    foreach(banks[i,j])
    begin
        if(banks[i][j].bankState == OPEN)
        begin
            case(banks[i][j].requestState)
                ACT0:
                    begin
                        ResetBankTimers(i,ACT0);
                        banks[i][j].tRC++;
                        banks[i][j].tRAS++;
                        banks[i][j].tRRD_L++;
                        banks[i][j].tRRD_S++;
                        banks[i][j].tRCD++;
                    end
                ACT1:
                    begin
                        banks[i][j].tRC++;
                        banks[i][j].tRAS++;
                        banks[i][j].tRRD_L++;
                        banks[i][j].tRRD_S++;
                        banks[i][j].tRCD++;
                    end
                RD0:
                    begin
                        banks[i][j].tRC++;
                        banks[i][j].tRAS++;
                        banks[i][j].tRRD_L++;
                        banks[i][j].tRRD_S++;

                        banks[i][j].tRTP++;

                        banks[i][j].tCL++;

                        ResetBankTimers(i,RD0);
                        banks[i][j].tCCD_L++;
                        banks[i][j].tCCD_S++;
                        banks[i][j].tCCD_L_RTW++;
                        banks[i][j].tCCD_S_RTW++;
                    end
                RD1:
                    begin
                        banks[i][j].tRAS++;
                        banks[i][j].tRC++;
                        banks[i][j].tRRD_L++;
                        banks[i][j].tRRD_S++;

                        banks[i][j].tRTP++;

                        banks[i][j].tCL++;
                        banks[i][j].tCCD_L++;
                        banks[i][j].tCCD_S++;
                        banks[i][j].tCCD_L_RTW++;
                        banks[i][j].tCCD_S_RTW++;

                        if(banks[i][j].tCL > `tCL)
                            banks[i][j].tBURST++;


                    end
                WR0:
                    begin
                        banks[i][j].tRAS++;
                        banks[i][j].tRC++;
                        banks[i][j].tRRD_L++;
                        banks[i][j].tRRD_S++;

                        banks[i][j].tCWD++;

                        ResetBankTimers(i,WR0);

                        banks[i][j].tCCD_L_WR++;
                        banks[i][j].tCCD_S_WR++;
                        banks[i][j].tCCD_L_WTR++;
                        banks[i][j].tCCD_S_WTR++;
                    end
                WR1:
                    begin
                        banks[i][j].tRAS++;
                        banks[i][j].tRC++;
                        banks[i][j].tRRD_L++;
                        banks[i][j].tRRD_S++;

                        banks[i][j].tCWD++;
                        banks[i][j].tCCD_L_WR++;
                        banks[i][j].tCCD_S_WR++;
                        banks[i][j].tCCD_L_WTR++;
                        banks[i][j].tCCD_S_WTR++;
                        
                        if(banks[i][j].tCWD > `tCWD)
                            banks[i][j].tBURST++;

                        if(banks[i][j].tBURST > `tBURST)
                            banks[i][j].tWR++;
          

                    end

                PRE:
                    begin
                        if(GetRequestOperation(i,j) == DATA_WRITE)
                        begin

                            if(banks[i][j].tWR == `tWR)
                            begin
                                ChangeRequestState(i, j, PROCESSED);
                            end

                            banks[i][j].tCWD++;

                            if(banks[i][j].tBURST >= `tBURST)
                                banks[i][j].tWR++;

                            if(banks[i][j].tCWD >= `tCWD)
                                banks[i][j].tBURST++;
                        end
                        else if(GetRequestOperation(i,j) == DATA_READ || GetRequestOperation(i,j) == INSTRUCTION_FETCH)
                        begin
                            if(banks[i][j].tCL >= `tCL)
                                banks[i][j].tBURST++;
                            
                            banks[i][j].tCL++;

                            if(banks[i][j].tBURST == `tBURST)
                            begin
                                ChangeRequestState(i, j, PROCESSED);
                            end
                        end
                        banks[i][j].tRC++;
                        banks[i][j].tRP++;


                        if(banks[i][j].tRRD_L)
                            banks[i][j].tRRD_L++;
                        if(banks[i][j].tRRD_S)
                            banks[i][j].tRRD_S++;

                        if(banks[i][j].tCCD_L)
                            banks[i][j].tCCD_L++;
                        if(banks[i][j].tCCD_S)
                            banks[i][j].tCCD_S++;

                        if(banks[i][j].tCCD_L_WR)
                            banks[i][j].tCCD_L_WR++;
                        if(banks[i][j].tCCD_S_WR)
                            banks[i][j].tCCD_S_WR++;

                        if(banks[i][j].tCCD_L_RTW)
                            banks[i][j].tCCD_L_RTW++;
                        if(banks[i][j].tCCD_S_RTW)
                            banks[i][j].tCCD_S_RTW++;

                        if(banks[i][j].tCCD_L_WTR)
                            banks[i][j].tCCD_L_WTR++;
                        if(banks[i][j].tCCD_S_WTR)
                            banks[i][j].tCCD_S_WTR++;
                    end

                PROCESSED:
                    begin

                        banks[i][j].tRP++;
                        banks[i][j].tRC++;

                        if(banks[i][j].tRRD_L)
                            banks[i][j].tRRD_L++;
                        if(banks[i][j].tRRD_S)
                            banks[i][j].tRRD_S++;

                        if(banks[i][j].tCCD_L)
                            banks[i][j].tCCD_L++;
                        if(banks[i][j].tCCD_S)
                            banks[i][j].tCCD_S++;

                        if(banks[i][j].tCCD_L_WR)
                            banks[i][j].tCCD_L_WR++;
                        if(banks[i][j].tCCD_S_WR)
                            banks[i][j].tCCD_S_WR++;

                        if(banks[i][j].tCCD_L_RTW)
                            banks[i][j].tCCD_L_RTW++;
                        if(banks[i][j].tCCD_S_RTW)
                            banks[i][j].tCCD_S_RTW++;

                        if(banks[i][j].tCCD_L_WTR)
                            banks[i][j].tCCD_L_WTR++;
                        if(banks[i][j].tCCD_S_WTR)
                            banks[i][j].tCCD_S_WTR++;

                        if(banks[i][j].tRP == `tRP)
                        begin

                            banks[i][j].bankState = CLOSED;

                            banks[i][j].tRP = 0;
                        end
                    end
            endcase
        end
    end
end
endfunction


function void ResetBankTimers(logic [0:3] bankGroup, State state);

    for(int i = 0; i <= `MAX_BANK_NUMBER; i++)
    begin
        case (state)

            ACT0:
                begin
                    banks[bankGroup][i].tRRD_L = 0;
                end

            RD0:
                begin
                    banks[bankGroup][i].tCCD_L = 0;
                    banks[bankGroup][i].tCCD_L_RTW = 0;
                end

            WR0:
                begin
                    banks[bankGroup][i].tCCD_L_WR = 0;
                    banks[bankGroup][i].tCCD_L_WTR = 0;
                end
        endcase
    end


    foreach(banks[i,j])
    begin
        case (state)
            ACT0:
                begin
                    banks[i][j].tRRD_S = 0;
                end
            RD0:
                begin
                    banks[i][j].tCCD_S = 0;
                    banks[i][j].tCCD_S_RTW = 0;
                end
            WR0:
                begin
                    banks[i][j].tCCD_S_WR = 0;
                    banks[i][j].tCCD_S_WTR = 0;
                end
        endcase
    end

endfunction


function integer GetRequestOperation (int bankGroup, int bank);
    static int op;

        op = -1;
        foreach(queue[i])
        begin
            if(queue[i].bankGroup == bankGroup && queue[i].bank == bank)
            begin
                if(queue[i].state != NOT_PROCESSED)
                begin
                    op =  queue[i].operation;
                end
            end
        end
return op;
endfunction


function void ChangeRequestState (int bankGroup, int bank, State state);

    if(!queue.size())
        return;

    foreach(queue[i])
    begin
        if(queue[i].bankGroup == bankGroup && queue[i].bank == bank)
        begin
            if(queue[i].state != NOT_PROCESSED)
            begin
                queue[i].state = PROCESSED;
                banks[bankGroup][bank].requestState = PROCESSED;
            end
        end
    end

endfunction


function void CheckCompletedRequest();
begin
    /*
        If the current request has completed the process, remove from the queue.
    */
    Request poppedRequest;
    if(!queue.size())
    return;
    
    if(queue[0].state == PROCESSED)
    begin
        poppedRequest = queue.pop_front();
    end

end
endfunction


function Request AddressMap(Request request);
begin
    request.row = request.address[33:18];
    request.column = {request.address[17:12], request.address[5:2]};
    request.bank = request.address[11:10];
    request.bankGroup = request.address[9:7];
    request.channel = 0;

    return request;
end
endfunction


function bit IssueCommand (Request request, integer OutputFileDptr);
begin
    string outputTrace, command;
    string clockCount, channel, state, col, row, bank, bankGroup;

    $sformat(clockCount, "%0d", clockTicksCount);
    $sformat(channel, "%0d", request.channel);

    case(request.state)
        PRE: state = "PRE\t";
        ACT0: state = "ACT0";
        ACT1: state = "ACT1";
        RD0: state = "RD0\t";
        RD1: state = "RD1\t";
        WR0: state = "WR0\t";
        WR1: state = "WR1\t";
    endcase
    
    $sformat(bankGroup, "%0d", request.bankGroup);
    $sformat(bank, "%0d", request.bank);
    $sformat(row, "%0H", request.row);
    $sformat(col, "%0H", request.column);

    command = {state, "\t", bankGroup, "\t", bank, "\t"};

    case(request.state)
        ACT0, ACT1: command = {command, row.toupper()};
        RD0, RD1, WR0, WR1: command = {command, col.toupper()};
    endcase
    outputTrace = {clockCount, "\t\t", channel, "\t", command};

    $fdisplay(OutputFileDptr, outputTrace);

    return `true;
end 
endfunction


function void AddToQueue (Request request);
begin
    if(queue.size() != `MAX_QUEUE_SIZE)
    begin
        queue.push_back(request);
`ifdef DEBUG
        $display("%d\t%d\t%d\t\t%d\t\t%d\t\t%h\t\t%h \t\t\t Size: %d",clockTicksCount, request.core, request.operation, request.bank, request.bankGroup, request.row, request.column, queue.size());
`endif
    end
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

function void InitBanks();
begin

    foreach(banks[i,j])
    begin
        banks[i][j] = new(CLOSED, `NO_CURRENT_ACTIVE_ROW);
    end

end
endfunction




endmodule