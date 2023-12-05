`timescale 1ps/1ps

`define MAX_QUEUE_SIZE              16
`define MAX_BANK_GROUP              7
`define MAX_BANK_NUMBER             3
`define NO_CURRENT_ACTIVE_ROW      -1


`define true                        1
`define false                       0


`define CPU_CLOCK_DELAY             104
`define DIMM_CLOCK_DELAY            208


/* Timing Contraints */
`define tRC                         115
`define tRAS                        76
`define tRRD_L                      12
`define tRRD_S                      8
`define tRP                         39
`define tRFC                        
`define tCWD                        38
`define tCL                         40
`define tRCD                        39                  
`define tWR                         30
`define tRTP                        18
`define tCCD_L                      12
`define tCCD_S                      8
`define tCCD_L_WR                   48
`define tCCD_S_WR                   8
`define tBURST                      8
`define tCCD_L_RTW                  16
`define tCCD_S_RTW                  16
`define tCCD_L_WTR                  70
`define tCCD_S_WTR                  52




typedef enum integer
{
    DATA_READ,
    DATA_WRITE,
    INSTRUCTION_FETCH
}Operation;

typedef enum int
{
    NOT_PROCESSED,          // 0
    ACT0,                   // 1
    ACT1,                   // 2
    RD0,                    // 3
    RD1,                    // 4
    WR0,                    // 5
    WR1,                    // 6
    PRE,                    // 7
    REF,                    // 8
    PROCESSED               // 9
}State;

typedef enum bit
{
    CLOSED,
    OPEN
}BankState;

typedef enum int
{
    PAGE_EMPTY,
    PAGE_MISS,
    PAGE_HIT
}PageAction;

typedef enum int
{
    tRRD_L,
    tRRD_S,
    tCCD_L,
    tCCD_S,
    tCCD_L_WR,
    tCCD_S_WR,
    tCCD_L_RTW,
    tCCD_S_RTW,
    tCCD_L_WTR,
    tCCD_S_WTR
}T_Constraints; 


class Request;

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
    State nextState;

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


class Bank;

    BankState bankState;
    State requestState;
    int currentActiveRow;
    bit isWriteDone;
    bit isReadDone;
    Request BankRequests [$ : `MAX_QUEUE_SIZE];

    /* Timers */

                int tRC;
                int tRAS;
                int tRRD_L;
                int tRRD_S;
                int tRP;
                int tRFC;
                int tCWD;
                int tCL;
                int tRCD;
                int tWR;
                int tRTP;
                int tCCD_L;
                int tCCD_S;
                int tCCD_L_WR;
                int tCCD_S_WR;
                int tBURST;
                int tCCD_L_RTW;
                int tCCD_S_RTW;
                int tCCD_L_WTR;
                int tCCD_S_WTR;



    function new (BankState bankstate = CLOSED, int currentActiveRow = `NO_CURRENT_ACTIVE_ROW);

        this.bankState = bankstate;
        this.currentActiveRow = currentActiveRow;
        this.isWriteDone = `false;
        this.isReadDone = `false;
        this.tRC = 0;
        this.tRAS = 0;
        this.tRRD_L = 0;
        this.tRRD_S = 0;
        this.tRP = 0;
        this.tRFC = 0;
        this.tCWD = 0; 
        this.tCL = 0;
        this.tRCD = 0;
        this.tWR = 0;
        this.tRTP = 0;
        this.tCCD_L = 0;
        this.tCCD_S = 0;
        this.tBURST = 0;
        this.tCCD_L_RTW = 0;
        this.tCCD_S_RTW = 0;
        this.tCCD_L_WTR = 0;
        this.tCCD_S_WTR = 0;


    endfunction
            
endclass




