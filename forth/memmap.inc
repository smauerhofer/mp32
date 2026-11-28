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
LEAVES      = SYSTEM + $2000    ; the LEAVE stack of the compiler: 64 cells
SBUF        = SYSTEM + $2100    ; S" while interpreting: the string, 256 bytes
BUFS        = SYSTEM + $2200    ; the block buffers: NBUF of 4 KB
NBUF        = 4
BTAB        = SYSTEM + $6200    ; for each buffer: its block (-1: none), changed (8 bytes)
CRC_TAB     = SYSTEM + $6220    ; the CRC-32's table (256 words), made by COLD
FREE0       = SYSTEM + $6620    ; free, 6.5 KB

; the drivers' state (DRIVERS, G_DRV): only the keyboard's handler uses it
D_PREV      = 0                 ; the last report's six key codes (8 bytes)
D_CAPS      = 8                 ; Caps Lock: 0 off, 1 on
D_SAVE      = 16                ; r0 .. r7 while the handler runs (32 bytes)
D_NEW       = 48                ; the report just read (8 bytes)
SD_CSD      = DRIVERS + $40     ; the card's CSD (16 bytes, as it sends them)
SD_CID      = DRIVERS + $50     ; its CID (16 bytes)

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

; ---------------------------------------------------------------- the SD card
; (the fonts: the range FONTS, font n in the card's blocks 8 * first + 4n ..)
BLK_LBA     = 0                 ; FORTH's block u (4 KB): the card's blocks BLK_LBA + 8u ..
BLK_SIZE    = 4096              ; + 7, as many as the card holds (its CSD)
BLK_SHIFT   = 3                 ; the card's blocks (512 bytes) in one: 1 << BLK_SHIFT
; a source block: a header of 64 bytes, then 56 lines of 72 characters (4,032 bytes)
SRC_MAGIC   = $900DF00D         ; the header's first word (bytes 0D F0 0D 90): a source block
SRC_HEAD    = 64                ; the header's size
SRC_COLS    = 72
SRC_ROWS    = 56
SRC_TITLE   = 4                 ; the header: the title (32 characters, INDEX shows it)
SRC_TLEN    = 32
SRC_NEXT    = 36                ; the block LOAD goes on with (CHAIN), 0 none
SRC_SHADOW  = 40                ; the block that documents this one (SHADOW, DOC), 0 none
SRC_VERSION = 44                ; + 1 each time it is written (0: never, no CRC)
SRC_CRC     = 48                ; the CRC-32 of the text, as it was written
                                ; (52 .. 63: not defined yet)

; the volume block: FORTH's block 0 describes the card
VOL_MAGIC   = $900DCA4D         ; its first word
VOL_VERSION = 4                 ; the layout's version: 1
VOL_STARTUP = 8                 ; the block COLD loads (0 none; S2 held: none)
VOL_NAME    = 16                ; the card's name (32 characters)
VOL_RANGES  = 64                ; the ranges: 16 bytes each, up to a name that is 0:
VOL_ENTRY   = 16                ;   +0 the name (8 characters, capitals, spaces after),
                                ;   +8 the first block, +12 how many
FONT_BLOCK  = 256               ; the fonts without a volume (or a range FONTS)
SD_SLOW     = 52 << 8           ; the card's CTRL: DIV 52, 396 kHz (to start it)

; ---------------------------------------------------------------- the screen
TEXT        = $780000           ; 60 rows of 80 cells
TEXT_END    = TEXT + 60 * 80 * 4
PIXELS      = $790000           ; 480 lines of 640 bytes
FONTRAM     = $FFFF8000         ; font f at FONTRAM + 2048 * f; font 0 PETSCII
INK_GREEN   = 82                ; $5FFF00, the PET's green
PAPER_BLACK = 0

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
; constants COLD puts here, so the handlers reach them with one LDR3 (they may use
; neither T nor a LIT)
G_UART      = $48 - $80         ; $FFFF_0000 the serial port
G_IRQC      = $4C - $80         ; $FFFF_0400 the interrupt controller
G_VIDEO     = $50 - $80         ; $FFFF_A000 the video registers
G_KBD       = $54 - $80         ; $FFFF_0600 the keyboard and the mouse
G_INQB      = $58 - $80         ; INQ: the input queue's address
G_OUTQB     = $5C - $80         ; OUTQ
G_QMASK     = $60 - $80         ; 1023: a queue index, round
G_DRV       = $64 - $80         ; DRIVERS: the drivers' state
; the compiler (only OPERATOR compiles)
G_LAST      = $68 - $80         ; the xt of the newest header (IMMEDIATE, RECURSE, ;)
G_LSP       = $6C - $80         ; the LEAVE stack (LEAVES), at compile time
G_CALLAT    = $70 - $80         ; the last call compiled: its address ...
G_CALLEND   = $74 - $80         ; ... HERE right after it ...
G_CALLXT    = $78 - $80         ; ... and the word it calls (; makes it a jump)
G_LABEL     = $7C - $80         ; the last place a branch goes to (no tail call there)
; the terminal and the errors
G_CRLF      = $80 - $80         ; ACCEPT ended at a CR: an LF right after it is skipped
G_CURSOR    = $84 - $80         ; the cursor is shown (KEY waits)
G_ERRADDR   = $88 - $80         ; the word the error is about (its name) ...
G_ERRLEN    = $8C - $80         ; ... and its length
G_ABORTMSG  = $90 - $80         ; ABORT": the message (a counted string)
G_EXCPC     = $94 - $80         ; an exception: where it happened
G_LEDS      = $98 - $80         ; $FFFF_0200 the LEDs
G_KTAB      = $9C - $80         ; the keyboard's table (key codes to characters)
; the SD card and the blocks
G_SD        = $A0 - $80         ; $FFFF_0100 the card
G_SDHC      = $A4 - $80         ; the card: -1 not started, 0 byte addresses (SDSC), 1 blocks
G_BNEXT     = $A8 - $80         ; the buffer to be taken next (round)
G_BCUR      = $AC - $80         ; the buffer of the last BLOCK / BUFFER (UPDATE)
G_SCR       = $B0 - $80         ; SCR: the block LIST showed last
G_BLK       = $B4 - $80         ; BLK: the block LOAD interprets (0: none)
G_SDBLKS    = $B8 - $80         ; the card's capacity in blocks of 512 bytes (0: not known)

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

; ---------------------------------------------------------------- the header cell
; at xt - 4 (dictionary.md): LEN 31..27, INL 26..23, LINK 22..4, FLAGS 3..0
H_LEN_SHIFT = 27                ; the name's length, 0 .. 31
H_INL_SHIFT = 23                ; inline this many bytes (0: call)
H_INL_MASK  = $0F << 23
H_LINK_MASK = $7FFFF0           ; the next older word's xt
F_IMMEDIATE = 1
F_COMPILE   = 2                 ; compile only
F_HIDDEN    = 4                 ; being defined: not found
F_CREATED   = 8                 ; a body at xt + 16
BODY        = 16                ; >BODY: xt + BODY
NAME_MAX    = 31
