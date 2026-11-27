; memmap.inc - the memory of the mp32 FORTH machine (see memory.md, tasks.md)
;
;   .include "memmap.inc"
;
; Two registers are reserved for the whole system:
;   r30 = GP = GLOBALS + $80   the system's variables: LDR3 / STR3 T, r30, G_...
;   r31 = UP = the task + $80  the running task's user area: LDR3 / STR3 T, r31, U_...
; With the $80 bias the 8-bit offset (-128 .. 127) reaches the first 256 bytes.

; ---------------------------------------------------------------- the image
LOAD        = $0                ; the vector table (VEC = 0), then the kernel
DICT_END    = $200000           ; the dictionary grows from the kernel's end up to here
HEAP0       = $200000           ; the free memory: ALLOCATE and the CONS heap
HEAP_END    = $770000

; ---------------------------------------------------------------- the system area
; 64 KB at a fixed address right below the screen, not in the image: COLD clears and
; fills it. Its layout is the same at any address: only SYSTEM would change.
SYSTEM      = $770000
GLOBALS     = SYSTEM + $0000    ; the system's variables (all tasks), 1 KB
GP_BASE     = GLOBALS + $80     ; r30
INQ         = SYSTEM + $0400    ; the input queue (serial port and keyboard), 1024 bytes
INQ_SIZE    = 1024
OUTQ        = SYSTEM + $0800    ; the serial port's output queue, 1024 bytes
OUTQ_SIZE   = 1024
DRIVERS     = SYSTEM + $0C00    ; the drivers' state (keyboard, screen), 1 KB
OPERATOR    = SYSTEM + $1000    ; OPERATOR's task area (below), 4 KB
FREE0       = SYSTEM + $2000    ; free, 24 KB (block buffers, ...)

; ---------------------------------------------------------------- OPERATOR
; the terminal task that runs the interpreter after COLD; its stacks are the big ones
OP_UP       = OPERATOR + $80    ; r31 while OPERATOR runs
OP_TIB      = SYSTEM + $1200    ; 1 KB (a pasted line may be long)
OP_TIB_SIZE = 1024
OP_WORD     = SYSTEM + $1600    ; 256 bytes
OP_HOLD     = SYSTEM + $1800    ; HLD grows down from here (from SYSTEM + $1700)
OP_PAD      = SYSTEM + $1800    ; 512 bytes
OP_PAD_SIZE = 512

OP_RSTACK   = SYSTEM + $8000    ; the return stack: 16 KB, 4096 cells
OP_PSTACK   = SYSTEM + $C000    ; the parameter stack: 16 KB, 4096 cells
OP_R0       = SYSTEM + $BFFC    ; RSP when empty
OP_S0       = SYSTEM + $FFFC    ; PSP when empty

; ---------------------------------------------------------------- every task
USER_SIZE   = 512               ; the user area: 128 cells
RS_HEADROOM = 64 * 4            ; words below RSPL, for INTR / EXC (interrupts run on
                                ; the running task's return stack)
; a task area for TASK / TERMINAL (in the dictionary), the defaults
TERM_BUFS   = 1024              ; TERMINAL only: TIB 256, WORD 256, HOLD 256, PAD 256
TASK_RS     = 1024              ; return stack, 256 cells (64 of them headroom)
TASK_PS     = 1024              ; parameter stack, 256 cells

; ---------------------------------------------------------------- the screen
TEXT        = $780000           ; 60 rows of 80 cells
TEXT_END    = TEXT + 60 * 80 * 4
PIXELS      = $790000           ; 480 lines of 640 bytes

; ---------------------------------------------------------------- the globals (r30)
G_INHEAD    = $00 - $80         ; the input queue: the handlers write here
G_INTAIL    = $04 - $80         ; KEY reads here
G_OUTHEAD   = $08 - $80         ; the output queue: EMIT writes here
G_OUTTAIL   = $0C - $80         ; the handler reads here
G_INWAIT    = $10 - $80         ; the task (UP) asleep in KEY: woken by the input handlers
G_OUTWAIT   = $14 - $80         ; the task asleep in EMIT (queue full): woken by TX
G_COL       = $18 - $80         ; the cursor
G_ROW       = $1C - $80
G_COLOURS   = $20 - $80         ; font, paper, ink (the text cell's bytes 1..3)
G_FRAMES    = $24 - $80         ; counted by the frame interrupt (vector 17)
G_TICKS     = $28 - $80         ; ms, for MS (later)
G_HEAP      = $2C - $80         ; the start of the free memory
G_DICTEND   = $30 - $80
G_BOOTED    = $34 - $80         ; r1 of the loader: 1 flash, 2 card, 3 serial port
G_FORTHWL   = $38 - $80         ; the FORTH word list: its newest word
G_SCREEN    = $3C - $80         ; facility: the task that owns the screen, 0 = free
G_SERIAL    = $40 - $80         ; facility: the serial port's output
G_KEYS      = $44 - $80         ; facility: the input

; ---------------------------------------------------------------- the user area (r31)
; the scheduler's cells first: PAUSE uses them
U_STATUS    = $00 - $80         ; 0 asleep, 1 awake
U_LINK      = $04 - $80         ; the next task's UP (a ring)
U_SPSAVE    = $08 - $80         ; PSP while not running (T, S pushed below it)
U_RPSAVE    = $0C - $80         ; RSP while not running (R pushed below it)
U_FPSAVE    = $10 - $80         ; FP
U_PSPL      = $14 - $80         ; the task's stack limits, loaded by PAUSE
U_PSPH      = $18 - $80
U_RSPL      = $1C - $80
U_RSPH      = $20 - $80
U_S0        = $24 - $80         ; PSP when empty
U_R0        = $28 - $80         ; RSP when empty
; the interpreter's cells
U_BASE      = $2C - $80
U_STATE     = $30 - $80         ; 0 interpreting, -1 compiling
U_DP        = $34 - $80         ; HERE
U_IN        = $38 - $80         ; >IN
U_NTIB      = $3C - $80         ; #TIB
U_TIB       = $40 - $80         ; 'TIB: the address of the task's TIB
U_SOURCEID  = $44 - $80         ; 0 the user (TIB), -1 a string (EVALUATE)
U_SOURCE    = $48 - $80         ; 'SOURCE: the address of the input
U_NSOURCE   = $4C - $80         ; #SOURCE: its length
U_HLD       = $50 - $80
U_HOLD      = $54 - $80         ; 'HOLD: where HLD starts (<#)
U_WORD      = $58 - $80         ; 'WORD: the buffer of WORD
U_PAD       = $5C - $80         ; 'PAD
U_HANDLER   = $60 - $80         ; CATCH / THROW
U_CURRENT   = $64 - $80
U_NORDER    = $68 - $80         ; #ORDER
U_CONTEXT   = $6C - $80         ; the search order, 8 cells ($6C .. $8B)
U_KEY       = $8C - $80         ; 'KEY:  the task's KEY  (vectored, for more terminals later)
U_EMIT      = $90 - $80         ; 'EMIT: the task's EMIT
U_NAME      = $94 - $80         ; the task's name (its header), for .TASKS
U_FREE      = $98 - $80         ; from here: USER variables (USER allots them)
