; forth.s: the FORTH kernel of the mp32 computer. The boot loader (../computer/boot.s)
; loads it from the flash, the microSD card or the serial port into the SDRAM at 0 and
; starts it; after COLD the mp32 is a FORTH machine.
;
;   make            build/forth.img (mp32as, mp32ld with forth.cfg, mp32img)
;   make test       boot it on the whole computer in simulation and talk to it
;
; The design is in memory.md (the memory), dictionary.md (headers, compiling) and
; tasks.md (PAUSE); the numbers are in memmap.inc.
;
; ---------------------------------------------------------------- what it is
;   - subroutine threaded with inlining: a colon definition is mp32 code; it calls
;     other words (JSRS / JSR / JSRL, the shortest that reaches) and has the short
;     ones (the primitives: INL > 0 in their header) copied in. ; makes a last call a
;     jump (a tail call).
;   - every word's code starts at a 16-byte line; the header (name, then one cell)
;     sits right in front of it (dictionary.md).
;   - T and S are the top two of the parameter stack, R the top of the return stack.
;     The hardware checks both stacks (PSPL .. RSPH): an underflow or overflow is
;     THROW -4 / -3 / -6 / -5.
;   - KEY takes from one input queue that the serial port (vector 19) and the
;     keyboard (vector 20) fill; EMIT writes to the screen and into the serial port's
;     output queue, which the serial port's TX interrupt empties. KEY with nothing to
;     read puts the task to sleep (PAUSE): with no task awake the processor WAITs.
;   - one task now, OPERATOR, in the ring of tasks that PAUSE goes round (tasks.md);
;     TASK, ACTIVATE and the rest come next.
;   - the screen goes on below what the boot loader wrote (the loader's row, r14),
;     and scrolls at the bottom.
;   - the SD card for FORTH: SD-READ, SD-WRITE (the card's 512-byte blocks), the
;     standard BLOCK words on blocks of 4 KB (BLOCK, BUFFER, UPDATE, FLUSH, LOAD,
;     THRU, LIST; 4 buffers); a source block (for LOAD, LIST) is a header of 64
;     bytes (the first word SRC_MAGIC, $900DF00D) and 56 lines of 72 characters,
;     made with NEW-SOURCE, its lines at LINE; what the card is (SD-INFO, SD-BLOCKS, BLOCKS, SD-CSD,
;     SD-CID) and FONT (a font from the card into the font RAM).
;   - QUIT asks for each line with "> " and ends it with " ok".
;
; ---------------------------------------------------------------- the registers
;   T, S, R     the stacks' tops
;   r0 .. r23   scratch: free in every word, and not kept across a call
;   r13         LDA's (below) own scratch
;   r24 .. r29  the interrupt handlers' own: no other code uses them
;   r30 = GP    the globals + $80 (G_...)        r31 = UP  the running task + $80 (U_...)
;
; ---------------------------------------------------------------- the vector table
;   0       reset: COLD (INTR 0 starts FORTH again)
;   1       an undefined opcode: THROW -256
;   4       CONS: the heap is full: THROW -257 (no garbage collector yet)
;   8 .. 11 a stack's limit: THROW -3 (PSP overflow), -4, -5 (RSP), -6
;   17      the display's frame: counts FRAMES
;   19      the serial port: received bytes into the input queue; the output queue
;           to the transmitter
;   20      the keyboard: key codes to characters (US layout), into the input queue
;   others  THROW -258 (unexpected interrupt or exception)

        .include "memmap.inc"

; ---------------------------------------------------------------- macros
; A word's header: the padding, the name, the header cell, then the code at xt (a
; 16-byte boundary). prev is the word before it, len the name's length: both are
; filled in and checked by tools/heads.py (make runs it).
.macro HEAD hxt, hprev, hname, hlen, hflags, hinl
        .align  16
        .res    (12 - hlen) & 15
        .ascii  hname
        .word   hprev + (hlen << H_LEN_SHIFT) + (hinl << H_INL_SHIFT) + hflags
hxt:
.endmacro

; a user variable: ( -- addr ), inlined
.macro USERV hxt, hprev, hname, hlen, hoff
        HEAD    hxt, hprev, hname, hlen, 0, 7
        DUP
        MOV2    T, r31
        ADDI2   T, hoff
        RET
.endmacro

; a global variable: ( -- addr ), inlined
.macro GLOBV hxt, hprev, hname, hlen, hoff
        HEAD    hxt, hprev, hname, hlen, 0, 7
        DUP
        MOV2    T, r30
        ADDI2   T, hoff
        RET
.endmacro

; push a constant: ( -- v )
.macro PUSHL pv
        DUP
        LIT     pv
.endmacro

; a constant (an address) into a register, T kept (r13 is the scratch)
.macro LDA lreg, lv
        MOV2    r13, T
        LIT     lv
        MOVR    lreg, T
        MOV2    T, r13
.endmacro

; print the string that follows (in the code, ending with a 0)
.macro ZDOTQ zs
        CALL    zdotq
        .asciiz zs
.endmacro

F_IC        = F_IMMEDIATE + F_COMPILE
KBD_KEYS    = $39               ; the keyboard's table: key codes 0 .. $38

        .import __BSS_END__

        .code
; ================================================================ the vector table
reset:  B       A, cold                 ; 0  reset
        .align  4
        B       A, exc_undef            ; 1  an undefined opcode
        .align  4
        .rept   2
        B       A, exc_other            ; 2, 3
        .align  4
        .endr
        B       A, exc_heap             ; 4  CONS: the heap is full
        .align  4
        .rept   3
        B       A, exc_other            ; 5 .. 7
        .align  4
        .endr
        B       A, exc_povf             ; 8  PSP overflow
        .align  4
        B       A, exc_punf             ; 9  PSP underflow
        .align  4
        B       A, exc_rovf             ; 10 RSP overflow
        .align  4
        B       A, exc_runf             ; 11 RSP underflow
        .align  4
        .rept   4
        B       A, exc_other            ; 12 .. 15
        .align  4
        .endr
        B       A, irq_other            ; 16 the display's line interrupt (off)
        .align  4
        B       A, irq_frame            ; 17 the display's frame interrupt
        .align  4
        B       A, irq_other            ; 18 the sound (off)
        .align  4
        B       A, irq_serial           ; 19 the serial port
        .align  4
        B       A, irq_kbd              ; 20 the keyboard and the mouse
        .align  4
        .rept   3
        B       A, irq_other            ; 21 .. 23 the buttons, the timers (off)
        .align  4
        .endr
        .rept   232
        B       A, exc_other            ; 24 .. 255
        .align  4
        .endr

; ================================================================ the interrupts
; Each handler keeps the flags with PUSHF / POPF, uses r24 .. r29 and GP only (no T,
; no S: they are the program's), and ends with EOI and RTI.

; ---------------------------------------------------------------- 17: the frame
irq_frame:
        PUSHF
        LDR3    r24, r30, G_FRAMES
        INCR    r24
        STR3    r24, r30, G_FRAMES
        LDR3    r24, r30, G_VIDEO
        MOVI2   r25, 2
        STR3    r25, r24, $30           ; IRQ_STATUS: FRAME cleared
        LDR3    r24, r30, G_IRQC
        STR3    r24, r24, 12            ; EOI
        POPF
        RTI

; ---------------------------------------------------------------- 19: the serial port
; RX: every byte that came, into the input queue. TX (while TXIE is on): bytes from
; the output queue into the transmitter until it is full; with the queue empty, TXIE
; off. The tasks waiting in KEY / EMIT are woken.
irq_serial:
        PUSHF
        LDR3    r24, r30, G_UART
@rx:    LDR     r25, r24                ; DATA: bit 8 = a byte came
        MOVI2   r27, 8
        LSR3    r26, r25, r27
        B       EQ, @tx
        MOV2    r29, r25
        CALL    inq_put
        B       A, @rx
@tx:    LDR3    r25, r24, 12            ; CTRL: TXIE on?
        MOVI2   r26, 2
        AND2    r26, r25
        B       EQ, @done
@txl:   LDR3    r25, r24, 4             ; STATUS: TXF, the transmitter full?
        MOVI2   r26, 2
        AND2    r26, r25
        B       NE, @done
        LDR3    r26, r30, G_OUTTAIL
        LDR3    r27, r30, G_OUTHEAD
        CMP2    r26, r27
        B       EQ, @empty
        LDR3    r27, r30, G_OUTQB
        ADD2    r27, r26
        LDRB    r28, r27
        STR     r28, r24                ; DATA: send it
        INCR    r26
        LDR3    r27, r30, G_QMASK
        AND2    r26, r27
        STR3    r26, r30, G_OUTTAIL
        LDR3    r28, r30, G_OUTWAIT     ; a task waits for room?
        CMPI2   r28, 0
        B       EQ, @txl
        MOVI2   r29, 1
        STR3    r29, r28, U_STATUS      ; awake
        MOVI2   r29, 0
        STR3    r29, r30, G_OUTWAIT
        B       A, @txl
@empty: MOVI2   r25, 1                  ; CTRL = RXIE: no more TX interrupts
        STR3    r25, r24, 12
@done:  LDR3    r24, r30, G_IRQC
        STR3    r24, r24, 12            ; EOI
        POPF
        RTI

; inq_put: the byte in r29 into the input queue (lost if it is full), and the task
; waiting in KEY woken. Uses r26 .. r29.
inq_put:
        LDR3    r26, r30, G_INHEAD
        MOV2    r27, r26
        INCR    r27
        LDR3    r28, r30, G_QMASK
        AND2    r27, r28
        LDR3    r28, r30, G_INTAIL
        CMP2    r27, r28
        B       EQ, @ret                ; full
        LDR3    r28, r30, G_INQB
        ADD2    r28, r26
        STRB    r29, r28
        STR3    r27, r30, G_INHEAD
        LDR3    r28, r30, G_INWAIT
        CMPI2   r28, 0
        B       EQ, @ret
        MOVI2   r29, 1
        STR3    r29, r28, U_STATUS      ; awake
        MOVI2   r29, 0
        STR3    r29, r30, G_INWAIT
@ret:   RET

; ---------------------------------------------------------------- 20: the keyboard
; Each report (KEYS0, KEYS1: the modifiers and six key codes) is compared with the one
; before: a key code that is new is a key just pressed. It becomes a character (the
; US layout, kbd_table), with Shift, Caps Lock and Ctrl. Caps Lock also lights its
; LED on the keyboard. Keys without a character (F1, the arrows, ...) are left out.
; The handler needs more registers: r0 .. r7 are kept in DRIVERS while it runs.
irq_kbd:
        PUSHF
        LDR3    r24, r30, G_DRV
        STR3    r0, r24, D_SAVE
        STR3    r1, r24, D_SAVE + 4
        STR3    r2, r24, D_SAVE + 8
        STR3    r3, r24, D_SAVE + 12
        STR3    r4, r24, D_SAVE + 16
        STR3    r5, r24, D_SAVE + 20
        STR3    r6, r24, D_SAVE + 24
        STR3    r7, r24, D_SAVE + 28
@next:  LDR3    r25, r30, G_KBD
        LDR     r0, r25                 ; STATUS: KEY, a report waits?
        MOVI2   r1, 1
        AND2    r1, r0
        B       EQ, @done
        LDR3    r1, r25, 4              ; KEYS0: modifiers, -, key 1, key 2
        LDR3    r2, r25, 8              ; KEYS1: keys 3 .. 6 (takes the report)
        STR3    r1, r24, D_NEW
        STR3    r2, r24, D_NEW + 4
        MOVI2   r3, 2                   ; byte 2 .. 7: the key codes
@key:   ADD3    r4, r24, r3
        LDRB3   r5, r4, D_NEW
        CMPI2   r5, 4
        B       LO, @nextk              ; 0 none, 1 too many keys, 2, 3 errors
        MOVI2   r6, 2                   ; down already in the last report?
@old:   ADD3    r4, r24, r6
        LDRB3   r7, r4, D_PREV
        CMP2    r7, r5
        B       EQ, @nextk
        INCR    r6
        CMPI2   r6, 8
        B       LO, @old
        CALL    kbd_press               ; new: pressed now
@nextk: INCR    r3
        CMPI2   r3, 8
        B       LO, @key
        LDR3    r4, r24, D_NEW          ; this report is the last one now
        STR3    r4, r24, D_PREV
        LDR3    r4, r24, D_NEW + 4
        STR3    r4, r24, D_PREV + 4
        B       A, @next
@done:  LDR3    r0, r24, D_SAVE
        LDR3    r1, r24, D_SAVE + 4
        LDR3    r2, r24, D_SAVE + 8
        LDR3    r3, r24, D_SAVE + 12
        LDR3    r4, r24, D_SAVE + 16
        LDR3    r5, r24, D_SAVE + 20
        LDR3    r6, r24, D_SAVE + 24
        LDR3    r7, r24, D_SAVE + 28
        LDR3    r24, r30, G_IRQC
        STR3    r24, r24, 12            ; EOI
        POPF
        RTI

; kbd_press: key code r5 pressed, the modifiers in r1 (bits 7..0: bit 0 left Ctrl, 1
; left Shift, 4 right Ctrl, 5 right Shift). r24 DRIVERS, r25 the keyboard. Uses r4,
; r6, r7, r26 .. r29.
kbd_press:
        CMPI2   r5, $39                 ; Caps Lock
        B       NE, @char
        LDR3    r4, r24, D_CAPS
        MOVI2   r6, 1
        XOR2    r4, r6
        STR3    r4, r24, D_CAPS
        ADD2    r4, r4                  ; its LED: bit 1 of LEDS
        STR3    r4, r25, 20
        RET
@char:  CMPI2   r5, KBD_KEYS - 1
        B       HI, @ret                ; no character
        LDR3    r4, r30, G_KTAB
        MOVI2   r6, $22                 ; Shift: the second table
        AND2    r6, r1
        B       EQ, @plain
        ADDI2   r4, KBD_KEYS
@plain: ADD2    r4, r5
        LDRB    r7, r4
        CMPI2   r7, 0
        B       EQ, @ret
        LDR3    r4, r24, D_CAPS         ; Caps Lock: the letters the other way
        CMPI2   r4, 0
        B       EQ, @ctrl
        CMPI2   r5, $04
        B       LO, @ctrl
        CMPI2   r5, $1D
        B       HI, @ctrl
        MOVI2   r6, $20
        XOR2    r7, r6
@ctrl:  MOVI2   r6, $11                 ; Ctrl: a control code
        AND2    r6, r1
        B       EQ, @put
        MOVI2   r6, $1F
        AND2    r7, r6
@put:   MOV2    r29, r7
        B       A, inq_put
@ret:   RET

; ================================================================ the exceptions
; The program is given up where it was: THROW (to QUIT's CATCH, which says what it
; was). r0 = the code for throw_r0; G_EXCPC = where it happened.
exc_undef:
        MOV2    r0, R
        STR3    r0, r30, G_EXCPC
        MOVI2   r0, -128
        ADD2    r0, r0                  ; -256
        B       A, throw_r0
exc_heap:
        MOV2    r0, R
        STR3    r0, r30, G_EXCPC
        MOVI2   r0, -128
        ADD2    r0, r0
        ADDI2   r0, -1                  ; -257
        B       A, throw_r0
exc_povf:
        MOVI2   r0, -3
        B       A, throw_r0
exc_punf:
        MOVI2   r0, -4
        B       A, throw_r0
exc_rovf:
        MOVI2   r0, -5
        B       A, throw_r0
exc_runf:
        MOVI2   r0, -6
        B       A, throw_r0
irq_other:
        LDR3    r0, r30, G_IRQC
        STR3    r0, r0, 12              ; EOI, in case it was a device
exc_other:
        MOV2    r0, R
        STR3    r0, r30, G_EXCPC
        MOVI2   r0, -128
        ADD2    r0, r0
        ADDI2   r0, -2                  ; -258
        B       A, throw_r0

; ================================================================ COLD
; From the loader: VEC = 0, I = 0, r1 = where the image came from, r14 = the row the
; loader would write next. COLD sets up the system area (memory.md), OPERATOR, the
; devices' interrupts, and starts QUIT.
cold:   CLI
        MOV2    r20, r1                 ; the boot source
        MOV2    r21, r14                ; the loader's row
        LIT     GP_BASE
        MOVR    r30, T
        LIT     OP_UP
        MOVR    r31, T
        LIT     OP_S0
        MOVR    PSP, T
        LIT     OP_R0
        MOVR    RSP, T
        MOVI2   r0, 0                   ; no checks while it is set up
        MOV2    PSPL, r0
        MOV2    PSPH, r0
        MOV2    RSPL, r0
        MOV2    RSPH, r0

        ; ---- the globals and OPERATOR's user area: all 0
        LIT     GLOBALS
        MOVR    r0, T
        MOVI2   r1, 0
        MOVI2   r2, 127
        ADDI2   r2, 127
        INCR    r2                      ; 255: 256 words
@clr1:  STR     r1, r0
        INCWR   r0
        NEXT    r2, @clr1
        LIT     OPERATOR
        MOVR    r0, T
        MOVI2   r2, 127                 ; 128 words
@clr2:  STR     r1, r0
        INCWR   r0
        NEXT    r2, @clr2

        ; ---- the globals
        LIT     -$10000                 ; $FFFF_0000
        STR3    T, r30, G_UART
        LIT     -$FC00                  ; $FFFF_0400
        STR3    T, r30, G_IRQC
        LIT     -$6000                  ; $FFFF_A000
        STR3    T, r30, G_VIDEO
        CALL    win_init                ; the text window, as the video unit has it
        LIT     -$FA00                  ; $FFFF_0600
        STR3    T, r30, G_KBD
        LIT     -$FE00                  ; $FFFF_0200
        STR3    T, r30, G_LEDS
        LIT     INQ
        STR3    T, r30, G_INQB
        LIT     OUTQ
        STR3    T, r30, G_OUTQB
        LIT     INQ_SIZE - 1
        STR3    T, r30, G_QMASK
        LIT     DRIVERS
        STR3    T, r30, G_DRV
        LIT     kbd_table
        STR3    T, r30, G_KTAB
        LIT     (INK_GREEN << 24) + (PAPER_BLACK << 16)
        STR3    T, r30, G_COLOURS
        LIT     HEAP0
        STR3    T, r30, G_HEAP
        LIT     DICT_END
        STR3    T, r30, G_DICTEND
        STR3    r20, r30, G_BOOTED
        LIT     KERNEL_LAST
        STR3    T, r30, G_FORTHWL
        LIT     LEAVES
        STR3    T, r30, G_LSP
        LIT     -$FF00                  ; $FFFF_0100: the SD card, not started yet
        STR3    T, r30, G_SD
        MOVI2   r0, -1
        STR3    r0, r30, G_SDHC
        CALL    empty_bufs              ; no block in the buffers
        LDR3    r0, r30, G_DRV          ; the keyboard's state
        MOVI2   r1, 0
        STR3    r1, r0, D_PREV
        STR3    r1, r0, D_PREV + 4
        STR3    r1, r0, D_CAPS

        ; ---- the cursor: on the row below the loader's lines (row 8 if r14 is not
        ;      in the text)
        MOVI2   r2, 8
        LIT     TEXT
        MOVR    r0, T
        CMP2    r21, r0
        B       LO, @row
        LIT     TEXT_END
        MOVR    r1, T
        CMP2    r21, r1
        B       HS, @row
        SUB3    r3, r21, r0
        MOVI2   r2, 0
        LIT     320
        MOVR    r4, T
@div:   CMP2    r3, r4
        B       LO, @row
        SUB2    r3, r4
        INCR    r2
        B       A, @div
@row:   LDR3    r0, r30, G_WTOP         ; inside the text window
        CMP2    r2, r0
        B       HS, @intop
        MOV2    r2, r0
@intop: LDR3    r1, r30, G_WROWS
        ADD2    r0, r1
        DECR    r0
        MINU2   r2, r0
        STR3    r2, r30, G_ROW

        ; ---- OPERATOR: its user area, linked to itself
        MOVI2   r0, 1
        STR3    r0, r31, U_STATUS
        STR3    r31, r31, U_LINK
        LIT     OP_S0
        STR3    T, r31, U_S0
        LIT     OP_R0
        STR3    T, r31, U_R0
        LIT     OP_PSTACK - 4 + 1       ; PSPL: the full stack (check on)
        STR3    T, r31, U_PSPL
        LIT     OP_S0 + 1               ; PSPH: the empty stack
        STR3    T, r31, U_PSPH
        LIT     OP_RSTACK + RS_HEADROOM - 4 + 1
        STR3    T, r31, U_RSPL
        LIT     OP_R0 + 1
        STR3    T, r31, U_RSPH
        MOVI2   r0, 10
        STR3    r0, r31, U_BASE
        LIT     __BSS_END__             ; HERE: right after the kernel
        STR3    T, r31, U_DP
        LIT     OP_TIB
        STR3    T, r31, U_TIB
        LIT     OP_WORD
        STR3    T, r31, U_WORD
        LIT     OP_HOLD
        STR3    T, r31, U_HOLD
        STR3    T, r31, U_HLD
        LIT     OP_PAD
        STR3    T, r31, U_PAD
        LIT     GLOBALS + $38           ; G_FORTHWL's address: the FORTH word list
        STR3    T, r31, U_CURRENT
        STR3    T, r31, U_CONTEXT
        MOVI2   r0, 1
        STR3    r0, r31, U_NORDER
        LIT     w_pkey
        STR3    T, r31, U_KEY
        LIT     w_pemit
        STR3    T, r31, U_EMIT

        ; ---- the stacks' limits: from now on the hardware checks them
        LDR3    r0, r31, U_PSPL
        MOV2    PSPL, r0
        LDR3    r0, r31, U_PSPH
        MOV2    PSPH, r0
        LDR3    r0, r31, U_RSPL
        MOV2    RSPL, r0
        LDR3    r0, r31, U_RSPH
        MOV2    RSPH, r0

        ; ---- LISP: the CONS heap is the free memory for now
        LIT     HEAP0 + 1
        MOVR    L, T
        LIT     HEAP_END - 7
        MOVR    HLIM, T

        ; ---- the interrupts: the serial port (RXIE), the frame, the keyboard
        LDR3    r0, r30, G_UART
        MOVI2   r1, 1
        STR3    r1, r0, 12              ; CTRL: RXIE
        LDR3    r0, r30, G_VIDEO
        MOVI2   r1, 2
        STR3    r1, r0, $2C             ; IRQ_CTRL: FIE
        STR3    r1, r0, $30             ; IRQ_STATUS: FRAME cleared
        LDR3    r0, r30, G_KBD
        MOVI2   r1, 5
        STR3    r1, r0, 24              ; CTRL: KIE, TXEN
        LDR3    r0, r30, G_IRQC
        MOVI2   r1, %11010
        STR3    r1, r0, 4               ; MASK: lines 1, 3, 4
        LDR3    r0, r30, G_LEDS
        MOVI2   r1, $0F
        STR     r1, r0                  ; LED3 too: FORTH runs
        SEI

        ZDOTQ   "mp32 FORTH, "
        CALL    w_unused
        CALL    w_udot
        ZDOTQ   "bytes free"
        CALL    w_cr
        CALL    crc_init
        PUSHL   autoload                ; the card's startup block (under CATCH)
        CALL    w_catch
        CMPI2   T, 0
        B       EQ, @ok
        CALL    error_msg
        B       A, w_quit
@ok:    DROP
        B       A, w_quit

; autoload: the volume's startup block, LOADed; nothing with S2 held at reset, or
; without a card or a volume
autoload:
        LDR3    r0, r30, G_LEDS         ; BUTTONS: S2
        LDR3    r1, r0, 4
        MOVI2   r2, 2
        AND2    r1, r2
        B       NE, @s2
        CALL    sd_start
        CMPI2   r0, 0
        B       NE, @r                  ; no card
        PUSHL   0
        CALL    w_block
        LDR     r0, T
        LDA     r1, VOL_MAGIC
        CMP2    r0, r1
        B       NE, @drop               ; no volume
        LDR3    T, T, VOL_STARTUP
        CMPI2   T, 0
        B       EQ, @drop
        ZDOTQ   "startup block "
        DUP
        CALL    udot0
        CALL    w_cr
        B       A, w_load
@drop:  DROP
@r:     RET
@s2:    ZDOTQ   "S2: no startup block"
        B       A, w_cr

; crc_init: CRC_TAB for the CRC-32 (the reflected polynomial $EDB88320)
crc_init:
        LDA     r0, CRC_TAB
        MOVI2   r1, 0
        LDA     r5, $EDB88320
        MOVI2   r7, 127
        ADDI2   r7, 127
        INCR    r7                      ; 256 entries
@i:     MOV2    r2, r1
        MOVI2   r3, 7
@b:     MOVI2   r4, 1
        AND3    r4, r2, r4
        MOVI2   r6, 1
        LSR2    r2, r6
        CMPI2   r4, 0
        B       EQ, @n
        XOR2    r2, r5
@n:     NEXT    r3, @b
        STR     r2, r0
        INCWR   r0
        INCR    r1
        NEXT    r7, @i
        RET

; crc32: r1 = the CRC-32 of r3 bytes from r2 on. Uses r1 .. r7.
crc32:  MOVI2   r1, -1
        LDA     r7, CRC_TAB
@l:     CMPI2   r3, 0
        B       EQ, @e
        LDRB    r4, r2
        XOR2    r4, r1
        MOVI2   r6, 24                  ; its low byte, times 4
        LSL2    r4, r6
        MOVI2   r6, 22
        LSR2    r4, r6
        ADD2    r4, r7
        LDR     r4, r4
        MOVI2   r6, 8
        LSR2    r1, r6
        XOR2    r1, r4
        INCR    r2
        DECR    r3
        B       A, @l
@e:     MOVI2   r6, -1
        XOR2    r1, r6
        RET

; udot0 ( u -- ): u without a space
udot0:  PUSHL   0
        CALL    w_lessnum
        CALL    w_sharps
        CALL    w_numgreater
        B       A, w_type

; type_clean ( a n -- ): n characters, control codes (and 0) as spaces
type_clean:
        CMPI2   T, 0
        B       LE, @d
@l:     OVER
        LDRB    T, T
        CMPI2   T, ' '
        B       HS, @p
        MOVI2   T, ' '
@p:     CALL    w_emit
        INCR    S
        DEC
        B       NE, @l
@d:     DROP
        DROP
        RET

; ================================================================ the screen
; The cursor's cell: r0 = TEXT + m * 320 + COL * 4, m the row of text that the
; screen's row ROW shows (the text window). Uses r1 .. r4.
cell_addr:
        LDR3    r1, r30, G_ROW
        CALL    text_row
        CALL    row_addr
        LDR3    r3, r30, G_COL
        ADD2    r3, r3
        ADD2    r3, r3
        ADD2    r0, r3
        RET

; text_row: r1, a row of the screen, becomes the row of text it shows: in the text
; window WTOP + (r1 - WTOP + WOFF) mod WROWS, outside it r1. Uses r2 .. r4.
text_row:
        LDR3    r2, r30, G_WTOP
        CMP2    r1, r2
        B       LO, @ret
        LDR3    r4, r30, G_WROWS
        ADD3    r3, r2, r4              ; r3: the row below the window
        CMP2    r1, r3
        B       HS, @ret
        LDR3    r2, r30, G_WOFF
        ADD2    r1, r2
        CMP2    r1, r3
        B       LO, @ret
        SUB2    r1, r4
@ret:   RET

; row_addr: r0 = TEXT + r1 * 320, row r1 of the text. Uses r2, r3.
row_addr:
        MOVI2   r2, 6
        LSL3    r3, r1, r2              ; row * 64
        MOVI2   r2, 8
        LSL3    r0, r1, r2              ; row * 256
        ADD2    r0, r3
        MOVI2   r2, TEXT >> 16
        MOVI2   r3, 16
        LSL2    r2, r3
        ADD2    r0, r2
        RET

; set_scroll: the video unit's SCROLL from WTOP, WROWS, WOFF. Uses r1 .. r3.
set_scroll:
        LDR3    r1, r30, G_WOFF
        MOVI2   r3, 8
        LSL2    r1, r3
        LDR3    r2, r30, G_WROWS
        OR2     r1, r2
        LSL2    r1, r3
        LDR3    r2, r30, G_WTOP
        OR2     r1, r2
        LDR3    r2, r30, G_VIDEO
        STR3    r1, r2, V_SCROLL
        RET

; win_init: the text window from the video unit's SCROLL (COLD keeps it, the screen
; as it is); none there (after the FPGA is loaded or the loader ran): the whole
; screen. Uses r0 .. r3.
win_init:
        LDR3    r0, r30, G_VIDEO
        LDR3    r0, r0, V_SCROLL
        MOVI2   r3, 63
        AND3    r1, r0, r3              ; TOP
        STR3    r1, r30, G_WTOP
        MOVI2   r2, 8
        LSR2    r0, r2
        AND3    r1, r0, r3              ; ROWS
        STR3    r1, r30, G_WROWS
        LSR2    r0, r2
        AND2    r0, r3                  ; OFFSET
        STR3    r0, r30, G_WOFF
        CMPI2   r1, 0
        B       NE, set_scroll
        STR3    r1, r30, G_WTOP         ; none: rows 0 .. 59
        STR3    r1, r30, G_WOFF
        MOVI2   r1, 60
        STR3    r1, r30, G_WROWS
        B       A, set_scroll

