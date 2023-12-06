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

  

    InitBanks();    //Initialize all the banks before processing any request
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
                
                if(DIMM_Clock)
                begin
                    ProcessRequest(OutputFileDptr);
                    CheckCompletedRequest();
                    UpdateTimers(); 
                end

                /* scan the request from the file only if there is atleast one position available in queue */
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

`ifdef LEVEL_0
/*
    Function for Closed Page Policy approach
*/
function void ProcessRequest(integer OutputFileDptr);
begin
    static bit isCommandIssued;
    if(!queue.size())   //if there are no request present in queue to process - return
        return;

    if(queue[0].state == PROCESSED)     // Process of request is completed, so return
        return;

    if(queue[0].state == NOT_PROCESSED)
    begin
        /*
            if request if not processed, before issuing ACT0, check if the request bank has pendting tRP 
        */
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
            banks[queue[0].bankGroup][queue[0].bank].requestState = queue[0].state;  //update the requeststate for the bank as well
            isCommandIssued = 0;
        end
    end


    /*State machine for request and issuing DIMM command*/
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
                
                if(queue[0].operation == DATA_WRITE)    /*For WR, we need to remove from the queue as soon as tWR is reached*/
                    queue[0].state = PROCESSED;
            end
    endcase
    

end
endfunction

`endif


function PageAction IsPageOpen(Request request);
begin
    /*
        If the request Bank is closed, return PAGE_EMPTY.
        If the request Bank is open and current active row matches with request row, return PAGE_HIT
        If the request Bank is open but current active row in a bank is not the request row, return PAGE_MISS
    */
    if(banks[request.bankGroup][request.bank].bankState == OPEN)
    begin
        if(banks[request.bankGroup][request.bank].currentActiveRow == request.row)
            return PAGE_HIT;
        else
        begin
            return PAGE_MISS;
        end
    end
    else
    begin
        return PAGE_EMPTY;
    end
end
endfunction


function bit IsTimerActiveInSameBankGroup(T_Constraints timer, logic [0:3] bankGroup);

