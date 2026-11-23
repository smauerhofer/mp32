; boot.s: the first program of the mp32 computer, in the block RAM at $F000_0000
; (loaded with the FPGA: the linker writes build/boot.hex for BRAM_INIT).
;
; It sets up the stacks and the LISP heap, clears the screen (blue, as a C64), writes
; "mp32 ready" on the screen and to the serial port, beeps, and then echoes every byte that
; comes in on the serial port, to the serial port and to the screen. The LEDs count
; the bytes. A CR starts a new line on the screen; when the screen is full it starts
; at the top again, clearing each line as it gets there.
;
; $F000_0000  the vector table (VEC after reset): 48 entries of 4 bytes, a jump each.
;             INTR n and EXC n go to $F000_0000 + 4n:
;               0      reset: a jump to start
;               1      an undefined opcode: says so and stops
;               4      the heap is full (CONS, L > HLIM): there is no garbage
;                      collector yet: says so and stops
;               16     the serial port (line 0 of the interrupt controller)
;               17     the sound (line 1)
;               others nothing expects them: says so and stops
;             Interrupts stay off (I = 0, and the controller's MASK is 0): the echo
;             polls the serial port.
;
; The I/O (see computer/iodec.v):
;   $FFFF_0000  UART: +0 DATA (write: send; read: bit 8 = a byte came, bits 7..0 the byte)
;   $FFFF_0200  LEDs: bits 5..0, 1 = lit
;   $FFFF_0300  sound: +8 CTRL (bit 0 the amplifier on), +16 TONE, +20 LEN
;   $FFFF_A000  video registers ($FFFF_A020 text_base, $FFFF_A024 pixel_base)
;   $0078_0000  the screen's text: 60 rows of 80 words (code, font, paper, ink)
;
; Registers kept across the whole program:
;   r10 UART  r11 text  r12 column * 4  r13 LEDs  r14 the row's address
;   r16 the colors of a character (ink 14, paper 6, font 0)  r17 320 (a row)
;   r18 the end of the text  r9 $100

TEXT     = $780000
TEXT_END = $780000 + 60 * 320
HEAP     = $100000                      ; the LISP heap: 1 MB .. 7.5 MB of the SDRAM
HEAP_END = $780000
SOUND    = -$FD00                       ; $FFFF_0300: the sound (../audio/audio.v)

        .code
; ---------------------------------------------------------------- the vector table
reset:  B       A, start                ; 0  $F000_0000: reset
        .align  4
        B       A, undefined            ; 1  an undefined opcode
        .align  4
        .rept   2
        B       A, unexpected           ; 2, 3
        .align  4
        .endr
        B       A, gc                   ; 4  $F000_0010: the heap is full
        .align  4
        .rept   11
        B       A, unexpected           ; 5 .. 15
        .align  4
        .endr
        B       A, unexpected           ; 16 the serial port (not used yet)
        .align  4
        B       A, unexpected           ; 17 the sound (not used yet)
        .align  4
        .rept   30
        B       A, unexpected           ; 18 .. 47
        .align  4
        .endr

; ---------------------------------------------------------------- the handlers
gc:     LEA     msg_full                ; the heap is full
        B       A, halt
undefined:
        LEA     msg_undefined
        B       A, halt
unexpected:
        LEA     msg_unexpected
halt:   MOVR    r6, T                   ; say so, and stop
        CALL    puts
@stop:  B       A, @stop

; ---------------------------------------------------------------- the start
start:  LEA     pstack_top              ; the stacks: in the block RAM (BSS)
        MOVR    PSP, T
        LEA     rstack_top
        MOVR    RSP, T

        LIT     -$10000                 ; $FFFF_0000: the UART
        MOVR    r10, T
        LIT     -$FE00                  ; $FFFF_0200: the LEDs
        MOVR    r13, T
        LIT     TEXT
        MOVR    r11, T
        LIT     TEXT_END
        MOVR    r18, T
        LIT     320
        MOVR    r17, T
        LIT     $100
        MOVR    r9, T
        LIT     $0E06                   ; ink 14 (light blue), paper 6 (blue), font 0
        LSLI    16
        MOVR    r16, T

        LIT     HEAP + 1                ; LISP: L the first free cell (tagged 01) ...
        MOVR    L, T
        LIT     HEAP_END - 7            ; ... HLIM the last one
        MOVR    HLIM, T

        MOVI2   r8, 1                   ; LED 0: alive
        STR     r8, r13

        CALL    cls
        LEA     banner
        MOVR    r6, T
        CALL    puts
        CALL    beep

; ---------------------------------------------------------------- the echo
loop:   LDR     r1, r10                 ; the UART: bit 8 = a byte came
        CMP2    r1, r9
        B       LO, loop                ; below $100: nothing
        SUB2    r1, r9                  ; the byte
        CALL    putc
        INCR    r8                      ; the LEDs count the bytes
        STR     r8, r13
        B       A, loop

; ---------------------------------------------------------------- putc
; The byte in r1 to the serial port and to the screen. Uses r2 .. r4.
putc:   STR     r1, r10                 ; the UART (waits while its queue is full)
        MOVI2   r3, 13
        CMP2    r1, r3
        B       EQ, newline             ; CR: a new line
        MOVI2   r3, 10
        CMP2    r1, r3
        B       EQ, putc_done           ; LF: only the serial port
        OR3     r2, r1, r16             ; the character with its colors
        ADD3    r3, r14, r12            ; where it goes
        STR     r2, r3
        INCWR   r12                     ; the next column
        CMP2    r12, r17
        B       LO, putc_done
newline:
        MOVI2   r12, 0
        ADD2    r14, r17                ; the next row ...
        CMP2    r14, r18
        B       LO, clear_row
        MOV2    r14, r11                ; ... or the top again
clear_row:
        LIT8    ' '                     ; the new row blank
        MOVR    r2, T
        OR2     r2, r16
        MOV2    r3, r14
        MOVI2   r4, 80
clear_loop:
        STR     r2, r3
        INCWR   r3
        DECR    r4
        B       NE, clear_loop
putc_done:
        RET

; ---------------------------------------------------------------- beep
; The amplifier on, and a beep: the sound's tone, 442 Hz for 0.1 s. The sound plays
; it alone; beep returns at once. Uses r1 .. r3.
beep:   LIT     SOUND + 8               ; CTRL: ON
        MOVR    r2, T
        MOVI2   r1, 1
        STR     r1, r2
        LIT     SOUND + 16              ; TONE: height 4000, half a period 53 samples
        MOVR    r2, T
        LIT     4000
        LSLI    16
        MOVR    r1, T
        MOVI2   r3, 53
        OR2     r1, r3
        STR     r1, r2
        LIT     SOUND + 20              ; LEN: 4,688 samples (46,875 a second)
        MOVR    r2, T
        LIT     4688
        MOVR    r1, T
        STR     r1, r2
        RET

; ---------------------------------------------------------------- puts
; The string at r6 (ending with a 0), with putc. Uses r1 .. r6.
puts:   LDRB    r1, r6
        MOVR    T, r1
        B       TZ, puts_done
        CALL    putc
        INCR    r6
        B       A, puts
puts_done:
        RET

; ---------------------------------------------------------------- cls
; The whole screen blank, the cursor at the top left. Uses r2 .. r4.
cls:    LIT8    ' '
        MOVR    r2, T
        OR2     r2, r16
        MOV2    r3, r11
        LIT     60 * 80
        MOVR    r4, T
cls_loop:
        STR     r2, r3
        INCWR   r3
        DECR    r4
        B       NE, cls_loop
        MOV2    r14, r11
        MOVI2   r12, 0
        RET

; ---------------------------------------------------------------- data
        .rodata
banner:   .asciiz "mp32 ready\r\n"
msg_full: .asciiz "\r\nheap full: no garbage collector yet\r\n"
msg_undefined:  .asciiz "\r\nundefined opcode\r\n"
msg_unexpected: .asciiz "\r\nunexpected interrupt or exception\r\n"

        .bss
pstack:     .res 252
pstack_top: .res 4
rstack:     .res 252
rstack_top: .res 4
