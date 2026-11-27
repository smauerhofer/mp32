; memmap.inc - the memory of the mp32 FORTH machine (see memory.md)
;
;   .include "memmap.inc"

; ---------------------------------------------------------------- page zero
USER        = $0000             ; the user area, 256 cells
UP_BASE     = $0080             ; r31 = UP: LDR3 / STR3 with -128 .. 127 reach USER .. $00FF
INQ         = $0400             ; the input queue (serial port and keyboard), 1024 bytes
INQ_SIZE    = 1024
OUTQ        = $0800             ; the serial port's output queue, 1024 bytes
OUTQ_SIZE   = 1024
TIB         = $0C00             ; the terminal input buffer
TIB_SIZE    = 1024
WORDBUF     = $1000             ; the buffer of WORD, 256 bytes
HOLD_END    = $1200             ; pictured numeric output: HLD grows down from here
PAD         = $1200             ; PAD, 512 bytes
PAD_SIZE    = 512
DRIVERS     = $1400             ; the drivers' state, up to $1FFF
FREE0       = $2000             ; free, up to $7FFF

; ---------------------------------------------------------------- the stacks
RSTACK      = $8000             ; the return stack: $8000 .. $BFFF
RSP0        = $BFFC             ; RSP when it is empty
RSP_HEADROOM = 64 * 4           ; words below RSPL for INTR / EXC
RSPH_INIT   = RSP0 | 1
RSPL_INIT   = (RSTACK + RSP_HEADROOM - 4) | 1

PSTACK      = $C000             ; the parameter stack: $C000 .. $FFFF
PSP0        = $FFFC             ; PSP when it is empty
PSPH_INIT   = PSP0 | 1
PSPL_INIT   = (PSTACK - 4) | 1

; ---------------------------------------------------------------- the image
LOAD        = $10000            ; the vector table (VEC), then the kernel
DICT_END    = $200000           ; the dictionary grows from the kernel's end up to here
HEAP0       = $200000           ; the free memory: ALLOCATE and the CONS heap
HEAP_END    = $780000

; ---------------------------------------------------------------- the screen
TEXT        = $780000           ; 60 rows of 80 cells
TEXT_END    = TEXT + 60 * 80 * 4
PIXELS      = $790000           ; 480 lines of 640 bytes

; ---------------------------------------------------------------- the user area
; the hot cells, as UP offsets (LDR3 T, r31, U_BASE) and as addresses
U_STATE     = $00 - UP_BASE
U_BASE      = $04 - UP_BASE
U_DP        = $08 - UP_BASE     ; HERE
U_LATEST    = $0C - UP_BASE
U_IN        = $10 - UP_BASE     ; >IN
U_NTIB      = $14 - UP_BASE     ; #TIB
U_SOURCEID  = $18 - UP_BASE
U_SOURCE    = $1C - UP_BASE     ; 'SOURCE: the address of the input
U_NSOURCE   = $20 - UP_BASE     ; #SOURCE: its length
U_HLD       = $24 - UP_BASE
U_HANDLER   = $28 - UP_BASE     ; CATCH / THROW
U_CURRENT   = $2C - UP_BASE
U_CONTEXT   = $30 - UP_BASE
U_INHEAD    = $34 - UP_BASE     ; the input queue: the handlers write here
U_INTAIL    = $38 - UP_BASE     ; KEY reads here
U_OUTHEAD   = $3C - UP_BASE     ; the output queue: EMIT writes here
U_OUTTAIL   = $40 - UP_BASE     ; the handler reads here
U_COL       = $44 - UP_BASE     ; the cursor
U_ROW       = $48 - UP_BASE
U_COLOURS   = $4C - UP_BASE     ; font, paper, ink (the text cell's bytes 1..3)
U_FRAMES    = $50 - UP_BASE
U_DICTEND   = $54 - UP_BASE
U_HEAP      = $58 - UP_BASE
U_BOOTED    = $5C - UP_BASE     ; r1 of the loader: 1 flash, 2 card, 3 serial port