/*
    Check if the requested timer is active is given Bank Group
*/
    static bit status;

    status = `false;


    for(int i = 0; i <= `MAX_BANK_GROUP; i++)
    begin
        case(timer)
            tRRD_L:
                begin
                    if(banks[bankGroup][i].tRRD_L > 0)
                        status = `true;
                end
            tCCD_L:
                begin
                    if(banks[bankGroup][i].tCCD_L > 0)
                        status = `true;
                end
            tCCD_L_WR:
                begin
                    if(banks[bankGroup][i].tCCD_L_WR > 0)
                        status = `true;
                end
            tCCD_L_RTW:
                begin
                    if(banks[bankGroup][i].tCCD_L_RTW > 0)
                        status = `true;
                end
            tCCD_L_WTR:
                begin
                    if(banks[bankGroup][i].tCCD_L_WTR > 0)
                        status = `true;
                end
        endcase
    end

    return status;
endfunction


function IsTimerActiveInDiffBankGroup (T_Constraints timer, logic [0:3] bankGroup);

/*
    Check if requested timer is active in all other banks except the given bank group
*/
    
    static bit status;

    status = `false;

    foreach(banks[i,j])
    begin
        if(i != bankGroup)
        begin
            case (timer)
            
                tRRD_S:
                    begin
                        if(banks[i][j].tRRD_S > 0)
                            status = `true;
                    end
                tCCD_S:
                    begin
                        if(banks[i][j].tCCD_S > 0)
                            status = `true;
                    end
                tCCD_S_WR:
                    begin
                        if(banks[i][j].tCCD_S_WR > 0)
                            status = `true;
                    end
                tCCD_S_RTW:
                    begin
                        if(banks[i][j].tCCD_S_RTW > 0)
                            status = `true;
                    end
                tCCD_S_WTR:
                    begin
                        if(banks[i][j].tCCD_S_WTR > 0)
                            status = `true;
                    end
            endcase
        end
    end

    return status;

endfunction


function bit TimerCheck(Request request, T_Constraints timer);

/*
    Check if the requested timer is active and if active, then check if the timer is satisfied for request Bank
*/

    static bit status;

    status = `false;


    case (timer)
        tRRD_L:         /* tRRD_L: ACT -> ACT timer for same BG and any bank (in BG) */
            begin
                if(!IsTimerActiveInSameBankGroup(tRRD_L, request.bankGroup))
                    return `true;

                for(int i = 0; i <= `MAX_BANK_NUMBER; i++)
                begin
                    if(banks[request.bankGroup][i].bankState == OPEN)
                    begin
                        if(banks[request.bankGroup][i].tRRD_L >= `tRRD_L)
                        begin
                            banks[request.bankGroup][i].tRRD_L = 0;
                            status = `true;
                        end
                    end
                end
            end
        tRRD_S:  /* tRRD_S: ACT -> ACT timer for diff BG and any bank (other BG)*/
            begin
                if(!IsTimerActiveInDiffBankGroup(tRRD_S, request.bankGroup))
                    return `true;

                foreach(banks[i,j])
                begin
                    if(i != request.bankGroup)
                    begin
                        if(banks[i][j].tRRD_S >= `tRRD_S)
                        begin
                            banks[i][j].tRRD_S = 0;
                            status = `true;
                        end
                    end
                end
                
            end
        tCCD_L: /* tCCD_L: RD0 -> RD0 timer for same BG and any bank (in BG) */
            begin
                if(!IsTimerActiveInSameBankGroup(tCCD_L, request.bankGroup))
                    return `true;

                for(int i = 0; i <= `MAX_BANK_NUMBER; i++)
                begin
                    if(banks[request.bankGroup][i].bankState == OPEN)
                    begin
                        if(banks[request.bankGroup][i].tCCD_L >= `tCCD_L)
                        begin
                            banks[request.bankGroup][i].tCCD_L = 0;
                            status = `true;
                        end
                    end
                end
            end
        tCCD_S: /* tCCD_S: RD0 -> RD0 timer for diff BG and any bank (other BG)*/
            begin
                if(!IsTimerActiveInDiffBankGroup(tCCD_S, request.bankGroup))
                    return `true;

                foreach(banks[i,j])
                begin
                    if(i != request.bankGroup)
                    begin
                        if(banks[i][j].tCCD_S >= `tCCD_S)
                        begin
                            banks[i][j].tCCD_S = 0;
                            status = `true;
                        end
                    end
                end    
            end
        tCCD_L_WR: /* tCCD_L_WR: WR0 -> WR0 timer for same BG and any bank (in BG) */
            begin
                if(!IsTimerActiveInSameBankGroup(tCCD_L_WR, request.bankGroup))
                    return `true;

                for(int i = 0; i <= `MAX_BANK_NUMBER; i++)
                begin
                    if(banks[request.bankGroup][i].bankState == OPEN)
                    begin
                        if(banks[request.bankGroup][i].tCCD_L_WR >= `tCCD_L_WR)
                        begin
                            banks[request.bankGroup][i].tCCD_L_WR = 0;
                            status = `true;
                        end
                    end
                end
            end
        tCCD_S_WR: /* tCCD_S_WR: WR0 -> WR0 timer for diff BG and any bank (other BG)*/
            begin
                if(!IsTimerActiveInDiffBankGroup(tCCD_S_WR, request.bankGroup))
                    return `true;

                foreach(banks[i,j])
                begin
                    if(i != request.bankGroup)
                    begin
                        if(banks[i][j].tCCD_S_WR >= `tCCD_S_WR)
                        begin
                            banks[i][j].tCCD_S_WR = 0;
                            status = `true;
                        end
                    end
                end
            end
        tCCD_L_RTW: /* tCCD_L_RTW: RD0 -> WR0 timer for same BG and any bank (in BG) (other BG)*/
            begin
                if(!IsTimerActiveInSameBankGroup(tCCD_L_RTW, request.bankGroup))
                    return `true;
        
                for(int i = 0; i <= `MAX_BANK_NUMBER; i++)
                begin
                    if(banks[request.bankGroup][i].bankState == OPEN)
                    begin
                        if(banks[request.bankGroup][i].tCCD_L_RTW >= `tCCD_L_RTW)
                        begin
                            banks[request.bankGroup][i].tCCD_L_RTW = 0;
                            status = `true;
                        end
                    end
                end
            end
        tCCD_S_RTW: /* tCCD_S_RTW: RD0 -> WR0 timer for diff BG and any bank (other BG) */
            begin
                if(!IsTimerActiveInDiffBankGroup(tCCD_S_RTW, request.bankGroup))
                    return `true;
               
                foreach(banks[i,j])
                begin
                    if(i != request.bankGroup)
                    begin
                        if(banks[i][j].tCCD_S_RTW >= `tCCD_S_RTW)
                        begin
                            banks[i][j].tCCD_S_RTW = 0;
                            status = `true;
                        end
                    end
                end
            end
        tCCD_L_WTR: /* tCCD_L_WTR: WR0 -> RD0 timer for same BG and any bank (in BG) (other BG)*/
            begin
                if(!IsTimerActiveInSameBankGroup(tCCD_L_WTR, request.bankGroup))
                    return `true;

                for(int i = 0; i <= `MAX_BANK_NUMBER; i++)
                begin
                    if(banks[request.bankGroup][i].bankState == OPEN)
                    begin
                        if(banks[request.bankGroup][i].tCCD_L_WTR >= `tCCD_L_WTR)
                        begin
                            banks[request.bankGroup][i].tCCD_L_WTR = 0;
                            status = `true;
                        end
                    end
                end
            end
        tCCD_S_WTR: /* tCCD_S_WTR: WR0 -> RD0 timer for diff BG and any bank (other BG) */
            begin
                if(!IsTimerActiveInDiffBankGroup(tCCD_S_WTR, request.bankGroup))
                    return `true;

                foreach(banks[i,j])
                begin
                    if(i != request.bankGroup)
                    begin
                        if(banks[i][j].tCCD_S_WTR >= `tCCD_S_WTR)
                        begin
                            banks[i][j].tCCD_S_WTR = 0;
                            status = `true;
                        end
                    end
                end
            end
    endcase

    return status;
endfunction


function bit CheckTimingConstraints (Request request, PageAction action);

/*
    Check if the all the timing contraints are satisfied for issuing the requried command
*/
    if(AllBanksClosed())
    begin
        return `true;
    end

    case(action)
        PAGE_HIT:
            begin
                if(request.operation == DATA_WRITE)
                begin
                    if(TimerCheck(request, tCCD_S_WR) && TimerCheck(request, tCCD_L_WR)  && TimerCheck(request, tCCD_L_RTW) && TimerCheck(request, tCCD_S_RTW))
                        return `true;
                    else
                        return `false;
                end
                else
                begin
                    if(TimerCheck(request, tCCD_S) && TimerCheck(request, tCCD_L) && TimerCheck(request, tCCD_L_WTR) && TimerCheck(request, tCCD_S_WTR))
                        return `true;
                    else
                        return `false;
                end

            end
        PAGE_MISS:
            begin
                // (tRTP / tWR / tRAS)
                if((banks[request.bankGroup][request.bank].tRTP == 0) || (banks[request.bankGroup][request.bank].tRTP >= `tRTP))
                    if(((banks[request.bankGroup][request.bank].tWR == 0) || (banks[request.bankGroup][request.bank].tWR >= `tWR)))
                        if((banks[request.bankGroup][request.bank].tRAS == 0) || (banks[request.bankGroup][request.bank].tRAS >= `tRTP))
                            return `true;
                        else
                            return `false;
                    else
                        return `false;
                else
                    return `false;
            end
        PAGE_EMPTY:
            begin
                // tRRD_S / tRRD_L
                if(TimerCheck(request, tRRD_S) && TimerCheck(request, tRRD_L) )
                    return `true;
                else
                    return `false;
            end
    endcase


endfunction


`ifdef LEVEL_1

/*
    Function for Open Page Policy approach
*/

function void ProcessRequest(integer OutputFileDptr);
begin
    static bit isCommandIssued;
    if(!queue.size())           //if there are no request present in queue to process - return
        return;

    if(queue[0].state == PROCESSED)         // Process of request is completed, so return
        return;
    
    if(queue[0].state == NOT_PROCESSED)
    begin
        case(IsPageOpen(queue[0]))              //check if the page is open in the request bank
            
            PAGE_HIT:
                begin
                    if(CheckTimingConstraints(queue[0], IsPageOpen(queue[0])))
                    begin
                        ResetBankTimings(queue[0].bankGroup , queue[0].bank);

                        if(queue[0].operation == DATA_WRITE)
                            queue[0].state = WR0;
                        else
                            queue[0].state = RD0;

                        banks[queue[0].bankGroup][queue[0].bank].requestState = queue[0].state;
                        isCommandIssued = 0; 
                    end
                    else
                        return;
                end
            PAGE_MISS:
                begin
                    if(CheckTimingConstraints(queue[0], IsPageOpen(queue[0])))
                    begin
                        ResetBankTimings(queue[0].bankGroup , queue[0].bank);
                        queue[0].state = PRE;
                        banks[queue[0].bankGroup][queue[0].bank].currentActiveRow = queue[0].row;
                        banks[queue[0].bankGroup][queue[0].bank].requestState = queue[0].state;
                        isCommandIssued = 0;
                    end
                end
            PAGE_EMPTY:
                begin
                    if(CheckTimingConstraints(queue[0], IsPageOpen(queue[0])))
                    begin
                        /* Once the timing constraints are satisfied set the bank state to open and store the current active row */
                        ResetBankTimings(queue[0].bankGroup , queue[0].bank);
                        banks[queue[0].bankGroup][queue[0].bank].bankState = OPEN;
                        banks[queue[0].bankGroup][queue[0].bank].currentActiveRow = queue[0].row;
                        queue[0].state = ACT0;
                        banks[queue[0].bankGroup][queue[0].bank].requestState = queue[0].state;
                        isCommandIssued = 0;
                    end
                end
        endcase

    end
    else
    begin
        if(queue[0].state != queue[0].nextState)
        begin
            queue[0].state = queue[0].nextState;
            banks[queue[0].bankGroup][queue[0].bank].requestState = queue[0].state;     //update the requeststate for the bank as well
            isCommandIssued = 0;
        end
    end


    case(queue[0].state)

        PRE:
            begin
                if(!isCommandIssued)
                    isCommandIssued = IssueCommand(queue[0], OutputFileDptr);

                if(banks[queue[0].bankGroup][queue[0].bank].tRP == `tRP - 1)
                    queue[0].nextState = ACT0;
                else
                    queue[0].nextState = PRE;
            end

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
            end
    endcase


end
endfunction

`endif

function void ResetBankTimings (logic [3:0] bankGroup, logic [1:0] bank);
/*
    Reset the necessary bank timers
*/
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
`ifdef LEVEL_1          
                        /*Once tBurst is satisfied, set the request state to PROCESSED so it can be popped*/              
                        if(banks[i][j].tBURST == `tBURST)
                            ChangeRequestState(i, j, PROCESSED);
`endif

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
`ifdef LEVEL_1
                        /*Once tBurst is satisfied, set the request state to PROCESSED so it can be popped*/
                        if(banks[i][j].tBURST == `tBURST)
                            ChangeRequestState(i, j, PROCESSED);
`endif            

                    end

                PRE:
                    begin
`ifdef LEVEL_0
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
`endif
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

                        /*

                            if the Bank requestState is processed (i.e the request this bank was processing 
                            has probably popped from the queue). But we still need to keep incrementing the 
                            timers which that request has started.
                            Note: Only increment the timers which were started by the request.

                        */
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
`ifdef LEVEL_0
                            banks[i][j].bankState = CLOSED;
`endif
                            banks[i][j].tRP = 0;
                        end
                    end
            endcase
        end
    end
end
endfunction

function void ResetBankTimers(logic [0:3] bankGroup, State state);

/* Reset the necessary timers (decieded based on requestState) for all the banks in a BG */
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


/* Reset the necessary timers (decieded based on requestState) for all the banks in all BGs */
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

function bit AllBanksClosed();
begin
    /* returns true if all the banks are closed*/

    static bit status;

    status = `true;
    
    foreach(banks[i,j])
    begin
        if(banks[i][j].bankState == OPEN)
            status = `false;
    end
    return status;
end
endfunction


function integer GetRequestOperation (int bankGroup, int bank);
    
    /*Get the operation of the request currently being processed by the given bank n BG*/

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

/*Change the request state (request that is currently being processed by the given Bank n BG) to the given state*/

    if(!queue.size())
        return;

    foreach(queue[i])
    begin
        if(queue[i].bankGroup == bankGroup && queue[i].bank == bank)
        begin
            if(queue[i].state != NOT_PROCESSED)
            begin
                queue[i].state = state;
                banks[bankGroup][bank].requestState = state;
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
`ifdef DEBUG
        //$display("popped:time_t: %0d state: %0d,   BG:%0d    Bank:%0d   Simtime: %0d", 
          //              poppedRequest.time_t, poppedRequest.state, poppedRequest.bankGroup, poppedRequest.bank, clockTicksCount);
`endif
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

/* Ensure that BankState for all the bank is closed and it does not have any active row */

    foreach(banks[i,j])
    begin
        banks[i][j] = new(CLOSED, `NO_CURRENT_ACTIVE_ROW);
    end

end
endfunction




endmodule