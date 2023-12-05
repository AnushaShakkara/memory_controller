`timescale 1ps/1ps
`define MAX_QUEUE_SIZE 16
`define CPU_CLOCK_DELAY 104
`define DIMM_CLOCK_DELAY 208

typedef enum integer
{
    DATA_READ,
    DATA_WRITE,
    INSTRUCTION_FETCH
}Operation;

typedef enum int
{
    NOT_PROCESSED,
    ACT0,
    ACT1,
    RD0,
    RD1,
    WR0,
    WR1,
    PRE,
    REF,
    PROCESSED
}State;

class Trace;

    integer time_t;
    integer core;
    integer operation;
    longint unsigned address;
    longint unsigned queueTime;

    logic [15:0] row;
    logic [9:0] column;
    logic [1:0] bank;
    logic [3:0] bankGroup;
    logic channel;


    int timer;
    State state;

    function new (integer time_t, integer core, integer operation, longint unsigned address);
        
        this.time_t = time_t;
        this.core = core;
        this.operation = operation;
        this.address = address;
        this.state = NOT_PROCESSED;
        this.timer = 0;

        this.row = 0;
        this.column = 0;
        this.bank = 0;
        this.bankGroup = 0;
        this.channel = 0; 

    endfunction

    function void display();

        $display ("%d %d %d\t %0h",this.time_t, this.core, this.operation, this.address);
    
    endfunction

endclass;