; scr_putc: the character r0 onto the screen at the cursor. CR, LF, BS move the
; cursor; other control codes are left out. The code goes into the cell as it is: in
; font 0 (Latin-1) the character itself; in fonts 1 and 2 (PETSCII) a PET screen code.
; Uses r0 .. r9 and T (kept).
scr_putc:
        CMPI2   r0, 13
        B       EQ, @cr
        CMPI2   r0, 10
        B       EQ, scr_lf
        CMPI2   r0, 8
        B       EQ, @bs
        CMPI2   r0, 32
        B       LO, @ret
        LDR3    r1, r30, G_COLOURS
        OR3     r9, r0, r1
        CALL    cell_addr
        STR     r9, r0
        LDR3    r1, r30, G_COL
        INCR    r1
        STR3    r1, r30, G_COL
        CMPI2   r1, 80
        B       LO, @ret
        MOVI2   r1, 0
        STR3    r1, r30, G_COL
        B       A, scr_lf
@cr:    MOVI2   r1, 0
        STR3    r1, r30, G_COL
        RET
@bs:    LDR3    r1, r30, G_COL
        CMPI2   r1, 0
        B       EQ, @ret
        DECR    r1
        STR3    r1, r30, G_COL
@ret:   RET

; scr_lf: the cursor one row down; from the text window's last row the window
; scrolls up. Below the window it goes down to row 59 and stays there.
scr_lf: LDR3    r1, r30, G_ROW
        INCR    r1
        LDR3    r2, r30, G_WTOP
        LDR3    r3, r30, G_WROWS
        ADD2    r2, r3                  ; the row below the window
        CMP2    r1, r2
        B       EQ, scroll              ; the cursor stays on the last row
        CMPI2   r1, 60
        B       LO, @ok
        MOVI2   r1, 59
@ok:    STR3    r1, r30, G_ROW
        RET

; scroll: the text window up by one row, in the video unit (WOFF + 1, round), its
; new last row blank: 80 words written, nothing copied. Uses r0 .. r4, r7, T (kept).
scroll: LDR3    r1, r30, G_WOFF
        INCR    r1
        LDR3    r2, r30, G_WROWS
        CMP2    r1, r2
        B       LO, @off
        MOVI2   r1, 0
@off:   STR3    r1, r30, G_WOFF
        CALL    set_scroll
        LDR3    r1, r30, G_WTOP         ; the window's last row
        LDR3    r2, r30, G_WROWS
        ADD2    r1, r2
        DECR    r1
        CALL    text_row
        CALL    row_addr
        MOV2    r4, r0
        MOVI2   r7, 79                  ; its 80 cells blank
; blank_words: r7 + 1 words from r4 on blank (a space in the colours). Uses r1, r2.
blank_words:
        LDR3    r1, r30, G_COLOURS
        MOVI2   r2, ' '
        OR2     r1, r2
@l:     STR     r1, r4
        INCWR   r4
        NEXT    r7, @l
        RET

; the cursor: the cell's ink and paper swapped while KEY waits
cursor_on:
        LDR3    r0, r30, G_CURSOR
        CMPI2   r0, 0
        B       NE, cursor_ret
        MOVI2   r0, 1
        STR3    r0, r30, G_CURSOR
        B       A, cursor_flip
cursor_off:
        LDR3    r0, r30, G_CURSOR
        CMPI2   r0, 0
        B       EQ, cursor_ret
        MOVI2   r0, 0
        STR3    r0, r30, G_CURSOR
cursor_flip:                            ; uses r0 .. r4
        CALL    cell_addr
        LDR     r1, r0                  ; ink (byte 3), paper (byte 2), font, code
        MOVI2   r3, 8
        LSR3    r2, r1, r3
        XOR2    r2, r1                  ; byte 2: ink XOR paper
        LDA     r4, $00FF0000
        AND2    r2, r4
        XOR2    r1, r2                  ; the paper becomes the ink ...
        LSL2    r2, r3
        XOR2    r1, r2                  ; ... and the ink the paper
        STR     r1, r0
cursor_ret:
        RET

; ================================================================ small helpers
; zdotq: prints the string that follows the call (ending with 0) and goes on after it
zdotq:  DUP
        MOVR    T, R
@l:     DUP
        LDRB    T, T
        CMPI2   T, 0
        B       EQ, @end
        CALL    w_emit
        INC
        B       A, @l
@end:   DROP
        INC
        MOVR    R, T
        DROP
        RET

; ztype ( a -- ): the string at a, ending with 0
ztype:  DUP
        LDRB    T, T
        CMPI2   T, 0
        B       EQ, @end
        CALL    w_emit
        INC
        B       A, ztype
@end:   DROP
        DROP
        RET

; udiv: {r1, r0} / r2 (64 / 32 bits, unsigned, r2 not 0): r1, r0 the quotient, r3 the
; remainder. Uses r4, r10, r11, TMPL, the flags; T and S kept.
udiv:   MOV2    r10, T
        MOV2    r11, S
        MOV2    S, r2
        MOVI2   T, 0                    ; the high word first: {0, r1} / r2
        MOV2    TMPL, r1
        MOVI2   ST, 0                   ; C = 0
        MOVI2   r4, 32                  ; 33 steps
@h:     DIVS
        NEXT    r4, @h
        RORC                            ; T = the remainder
        MOV2    r1, TMPL
        MOV2    TMPL, r0                ; then {remainder, r0} / r2
        MOVI2   ST, 0
        MOVI2   r4, 32
@l:     DIVS
        NEXT    r4, @l
        RORC
        MOV2    r3, T
        MOV2    r0, TMPL
        MOV2    T, r10
        MOV2    S, r11
        RET

divzero:
        MOVI2   r0, -10
        B       A, throw_r0

; ================================================================ the SD card
; The card in SPI mode, as the boot loader starts it (../computer/boot.s): SDHC and
; SDXC (block addresses), SDSC (byte addresses, CMD16). Started when it is first used
; (G_SDHC = -1), and again after an error. Leaf routines: r12 = the card, r11 = -1;
; they use r0 .. r12 (and r13 in LDA). r0 = 0 when it went well.

; sd_xfer: the byte r1 out, the byte that came in into r1
sd_xfer:
        STR     r1, r12
        LDR     r1, r12
        RET

; sd_cmd: command r1 with the argument r2 and the CRC byte r3; r1 = the answer R1 (bit
; 7 set: none came). Uses r1 .. r6.
sd_cmd: MOV2    r4, r1
        MOVI2   r1, -1                  ; a byte of $FF first
        CALL    sd_xfer
        MOVI2   r5, $40
        OR3     r1, r4, r5
        CALL    sd_xfer
        STR3    r2, r12, 4              ; DATA32: the argument, high byte first
        MOV2    r1, r3
        CALL    sd_xfer
        MOVI2   r5, 16                  ; the answer: within 8 bytes, give it 16
        MOVI2   r6, 64
        ADD2    r6, r6                  ; $80
@poll:  MOVI2   r1, -1
        CALL    sd_xfer
        AND3    r4, r1, r6
        B       EQ, @got
        DECR    r5
        B       NE, @poll
@got:   RET

; sd_close: CS off (and 21 MHz), a byte of clocks so the card lets go of MISO
sd_close:
        MOVI2   r1, 0
        STR3    r1, r12, 8
        MOVI2   r1, -1
        B       A, sd_xfer

; sd_fail: the card closed, to be started again next time; r0 = 1
sd_fail:
        CALL    sd_close
        MOVI2   r0, -1
        STR3    r0, r30, G_SDHC
        MOVI2   r0, 0
        STR3    r0, r30, G_SDBLKS
        MOVI2   r0, 1
        RET

; sd_start: r12, r11 set, and the card started if it is not yet
sd_start:
        LDR3    r12, r30, G_SD
        MOVI2   r11, -1
        LDR3    r0, r30, G_SDHC
        CMPI2   r0, 0
        B       LT, sd_init
        MOVI2   r0, 0
        RET

; sd_init: reset to SPI mode at 396 kHz, CMD0, CMD8, ACMD41 until ready, CMD58 (SDHC?)
; or CMD16, CMD9 and CMD10 (the CSD and the CID, into SD_CSD and SD_CID); then 21 MHz.
; G_SDHC = 1 or 0, G_SDBLKS the capacity. Uses r1 .. r8 (not r9, r10: sd_read's).
sd_init:
        LDA     r1, SD_SLOW             ; CS off, 396 kHz
        STR3    r1, r12, 8
        MOVI2   r7, 9                   ; 80 clocks with CS off
@clk:   MOVI2   r1, -1
        CALL    sd_xfer
        NEXT    r7, @clk
        LDA     r1, SD_SLOW + 1         ; CS on
        STR3    r1, r12, 8
        MOVI2   r8, 100                 ; CMD0 until it says idle: a card that was
@cmd0:  MOVI2   r1, 0                   ; left in the middle of a block (the boot
        MOVI2   r2, 0                   ; loader reads only block 0's header) sends
        LDA     r3, $95                 ; the rest of it first, and takes no command
        CALL    sd_cmd                  ; until then: each try clocks some 20 bytes
        CMPI2   r1, 1
        B       EQ, @idle
        DECR    r8
        B       NE, @cmd0
        B       A, sd_fail              ; no card
@idle:
        MOVI2   r1, 8                   ; CMD8: 2.7 .. 3.6 V, the pattern $AA
        LDA     r2, $1AA
        LDA     r3, $87
        CALL    sd_cmd
        MOVI2   r7, 0                   ; ACMD41's argument: 0 for a version 1 card
        CMPI2   r1, 1
        B       NE, @acmd               ; illegal command: version 1
        STR3    r11, r12, 4             ; R7: four more bytes
        LDR3    r1, r12, 4
        LDA     r2, $FFF
        AND2    r1, r2
        LDA     r2, $1AA
        CMP2    r1, r2
        B       NE, sd_fail             ; not our voltage
        LDA     r7, $40000000           ; HCS: we take SDHC
@acmd:  LDA     r8, 3000                ; about a second
@try:   MOVI2   r1, 55                  ; CMD55: an application command follows
        MOVI2   r2, 0
        MOVI2   r3, $65
        CALL    sd_cmd
        MOVI2   r1, 41                  ; ACMD41: start
        MOV2    r2, r7
        MOVI2   r3, $77
        CALL    sd_cmd
        CMPI2   r1, 0
        B       EQ, @ready
        DECR    r8
        B       NE, @try
        B       A, sd_fail              ; never got ready
@ready: MOVI2   r8, 0
        CMPI2   r7, 0
        B       EQ, @sdsc               ; version 1: SDSC
        MOVI2   r1, 58                  ; CMD58: the OCR
        MOVI2   r2, 0
        MOVI2   r3, -3                  ; $FD
        CALL    sd_cmd
        STR3    r11, r12, 4
        LDR3    r1, r12, 4              ; bit 30: CCS, block addresses
        LDA     r2, $40000000
        AND2    r1, r2
        B       EQ, @sdsc
        MOVI2   r8, 1
        B       A, @regs
@sdsc:  MOVI2   r1, 16                  ; CMD16: blocks of 512 bytes
        LDA     r2, 512
        MOVI2   r3, 1
        CALL    sd_cmd
@regs:  LDA     r7, SD_CSD              ; CMD9: the CSD (the capacity)
        MOVI2   r1, 9
        CALL    sd_reg
        CMPI2   r0, 0
        B       NE, sd_fail
        LDA     r7, SD_CID              ; CMD10: the CID (who made it)
        MOVI2   r1, 10
        CALL    sd_reg
        CMPI2   r0, 0
        B       NE, sd_fail
        CALL    sd_capacity
@fast:  STR3    r8, r30, G_SDHC
        CALL    sd_close
        MOVI2   r0, 0
        RET

; sd_reg: command r1 (CMD9 the CSD, CMD10 the CID): its 16 bytes to r7 on. Uses r0 ..
; r7.
sd_reg: MOVI2   r2, 0
        MOVI2   r3, 1
        CALL    sd_cmd
        CMPI2   r1, 0
        B       NE, @fail
        LDA     r3, 100000              ; the data token $FE
        MOVI2   r5, 127
        ADD2    r5, r5
@tok:   MOVI2   r1, -1
        CALL    sd_xfer
        CMP2    r1, r5
        B       EQ, @data
        DECR    r3
        B       NE, @tok
@fail:  MOVI2   r0, 1
        RET
@data:  MOVI2   r6, 15
@b:     MOVI2   r1, -1
        CALL    sd_xfer
        STRB    r1, r7
        INCR    r7
        NEXT    r6, @b
        MOVI2   r1, -1                  ; the CRC
        CALL    sd_xfer
        MOVI2   r1, -1
        CALL    sd_xfer
        MOVI2   r0, 0
        RET

; sd_capacity: G_SDBLKS = the card's blocks of 512 bytes, from its CSD. Version 2
; (SDHC, SDXC): (C_SIZE + 1) * 1024; version 1 (SDSC): (C_SIZE + 1) << (C_SIZE_MULT + 2
; + READ_BL_LEN - 9). Uses r1 .. r4, r7.
sd_capacity:
        LDA     r7, SD_CSD
        LDRB    r1, r7                  ; CSD_STRUCTURE: bits 127..126
        MOVI2   r2, 6
        LSR2    r1, r2
        CMPI2   r1, 1
        B       NE, @v1
        LDRB3   r1, r7, 7               ; C_SIZE: bits 69..48
        MOVI2   r2, $3F
        AND2    r1, r2
        MOVI2   r2, 16
        LSL2    r1, r2
        LDRB3   r3, r7, 8
        MOVI2   r2, 8
        LSL2    r3, r2
        OR2     r1, r3
        LDRB3   r3, r7, 9
        OR2     r1, r3
        INCR    r1
        MOVI2   r2, 10
        LSL2    r1, r2
        B       A, @set
@v1:    LDRB3   r1, r7, 6               ; C_SIZE: bits 73..62
        MOVI2   r2, 3
        AND2    r1, r2
        MOVI2   r2, 10
        LSL2    r1, r2
        LDRB3   r3, r7, 7
        MOVI2   r2, 2
        LSL2    r3, r2
        OR2     r1, r3
        LDRB3   r3, r7, 8
        MOVI2   r2, 6
        LSR2    r3, r2
        OR2     r1, r3
        INCR    r1
        LDRB3   r3, r7, 9               ; C_SIZE_MULT: bits 49..47
        MOVI2   r2, 3
        AND2    r3, r2
        ADD2    r3, r3
        LDRB3   r4, r7, 10
        MOVI2   r2, 7
        LSR2    r4, r2
        OR2     r3, r4
        LDRB3   r4, r7, 5               ; READ_BL_LEN: bits 83..80
        MOVI2   r2, 15
        AND2    r4, r2
        ADD2    r3, r4
        ADDI2   r3, 2 - 9
        LSL2    r1, r3
@set:   STR3    r1, r30, G_SDBLKS
        RET

; sd_addr: r2 = the address of block r9 for the card (its byte for SDSC)
sd_addr:
        MOV2    r2, r9
        LDR3    r1, r30, G_SDHC
        CMPI2   r1, 0
        B       NE, @r
        MOVI2   r1, 9
        LSL2    r2, r1
@r:     RET

; sd_read: the card's block r9 (512 bytes) to r10 on (word aligned)
sd_read:
        CALL    sd_start
        CMPI2   r0, 0
        B       NE, @r
        MOVI2   r1, 1                   ; CS on, 21 MHz
        STR3    r1, r12, 8
        CALL    sd_addr
        MOVI2   r1, 17                  ; CMD17: read a block
        MOVI2   r3, 1
        CALL    sd_cmd
        CMPI2   r1, 0
        B       NE, sd_fail
        LDA     r7, 200000              ; the data token $FE, within about 100 ms
        MOVI2   r8, 127
        ADD2    r8, r8                  ; $FE
@tok:   MOVI2   r1, -1
        CALL    sd_xfer
        CMP2    r1, r8
        B       EQ, @data
        DECR    r7
        B       NE, @tok
        B       A, sd_fail
@data:  MOVI2   r7, 127                 ; 128 words, as they come (DATA32LE)
@w:     STR3    r11, r12, 12
        LDR3    r1, r12, 12
        STR     r1, r10
        INCWR   r10
        NEXT    r7, @w
        MOVI2   r1, -1                  ; the CRC (not checked)
        CALL    sd_xfer
        MOVI2   r1, -1
        CALL    sd_xfer
        CALL    sd_close
        MOVI2   r0, 0
@r:     RET

; sd_write: 512 bytes from r10 on to the card's block r9
sd_write:
        CALL    sd_start
        CMPI2   r0, 0
        B       NE, @r
        MOVI2   r1, 1
        STR3    r1, r12, 8
        CALL    sd_addr
        MOVI2   r1, 24                  ; CMD24: write a block
        MOVI2   r3, 1
        CALL    sd_cmd
        CMPI2   r1, 0
        B       NE, sd_fail
        MOVI2   r1, -1
        CALL    sd_xfer
        MOVI2   r1, -2                  ; the data token $FE
        CALL    sd_xfer
        MOVI2   r7, 127
@w:     LDR     r1, r10                 ; 128 words (DATA32LE: the bytes in order)
        STR3    r1, r12, 12
        INCWR   r10
        NEXT    r7, @w
        MOVI2   r1, -1                  ; a CRC (not checked in SPI mode)
        CALL    sd_xfer
        MOVI2   r1, -1
        CALL    sd_xfer
        MOVI2   r7, 16                  ; the data response: xxx0 0101 = accepted
@resp:  MOVI2   r1, -1
        CALL    sd_xfer
        MOVI2   r2, $1F
        AND2    r2, r1
        CMPI2   r2, $1F
        B       NE, @got
        DECR    r7
        B       NE, @resp
        B       A, sd_fail
@got:   CMPI2   r2, 5
        B       NE, sd_fail
        LDA     r7, 5000000             ; busy (MISO 0) while it writes: up to 1 s
@busy:  MOVI2   r1, -1
        CALL    sd_xfer
        CMPI2   r1, 0
        B       NE, @done
        DECR    r7
        B       NE, @busy
        B       A, sd_fail
@done:  CALL    sd_close
        MOVI2   r0, 0
@r:     RET

; ================================================================ the block buffers
; NBUF buffers of 4 KB (BUFS), each with its block number (-1: none) and whether it
; was changed (BTAB). FORTH's block u is the card's blocks BLK_LBA + 8u .. + 7.

; buf_ptrs: buffer r16: r14 = its data, r15 = its entry in BTAB. Uses r1.
buf_ptrs:
        MOVI2   r1, 12
        LSL3    r14, r16, r1
        LDA     r1, BUFS
        ADD2    r14, r1
        MOVI2   r1, 3
        LSL3    r15, r16, r1
        LDA     r1, BTAB
        ADD2    r15, r1
        RET

; buf_save: buffer r16 back onto the card, if it was changed. r0 = 0, or not if the
; card failed. Uses r0 .. r15, r18.
buf_save:
        CALL    buf_ptrs
        LDR3    r1, r15, 4              ; changed (bit 0)?
        MOVI2   r2, 1
        AND2    r1, r2
        MOVI2   r0, 0
        B       EQ, @r
        LDR     r1, r14                 ; a source block: its version + 1, its CRC
        LDA     r2, SRC_MAGIC
        CMP2    r1, r2
        B       NE, @write
        LDR3    r1, r14, SRC_VERSION
        INCR    r1
        STR3    r1, r14, SRC_VERSION
        MOV2    r2, r14
        ADDI2   r2, SRC_HEAD
        LDA     r3, SRC_COLS * SRC_ROWS
        CALL    crc32
        STR3    r1, r14, SRC_CRC
@write: LDR     r9, r15                 ; its 8 blocks on the card
        MOVI2   r1, BLK_SHIFT
        LSL2    r9, r1
        LDA     r1, BLK_LBA
        ADD2    r9, r1
        MOV2    r10, r14
        MOVI2   r18, (1 << BLK_SHIFT) - 1
@wr:    CALL    sd_write                ; (r10 moves on by 512)
        CMPI2   r0, 0
        B       NE, @r
        INCR    r9
        NEXT    r18, @wr
        MOVI2   r1, 0
        STR3    r1, r15, 4              ; saved
@r:     RET

; block_get: block r0 in a buffer (read from the card if r20 != 0); r14 = its data,
; r0 = 0, or the THROW code (-35 no such block on the card, -33 read, -34 write).
; Uses r0 .. r20.
block_get:
        MOV2    r17, r0
        LDR3    r1, r30, G_SDBLKS       ; the card's capacity: started already?
        CMPI2   r1, 0
        B       NE, @known
        CALL    sd_start
        CMPI2   r0, 0
        B       NE, @rerr
        LDR3    r1, r30, G_SDBLKS
@known: MOVI2   r3, 32 - BLK_SHIFT      ; block u on the card at all?
        LSR3    r2, r17, r3
        CMPI2   r2, 0
        B       NE, @range
        MOVI2   r3, BLK_SHIFT
        LSL3    r2, r17, r3
        LDA     r3, BLK_LBA + (1 << BLK_SHIFT) - 1
        ADD2    r2, r3
        CMP2    r2, r1
        B       HS, @range
        LDA     r2, BTAB                ; in a buffer already?
        MOVI2   r16, 0
@find:  LDR     r3, r2
        CMP2    r3, r17
        B       EQ, @have
        ADDI2   r2, 8
        INCR    r16
        CMPI2   r16, NBUF
        B       LO, @find
        LDR3    r16, r30, G_BNEXT       ; no: the next buffer in turn
        MOV2    r1, r16
        INCR    r1
        MOVI2   r2, NBUF - 1
        AND2    r1, r2
        STR3    r1, r30, G_BNEXT
        CALL    buf_save                ; its block first back to the card
        CMPI2   r0, 0
        B       NE, @werr
        MOVI2   r1, -1
        STR     r1, r15
        CMPI2   r20, 0
        B       EQ, @mine
        MOV2    r9, r17                 ; read it: 8 blocks of the card
        MOVI2   r1, BLK_SHIFT
        LSL2    r9, r1
        LDA     r1, BLK_LBA
        ADD2    r9, r1
        MOV2    r10, r14
        MOVI2   r18, (1 << BLK_SHIFT) - 1
@rd:    CALL    sd_read                 ; (r10 moves on by 512)
        CMPI2   r0, 0
        B       NE, @rerr
        INCR    r9
        NEXT    r18, @rd
        LDR     r1, r14                 ; a source block: is its text as written?
        LDA     r2, SRC_MAGIC
        CMP2    r1, r2
        B       NE, @mine
        LDR3    r1, r14, SRC_VERSION
        CMPI2   r1, 0
        B       EQ, @mine               ; never written by FORTH: no CRC
        MOV2    r2, r14
        ADDI2   r2, SRC_HEAD
        LDA     r3, SRC_COLS * SRC_ROWS
        CALL    crc32
        LDR3    r2, r14, SRC_CRC
        CMP2    r1, r2
        B       EQ, @mine
        MOVI2   r1, 2                   ; damaged: LOAD and LIST refuse it
        STR3    r1, r15, 4
@mine:  STR     r17, r15                ; the buffer holds block u now
@have:  CALL    buf_ptrs
        STR3    r16, r30, G_BCUR
        MOVI2   r0, 0
        RET
@range: MOVI2   r0, -35
        RET
@rerr:  MOVI2   r0, -33
        RET
@werr:  MOVI2   r0, -34
        RET

; empty_bufs: no block in any buffer. Uses r0 .. r2.
empty_bufs:
        LDA     r1, BTAB
        MOVI2   r2, -1
        MOVI2   r0, 0
        .rept   NBUF
        STR     r2, r1
        STR3    r0, r1, 4
        ADDI2   r1, 8
        .endr
        RET

; ================================================================ the compiler's helpers
; Leaf routines on HERE (U_DP); they keep what they are given in r6 .. r12 unless
; said otherwise.

; c_room: makes room for an instruction of r1 bytes in the line: if it would cross the
; end of the line, NOPs up to the line's end first (the line rule). r0 = HERE after.
; Uses r2, r3.
c_room: LDR3    r0, r31, U_DP
        MOVI2   r2, 15
        AND3    r2, r0, r2
        ADD2    r2, r1
        CMPI2   r2, 16
        B       LS, @ok
        MOVI2   r3, 0
@pad:   STRB    r3, r0
        INCR    r0
        MOVI2   r2, 15
        AND3    r2, r0, r2
        B       NE, @pad
        STR3    r0, r31, U_DP
@ok:    RET

; c_b: the byte r4 at HERE. r0 = HERE after.
c_b:    LDR3    r0, r31, U_DP
        STRB    r4, r0
        INCR    r0
        STR3    r0, r31, U_DP
        RET

; c_bytes: the r7 low bytes of r4 at HERE, the lowest first. Uses r0, r2, r4, r7.
c_bytes:
@l:     CALL    c_b
        MOVI2   r2, 8
        LSR2    r4, r2
        DECR    r7
        B       NE, @l
        RET

; c_copy: the r7 bytes of code at r6 copied to HERE, an instruction at a time (each
; with the line rule). Uses r0 .. r4, r6, r7, r9, r11.
c_copy: CMPI2   r7, 0
        B       LE, @ret
@i:     LDRB    r9, r6                  ; the opcode byte: its length in bits 7..6
        MOVI2   r2, 6
        LSR3    r1, r9, r2
        INCR    r1
        MOV2    r11, r1
        CALL    c_room
@b:     LDRB    r4, r6
        CALL    c_b
        INCR    r6
        DECR    r7
        DECR    r11
        B       NE, @b
        CMPI2   r7, 0
        B       GT, @i
@ret:   RET

; c_lit: code that pushes r6: DUP and the shortest LIT (LIT24 and LITH for 32 bits).
; Uses r0 .. r4, r7.
c_lit:  MOVI2   r1, 1
        CALL    c_room
        MOVI2   r4, $02                 ; DUP
        CALL    c_b
        MOVI2   r2, 24                  ; 8 bits?
        LSL3    r7, r6, r2
        ASR2    r7, r2
        CMP2    r7, r6
        B       NE, @16
        MOVI2   r1, 2
        CALL    c_room
        MOVI2   r4, $40                 ; LIT8
        CALL    c_b
        MOV2    r4, r6
        B       A, c_b
@16:    MOVI2   r2, 16
        LSL3    r7, r6, r2
        ASR2    r7, r2
        CMP2    r7, r6
        B       NE, @24
        MOVI2   r1, 3
        CALL    c_room
        MOVI2   r4, -128                ; $80 LIT16
        CALL    c_b
        MOV2    r4, r6
        MOVI2   r7, 2
        B       A, c_bytes
@24:    MOVI2   r1, 4
        CALL    c_room
        MOVI2   r4, -64                 ; $C0 LIT24
        CALL    c_b
        MOV2    r4, r6
        MOVI2   r7, 3
        CALL    c_bytes
        MOVI2   r2, 8
        LSL3    r7, r6, r2
        ASR2    r7, r2
        CMP2    r7, r6
        B       EQ, @ret
        MOVI2   r1, 2                   ; 32 bits: LITH the top byte
        CALL    c_room
        MOVI2   r4, $45
        CALL    c_b
        MOVI2   r2, 24
        LSR3    r4, r6, r2
        B       A, c_b
@ret:   RET

; c_call: a call of r6: JSRS, JSR or JSRL, the shortest that reaches. Remembers it for
; ; (G_CALLAT, G_CALLEND, G_CALLXT). Uses r0 .. r4, r7.
c_call: STR3    r6, r30, G_CALLXT
        LDR3    r0, r31, U_DP
        SUB3    r7, r6, r0              ; how far, roughly
        MOVI2   r2, 6
        ASR2    r7, r2                  ; within +-64 bytes: JSRS
        CMPI2   r7, 0
        B       EQ, @s
        CMPI2   r7, -1
        B       EQ, @s
        SUB3    r7, r6, r0
        MOVI2   r2, 14
        ASR2    r7, r2                  ; within +-16 KB: JSR
        CMPI2   r7, 0
        B       EQ, @m
        CMPI2   r7, -1
        B       EQ, @m
        MOVI2   r1, 4                   ; JSRL
        CALL    c_room
        STR3    r0, r30, G_CALLAT
        MOVI2   r4, -62                 ; $C2
        CALL    c_b
        SUB3    r4, r6, r0
        ADDI2   r4, -3
        MOVI2   r7, 3
        CALL    c_bytes
        B       A, @end
@m:     MOVI2   r1, 3                   ; JSR
        CALL    c_room
        STR3    r0, r30, G_CALLAT
        MOVI2   r4, -126                ; $82
        CALL    c_b
        SUB3    r4, r6, r0
        ADDI2   r4, -2
        MOVI2   r7, 2
        CALL    c_bytes
        B       A, @end
@s:     MOVI2   r1, 2                   ; JSRS
        CALL    c_room
        STR3    r0, r30, G_CALLAT
        MOVI2   r4, $42
        CALL    c_b
        SUB3    r4, r6, r0
        ADDI2   r4, -1
        CALL    c_b
@end:   LDR3    r0, r31, U_DP
        STR3    r0, r30, G_CALLEND
        RET

; c_cbrl: CBRL with the condition r8 (0 .. 15) to r6. Uses r0 .. r4, r7, r9.
c_cbrl: MOVI2   r1, 4
        CALL    c_room
        MOVI2   r4, -63                 ; $C1
        CALL    c_b
        SUB3    r9, r6, r0              ; the offset from the next instruction
        ADDI2   r9, -3
        MOVI2   r2, 4
        LSL3    r4, r8, r2
        MOVI2   r2, 15
        AND3    r2, r9, r2
        OR2     r4, r2
        CALL    c_b
        MOVI2   r2, 4
        ASR3    r4, r9, r2
        MOVI2   r7, 2
        B       A, c_bytes

; c_fwd: a CBRL with the condition r8 that goes nowhere yet: r10 = its address, for
; c_resolve. Uses r0 .. r4, r6, r7, r9.
c_fwd:  MOVI2   r1, 4
        CALL    c_room
        MOV2    r10, r0
        MOV2    r6, r0
        ADDI2   r6, 4
        B       A, c_cbrl

; c_resolve: the CBRL at r10 goes to r6. Uses r2, r4, r9.
c_resolve:
        SUB3    r9, r6, r10
        ADDI2   r9, -4
        LDRB3   r4, r10, 1
        MOVI2   r2, -16
        AND2    r4, r2                  ; its condition
        MOVI2   r2, 15
        AND3    r2, r9, r2
        OR2     r4, r2
        STRB3   r4, r10, 1
        MOVI2   r2, 4
        ASR3    r4, r9, r2
        STRB3   r4, r10, 2
        MOVI2   r2, 12
        ASR3    r4, r9, r2
        STRB3   r4, r10, 3
        RET

; c_label: a branch goes to HERE: no tail call into it
c_label:
        LDR3    r0, r31, U_DP
        STR3    r0, r30, G_LABEL
        RET

; c_leaves: the LEAVEs of the loop (back to its 0 on the LEAVE stack) go to HERE.
; Uses r0 .. r4, r6, r9, r10, r12.
c_leaves:
        LDR3    r12, r30, G_LSP
@l:     DECWR   r12
        LDR     r10, r12
        CMPI2   r10, 0
        B       EQ, @done
        LDR3    r6, r31, U_DP
        CALL    c_resolve
        B       A, @l
@done:  STR3    r12, r30, G_LSP
        B       A, c_label

; c_lpush: r10 onto the LEAVE stack. Uses r0.
c_lpush:
        LDR3    r0, r30, G_LSP
        STR     r10, r0
        INCWR   r0
        STR3    r0, r30, G_LSP
        RET

; templates: code that the control words copy (never run here)
t_if:   CMPI2   T, 0                    ; IF, UNTIL, WHILE: the flag, dropped
        DROP
t_if_end:
t_do:   SWAP                            ; DO ( limit start ): R = start, under it limit
        PUSH
        DROP
        PUSH
        DROP
t_do_end:
t_qdo:  CMP                             ; ?DO: EQ if limit = start
        SWAP
        PUSH
        DROP
        PUSH
        DROP
t_qdo_end:
t_loop: INCR    R                       ; LOOP: the index + 1, = the limit?
        LDR3    r0, RSP, 4
        CMP2    R, r0
t_loop_end:
t_ploop:                                ; +LOOP: did index - limit change its sign?
        MOVR    r0, T
        DROP
        LDR3    r1, RSP, 4
        SUB3    r2, R, r1
        ADD2    R, r0
        SUB3    r3, R, r1
        XOR2    r2, r3
t_ploop_end:

; ================================================================ the dictionary
; The kernel's words, oldest first. A word's flags: F_IMMEDIATE (runs while
; compiling), F_COMPILE (only while compiling), F_IC both; inl > 0: its first inl
; bytes are copied into a definition instead of a call.

; ---------------------------------------------------------------- the stacks
        HEAD    w_dup, 0, "DUP", 3, 0, 1
        DUP
        RET
        HEAD    w_drop, w_dup, "DROP", 4, 0, 1
        DROP
        RET
        HEAD    w_swap, w_drop, "SWAP", 4, 0, 1
        SWAP
        RET
        HEAD    w_over, w_swap, "OVER", 4, 0, 1
        OVER
        RET
        HEAD    w_nip, w_over, "NIP", 3, 0, 1
        NIP
        RET
        HEAD    w_tuck, w_nip, "TUCK", 4, 0, 1
        TUCK
        RET
        HEAD    w_rot, w_tuck, "ROT", 3, 0, 1
        ROT
        RET
        HEAD    w_mrot, w_rot, "-ROT", 4, 0, 1
        DROT
        RET
        HEAD    w_2dup, w_mrot, "2DUP", 4, 0, 2
        OVER
        OVER
        RET
        HEAD    w_2drop, w_2dup, "2DROP", 5, 0, 2
        DROP
        DROP
        RET
        HEAD    w_2swap, w_2drop, "2SWAP", 5, 0, 6
        ROT
        PUSH
        DROP
        ROT
        DUP
        POP
        RET
        HEAD    w_2over, w_2swap, "2OVER", 5, 0, 10
        DUP
        LDR3    T, PSP, 12
        DUP
        LDR3    T, PSP, 12
        RET
        HEAD    w_qdup, w_2over, "?DUP", 4, 0, 0
        CMPI2   T, 0
        B       EQ, @r
        DUP
@r:     RET
        HEAD    w_pick, w_qdup, "PICK", 4, 0, 0
        CMPI2   T, 0
        B       EQ, @s
        LSLI    2
        LDR3    T, PSP, T
        RET
@s:     MOV2    T, S
        RET
        HEAD    w_depth, w_pick, "DEPTH", 5, 0, 15
        MOV2    r0, PSP
        LDR3    r1, r31, U_S0
        SUB2    r1, r0
        DUP
        MOVR    T, r1
        ASRI    2
        RET
        HEAD    w_tor, w_depth, ">R", 2, F_COMPILE, 2
        PUSH
        DROP
        RET
        HEAD    w_rfrom, w_tor, "R>", 2, F_COMPILE, 2
        DUP
        POP
        RET
        HEAD    w_rfetch, w_rfrom, "R@", 2, F_COMPILE, 3
        DUP
        MOVR    T, R
        RET
        HEAD    w_2tor, w_rfetch, "2>R", 3, F_COMPILE, 5
        SWAP
        PUSH
        DROP
        PUSH
        DROP
        RET
        HEAD    w_2rfrom, w_2tor, "2R>", 3, F_COMPILE, 5
        DUP
        POP
        DUP
        POP
        SWAP
        RET

; ---------------------------------------------------------------- arithmetic, logic
        HEAD    w_plus, w_2rfrom, "+", 1, 0, 1
        ADD
        RET
        HEAD    w_minus, w_plus, "-", 1, 0, 1
        SUB
        RET
        HEAD    w_and, w_minus, "AND", 3, 0, 1
        AND
        RET
        HEAD    w_or, w_and, "OR", 2, 0, 1
        OR
        RET
        HEAD    w_xor, w_or, "XOR", 3, 0, 1
        XOR
        RET
        HEAD    w_invert, w_xor, "INVERT", 6, 0, 1
        INV
        RET
        HEAD    w_negate, w_invert, "NEGATE", 6, 0, 1
        NEG
        RET
        HEAD    w_1plus, w_negate, "1+", 2, 0, 1
        INC
        RET
        HEAD    w_1minus, w_1plus, "1-", 2, 0, 1
        DEC
        RET
        HEAD    w_2star, w_1minus, "2*", 2, 0, 1
        LSL
        RET
        HEAD    w_2slash, w_2star, "2/", 2, 0, 1
        ASR
        RET
        HEAD    w_cellplus, w_2slash, "CELL+", 5, 0, 1
        INCW
        RET
        HEAD    w_cells, w_cellplus, "CELLS", 5, 0, 2
        LSLI    2
        RET
        HEAD    w_charplus, w_cells, "CHAR+", 5, 0, 1
        INC
        RET
        HEAD    w_chars, w_charplus, "CHARS", 5, 0, 1
        NOP
        RET
        HEAD    w_abs, w_chars, "ABS", 3, 0, 3
        ABS
        RET
        HEAD    w_min, w_abs, "MIN", 3, 0, 5
        MIN3    T, S, T
        NIP
        RET
        HEAD    w_max, w_min, "MAX", 3, 0, 5
        MAX3    T, S, T
        NIP
        RET
        HEAD    w_lshift, w_max, "LSHIFT", 6, 0, 5
        LSL3    T, S, T
        NIP
        RET
        HEAD    w_rshift, w_lshift, "RSHIFT", 6, 0, 5
        LSR3    T, S, T
        NIP
        RET
        HEAD    w_star, w_rshift, "*", 1, 0, 2
        MUL
        NIP
        RET
        HEAD    w_umstar, w_star, "UM*", 3, 0, 2
        MUL
        SWAP
        RET
        HEAD    w_mstar, w_umstar, "M*", 2, 0, 2
        SMUL
        SWAP
        RET
        HEAD    w_stod, w_mstar, "S>D", 3, 0, 3
        DUP
        ASRI    31
        RET
        HEAD    w_ummod, w_stod, "UM/MOD", 6, 0, 0
        MOVR    r2, T                   ; ( ud u -- urem uquot )
        DROP
        MOVR    r1, T
        DROP
        MOVR    r0, T
        CMPI2   r2, 0
        B       EQ, divzero
        CALL    udiv
        MOVR    T, r3
        DUP
        MOVR    T, r0
        RET
        HEAD    w_smrem, w_ummod, "SM/REM", 6, 0, 0
        MOVR    r2, T                   ; ( d n -- rem quot ), symmetric
        DROP
        MOVR    r1, T
        DROP
        MOVR    r0, T
        CMPI2   r2, 0
        B       EQ, divzero
        MOV2    r5, r1                  ; the remainder's sign
        XOR3    r6, r1, r2              ; the quotient's
        CMPI2   r1, 0
        B       GE, @p1
        MOVI2   r7, 0                   ; |d|
        SUB3    r0, r7, r0
        SBC3    r1, r7, r1
@p1:    ABS     r2, r2
        CALL    udiv
        CMPI2   r6, 0
        B       GE, @p2
        MOVI2   r7, 0
        SUB3    r0, r7, r0
@p2:    CMPI2   r5, 0
        B       GE, @p3
        MOVI2   r7, 0
        SUB3    r3, r7, r3
@p3:    MOVR    T, r3
        DUP
        MOVR    T, r0
        RET
        HEAD    w_fmmod, w_smrem, "FM/MOD", 6, 0, 0
        MOV2    r12, T                  ; ( d n -- rem quot ), floored
        CALL    w_smrem
        CMPI2   S, 0
        B       EQ, @r
        XOR3    r0, S, r12
        B       PL, @r
        DEC
        ADD2    S, r12
@r:     RET
        HEAD    w_slashmod, w_fmmod, "/MOD", 4, 0, 0
        MOVR    r8, T                   ; ( n1 n2 -- rem quot )
        DROP
        DUP
        ASRI    31
        DUP
        MOVR    T, r8
        B       A, w_smrem
        HEAD    w_slash, w_slashmod, "/", 1, 0, 0
        CALL    w_slashmod
        NIP
        RET
        HEAD    w_mod, w_slash, "MOD", 3, 0, 0
        CALL    w_slashmod
        DROP
        RET
        HEAD    w_ssmod, w_mod, "*/MOD", 5, 0, 0
        PUSH                            ; ( n1 n2 n3 -- rem quot ), n1 * n2 in 64 bits
        DROP
        SMUL
        SWAP
        DUP
        POP
        B       A, w_smrem
        HEAD    w_starslash, w_ssmod, "*/", 2, 0, 0
        CALL    w_ssmod
        NIP
        RET

; ---------------------------------------------------------------- comparisons
        HEAD    w_equal, w_starslash, "=", 1, 0, 4
        CMP
        NIP
        SET     EQ
        RET
        HEAD    w_nequal, w_equal, "<>", 2, 0, 4
        CMP
        NIP
        SET     NE
        RET
        HEAD    w_less, w_nequal, "<", 1, 0, 4
        CMP
        NIP
        SET     LT
        RET
        HEAD    w_greater, w_less, ">", 1, 0, 4
        CMP
        NIP
        SET     GT
        RET
        HEAD    w_uless, w_greater, "U<", 2, 0, 4
        CMP
        NIP
        SET     LO
        RET
        HEAD    w_ugreater, w_uless, "U>", 2, 0, 4
        CMP
        NIP
        SET     HI
        RET
        HEAD    w_zequal, w_ugreater, "0=", 2, 0, 2
        SET     TZ
        RET
        HEAD    w_znequal, w_zequal, "0<>", 3, 0, 3
        SET     TZ
        INV
        RET
        HEAD    w_zless, w_znequal, "0<", 2, 0, 2
        ASRI    31
        RET
        HEAD    w_zgreater, w_zless, "0>", 2, 0, 5
        CMPI2   T, 0
        SET     GT
        RET
        HEAD    w_lesseq, w_zgreater, "<=", 2, 0, 4
        CMP
        NIP
        SET     LE
        RET
        HEAD    w_greatereq, w_lesseq, ">=", 2, 0, 4
        CMP
        NIP
        SET     GE
        RET
        HEAD    w_ulesseq, w_greatereq, "U<=", 3, 0, 4
        CMP
        NIP
        SET     LS
        RET
        HEAD    w_ugreatereq, w_ulesseq, "U>=", 3, 0, 4
        CMP
        NIP
        SET     HS
        RET
        HEAD    w_zlesseq, w_ugreatereq, "0<=", 3, 0, 5
        CMPI2   T, 0
        SET     LE
        RET
        HEAD    w_zgreatereq, w_zlesseq, "0>=", 3, 0, 3
        ASRI    31                      ; -1 if negative, then the other way
        INV
        RET
        HEAD    w_within, w_zgreatereq, "WITHIN", 6, 0, 11
        OVER                            ; ( x lo hi -- f ): x - lo U< hi - lo
        SUB
        PUSH
        DROP
        SUB
        DUP
        POP
        CMP
        NIP
        SET     LO
        RET
        HEAD    w_true, w_within, "TRUE", 4, 0, 3
        DUP
        LIT8    -1
        RET
        HEAD    w_false, w_true, "FALSE", 5, 0, 3
        DUP
        LIT8    0
        RET
        HEAD    w_bl, w_false, "BL", 2, 0, 3
        DUP
        LIT8    ' '
        RET

; ---------------------------------------------------------------- memory
        HEAD    w_fetch, w_bl, "@", 1, 0, 3
        LDR     T, T
        RET
        HEAD    w_store, w_fetch, "!", 1, 0, 5
        STR     S, T
        DROP
        DROP
        RET
        HEAD    w_cfetch, w_store, "C@", 2, 0, 3
        LDRB    T, T
        RET
        HEAD    w_cstore, w_cfetch, "C!", 2, 0, 5
        STRB    S, T
        DROP
        DROP
        RET
        HEAD    w_plusstore, w_cstore, "+!", 2, 0, 11
        LDR     r0, T
        ADD2    r0, S
        STR     r0, T
        DROP
        DROP
        RET
        HEAD    w_2fetch, w_plusstore, "2@", 2, 0, 9
        DUP
        LDR3    T, T, 4
        SWAP
        LDR     T, T
        RET
        HEAD    w_2store, w_2fetch, "2!", 2, 0, 14
        STR     S, T
        LDR3    r0, PSP, 4
        STR3    r0, T, 4
        DROP
        DROP
        DROP
        RET
        HEAD    w_count, w_2store, "COUNT", 5, 0, 7
        LDRB    r0, T
        INC
        DUP
        MOVR    T, r0
        RET
        HEAD    w_sstring, w_count, "/STRING", 7, 0, 8
        MOVR    r0, T
        DROP
        SUBR    T, r0
        ADD2    S, r0
        RET
        HEAD    w_cmove, w_sstring, "CMOVE", 5, 0, 0
        MOVR    r2, T                   ; ( from to n -- ), upwards
        DROP
        MOVR    r1, T
        DROP
        MOVR    r0, T
        DROP
cmove_up:
        CMPI2   r2, 0
        B       LE, @r
        LDRB    r3, r0
        STRB    r3, r1
        INCR    r0
        INCR    r1
        DECR    r2
        B       A, cmove_up
@r:     RET
        HEAD    w_cmoveup, w_cmove, "CMOVE>", 6, 0, 0
        MOVR    r2, T                   ; ( from to n -- ), downwards
        DROP
        MOVR    r1, T
        DROP
        MOVR    r0, T
        DROP
cmove_down:
        ADD2    r0, r2
        ADD2    r1, r2
@l:     CMPI2   r2, 0
        B       LE, @r
        DECR    r0
        DECR    r1
        LDRB    r3, r0
        STRB    r3, r1
        DECR    r2
        B       A, @l
@r:     RET
        HEAD    w_move, w_cmoveup, "MOVE", 4, 0, 0
        MOVR    r2, T                   ; ( from to n -- ), either way
        DROP
        MOVR    r1, T
        DROP
        MOVR    r0, T
        DROP
        CMP2    r1, r0
        B       HI, cmove_down
        B       A, cmove_up
        HEAD    w_fill, w_move, "FILL", 4, 0, 0
        MOVR    r2, T                   ; ( a n c -- )
        DROP
        MOVR    r1, T
        DROP
        MOVR    r0, T
        DROP
@l:     CMPI2   r1, 0
        B       LE, @r
        STRB    r2, r0
        INCR    r0
        DECR    r1
        B       A, @l
@r:     RET

; ---------------------------------------------------------------- variables
        USERV   w_base, w_fill, "BASE", 4, U_BASE
        USERV   w_state, w_base, "STATE", 5, U_STATE
        USERV   w_toin, w_state, ">IN", 3, U_IN
        GLOBV   w_frames, w_toin, "FRAMES", 6, G_FRAMES
        HEAD    w_hex, w_frames, "HEX", 3, 0, 0
        MOVI2   r0, 16
        STR3    r0, r31, U_BASE
        RET
        HEAD    w_decimal, w_hex, "DECIMAL", 7, 0, 0
        MOVI2   r0, 10
        STR3    r0, r31, U_BASE
        RET
        HEAD    w_pad, w_decimal, "PAD", 3, 0, 5
        DUP
        LDR3    T, r31, U_PAD
        RET
        HEAD    w_source, w_pad, "SOURCE", 6, 0, 10
        DUP
        LDR3    T, r31, U_SOURCE
        DUP
        LDR3    T, r31, U_NSOURCE
        RET

; ---------------------------------------------------------------- the dictionary
        HEAD    w_here, w_source, "HERE", 4, 0, 5
        DUP
        LDR3    T, r31, U_DP
        RET
        HEAD    w_allot, w_here, "ALLOT", 5, 0, 0
        LDR3    r0, r31, U_DP
        ADD2    r0, T
        STR3    r0, r31, U_DP
        DROP
        RET
        HEAD    w_align, w_allot, "ALIGN", 5, 0, 0
        LDR3    r0, r31, U_DP
        ADDI2   r0, 3
        MOVI2   r1, -4
        AND2    r0, r1
        STR3    r0, r31, U_DP
        RET
        HEAD    w_aligned, w_align, "ALIGNED", 7, 0, 8
        ADDI2   T, 3
        MOVI2   r0, -4
        ANDR    T, r0
        RET
        HEAD    w_comma, w_aligned, ",", 1, 0, 0
        LDR3    r0, r31, U_DP           ; ( x -- ), at HERE aligned
        ADDI2   r0, 3
        MOVI2   r1, -4
        AND2    r0, r1
        STR     T, r0
        INCWR   r0
        STR3    r0, r31, U_DP
        DROP
        RET
        HEAD    w_ccomma, w_comma, "C,", 2, 0, 0
        LDR3    r0, r31, U_DP
        STRB    T, r0
        INCR    r0
        STR3    r0, r31, U_DP
        DROP
        RET
        HEAD    w_unused, w_ccomma, "UNUSED", 6, 0, 0
        DUP
        LDR3    r0, r31, U_DP
        LDR3    T, r30, G_DICTEND
        SUBR    T, r0
        RET
        HEAD    w_tobody, w_unused, ">BODY", 5, 0, 3
        ADDI2   T, BODY
        RET
        HEAD    w_execute, w_tobody, "EXECUTE", 7, 0, 0
        PUSH                            ; R = xt: RET jumps there, it returns to our
        DROP                            ; caller
        RET

; ---------------------------------------------------------------- tasks
        HEAD    w_pause, w_execute, "PAUSE", 5, 0, 0
        DUP                             ; T and S into memory
        DUP
        PUSH                            ; R (where this task goes on) too
        MOV2    r0, PSP
        STR3    r0, r31, U_SPSAVE
        MOV2    r0, RSP
        STR3    r0, r31, U_RPSAVE
        MOV2    r0, FP
        STR3    r0, r31, U_FPSAVE
        MOV2    r1, r31                 ; where the round starts
@again: CLI
@scan:  LDR3    r31, r31, U_LINK        ; the next task ...
        LDR3    r0, r31, U_STATUS
        CMPI2   r0, 0
        B       NE, @run                ; ... that is awake
        CMP2    r31, r1
        B       NE, @scan
        WAIT                            ; none: wait for an interrupt (with I = 0:
        SEI                             ; no wake-up is lost), then let it in: fetch
        B       A, @again               ; injects it at the branch's target, before
                                        ; the CLI (isa.md, WAIT)
@run:   LDR3    r0, r31, U_PSPL         ; its limits, then its stacks
        MOV2    PSPL, r0
        LDR3    r0, r31, U_PSPH
        MOV2    PSPH, r0
        LDR3    r0, r31, U_RSPL
        MOV2    RSPL, r0
        LDR3    r0, r31, U_RSPH
        MOV2    RSPH, r0
        LDR3    r0, r31, U_FPSAVE
        MOV2    FP, r0
        LDR3    r0, r31, U_RPSAVE
        MOV2    RSP, r0
        LDR3    r0, r31, U_SPSAVE
        MOV2    PSP, r0
        SEI
        POP                             ; R: where it goes on
        DROP
        DROP                            ; T, S
        RET
        HEAD    w_stop, w_pause, "STOP", 4, 0, 0
        MOVI2   r0, 0
        STR3    r0, r31, U_STATUS
        B       A, w_pause
        HEAD    w_wake, w_stop, "WAKE", 4, 0, 0
        MOVI2   r0, 1                   ; ( task -- )
        STR3    r0, T, U_STATUS
        DROP
        RET
        HEAD    w_sleep, w_wake, "SLEEP", 5, 0, 0
        MOVI2   r0, 0
        STR3    r0, T, U_STATUS
        DROP
        RET

; ---------------------------------------------------------------- the terminal
        HEAD    w_emit, w_sleep, "EMIT", 4, 0, 0
        DUP                             ; the task's 'EMIT
        LDR3    T, r31, U_EMIT
        PUSH
        DROP
        RET
        HEAD    w_key, w_emit, "KEY", 3, 0, 0
        DUP                             ; the task's 'KEY
        LDR3    T, r31, U_KEY
        PUSH
        DROP
        RET
        HEAD    w_keyq, w_key, "KEY?", 4, 0, 0
        DUP
        LDR3    r0, r30, G_INTAIL
        LDR3    r1, r30, G_INHEAD
        CMP2    r0, r1
        SET     NE
        RET
; (EMIT) ( c -- ): into the serial port's output queue (asleep while it is full),
; then onto the screen
        HEAD    w_pemit, w_keyq, "(EMIT)", 6, 0, 0
@again: CLI
        LDR3    r1, r30, G_OUTHEAD
        MOV2    r2, r1
        INCR    r2
        LDR3    r3, r30, G_QMASK
        AND2    r2, r3
        LDR3    r3, r30, G_OUTTAIL
        CMP2    r2, r3
        B       NE, @room
        MOVI2   r4, 0                   ; full: asleep until the TX interrupt
        STR3    r4, r31, U_STATUS
        STR3    r31, r30, G_OUTWAIT
        SEI
        CALL    w_pause
        B       A, @again
@room:  LDR3    r4, r30, G_OUTQB
        ADD2    r4, r1
        STRB    T, r4
        STR3    r2, r30, G_OUTHEAD
        LDR3    r4, r30, G_UART
        MOVI2   r5, 3
        STR3    r5, r4, 12              ; CTRL: RXIE, TXIE
        SEI
        MOVR    r0, T
        DROP
        B       A, scr_putc
; (KEY) ( -- c ): the next character of the input queue (asleep while it is empty)
        HEAD    w_pkey, w_pemit, "(KEY)", 5, 0, 0
@again: CLI
        LDR3    r0, r30, G_INTAIL
        LDR3    r1, r30, G_INHEAD
        CMP2    r0, r1
        B       NE, @got
        MOVI2   r2, 0                   ; empty: asleep until a character comes
        STR3    r2, r31, U_STATUS
        STR3    r31, r30, G_INWAIT
        SEI
        CALL    cursor_on
        CALL    w_pause
        B       A, @again
@got:   LDR3    r1, r30, G_INQB
        ADD2    r1, r0
        INCR    r0
        LDR3    r2, r30, G_QMASK
        AND2    r0, r2
        STR3    r0, r30, G_INTAIL
        SEI
        DUP
        LDRB    T, r1
        B       A, cursor_off
        HEAD    w_type, w_pkey, "TYPE", 4, 0, 0
        CMPI2   T, 0                    ; ( a n -- )
        B       LE, @done
@l:     OVER
        LDRB    T, T
        CALL    w_emit
        INCR    S
        DEC
        B       NE, @l
@done:  DROP
        DROP
        RET
        HEAD    w_cr, w_type, "CR", 2, 0, 0
        PUSHL   13
        CALL    w_emit
        PUSHL   10
        B       A, w_emit
        HEAD    w_space, w_cr, "SPACE", 5, 0, 0
        PUSHL   ' '
        B       A, w_emit
        HEAD    w_spaces, w_space, "SPACES", 6, 0, 0
@l:     CMPI2   T, 0                    ; ( n -- )
        B       LE, @done
        CALL    w_space
        DEC
        B       A, @l
@done:  DROP
        RET
        HEAD    w_page, w_spaces, "PAGE", 4, 0, 0
        MOVI2   r0, 0                   ; the text window blank, not scrolled, the
        STR3    r0, r30, G_WOFF         ; cursor at its top (the rows outside it stay)
        CALL    set_scroll
        LDR3    r1, r30, G_WTOP
        CALL    row_addr
        MOV2    r4, r0
        LDR3    r1, r30, G_WROWS        ; rows * 80 - 1 words
        MOVI2   r2, 4
        LSL3    r3, r1, r2
        MOVI2   r2, 6
        LSL2    r1, r2
        ADD2    r1, r3
        DECR    r1
        MOV2    r7, r1
        CALL    blank_words
        MOVI2   r0, 0
        STR3    r0, r30, G_COL
        STR3    r0, r30, G_CURSOR
        LDR3    r0, r30, G_WTOP
        STR3    r0, r30, G_ROW
        RET
        HEAD    w_atxy, w_page, "AT-XY", 5, 0, 0
        MOVR    r1, T                   ; ( col row -- ): the screen's cursor
        DROP
        MOVR    r0, T
        DROP
        MOVI2   r2, 79
        MINU2   r0, r2
        MOVI2   r2, 59
        MINU2   r1, r2
        STR3    r0, r30, G_COL
        STR3    r1, r30, G_ROW
        RET
; TEXT-WINDOW ( top rows -- ): rows top .. top + rows - 1 are the text window, the
; rows that scroll; then PAGE (the window blank, the cursor at its top). top 0 .. 59,
; rows 1 .. 60 - top (clamped). The rows outside it keep their text and do not
; scroll: graphics (the mode RAM), a status line, ...
        HEAD    w_twin, w_atxy, "TEXT-WINDOW", 11, 0, 0
        MOVR    r1, T                   ; rows
        DROP
        MOVR    r0, T                   ; top
        DROP
        MOVI2   r2, 59
        MINU2   r0, r2
        MOVI2   r2, 60
        SUB2    r2, r0                  ; the rows from top down
        MINU2   r1, r2
        CMPI2   r1, 0
        B       NE, @ok
        MOVI2   r1, 1
@ok:    STR3    r0, r30, G_WTOP
        STR3    r1, r30, G_WROWS
        B       A, w_page
; TEXT-WINDOW@ ( -- top rows ): the text window
        HEAD    w_twinat, w_twin, "TEXT-WINDOW@", 12, 0, 0
        DUP
        LDR3    T, r30, G_WTOP
        DUP
        LDR3    T, r30, G_WROWS
        RET
        HEAD    w_accept, w_twinat, "ACCEPT", 6, 0, 0
        OVER                            ; ( a n -- n' ): a line, edited with BS
        ADD
        OVER                            ; ( a end p )
@loop:  CALL    w_key                   ; ( a end p c )
        CMPI2   T, 13
        B       EQ, @cr
        CMPI2   T, 10
        B       EQ, @lf
        MOVI2   r0, 0
        STR3    r0, r30, G_CRLF
        CMPI2   T, 8
        B       EQ, @bs
        CMPI2   T, 127
        B       EQ, @bs
        CMPI2   T, ' '
        B       LO, @drop               ; other control codes
        LDR3    r0, PSP, 4              ; the end
        CMP2    S, r0
        B       HS, @drop               ; full
        STRB    T, S
        INCR    S
        CALL    w_emit                  ; the echo
        B       A, @loop
@drop:  DROP
        B       A, @loop
@bs:    DROP                            ; ( a end p )
        LDR3    r0, PSP, 4              ; a
        CMP2    T, r0
        B       LS, @loop
        DEC
        PUSHL   8
        CALL    w_emit
        PUSHL   ' '
        CALL    w_emit
        PUSHL   8
        CALL    w_emit
        B       A, @loop
@lf:    LDR3    r0, r30, G_CRLF         ; the LF of a CR LF: nothing
        CMPI2   r0, 0
        MOVI2   r0, 0
        STR3    r0, r30, G_CRLF
        B       NE, @drop
        B       A, @end
@cr:    MOVI2   r0, 1
        STR3    r0, r30, G_CRLF
@end:   DROP                            ; ( a end p )
        NIP
        SWAP
        SUB                             ; p - a
        PUSHL   ' '
        B       A, w_emit

; ---------------------------------------------------------------- numbers out
        HEAD    w_hold, w_accept, "HOLD", 4, 0, 0
        LDR3    r0, r31, U_HLD          ; ( c -- )
        DECR    r0
        STRB    T, r0
        STR3    r0, r31, U_HLD
        DROP
        RET
        HEAD    w_lessnum, w_hold, "<#", 2, 0, 0
        LDR3    r0, r31, U_HOLD
        STR3    r0, r31, U_HLD
        RET
        HEAD    w_sharp, w_lessnum, "#", 1, 0, 0
        MOVR    r1, T                   ; ( ud -- ud' ): one digit
        DROP
        MOVR    r0, T
        LDR3    r2, r31, U_BASE
        CALL    udiv
        MOVR    T, r0
        DUP
        MOVR    T, r1
        CMPI2   r3, 10
        B       LO, @d
        ADDI2   r3, 7
@d:     ADDI2   r3, '0'
        LDR3    r4, r31, U_HLD
        DECR    r4
        STRB    r3, r4
        STR3    r4, r31, U_HLD
        RET
        HEAD    w_sharps, w_sharp, "#S", 2, 0, 0
@l:     CALL    w_sharp
        OVER
        OVER
        OR
        DROP
        B       NE, @l
        RET
        HEAD    w_numgreater, w_sharps, "#>", 2, 0, 0
        LDR3    r0, r31, U_HLD          ; ( ud -- a n )
        LDR3    r1, r31, U_HOLD
        MOV2    S, r0
        SUB3    T, r1, r0
        RET
        HEAD    w_sign, w_numgreater, "SIGN", 4, 0, 0
        CMPI2   T, 0
        DROP
        B       GE, @r
        PUSHL   '-'
        B       A, w_hold
@r:     RET
        HEAD    w_dot, w_sign, ".", 1, 0, 0
        DUP
        ABS
        PUSHL   0
        CALL    w_lessnum
        CALL    w_sharps
        ROT
        CALL    w_sign
        CALL    w_numgreater
        CALL    w_type
        B       A, w_space
        HEAD    w_udot, w_dot, "U.", 2, 0, 0
        PUSHL   0
        CALL    w_lessnum
        CALL    w_sharps
        CALL    w_numgreater
        CALL    w_type
        B       A, w_space
        HEAD    w_dotr, w_udot, ".R", 2, 0, 0
        PUSH                            ; ( n w -- )
        DROP
        DUP
        ABS
        PUSHL   0
        CALL    w_lessnum
        CALL    w_sharps
        ROT
        CALL    w_sign
        CALL    w_numgreater
        DUP
        POP
        OVER
        SUB
        CALL    w_spaces
        B       A, w_type
        HEAD    w_udotr, w_dotr, "U.R", 3, 0, 0
        PUSH                            ; ( u w -- )
        DROP
        PUSHL   0
        CALL    w_lessnum
        CALL    w_sharps
        CALL    w_numgreater
        DUP
        POP
        OVER
        SUB
        CALL    w_spaces
        B       A, w_type
        HEAD    w_question, w_udotr, "?", 1, 0, 0
        LDR     T, T
        B       A, w_dot
; hexdot ( u -- ): 8 hex digits
hexdot: LDR3    r0, r31, U_BASE
        DUP
        MOVR    T, r0
        PUSH
        DROP
        MOVI2   r0, 16
        STR3    r0, r31, U_BASE
        PUSHL   0
        CALL    w_lessnum
        .rept   8
        CALL    w_sharp
        .endr
        CALL    w_numgreater
        CALL    w_type
        DUP
        POP
        STR3    T, r31, U_BASE
        DROP
        RET
        HEAD    w_dots, w_question, ".S", 2, 0, 0
        CALL    w_depth                 ; ( -- ): the stack, bottom first
        PUSHL   '['
        CALL    w_emit
        DUP
        PUSHL   0
        CALL    w_lessnum
        CALL    w_sharps
        CALL    w_numgreater
        CALL    w_type
        PUSHL   ']'
        CALL    w_emit
        CALL    w_space
        CMPI2   T, 0
        B       LE, @none
        PUSH
        DROP                            ; R: the count
@l:     DECR    R
        DUP
        MOVR    T, R
        CALL    w_pick
        CALL    w_dot
        CMPI2   R, 0
        B       NE, @l
        DUP
        POP
@none:  DROP
        RET
        HEAD    w_dump, w_dots, "DUMP", 4, 0, 0
        LDR3    r0, r31, U_BASE         ; ( a n -- ): bytes in hex
        DUP
        MOVR    T, r0
        PUSH
        DROP
        MOVI2   r0, 16
        STR3    r0, r31, U_BASE
@line:  CMPI2   T, 0
        B       LE, @end
        CALL    w_cr
        OVER
        PUSHL   9
        CALL    w_udotr
        PUSHL   0                       ; ( a n j )
@byte:  CMPI2   T, 16
        B       GE, @next
        CMP                             ; n - j
        B       LE, @next
        DUP
        LDR3    r0, PSP, 8              ; a
        ADDR    T, r0
        LDRB    T, T
        PUSHL   3
        CALL    w_udotr
        INC
        B       A, @byte
@next:  DROP
        PUSHL   16
        SUB
        SWAP
        ADDI2   T, 16
        SWAP
        B       A, @line
@end:   DROP
        DROP
        DUP
        POP
        STR3    T, r31, U_BASE
        DROP
        B       A, w_cr

; ---------------------------------------------------------------- numbers in
; NUMBER? ( a n -- x -1 | 0 ): a number in BASE, with - in front, $ # % for hex,
; decimal, binary, or a character as 'c'
        HEAD    w_number, w_dump, "NUMBER?", 7, 0, 0
        MOVR    r1, T
        DROP
        MOVR    r0, T
        LDR3    r2, r31, U_BASE
        MOVI2   r3, 0                   ; negative?
        MOVI2   r5, 0                   ; the value
        CMPI2   r1, 0
        B       EQ, @fail
        CMPI2   r1, 3                   ; 'c'
        B       NE, @pre
        LDRB    r4, r0
        CMPI2   r4, 39
        B       NE, @pre
        LDRB3   r4, r0, 2
        CMPI2   r4, 39
        B       NE, @pre
        LDRB3   r5, r0, 1
        B       A, @ok
@pre:   LDRB    r4, r0
        CMPI2   r4, '$'
        B       NE, @p1
        MOVI2   r2, 16
        B       A, @skip
@p1:    CMPI2   r4, '#'
        B       NE, @p2
        MOVI2   r2, 10
        B       A, @skip
@p2:    CMPI2   r4, '%'
        B       NE, @sign
        MOVI2   r2, 2
@skip:  INCR    r0
        DECR    r1
        B       EQ, @fail
@sign:  LDRB    r4, r0
        CMPI2   r4, '-'
        B       NE, @dig
        MOVI2   r3, 1
        INCR    r0
        DECR    r1
        B       EQ, @fail
@dig:   LDRB    r4, r0
        CMPI2   r4, '0'
        B       LO, @fail
        CMPI2   r4, '9'
        B       HI, @alpha
        ADDI2   r4, -'0'
        B       A, @have
@alpha: CMPI2   r4, 'a'
        B       LO, @up
        ADDI2   r4, -32
@up:    CMPI2   r4, 'A'
        B       LO, @fail
        ADDI2   r4, -55
@have:  CMP2    r4, r2
        B       HS, @fail
        MOV2    r6, T                   ; r5 = r5 * base + digit
        MOV2    r7, S
        MOV2    T, r5
        MOV2    S, r2
        MUL
        MOV2    r5, T
        MOV2    T, r6
        MOV2    S, r7
        ADD2    r5, r4
        INCR    r0
        DECR    r1
        B       NE, @dig
@ok:    CMPI2   r3, 0
        B       EQ, @pos
        MOVI2   r6, 0
        SUB3    r5, r6, r5
@pos:   MOVR    T, r5
        PUSHL   -1
        RET
@fail:  MOVI2   T, 0
        RET

; ---------------------------------------------------------------- parsing
        HEAD    w_parsename, w_number, "PARSE-NAME", 10, 0, 0
        LDR3    r0, r31, U_SOURCE       ; ( -- a n ): the next word (0 at the end)
        LDR3    r1, r31, U_NSOURCE
        LDR3    r2, r31, U_IN
@skip:  CMP2    r2, r1
        B       HS, @end0
        ADD3    r3, r0, r2
        LDRB    r3, r3
        CMPI2   r3, ' '
        B       HI, @word
        INCR    r2
        B       A, @skip
@word:  MOV2    r4, r2
@scan:  INCR    r2
        CMP2    r2, r1
        B       HS, @end
        ADD3    r3, r0, r2
        LDRB    r3, r3
        CMPI2   r3, ' '
        B       HI, @scan
        SUB3    r5, r2, r4
        INCR    r2                      ; past the space
        B       A, @set
@end:   SUB3    r5, r2, r4
        B       A, @set
@end0:  MOV2    r4, r2
        MOVI2   r5, 0
@set:   STR3    r2, r31, U_IN
        ADD2    r4, r0
        DUP
        MOVR    T, r4
        DUP
        MOVR    T, r5
        RET
        HEAD    w_parse, w_parsename, "PARSE", 5, 0, 0
        MOVR    r6, T                   ; ( c -- a n ): up to c (or the end)
        LDR3    r0, r31, U_SOURCE
        LDR3    r1, r31, U_NSOURCE
        LDR3    r2, r31, U_IN
        MOV2    r4, r2
@scan:  CMP2    r2, r1
        B       HS, @end
        ADD3    r3, r0, r2
        LDRB    r3, r3
        CMP2    r3, r6
        B       EQ, @found
        INCR    r2
        B       A, @scan
@found: SUB3    r5, r2, r4
        INCR    r2
        B       A, @set
@end:   SUB3    r5, r2, r4
@set:   STR3    r2, r31, U_IN
        ADD2    r4, r0
        MOVR    T, r4
        DUP
        MOVR    T, r5
        RET
        HEAD    w_word, w_parse, "WORD", 4, 0, 0
        MOVR    r6, T                   ; ( c -- c-addr ): a counted string in 'WORD
        LDR3    r0, r31, U_SOURCE
        LDR3    r1, r31, U_NSOURCE
        LDR3    r2, r31, U_IN
@skip:  CMP2    r2, r1                  ; c in front: skipped (BL: any control code)
        B       HS, @start
        ADD3    r3, r0, r2
        LDRB    r3, r3
        CMPI2   r6, ' '
        B       NE, @exact
        CMPI2   r3, ' '
        B       HI, @start
        B       A, @next
@exact: CMP2    r3, r6
        B       NE, @start
@next:  INCR    r2
        B       A, @skip
@start: MOV2    r4, r2
@scan:  CMP2    r2, r1
        B       HS, @end
        ADD3    r3, r0, r2
        LDRB    r3, r3
        CMPI2   r6, ' '
        B       NE, @ex2
        CMPI2   r3, ' '
        B       LS, @found
        B       A, @nx
@ex2:   CMP2    r3, r6
        B       EQ, @found
@nx:    INCR    r2
        B       A, @scan
@found: SUB3    r5, r2, r4
        INCR    r2
        B       A, @copy
@end:   SUB3    r5, r2, r4
@copy:  STR3    r2, r31, U_IN
        ADD2    r4, r0
        LDR3    r7, r31, U_WORD
        MOVI2   r8, 127
        ADDI2   r8, 127
        INCR    r8
        MINU2   r5, r8                  ; at most 255
        STRB    r5, r7
        MOV2    r8, r7
        INCR    r8
        MOV2    r9, r5
@cp:    CMPI2   r9, 0
        B       EQ, @cpe
        LDRB    r3, r4
        STRB    r3, r8
        INCR    r4
        INCR    r8
        DECR    r9
        B       A, @cp
@cpe:   MOVI2   r3, ' '
        STRB    r3, r8
        MOVR    T, r7
        RET
        HEAD    w_char, w_word, "CHAR", 4, 0, 0
        CALL    w_parsename
        DROP
        LDRB    T, T
        RET
        HEAD    w_paren, w_char, "(", 1, F_IMMEDIATE, 0
        PUSHL   ')'
        CALL    w_parse
        DROP
        DROP
        RET
; // a line comment (as in C++): to the end of the line
        HEAD    w_slashslash, w_paren, "//", 2, F_IMMEDIATE, 0
        LDR3    r0, r30, G_BLK          ; LOADing a block: to the end of its line
        CMPI2   r0, 0
        B       NE, @blk
        LDR3    r0, r31, U_NSOURCE      ; else: to the end of the source
        STR3    r0, r31, U_IN
        RET
@blk:   LDR3    r0, r31, U_IN           ; to the next multiple of SRC_COLS
        ADDI2   r0, SRC_COLS - 1
        MOVI2   r1, 0
        MOVI2   r2, SRC_COLS
        CALL    udiv
        MOVI2   r1, 6                   ; * 72 = * 64 + * 8
        LSL3    r2, r0, r1
        MOVI2   r1, 3
        LSL3    r3, r0, r1
        ADD3    r0, r2, r3
        STR3    r0, r31, U_IN
        RET
; /* a comment (as in C) up to */, over lines: in a block or EVALUATE up to the
; source's end at most; at the terminal it reads the next lines until the */ comes
        HEAD    w_slashstar, w_slashslash, "/*", 2, F_IMMEDIATE, 0
@scan:  LDR3    r0, r31, U_SOURCE
        LDR3    r1, r31, U_NSOURCE
        LDR3    r2, r31, U_IN
@l:     MOV2    r3, r2
        INCR    r3
        CMP2    r3, r1                  ; two characters left?
        B       HS, @end
        ADD3    r3, r0, r2
        LDRB    r4, r3
        INCR    r2
        CMPI2   r4, '*'
        B       NE, @l
        LDRB3   r4, r3, 1
        CMPI2   r4, '/'
        B       NE, @l
        INCR    r2                      ; past the */
        STR3    r2, r31, U_IN
        RET
@end:   STR3    r1, r31, U_IN           ; the source is over
        LDR3    r0, r31, U_SOURCEID
        CMPI2   r0, 0
        B       NE, @r                  ; not the terminal: the comment ends here
        CALL    w_cr
        CALL    refill                  ; the terminal: its next line
        B       A, @scan
@r:     RET
; refill: the next line from the terminal into the TIB, the source
refill: LDR3    r0, r31, U_TIB
        STR3    r0, r31, U_SOURCE
        DUP
        MOVR    T, r0
        PUSHL   OP_TIB_SIZE
        CALL    w_accept
        STR3    T, r31, U_NSOURCE
        STR3    T, r31, U_NTIB
        DROP
        MOVI2   r0, 0
        STR3    r0, r31, U_IN
        RET
        HEAD    w_dotparen, w_slashstar, ".(", 2, F_IMMEDIATE, 0
        PUSHL   ')'
        CALL    w_parse
        B       A, w_type

; ---------------------------------------------------------------- finding words
; (FIND) ( a n -- a n 0 | xt h -1 ): the word named a n in the search order; h is its
; header cell. Names are compared without case (they are kept in capitals).
        HEAD    w_sfind, w_dotparen, "(FIND)", 6, 0, 0
        MOVR    r1, T
        MOV2    r0, S
        LDR3    r9, r31, U_NORDER
        MOV2    r8, r31
        ADDI2   r8, U_CONTEXT
        LDA     r11, H_LINK_MASK
@wl:    CMPI2   r9, 0
        B       EQ, @none
        LDR     r2, r8
        LDR     r2, r2                  ; the word list's newest word
@w:     CMPI2   r2, 0
        B       EQ, @nextwl
        LDR3    r3, r2, -4              ; its header cell
        MOVI2   r4, H_LEN_SHIFT
        LSR3    r4, r3, r4
        CMP2    r4, r1
        B       NE, @link
        MOVI2   r4, F_HIDDEN
        AND2    r4, r3
        B       NE, @link
        SUB3    r5, r2, r1              ; its name
        ADDI2   r5, -4
        MOV2    r6, r0
        MOV2    r7, r1
@c:     LDRB    r4, r5
        LDRB    r10, r6
        CMPI2   r10, 'a'
        B       LO, @f
        CMPI2   r10, 'z'
        B       HI, @f
        ADDI2   r10, -32
@f:     CMP2    r4, r10
        B       NE, @link
        INCR    r5
        INCR    r6
        DECR    r7
        B       NE, @c
        MOV2    S, r2                   ; found
        MOVR    T, r3
        PUSHL   -1
        RET
@link:  AND3    r2, r3, r11
        B       A, @w
@nextwl:
        INCWR   r8
        DECR    r9
        B       A, @wl
@none:  PUSHL   0
        RET
        HEAD    w_find, w_sfind, "FIND", 4, 0, 0
        DUP                             ; ( c-addr -- c-addr 0 | xt 1 | xt -1 )
        CALL    w_count
        CALL    w_sfind
        CMPI2   T, 0
        B       EQ, @no
        DROP                            ; ( c xt h )
        MOVI2   r0, F_IMMEDIATE
        ANDR    T, r0
        B       NE, @imm
        MOVI2   T, -1
        B       A, @r
@imm:   MOVI2   T, 1
@r:     ROT
        DROP
        RET
@no:    NIP
        NIP
        RET
        HEAD    w_tick, w_find, "'", 1, 0, 0
        CALL    w_parsename             ; ( "name" -- xt )
        CALL    w_sfind
        CMPI2   T, 0
        B       EQ, undefined
        DROP
        DROP
        RET
; undefined ( a n 0 -- ): THROW -13 about the word a n (-16: no word)
undefined:
        DROP
        STR3    T, r30, G_ERRLEN
        CMPI2   T, 0
        DROP
        STR3    T, r30, G_ERRADDR
        MOVI2   T, -16
        B       EQ, w_throw
        MOVI2   T, -13
        B       A, w_throw
        HEAD    w_words, w_tick, "WORDS", 5, 0, 0
        LDR3    r0, r31, U_CONTEXT      ; the first word list of the search order
        LDR     r0, r0
        DUP
        MOVR    T, r0                   ; ( xt )
        MOVI2   r1, 0
        DUP
        MOVR    T, r1
        PUSH                            ; R: the column
        DROP
@l:     CMPI2   T, 0
        B       EQ, @end
        LDR3    r0, T, -4
        MOVI2   r1, H_LEN_SHIFT
        LSR3    r2, r0, r1              ; its length
        MOVI2   r1, F_HIDDEN
        AND2    r1, r0
        B       NE, @next
        ADD3    r3, R, r2
        INCR    r3
        CMPI2   r3, 79
        B       LE, @fit
        CALL    w_cr
        LDR3    r0, T, -4
        MOVI2   r1, H_LEN_SHIFT
        LSR3    r2, r0, r1
        MOV2    r3, r2
        INCR    r3
@fit:   MOV2    R, r3
        DUP
        SUB3    T, T, r2
        ADDI2   T, -4
        DUP
        MOVR    T, r2
        CALL    w_type
        CALL    w_space
@next:  LDR3    r0, T, -4
        LDA     r1, H_LINK_MASK
        AND3    T, r0, r1
        B       A, @l
@end:   DROP
        DUP
        POP
        DROP
        B       A, w_cr

; ---------------------------------------------------------------- the interpreter
        HEAD    w_interpret, w_words, "INTERPRET", 9, 0, 0
@l:     CALL    w_parsename             ; ( a n )
        CMPI2   T, 0
        B       EQ, @done
        CALL    w_sfind
        CMPI2   T, 0
        DROP
        B       EQ, @num
        LDR3    r0, r31, U_STATE        ; ( xt h )
        CMPI2   r0, 0
        B       EQ, @exec
        MOVR    r1, T                   ; compiling
        MOVI2   r2, F_IMMEDIATE
        AND2    r1, r2
        B       NE, @exec2
        DROP
        CALL    w_compilecomma
        B       A, @l
@exec:  MOVR    r1, T                   ; interpreting
        MOVI2   r2, F_COMPILE
        AND2    r1, r2
        B       NE, @conly
@exec2: DROP
        CALL    w_execute
        B       A, @l
@conly: MOVR    r1, T                   ; a word only for compiling: its name
        MOVI2   r2, H_LEN_SHIFT
        LSR2    r1, r2
        MOV2    r3, S
        SUB2    r3, r1
        ADDI2   r3, -4
        STR3    r3, r30, G_ERRADDR
        STR3    r1, r30, G_ERRLEN
        MOVI2   T, -14
        B       A, w_throw
@num:   OVER                            ; ( a n )
        OVER
        CALL    w_number
        CMPI2   T, 0
        B       EQ, undefined
        DROP
        NIP
        NIP                             ; ( x )
        LDR3    r0, r31, U_STATE
        CMPI2   r0, 0
        B       EQ, @l
        MOVR    r6, T
        DROP
        CALL    c_lit
        B       A, @l
@done:  DROP
        DROP
        RET
        HEAD    w_evaluate, w_interpret, "EVALUATE", 8, 0, 0
        LDR3    r0, r31, U_SOURCE       ; ( a n -- ): the source kept on the return stack
        LDR3    r1, r31, U_NSOURCE
        LDR3    r2, r31, U_IN
        LDR3    r3, r31, U_SOURCEID
        DUP
        MOVR    T, r0
        PUSH
        MOVR    T, r1
        PUSH
        MOVR    T, r2
        PUSH
        MOVR    T, r3
        PUSH
        DROP
        STR3    T, r31, U_NSOURCE
        DROP
        STR3    T, r31, U_SOURCE
        DROP
        MOVI2   r0, 0
        STR3    r0, r31, U_IN
        MOVI2   r0, -1
        STR3    r0, r31, U_SOURCEID
        CALL    w_interpret
        DUP
        POP
        STR3    T, r31, U_SOURCEID
        POP
        STR3    T, r31, U_IN
        POP
        STR3    T, r31, U_NSOURCE
        POP
        STR3    T, r31, U_SOURCE
        DROP
        RET

; ---------------------------------------------------------------- CATCH and THROW
; CATCH ( xt -- 0 | n ) keeps a frame on the return stack: R (its return), S, T, PSP
; and the HANDLER before; HANDLER points at it. THROW goes back to it.
;   HANDLER + 4   the HANDLER before      + 8   PSP        + 12  T
;   HANDLER + 16  S                       + 20  the return address of CATCH
        HEAD    w_catch, w_evaluate, "CATCH", 5, 0, 0
        MOVR    r0, T                   ; the xt
        DROP
        PUSHS                           ; the return address into memory, R = S
        PUSH                            ; S into memory, R = T
        MOV2    r1, PSP
        DUP
        MOVR    T, r1
        PUSH                            ; T into memory, R = PSP
        DROP
        LDR3    r2, r31, U_HANDLER
        DUP
        MOVR    T, r2
        PUSH                            ; PSP into memory, R = the old HANDLER
        DROP
        PUSH                            ; the old HANDLER into memory
        MOV2    r3, RSP
        STR3    r3, r31, U_HANDLER
        DUP
        MOVR    T, r0
        PUSH
        DROP
        EXEC                            ; the xt
        LDR3    r1, r31, U_HANDLER      ; back without a THROW
        LDR3    r2, r1, 4
        STR3    r2, r31, U_HANDLER
        LDR3    R, r1, 20
        ADDI2   r1, 20
        MOV2    RSP, r1
        PUSHL   0
        RET
        HEAD    w_throw, w_catch, "THROW", 5, 0, 0
        CMPI2   T, 0                    ; ( n -- ): 0 does nothing
        B       NE, @t
        DROP
        RET
@t:     MOVR    r0, T
; throw_r0: THROW r0 (from the exceptions too)
throw_r0:
        LDR3    r1, r31, U_HANDLER
        CMPI2   r1, 0
        B       EQ, @nocatch
        LDR3    r2, r1, 4
        STR3    r2, r31, U_HANDLER
        LDR3    r3, r1, 8
        MOV2    PSP, r3
        LDR3    T, r1, 12
        LDR3    S, r1, 16
        LDR3    R, r1, 20
        ADDI2   r1, 20
        MOV2    RSP, r1
        DUP
        MOVR    T, r0
        RET                             ; out of CATCH, with n
@nocatch:
        LDR3    r1, r31, U_R0           ; no CATCH: say it, and QUIT
        MOV2    RSP, r1
        LDR3    r1, r31, U_S0
        MOV2    PSP, r1
        SEI
        DUP
        MOVR    T, r0
        CALL    error_msg
        B       A, w_quit
        HEAD    w_abort, w_throw, "ABORT", 5, 0, 0
        PUSHL   -1
        B       A, w_throw

; error_msg ( n -- ): what THROW n means
error_msg:
        CMPI2   T, -1
        B       EQ, @silent
        CMPI2   T, -2
        B       NE, @n13
        LDR3    r0, r30, G_ABORTMSG     ; ABORT" ..."
        DUP
        MOVR    T, r0
        CALL    w_count
        CALL    w_type
        B       A, @end
@n13:   CMPI2   T, -13
        B       NE, @n14
        CALL    errword
        ZDOTQ   " ?"
        B       A, @end
@n14:   CMPI2   T, -14
        B       NE, @table
        CALL    errword
        ZDOTQ   " compile only"
        B       A, @end
@table: LDA     r0, errtab
@tl:    LDR     r1, r0
        CMPI2   r1, 0
        B       EQ, @unknown
        CMPR    T, r1
        B       EQ, @found
        ADDI2   r0, 8
        B       A, @tl
@found: LDR3    r1, r0, 4
        DUP
        MOVR    T, r1
        CALL    ztype
        B       A, @exc
@unknown:
        ZDOTQ   "error "
        DUP
        CALL    w_dot
@exc:   MOVI2   r0, -128                ; -256 .. -258: where
        ADD2    r0, r0
        CMPR    T, r0
        B       GT, @end
        ADDI2   r0, -2
        CMPR    T, r0
        B       LT, @end
        ZDOTQ   " at "
        LDR3    r0, r30, G_EXCPC
        DUP
        MOVR    T, r0
        CALL    hexdot
@end:   CALL    w_cr
@silent:
        DROP
        RET
; errword: the word an error is about
errword:
        LDR3    r0, r30, G_ERRADDR
        LDR3    r1, r30, G_ERRLEN
        DUP
        MOVR    T, r0
        DUP
        MOVR    T, r1
        B       A, w_type

; ---------------------------------------------------------------- QUIT
        HEAD    w_quit, w_abort, "QUIT", 4, 0, 0
        LDR3    r0, r31, U_R0           ; the return stack empty
        MOV2    RSP, r0
        MOVI2   r0, 0
        STR3    r0, r31, U_STATE
        STR3    r0, r31, U_SOURCEID
        STR3    r0, r31, U_HANDLER
        SEI
@line:  MOVI2   r0, 0                   ; no block (BLK 0)
        STR3    r0, r30, G_BLK
        ZDOTQ   "> "                    ; the prompt
        CALL    refill                  ; a line into the TIB
        PUSHL   w_interpret
        CALL    w_catch
        CMPI2   T, 0
        B       NE, @err
        DROP
        LDR3    r0, r31, U_STATE
        CMPI2   r0, 0
        B       NE, @comp
        ZDOTQ   " ok"
@comp:  CALL    w_cr
        B       A, @line
@err:   CALL    error_msg
        LDR3    r0, r31, U_S0           ; the stack empty, interpreting
        MOV2    PSP, r0
        MOVI2   r0, 0
        STR3    r0, r31, U_STATE
        SEI
        B       A, @line
        HEAD    w_cold, w_quit, "COLD", 4, 0, 0
        MOVI2   r14, 0                  ; no loader's row: the cursor on row 8
        B       A, cold

; ---------------------------------------------------------------- defining words
; HEADER ( a n -- ): a header for the name a n, in CURRENT; HERE = its xt
        HEAD    w_header, w_cold, "HEADER", 6, 0, 0
        MOVR    r1, T
        DROP
        MOVR    r0, T
        DROP
        CMPI2   r1, 0
        B       EQ, @noname
        CMPI2   r1, NAME_MAX
        B       GT, @long
        LDR3    r2, r31, U_DP
        ADD3    r3, r2, r1              ; the padding: -(HERE + n + 4) & 15
        ADDI2   r3, 4
        MOVI2   r4, 0
        SUB3    r3, r4, r3
        MOVI2   r4, 15
        AND2    r3, r4
        MOVI2   r4, 0
@pad:   CMPI2   r3, 0
        B       EQ, @name
        STRB    r4, r2
        INCR    r2
        DECR    r3
        B       A, @pad
@name:  MOV2    r5, r1
@n:     LDRB    r4, r0                  ; the name in capitals
        CMPI2   r4, 'a'
        B       LO, @s
        CMPI2   r4, 'z'
        B       HI, @s
        ADDI2   r4, -32
@s:     STRB    r4, r2
        INCR    r0
        INCR    r2
        DECR    r5
        B       NE, @n
        LDR3    r6, r31, U_CURRENT      ; the header cell: the link and the length
        LDR     r7, r6
        MOVI2   r4, H_LEN_SHIFT
        LSL3    r8, r1, r4
        OR2     r8, r7
        STR     r8, r2
        INCWR   r2                      ; the xt
        STR     r2, r6                  ; the newest word of CURRENT
        STR3    r2, r30, G_LAST
        STR3    r2, r31, U_DP
        MOVI2   r0, 0
        STR3    r0, r30, G_CALLAT
        RET
@noname:
        MOVI2   r0, -16
        B       A, throw_r0
@long:  MOVI2   r0, -19
        B       A, throw_r0
        HEAD    w_colon, w_header, ":", 1, 0, 0
        CALL    w_parsename
        CALL    w_header
        LDR3    r0, r30, G_LAST         ; hidden until ;
        LDR3    r1, r0, -4
        MOVI2   r2, F_HIDDEN
        OR2     r1, r2
        STR3    r1, r0, -4
        MOVI2   r0, -1
        STR3    r0, r31, U_STATE
        LDA     r0, LEAVES
        STR3    r0, r30, G_LSP
        MOVI2   r0, 0
        STR3    r0, r30, G_CALLAT
        STR3    r0, r30, G_LABEL
        RET
        HEAD    w_semicolon, w_colon, ";", 1, F_IC, 0
        LDR3    r0, r31, U_DP           ; the last thing a call (and no branch to
        LDR3    r1, r30, G_CALLEND      ; the end)? then a jump instead
        CMP2    r0, r1
        B       NE, @ret
        LDR3    r1, r30, G_LABEL
        CMP2    r0, r1
        B       EQ, @ret
        LDR3    r1, r30, G_CALLAT
        CMPI2   r1, 0
        B       EQ, @ret
        STR3    r1, r31, U_DP
        LDR3    r6, r30, G_CALLXT
        MOVI2   r8, $E                  ; A
        CALL    c_cbrl
        B       A, @end
@ret:   MOVI2   r1, 1
        CALL    c_room
        MOVI2   r4, $01                 ; RET
        CALL    c_b
@end:   LDR3    r0, r30, G_LAST         ; it can be found now
        LDR3    r1, r0, -4
        MOVI2   r2, -(F_HIDDEN + 1)
        AND2    r1, r2
        STR3    r1, r0, -4
        MOVI2   r0, 0
        STR3    r0, r31, U_STATE
        STR3    r0, r30, G_CALLAT
        RET
        HEAD    w_immediate, w_semicolon, "IMMEDIATE", 9, 0, 0
        LDR3    r0, r30, G_LAST
        LDR3    r1, r0, -4
        MOVI2   r2, F_IMMEDIATE
        OR2     r1, r2
        STR3    r1, r0, -4
        RET
        HEAD    w_create, w_immediate, "CREATE", 6, 0, 0
        CALL    w_parsename
        CALL    w_header
        LDR3    r0, r30, G_LAST
        LDR3    r1, r0, -4
        MOVI2   r2, F_CREATED
        OR2     r1, r2
        STR3    r1, r0, -4
        MOV2    r3, r0                  ; its code: DUP LIT24 body RET
        ADDI2   r3, BODY
        MOVI2   r4, $02
        STRB    r4, r0
        MOVI2   r4, -64                 ; $C0
        STRB3   r4, r0, 1
        STRB3   r3, r0, 2
        MOVI2   r2, 8
        LSR3    r4, r3, r2
        STRB3   r4, r0, 3
        MOVI2   r2, 16
        LSR3    r4, r3, r2
        STRB3   r4, r0, 4
        MOVI2   r4, $01
        STRB3   r4, r0, 5
        STR3    r3, r31, U_DP           ; HERE: the body
        RET
        HEAD    w_variable, w_create, "VARIABLE", 8, 0, 0
        CALL    w_create
        LDR3    r0, r30, G_LAST         ; inlined: its DUP LIT24 (5 bytes)
        LDR3    r1, r0, -4
        MOVI2   r2, 5
        MOVI2   r3, H_INL_SHIFT
        LSL2    r2, r3
        OR2     r1, r2
        STR3    r1, r0, -4
        LDR3    r0, r31, U_DP           ; one cell, 0
        MOVI2   r1, 0
        STR     r1, r0
        INCWR   r0
        STR3    r0, r31, U_DP
        RET
        HEAD    w_constant, w_variable, "CONSTANT", 8, 0, 0
        CALL    w_parsename             ; ( x "name" -- )
        CALL    w_header
        LDR3    r0, r30, G_LAST
        MOVR    r6, T
        DROP
        MOVI2   r4, $02                 ; DUP LIT24 x
        STRB    r4, r0
        MOVI2   r4, -64
        STRB3   r4, r0, 1
        STRB3   r6, r0, 2
        MOVI2   r2, 8
        LSR3    r4, r6, r2
        STRB3   r4, r0, 3
        MOVI2   r2, 16
        LSR3    r4, r6, r2
        STRB3   r4, r0, 4
        MOVI2   r2, 8
        LSL3    r7, r6, r2
        ASR2    r7, r2
        CMP2    r7, r6
        B       NE, @32
        MOVI2   r4, $01                 ; RET
        STRB3   r4, r0, 5
        MOVI2   r5, 5
        B       A, @inl
@32:    MOVI2   r4, $45                 ; LITH x >> 24, RET
        STRB3   r4, r0, 5
        MOVI2   r2, 24
        LSR3    r4, r6, r2
        STRB3   r4, r0, 6
        MOVI2   r4, $01
        STRB3   r4, r0, 7
        MOVI2   r5, 7
@inl:   LDR3    r1, r0, -4
        MOVI2   r2, H_INL_SHIFT
        LSL2    r5, r2
        OR2     r1, r5
        STR3    r1, r0, -4
        ADDI2   r0, 16
        STR3    r0, r31, U_DP
        RET
        HEAD    w_does, w_constant, "DOES>", 5, F_IC, 0
        LDA     r6, w_pdoes             ; (DOES>), then the code of DOES>
        CALL    c_call
        CALL    c_label
        MOVI2   r0, 0
        STR3    r0, r30, G_CALLAT
        RET
; (DOES>): the newest word (CREATEd) goes on with the code after the call: its
; line becomes DUP LIT24 body, CBRL A code. Then back to the caller of the defining
; word.
        HEAD    w_pdoes, w_does, "(DOES>)", 7, 0, 0
        LDR3    r0, r30, G_LAST
        MOV2    r6, R                   ; the code after DOES>
        MOVI2   r4, -63                 ; $C1 at xt + 5
        STRB3   r4, r0, 5
        SUB3    r9, r6, r0
        ADDI2   r9, -9
        MOVI2   r4, 15
        AND2    r4, r9
        MOVI2   r2, -32                 ; $E0: A
        OR2     r4, r2
        STRB3   r4, r0, 6
        MOVI2   r2, 4
        ASR3    r4, r9, r2
        STRB3   r4, r0, 7
        MOVI2   r2, 12
        ASR3    r4, r9, r2
        STRB3   r4, r0, 8
        LDR3    R, RSP, 4               ; R dropped: back past the defining word
        ADDI2   RSP, 4
        RET

; ---------------------------------------------------------------- compiling
        HEAD    w_lbracket, w_pdoes, "[", 1, F_IMMEDIATE, 0
        MOVI2   r0, 0
        STR3    r0, r31, U_STATE
        RET
        HEAD    w_rbracket, w_lbracket, "]", 1, 0, 0
        MOVI2   r0, -1
        STR3    r0, r31, U_STATE
        RET
        HEAD    w_compilecomma, w_rbracket, "COMPILE,", 8, 0, 0
        MOVR    r6, T                   ; ( xt -- ): a call, or its code inlined
        DROP
        LDR3    r1, r6, -4
        MOVI2   r2, H_INL_SHIFT
        LSR2    r1, r2
        MOVI2   r2, 15
        AND3    r7, r1, r2
        B       EQ, c_call
        B       A, c_copy
        HEAD    w_literal, w_compilecomma, "LITERAL", 7, F_IC, 0
        MOVR    r6, T
        DROP
        B       A, c_lit
        HEAD    w_recurse, w_literal, "RECURSE", 7, F_IC, 0
        LDR3    r6, r30, G_LAST
        B       A, c_call
        HEAD    w_bracktick, w_recurse, "[']", 3, F_IC, 0
        CALL    w_tick
        MOVR    r6, T
        DROP
        B       A, c_lit
        HEAD    w_brackchar, w_bracktick, "[CHAR]", 6, F_IC, 0
        CALL    w_char
        MOVR    r6, T
        DROP
        B       A, c_lit
        HEAD    w_postpone, w_brackchar, "POSTPONE", 8, F_IC, 0
        CALL    w_parsename
        CALL    w_sfind
        CMPI2   T, 0
        B       EQ, undefined
        DROP                            ; ( xt h )
        MOVR    r0, T
        DROP
        MOVR    r6, T
        DROP
        MOVI2   r1, F_IMMEDIATE
        AND2    r0, r1
        B       NE, c_call              ; immediate: a call of it
        CALL    c_lit                   ; else: code that compiles it
        LDA     r6, w_compilecomma
        B       A, c_call
        HEAD    w_exit, w_postpone, "EXIT", 4, F_IC, 0
        MOVI2   r1, 1
        CALL    c_room
        MOVI2   r4, $01                 ; RET
        CALL    c_b
        MOVI2   r0, 0
        STR3    r0, r30, G_CALLAT
        RET

; ---------------------------------------------------------------- control
        HEAD    w_if, w_exit, "IF", 2, F_IC, 0
        LDA     r6, t_if                ; ( -- orig )
        LDA     r7, t_if_end - t_if
        CALL    c_copy
        MOVI2   r8, 0                   ; EQ: the flag was 0
        CALL    c_fwd
        DUP
        MOVR    T, r10
        RET
        HEAD    w_else, w_if, "ELSE", 4, F_IC, 0
        MOVI2   r8, $E                  ; ( orig -- orig' )
        CALL    c_fwd
        MOV2    r12, r10
        MOVR    r10, T
        LDR3    r6, r31, U_DP
        CALL    c_resolve
        CALL    c_label
        MOVR    T, r12
        RET
        HEAD    w_then, w_else, "THEN", 4, F_IC, 0
        MOVR    r10, T                  ; ( orig -- )
        DROP
        LDR3    r6, r31, U_DP
        CALL    c_resolve
        B       A, c_label
        HEAD    w_begin, w_then, "BEGIN", 5, F_IC, 0
        CALL    c_label                 ; ( -- dest )
        DUP
        MOVR    T, r0
        RET
        HEAD    w_until, w_begin, "UNTIL", 5, F_IC, 0
        LDA     r6, t_if                ; ( dest -- )
        LDA     r7, t_if_end - t_if
        CALL    c_copy
        MOVR    r6, T
        DROP
        MOVI2   r8, 0
        B       A, c_cbrl
        HEAD    w_again, w_until, "AGAIN", 5, F_IC, 0
        MOVR    r6, T                   ; ( dest -- )
        DROP
        MOVI2   r8, $E
        B       A, c_cbrl
        HEAD    w_while, w_again, "WHILE", 5, F_IC, 0
        CALL    w_if                    ; ( dest -- orig dest )
        SWAP
        RET
        HEAD    w_repeat, w_while, "REPEAT", 6, F_IC, 0
        CALL    w_again                 ; ( orig dest -- )
        B       A, w_then
        HEAD    w_do, w_repeat, "DO", 2, F_IC, 0
        LDA     r6, t_do                ; ( -- dest )
        LDA     r7, t_do_end - t_do
do_common:
        CALL    c_copy
        MOVI2   r10, 0                  ; the LEAVE stack: where this loop's begin
        CALL    c_lpush
        CALL    c_label
        DUP
        MOVR    T, r0
        RET
        HEAD    w_qdo, w_do, "?DO", 3, F_IC, 0
        LDA     r6, t_qdo
        LDA     r7, t_qdo_end - t_qdo
        CALL    c_copy
        MOVI2   r10, 0
        CALL    c_lpush
        MOVI2   r8, 0                   ; EQ: the loop is skipped
        CALL    c_fwd
        CALL    c_lpush
        CALL    c_label
        DUP
        MOVR    T, r0
        RET
        HEAD    w_leave, w_qdo, "LEAVE", 5, F_IC, 0
        MOVI2   r8, $E
        CALL    c_fwd
        B       A, c_lpush
        HEAD    w_loop, w_leave, "LOOP", 4, F_IC, 0
        LDA     r6, t_loop              ; ( dest -- )
        LDA     r7, t_loop_end - t_loop
        CALL    c_copy
        MOVR    r6, T
        DROP
        MOVI2   r8, 1                   ; NE: not at the limit
loop_common:
        CALL    c_cbrl
        CALL    c_leaves
        LDA     r6, w_unloop
        MOVI2   r7, 7
        B       A, c_copy
        HEAD    w_ploop, w_loop, "+LOOP", 5, F_IC, 0
        LDA     r6, t_ploop
        LDA     r7, t_ploop_end - t_ploop
        CALL    c_copy
        MOVR    r6, T
        DROP
        MOVI2   r8, 5                   ; PL: the sign did not change
        B       A, loop_common
        HEAD    w_unloop, w_ploop, "UNLOOP", 6, F_COMPILE, 7
        LDR3    R, RSP, 8
        ADDI2   RSP, 8
        RET
        HEAD    w_i, w_unloop, "I", 1, F_COMPILE, 3
        DUP
        MOVR    T, R
        RET
        HEAD    w_j, w_i, "J", 1, F_COMPILE, 5
        DUP
        LDR3    T, RSP, 8
        RET
        HEAD    w_for, w_j, "FOR", 3, F_IC, 0
        LDA     r6, w_tor               ; ( -- dest ): PUSH DROP
        MOVI2   r7, 2
        CALL    c_copy
        CALL    c_label
        DUP
        MOVR    T, r0
        RET
        HEAD    w_next, w_for, "NEXT", 4, F_IC, 0
        MOVR    r6, T                   ; ( dest -- ): UNEXT in the line, or NEXT2 R
        DROP                            ; / NEXT3 R
        MOVI2   r1, 2
        CALL    c_room
        XOR3    r2, r0, r6
        MOVI2   r3, -16
        AND2    r2, r3
        B       NE, @far
        MOVI2   r4, $48                 ; UNEXT
        CALL    c_b
        MOVI2   r2, 15
        AND3    r4, r6, r2
        B       A, c_b
@far:   MOVI2   r1, 3
        CALL    c_room
        SUB3    r9, r6, r0
        ADDI2   r9, -3
        MOVI2   r2, 24
        LSL3    r7, r9, r2
        ASR2    r7, r2
        CMP2    r7, r9
        B       NE, @n3
        MOVI2   r4, -120                ; $88 NEXT2
        CALL    c_b
        MOVI2   r4, $22                 ; R
        CALL    c_b
        MOV2    r4, r9
        B       A, c_b
@n3:    MOVI2   r1, 4
        CALL    c_room
        SUB3    r9, r6, r0
        ADDI2   r9, -4
        MOVI2   r4, -56                 ; $C8 NEXT3
        CALL    c_b
        MOVI2   r4, $22
        CALL    c_b
        MOV2    r4, r9
        MOVI2   r7, 2
        B       A, c_bytes

; ---------------------------------------------------------------- strings
; c_string ( a n -- ): a counted string at HERE (data in the code: no tail call)
c_string:
        MOVR    r1, T
        DROP
        MOVR    r0, T
        DROP
        LDR3    r2, r31, U_DP
        STRB    r1, r2
        INCR    r2
@l:     CMPI2   r1, 0
        B       EQ, @e
        LDRB    r3, r0
        STRB    r3, r2
        INCR    r0
        INCR    r2
        DECR    r1
        B       A, @l
@e:     STR3    r2, r31, U_DP
        MOVI2   r0, 0
        STR3    r0, r30, G_CALLAT
        RET
        HEAD    w_squote, w_next, "S\"", 2, F_IMMEDIATE, 0
        PUSHL   '"'                     ; ( "ccc" -- a n )
        CALL    w_parse
        LDR3    r0, r31, U_STATE
        CMPI2   r0, 0
        B       EQ, @interp
        LDA     r6, w_psquote           ; compiling: (S") and the string
        CALL    c_call
        B       A, c_string
@interp:
        MOVR    r1, T                   ; interpreting: the string into SBUF
        MOV2    r0, S
        LDA     r2, SBUF
        MOV2    S, r2
@l:     CMPI2   r1, 0
        B       EQ, @r
        LDRB    r3, r0
        STRB    r3, r2
        INCR    r0
        INCR    r2
        DECR    r1
        B       A, @l
@r:     RET
        HEAD    w_psquote, w_squote, "(S\")", 4, 0, 0
        DUP                             ; ( -- a n ): the string after the call
        MOVR    T, R
        LDRB    r0, T
        INC
        DUP
        MOVR    T, r0
        ADD3    r1, S, T
        MOV2    R, r1                   ; back after it
        RET
        HEAD    w_dotquote, w_psquote, ".\"", 2, F_IC, 0
        PUSHL   '"'
        CALL    w_parse
        LDA     r6, w_pdotquote
        CALL    c_call
        B       A, c_string
        HEAD    w_pdotquote, w_dotquote, "(.\")", 4, 0, 0
        DUP
        MOVR    T, R
        LDRB    r0, T
        INC
        DUP
        MOVR    T, r0
        ADD3    r1, S, T
        MOV2    R, r1
        B       A, w_type
        HEAD    w_abortq, w_pdotquote, "ABORT\"", 6, F_IC, 0
        PUSHL   '"'
        CALL    w_parse
        LDA     r6, w_pabortq
        CALL    c_call
        B       A, c_string
        HEAD    w_pabortq, w_abortq, "(ABORT\")", 8, 0, 0
        DUP                             ; ( f -- ): THROW -2 if f
        MOVR    T, R
        LDRB    r0, T
        ADD3    r1, T, r0
        INCR    r1
        MOV2    R, r1
        SWAP
        CMPI2   T, 0
        DROP
        B       NE, @abort
        DROP
        RET
@abort: STR3    T, r30, G_ABORTMSG
        MOVI2   T, -2
        B       A, w_throw

; ---------------------------------------------------------------- the SD card, blocks
        HEAD    w_sdread, w_pabortq, "SD-READ", 7, 0, 0
        MOVR    r9, T                   ; ( addr lba -- ior ): the card's block lba
        DROP                            ; (512 bytes) to addr; ior 0: done
        MOVR    r10, T
        CALL    sd_read
        MOVR    T, r0
        RET
        HEAD    w_sdwrite, w_sdread, "SD-WRITE", 8, 0, 0
        MOVR    r9, T                   ; ( addr lba -- ior ): 512 bytes from addr
        DROP                            ; to the card's block lba
        MOVR    r10, T
        CALL    sd_write
        MOVR    T, r0
        RET
        HEAD    w_block, w_sdwrite, "BLOCK", 5, 0, 0
        MOVR    r0, T                   ; ( u -- addr ): block u in a buffer, read
        MOVI2   r20, 1
block_common:
        CALL    block_get
        CMPI2   r0, 0
        B       NE, throw_r0
        MOVR    T, r14
        RET
        HEAD    w_buffer, w_block, "BUFFER", 6, 0, 0
        MOVR    r0, T                   ; ( u -- addr ): a buffer for block u, not read
        MOVI2   r20, 0
        B       A, block_common
        HEAD    w_update, w_buffer, "UPDATE", 6, 0, 0
        LDR3    r16, r30, G_BCUR        ; the last BLOCK / BUFFER was changed
        CALL    buf_ptrs
        MOVI2   r1, 1
        STR3    r1, r15, 4
        RET
        HEAD    w_savebufs, w_update, "SAVE-BUFFERS", 12, 0, 0
        MOVI2   r21, 0                  ; the changed buffers onto the card
@l:     MOV2    r16, r21
        CALL    buf_save
        CMPI2   r0, 0
        B       NE, @err
        INCR    r21
        CMPI2   r21, NBUF
        B       LO, @l
        RET
@err:   MOVI2   r0, -34
        B       A, throw_r0
        HEAD    w_emptybufs, w_savebufs, "EMPTY-BUFFERS", 13, 0, 0
        B       A, empty_bufs           ; forgotten, changed or not
        HEAD    w_flush, w_emptybufs, "FLUSH", 5, 0, 0
        CALL    w_savebufs
        B       A, empty_bufs
        GLOBV   w_blk, w_flush, "BLK", 3, G_BLK
        GLOBV   w_scr, w_blk, "SCR", 3, G_SCR
        HEAD    w_load, w_scr, "LOAD", 4, 0, 0
        LDR3    r0, r30, G_BLK          ; ( u -- ): interpret block u
        DUP
        MOVR    T, r0
        PUSH                            ; BLK kept on the return stack
        DROP
@blk:   STR3    T, r30, G_BLK           ; ( u -- ): interpret source block u
        CALL    w_block
        CALL    src_check               ; a source block: its text
        ADDI2   T, SRC_HEAD
        PUSHL   SRC_COLS * SRC_ROWS
        CALL    w_evaluate
        PUSHL   0                       ; then the block it CHAINs to (its buffer
        LDR3    T, r30, G_BLK           ; may hold another block by now)
        CALL    w_block
        LDR3    T, T, SRC_NEXT
        CMPI2   T, 0
        B       NE, @blk
        POP
        STR3    T, r30, G_BLK
        DROP
        RET
        HEAD    w_thru, w_load, "THRU", 4, 0, 0
@l:     CMP                             ; ( u1 u2 -- ): LOAD u1 .. u2
        B       GT, @done
        OVER
        CALL    w_load
        SWAP
        INC
        SWAP
        B       A, @l
@done:  DROP
        DROP
        RET
        HEAD    w_list, w_thru, "LIST", 4, 0, 0
        STR3    T, r30, G_SCR           ; ( u -- ): source block u, 56 lines of 72
        CALL    w_block
        CALL    src_check
        PUSHL   '['                     ; [u] the title, next, shadow, version
        CALL    w_emit
        LDR3    r0, r30, G_SCR
        DUP
        MOVR    T, r0
        CALL    udot0
        ZDOTQ   "] "
        DUP
        ADDI2   T, SRC_TITLE
        PUSHL   SRC_TLEN
        CALL    type_clean
        DUP
        LDR3    T, T, SRC_NEXT
        CMPI2   T, 0
        B       EQ, @nn
        ZDOTQ   " next "
        CALL    udot0
        B       A, @sh
@nn:    DROP
@sh:    DUP
        LDR3    T, T, SRC_SHADOW
        CMPI2   T, 0
        B       EQ, @ns
        ZDOTQ   " shadow "
        CALL    udot0
        B       A, @ve
@ns:    DROP
@ve:    ZDOTQ   " version "
        DUP
        LDR3    T, T, SRC_VERSION
        CALL    udot0
        ADDI2   T, SRC_HEAD
        PUSHL   0                       ; ( text line )
@line:  CALL    w_cr
        DUP
        PUSHL   2
        CALL    w_udotr
        CALL    w_space
        OVER
        OVER
        MOVR    r0, T                   ; line * 72
        MOVI2   r1, 6
        LSL3    r2, r0, r1
        MOVI2   r1, 3
        LSL3    r3, r0, r1
        ADD3    T, r2, r3
        ADD                             ; ( text line a )
        PUSHL   SRC_COLS - 1
        PUSH
        DROP
@c:     DUP
        LDRB    T, T
        CMPI2   T, ' '
        B       HS, @p
        MOVI2   T, ' '                  ; control codes (and 0) as spaces
@p:     CALL    w_emit
        INC
        DECR    R
        B       PL, @c
        DUP
        POP
        DROP
        DROP
        INC
        CMPI2   T, SRC_ROWS
        B       LT, @line
        DROP
        DROP
        B       A, w_cr
; src_check ( addr -- addr ): the block at addr (the last BLOCK) a source block
; (SRC_MAGIC), else THROW -259; and not damaged (its CRC), else THROW -261
src_check:
        LDR     r0, T
        LDA     r1, SRC_MAGIC
        CMP2    r0, r1
        B       NE, @bad
        LDR3    r16, r30, G_BCUR        ; its buffer (the last BLOCK): damaged?
        CALL    buf_ptrs
        LDR3    r0, r15, 4
        MOVI2   r1, 2
        AND2    r0, r1
        B       NE, @dmg
        RET
@bad:   LDA     r0, -259
        B       A, throw_r0
@dmg:   LDA     r0, -261
        B       A, throw_r0
        HEAD    w_newsource, w_list, "NEW-SOURCE", 10, 0, 0
        STR3    T, r30, G_SCR           ; ( u -- ): block u a new source block: the
        CALL    w_buffer                ; magic, the header 0, the text blank; changed
        MOVR    r0, T
        DROP
        LDA     r1, SRC_MAGIC
        STR     r1, r0
        INCWR   r0
        MOVI2   r1, 0
        MOVI2   r2, (SRC_HEAD - 4) / 4 - 1
@z:     STR     r1, r0
        INCWR   r0
        NEXT    r2, @z
        LDA     r1, $20202020
        LDA     r2, SRC_COLS * SRC_ROWS / 4 - 1
@s:     STR     r1, r0
        INCWR   r0
        NEXT    r2, @s
        B       A, w_update
        HEAD    w_line, w_newsource, "LINE", 4, 0, 0
        DUP                             ; ( n -- addr ): line n (0 .. 55) of the
        LDR3    T, r30, G_SCR           ; source block SCR (LIST, NEW-SOURCE set it)
        CALL    w_block
        SWAP
        MOVR    r0, T                   ; n * 72
        MOVI2   r1, 6
        LSL3    r2, r0, r1
        MOVI2   r1, 3
        LSL3    r3, r0, r1
        ADD3    T, r2, r3
        ADD
        ADDI2   T, SRC_HEAD
        RET
        HEAD    w_sdinit, w_line, "SD-INIT", 7, 0, 0
        MOVI2   r0, -1                  ; ( -- ior ): start the card (again)
        STR3    r0, r30, G_SDHC
        CALL    sd_start
        DUP
        MOVR    T, r0
        RET
        HEAD    w_sdblocks, w_sdinit, "SD-BLOCKS", 9, 0, 0
        LDR3    r0, r30, G_SDBLKS       ; ( -- u ): the card's blocks of 512 bytes
        CMPI2   r0, 0                   ; (0: no card)
        B       NE, @r
        CALL    sd_start
        LDR3    r0, r30, G_SDBLKS
@r:     DUP
        MOVR    T, r0
        RET
        HEAD    w_blocks, w_sdblocks, "BLOCKS", 6, 0, 0
        CALL    w_sdblocks              ; ( -- u ): FORTH's blocks on the card
        LSRI    BLK_SHIFT
        RET
        HEAD    w_sdcsd, w_blocks, "SD-CSD", 6, 0, 5
        DUP                             ; ( -- addr ): the card's CSD, 16 bytes
        LIT     SD_CSD
        RET
        HEAD    w_sdcid, w_sdcsd, "SD-CID", 6, 0, 5
        DUP                             ; ( -- addr ): its CID, 16 bytes
        LIT     SD_CID
        RET
        HEAD    w_sdinfo, w_sdcid, "SD-INFO", 7, 0, 0
        CALL    w_sdblocks              ; ( -- ): what the card is
        CMPI2   T, 0
        B       EQ, @none
        LDR3    r0, r30, G_SDHC
        CMPI2   r0, 0
        B       EQ, @sc
        ZDOTQ   "SDHC/SDXC card, "
        B       A, @cap
@sc:    ZDOTQ   "SDSC card, "
@cap:   DUP
        LSRI    11
        CALL    w_udot
        ZDOTQ   "MB: "
        DUP
        CALL    w_udot
        ZDOTQ   "blocks of 512 bytes, "
        LSRI    BLK_SHIFT
        CALL    w_udot
        ZDOTQ   "FORTH blocks of 4 KB"
        CALL    w_cr
        ZDOTQ   "maker "                ; the CID
        PUSHL   SD_CID
        LDRB    T, T
        CALL    hex2
        ZDOTQ   ", OEM "
        PUSHL   SD_CID + 1
        PUSHL   2
        CALL    w_type
        ZDOTQ   ", product "
        PUSHL   SD_CID + 3
        PUSHL   5
        CALL    w_type
        ZDOTQ   ", revision "
        PUSHL   SD_CID + 8
        LDRB    T, T
        DUP
        LSRI    4
        CALL    digit_emit
        PUSHL   '.'
        CALL    w_emit
        MOVI2   r0, 15
        ANDR    T, r0
        CALL    digit_emit
        ZDOTQ   ", serial "
        LDA     r2, SD_CID + 9
        MOVI2   r0, 0
        MOVI2   r3, 3
@sn:    MOVI2   r1, 8
        LSL2    r0, r1
        LDRB    r1, r2
        OR2     r0, r1
        INCR    r2
        NEXT    r3, @sn
        DUP
        MOVR    T, r0
        CALL    hexdot
        ZDOTQ   ", made "
        LDA     r2, SD_CID              ; the year: 2000 + bits 19..12
        LDRB3   r0, r2, 13
        MOVI2   r1, 15
        AND2    r0, r1
        MOVI2   r1, 4
        LSL2    r0, r1
        LDRB3   r3, r2, 14
        LSR3    r4, r3, r1
        OR2     r0, r4
        LDA     r4, 2000
        ADD2    r0, r4
        DUP
        MOVR    T, r0
        PUSHL   0
        CALL    w_lessnum
        CALL    w_sharps
        CALL    w_numgreater
        CALL    w_type
        PUSHL   '-'
        CALL    w_emit
        PUSHL   SD_CID + 14             ; the month: bits 11..8, two digits
        LDRB    T, T
        MOVI2   r0, 15
        ANDR    T, r0
        PUSHL   10
        CALL    w_slashmod
        CALL    digit_emit
        CALL    digit_emit
        B       A, w_cr
@none:  DROP
        ZDOTQ   "no card"
        B       A, w_cr
; hex2 ( b -- ): two hex digits
hex2:   DUP
        LSRI    4
        MOVI2   r0, 15
        ANDR    T, r0
        CALL    digit_emit
        MOVI2   r0, 15
        ANDR    T, r0
; digit_emit ( n -- ): the digit 0 .. 35
digit_emit:
        CMPI2   T, 10
        B       LO, @d
        ADDI2   T, 7
@d:     ADDI2   T, '0'
        B       A, w_emit
        HEAD    w_font, w_sdinfo, "FONT", 4, 0, 0
        PUSHL   fonts_first             ; ( n f -- ): the card's font n (its 4 card
        CALL    w_catch                 ; blocks from 8 * FONTS + 4n) into font f of
        CMPI2   T, 0                    ; the font RAM; FONTS: the range, else
        DROP                            ; FONT_BLOCK
        B       EQ, @have
        PUSHL   FONT_BLOCK              ; (no volume, no FONTS: ( n f ) as it was)
@have:  MOVR    r22, T
        DROP
        MOVR    r18, T
        DROP
        MOVR    r17, T
        DROP
        MOVI2   r1, 2
        LSL3    r19, r17, r1
        MOVI2   r1, BLK_SHIFT
        LSL2    r22, r1
        ADD2    r19, r22
        MOVI2   r1, 3
        AND2    r18, r1
        MOVI2   r1, 11
        LSL3    r20, r18, r1
        LDA     r1, FONTRAM
        ADD2    r20, r1
        MOVI2   r21, 3
@l:     MOV2    r9, r19
        MOV2    r10, r20
        CALL    sd_read
        CMPI2   r0, 0
        B       NE, @err
        INCR    r19
        LDA     r1, 512
        ADD2    r20, r1
        NEXT    r21, @l
        RET
@err:   MOVI2   r0, -33
        B       A, throw_r0

; fonts_first ( -- u ): the range FONTS' first block
fonts_first:
        PUSHL   str_fonts
        PUSHL   5
        CALL    range_find
        CMPI2   T, 0
        B       EQ, no_range
        LDR3    T, T, 8
        RET
no_range:
        LDA     r0, -260
        B       A, throw_r0

; ---------------------------------------------------------------- source blocks
        HEAD    w_title, w_font, "TITLE", 5, 0, 0
        DUP                             ; ( addr n -- ): the title of block SCR
        LDR3    T, r30, G_SCR           ; (32 characters at most)
        CALL    w_block
        CALL    src_check
        ADDI2   T, SRC_TITLE
        MOVR    r2, T
        DROP
        MOVR    r1, T
        DROP
        MOVR    r0, T
        DROP
        MOVI2   r3, SRC_TLEN
        MINU2   r1, r3
        MOVI2   r4, 0
@c:     MOVI2   r5, ' '
        CMP2    r4, r1
        B       HS, @pad
        ADD3    r5, r0, r4
        LDRB    r5, r5
@pad:   ADD3    r6, r2, r4
        STRB    r5, r6
        INCR    r4
        CMPI2   r4, SRC_TLEN
        B       LO, @c
        B       A, w_update
        HEAD    w_chain, w_title, "CHAIN", 5, 0, 0
        DUP                             ; ( u -- ): LOAD of block SCR goes on with
        LDR3    T, r30, G_SCR           ; block u (0: no more)
        CALL    w_block
        CALL    src_check
        STR3    S, T, SRC_NEXT
        DROP
        DROP
        B       A, w_update
        HEAD    w_shadow, w_chain, "SHADOW", 6, 0, 0
        DUP                             ; ( u -- ): block u documents block SCR
        LDR3    T, r30, G_SCR           ; (0: none)
        CALL    w_block
        CALL    src_check
        STR3    S, T, SRC_SHADOW
        DROP
        DROP
        B       A, w_update
        HEAD    w_doc, w_shadow, "DOC", 3, 0, 0
        CALL    w_block                 ; ( u -- ): LIST block u's shadow block
        CALL    src_check
        LDR3    T, T, SRC_SHADOW
        CMPI2   T, 0
        B       NE, w_list
        LDA     r0, -264
        B       A, throw_r0
        HEAD    w_index, w_doc, "INDEX", 5, 0, 0
@l:     CMP                             ; ( from to -- ): a line for each source
        B       GT, @done               ; block: its number, its title
        OVER
        CALL    w_block
        LDR     r0, T
        LDA     r1, SRC_MAGIC
        CMP2    r0, r1
        B       NE, @skip
        CALL    w_cr
        LDR3    r0, PSP, 4              ; ( from to blk ): from
        DUP
        MOVR    T, r0
        PUSHL   6
        CALL    w_udotr
        CALL    w_space
        ADDI2   T, SRC_TITLE
        PUSHL   SRC_TLEN
        CALL    type_clean
        B       A, @nx
@skip:  DROP
@nx:    SWAP
        INC
        SWAP
        B       A, @l
@done:  DROP
        DROP
        B       A, w_cr

; ---------------------------------------------------------------- the volume
; vol_block ( -- addr ): block 0, the volume block (else THROW -262)
vol_block:
        PUSHL   0
        CALL    w_block
        LDR     r0, T
        LDA     r1, VOL_MAGIC
        CMP2    r0, r1
        B       NE, @no
        RET
@no:    LDA     r0, -262
        B       A, throw_r0

; range_find ( a n -- entry | 0 ): the volume's range named a n (case does not
; matter, 8 characters at most)
range_find:
        CALL    vol_block
        MOVR    r2, T
        DROP
        MOVR    r1, T
        DROP
        MOVR    r0, T
        ADDI2   r2, VOL_RANGES
        CMPI2   r1, 8
        B       HI, @none
@e:     LDRB    r3, r2
        CMPI2   r3, 0
        B       EQ, @none
        MOVI2   r4, 0
@c:     MOVI2   r5, ' '
        CMP2    r4, r1
        B       HS, @cmp
        ADD3    r5, r0, r4
        LDRB    r5, r5
        CMPI2   r5, 'a'
        B       LO, @cmp
        CMPI2   r5, 'z'
        B       HI, @cmp
        ADDI2   r5, -32
@cmp:   ADD3    r6, r2, r4
        LDRB    r6, r6
        CMP2    r5, r6
        B       NE, @next
        INCR    r4
        CMPI2   r4, 8
        B       LO, @c
        MOVR    T, r2                   ; found
        RET
@next:  ADDI2   r2, VOL_ENTRY
        B       A, @e
@none:  MOVI2   T, 0
        RET

        HEAD    w_newvolume, w_index, "NEW-VOLUME", 10, 0, 0
        CALL    w_blocks                ; ( addr n -- ): block 0 a new volume block,
        PUSHL   0                       ; named addr n, with the ranges BOOT, FONTS,
        CALL    w_buffer                ; SYSTEM, SOURCE, DATA; no startup block
        MOVR    r8, T                   ; ( addr n blocks vol )
        DROP
        MOVR    r7, T
        DROP
        MOVR    r1, T
        DROP
        MOVR    r0, T
        DROP
        MOV2    r2, r8                  ; all 0
        MOVI2   r3, 0
        LDA     r4, BLK_SIZE / 4 - 1
@z:     STR     r3, r2
        INCWR   r2
        NEXT    r4, @z
        LDA     r2, VOL_MAGIC
        STR     r2, r8
        MOVI2   r2, 1
        STR3    r2, r8, VOL_VERSION
        MOVI2   r3, 32                  ; the name
        MINU2   r1, r3
        MOV2    r2, r8
        ADDI2   r2, VOL_NAME
@n:     CMPI2   r1, 0
        B       EQ, @rg
        LDRB    r3, r0
        STRB    r3, r2
        INCR    r0
        INCR    r2
        DECR    r1
        B       A, @n
@rg:    LDA     r2, vol_default         ; the ranges
        MOV2    r3, r8
        ADDI2   r3, VOL_RANGES
        MOVI2   r4, VOL_DEFAULTS * VOL_ENTRY / 4 - 1
@r:     LDR     r5, r2
        STR     r5, r3
        INCWR   r2
        INCWR   r3
        NEXT    r4, @r
        LDA     r2, 65536               ; DATA: the rest of the card
        SUB2    r7, r2
        B       PL, @d
        MOVI2   r7, 0
@d:     LDA     r2, VOL_RANGES + (VOL_DEFAULTS - 1) * VOL_ENTRY + 12
        ADD2    r2, r8
        STR     r7, r2
        CALL    w_update
        B       A, w_savebufs
        HEAD    w_volume, w_newvolume, "VOLUME", 6, 0, 0
        CALL    vol_block               ; ( -- ): the volume: its name, the startup
        ZDOTQ   "volume "               ; block, the ranges
        DUP
        ADDI2   T, VOL_NAME
        PUSHL   32
        CALL    type_clean
        ZDOTQ   " startup "
        DUP
        LDR3    T, T, VOL_STARTUP
        CALL    udot0
        ADDI2   T, VOL_RANGES
@l:     DUP
        LDRB    T, T
        CMPI2   T, 0
        DROP
        B       EQ, @end
        CALL    w_cr
        ZDOTQ   "  "
        DUP
        PUSHL   8
        CALL    type_clean
        DUP
        LDR3    T, T, 8
        PUSHL   11
        CALL    w_udotr
        DUP
        LDR3    T, T, 12
        PUSHL   11
        CALL    w_udotr
        ADDI2   T, VOL_ENTRY
        B       A, @l
@end:   DROP
        B       A, w_cr
        HEAD    w_range, w_volume, "RANGE", 5, 0, 0
        CALL    w_parsename             ; ( "name" -- u n ): the range's first block
        CALL    range_find              ; and how many
        CMPI2   T, 0
        B       EQ, no_range
        DUP
        LDR3    T, T, 8
        SWAP
        LDR3    T, T, 12
        RET
        HEAD    w_setrange, w_range, "SET-RANGE", 9, 0, 0
        CALL    w_parsename             ; ( u n "name" -- ): the range, new or changed
        OVER                            ; ( u n a len )
        OVER
        CALL    range_find
        CMPI2   T, 0
        B       NE, @have
        DROP                            ; new: after the last one
        CALL    vol_block
        ADDI2   T, VOL_RANGES
@end:   DUP
        LDRB    T, T
        CMPI2   T, 0
        DROP
        B       EQ, @have
        ADDI2   T, VOL_ENTRY
        B       A, @end
@have:  MOVR    r4, T                   ; ( u n a len entry )
        DROP
        MOVR    r1, T
        DROP
        MOVR    r0, T
        DROP
        MOVR    r3, T
        DROP
        MOVR    r2, T
        DROP
        MOVI2   r5, 8
        MINU2   r1, r5
        MOVI2   r5, 0                   ; the name: capitals, spaces after
@c:     MOVI2   r6, ' '
        CMP2    r5, r1
        B       HS, @st
        ADD3    r6, r0, r5
        LDRB    r6, r6
        CMPI2   r6, 'a'
        B       LO, @st
        CMPI2   r6, 'z'
        B       HI, @st
        ADDI2   r6, -32
@st:    ADD3    r7, r4, r5
        STRB    r6, r7
        INCR    r5
        CMPI2   r5, 8
        B       LO, @c
        STR3    r2, r4, 8
        STR3    r3, r4, 12
        CALL    w_update
        B       A, w_savebufs
        HEAD    w_startup, w_setrange, "STARTUP", 7, 0, 0
        CALL    vol_block               ; ( u -- ): COLD loads block u (0: none)
        STR3    S, T, VOL_STARTUP
        DROP
        DROP
        CALL    w_update
        B       A, w_savebufs

; ---------------------------------------------------------------- images
; recv_image ( -- addr n ): an image from the serial port (as the boot loader takes
; it: the header of 32 bytes, then the payload), at HERE + 64 on, n bytes with the
; header; checked (THROW -263 if it is not a good one)
recv_image:
        ZDOTQ   "send the image"
        CALL    w_cr
        LDR3    r0, r31, U_DP
        ADDI2   r0, 64
        MOVI2   r1, -16
        AND2    r0, r1
        DUP
        MOVR    T, r0                   ; ( a )
        DUP
        PUSHL   32
        CALL    recv_bytes
        MOV2    r0, T                   ; the header
        LDR     r1, r0
        LDA     r2, $3233706D           ; "mp32"
        CMP2    r1, r2
        B       NE, bad_image
        MOVI2   r1, 0                   ; its words add up to 0
        MOVI2   r3, 7
@h:     LDR     r2, r0
        ADD2    r1, r2
        INCWR   r0
        NEXT    r3, @h
        CMPI2   r1, 0
        B       NE, bad_image
        LDR3    r1, T, 8                ; the size: not 0, a multiple of 4, room
        CMPI2   r1, 0
        B       EQ, bad_image
        MOVI2   r2, 3
        AND3    r2, r1, r2
        B       NE, bad_image
        CALL    w_unused
        LDR3    r1, S, 8
        LDA     r2, 1024
        ADD2    r1, r2
        CMP2    r1, T
        DROP
        B       HS, bad_image
        DUP                             ; ( a ): the payload
        LDR3    T, T, 8
        OVER
        ADDI2   T, 32
        OVER                            ; ( a size a+32 size )
        CALL    recv_bytes
        MOVR    r0, T                   ; ( a size ): its sum
        MOV2    r4, S
        ADDI2   r4, 32
        MOVI2   r1, 0
        MOVI2   r2, 2
        LSR3    r3, r0, r2
@p:     LDR     r2, r4
        ADD2    r1, r2
        INCWR   r4
        DECR    r3
        B       NE, @p
        LDR3    r2, S, 16
        CMP2    r1, r2
        B       NE, bad_image
        ZDOTQ   "received "
        DUP
        CALL    w_udot
        ZDOTQ   "bytes"
        CALL    w_cr
        ADDI2   T, 32
        RET
bad_image:
        LDA     r0, -263
        B       A, throw_r0

; recv_bytes ( a n -- ): n bytes from KEY to a on
recv_bytes:
@l:     CMPI2   T, 0
        B       LE, @d
        CALL    w_key                   ; ( a n c )
        LDR3    r0, PSP, 4
        STRB    T, r0
        INCR    r0
        STR3    r0, PSP, 4
        DROP
        DEC
        B       A, @l
@d:     DROP
        DROP
        RET

; blocks_put ( a n u -- ): n bytes from a into the blocks u, u + 1, ... (the last
; one filled up with 0), onto the card
blocks_put:
@l:     CMPI2   S, 0
        B       LE, @done
        DUP
        CALL    w_buffer                ; ( a n u buf )
        LDR3    r1, PSP, 4
        LDR3    r0, PSP, 8
        MOV2    r2, T
        LDA     r3, BLK_SIZE
        MINU2   r3, r1
        MOV2    r4, r3
@c:     CMPI2   r4, 0
        B       EQ, @z
        LDRB    r5, r0
        STRB    r5, r2
        INCR    r0
        INCR    r2
        DECR    r4
        B       A, @c
@z:     LDA     r4, BLK_SIZE
        SUB2    r4, r3
        MOVI2   r5, 0
@zz:    CMPI2   r4, 0
        B       EQ, @nx
        STRB    r5, r2
        INCR    r2
        DECR    r4
        B       A, @zz
@nx:    STR3    r0, PSP, 8
        SUB2    r1, r3
        STR3    r1, PSP, 4
        DROP
        CALL    w_update
        INC
        B       A, @l
@done:  DROP
        DROP
        DROP
        B       A, w_savebufs
        HEAD    w_receive, w_startup, "RECEIVE", 7, 0, 0
        CALL    recv_image              ; ( u -- ): an image from the serial port: its
        ADDI2   T, -32                  ; payload (without the header) into blocks
        SWAP                            ; u, u + 1, ...
        ADDI2   T, 32
        SWAP
        ROT
        B       A, blocks_put
        HEAD    w_install, w_receive, "INSTALL", 7, 0, 0
        PUSHL   str_boot                ; ( -- ): a boot image from the serial port
        PUSHL   4                       ; into the range BOOT (header and all): the
        CALL    range_find              ; loader boots it from the card
        CMPI2   T, 0
        B       EQ, no_range
        CALL    recv_image              ; ( entry a n ): with the header
        LDR3    r0, PSP, 4              ; does it fit?
        LDR3    r1, r0, 12
        MOVI2   r2, BLK_SHIFT + 9
        LSL2    r1, r2
        CMP2    T, r1
        B       HI, bad_image
        ROT
        LDR3    T, T, 8                 ; ( a n first )
        DUP
        PUSH
        DROP
        CALL    blocks_put
        ZDOTQ   "installed from block "
        DUP
        POP
        CALL    w_udot
        ZDOTQ   "on: reset to boot it"
        B       A, w_cr

; ================================================================ data
; the volume's ranges at first (NEW-VOLUME): name, first block, how many
VOL_DEFAULTS = 5
        .align  4
vol_default:
        .ascii  "BOOT    "
        .word   1, 255
        .ascii  "FONTS   "
        .word   256, 256
        .ascii  "SYSTEM  "
        .word   512, 512
        .ascii  "SOURCE  "
        .word   1024, 64512
        .ascii  "DATA    "
        .word   65536, 0
str_boot:  .ascii "BOOT"
str_fonts: .ascii "FONTS"

; the error messages: code, text
        .align  4
errtab: .word   -3, msg_m3
        .word   -4, msg_m4
        .word   -5, msg_m5
        .word   -6, msg_m6
        .word   -10, msg_m10
        .word   -16, msg_m16
        .word   -19, msg_m19
        .word   -33, msg_m33
        .word   -34, msg_m34
        .word   -35, msg_m35
        .word   -256, msg_m256
        .word   -257, msg_m257
        .word   -258, msg_m258
        .word   -259, msg_m259
        .word   -260, msg_m260
        .word   -261, msg_m261
        .word   -262, msg_m262
        .word   -263, msg_m263
        .word   -264, msg_m264
        .word   0, 0
msg_m3:   .asciiz "stack overflow"
msg_m4:   .asciiz "stack underflow"
msg_m5:   .asciiz "return stack overflow"
msg_m6:   .asciiz "return stack underflow"
msg_m10:  .asciiz "division by zero"
msg_m16:  .asciiz "a name is missing"
msg_m19:  .asciiz "name too long"
msg_m33:  .asciiz "block read error (no card?)"
msg_m34:  .asciiz "block write error"
msg_m35:  .asciiz "invalid block number"
msg_m256: .asciiz "undefined opcode"
msg_m257: .asciiz "heap full"
msg_m258: .asciiz "unexpected interrupt"
msg_m259: .asciiz "not a source block"
msg_m260: .asciiz "no such range"
msg_m261: .asciiz "source block damaged (its CRC)"
msg_m262: .asciiz "no volume (NEW-VOLUME makes one)"
msg_m263: .asciiz "bad image"
msg_m264: .asciiz "no shadow block"

; the keyboard: USB key codes 0 .. KBD_KEYS - 1 to characters, the US layout; first
; without Shift, then with it (0: no character)
kbd_table:
        .byte   0, 0, 0, 0
        .ascii  "abcdefghijklmnopqrstuvwxyz"
        .ascii  "1234567890"
        .byte   13, 27, 8, 9, ' '
        .ascii  "-=[]\\#;'`,./"
        .byte   0, 0, 0, 0
        .ascii  "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        .ascii  "!@#$%^&*()"
        .byte   13, 27, 8, 9, ' '
        .ascii  "_+{}|~:\"~<>?"

KERNEL_LAST = w_install
