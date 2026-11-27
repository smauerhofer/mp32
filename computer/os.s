; os.s: a first operating system for the mp32 computer - the demo that used to be the
; boot program. The boot loader (boot.s) loads it from the flash, the microSD card or
; the serial port into the SDRAM at 0 and starts it (os.cfg, mp32img).
;
; It sets up the stacks and the LISP heap, leaves what the boot loader wrote on the
; screen (green on black, as a PET) and goes on at row 8: it writes "mp32 ready" there
; and to the serial port, beeps, and then echoes every byte that comes in on the
; serial port, to the serial port and to the screen. The LEDs count
; the bytes. A CR starts a new line on the screen; when the screen is full it starts
; at the top again, clearing each line as it gets there.
;
; The bytes come in by interrupt: the serial port's handler puts them into a ring
; buffer of 256 bytes, and the main loop takes them out. The display's frame interrupt
; counts the frames (in the word "frames").
;
; What the loader hands over: VEC = 0 (this image's vector table, at its start), the
; processor at entry 0 (the reset), I = 0, r1 = where the image came from (1 the
; flash, 2 the card, 3 the serial port), r2 = its size. The stacks still point into
; the block RAM: this program sets up its own, in its BSS in the SDRAM. The loader
; does not clear the BSS.
;
; $0000_0000  the vector table (VEC): 256 entries of 4 bytes, a jump each.
;             INTR n and EXC n go to 4n:
;               0      reset: a jump to start (INTR 0 starts this program again)
;               1      an undefined opcode: says so and stops
;               4      the heap is full (CONS, L > HLIM): there is no garbage
;                      collector yet: says so and stops
;               16     the display's line interrupt (line 0 of the interrupt
;                      controller): off
;               17     the display's frame interrupt (line 1): counts the frames
;               18     the sound (line 2): off
;               19     the serial port (line 3): the bytes into the ring buffer
;               others nothing expects them: says so and stops
;             The handlers keep T, S, R and the flags, and use r24 .. r31 only; they
;             end with EOI (the interrupt controller) and RTI.
;
; The I/O (see computer/iodec.v):
;   $FFFF_0000  UART: +0 DATA (write: send; read: bit 8 = a byte came, bits 7..0 the byte)
;   $FFFF_0200  LEDs: bits 5..0, 1 = lit
;   $FFFF_0300  sound: +8 CTRL (bit 0 the amplifier on), +16 TONE, +20 LEN
;   $FFFF_0400  the interrupt controller (cpu/irqc.v): +4 MASK, +12 EOI
;   $FFFF_A000  video registers ($FFFF_A020 text_base, $FFFF_A024 pixel_base,
;               $FFFF_A02C IRQ_CTRL, $FFFF_A030 IRQ_STATUS)
;   $0078_0000  the screen's text: 60 rows of 80 words (code, font, paper, ink); the
;               code is the PET's screen code (font 0, ../display2/tools/make_petscii.py)
;
; Registers kept across the whole program:
;   r10 UART  r11 text  r12 column * 4  r13 LEDs  r14 the row's address
;   r16 the colors of a character (ink 82, paper 0, font 0)  r17 320 (a row)
;   r18 the end of the text  r9 $100  r19 where the main loop reads the ring buffer
; and the handlers' own:
;   r24 the ring buffer  r25 where the handler writes into it  r28 255
;   r29 the interrupt controller  r30 the address of "frames"  r31 the video registers
;   r26, r27 scratch

TEXT     = $780000
TEXT_END = $780000 + 60 * 320
HEAP     = $100000                      ; the LISP heap: 1 MB .. 7.5 MB of the SDRAM
HEAP_END = $780000
SOUND    = -$FD00                       ; $FFFF_0300: the sound (../audio/audio.v)
IRQC     = -$FC00                       ; $FFFF_0400: the interrupt controller
VIDEO    = -$6000                       ; $FFFF_A000: the video registers

        .code
; ---------------------------------------------------------------- the vector table
reset:  B       A, start                ; 0  $0000_0000: reset
        .align  4
        B       A, undefined            ; 1  an undefined opcode
        .align  4
        .rept   2
        B       A, unexpected           ; 2, 3
        .align  4
        .endr
        B       A, gc                   ; 4  $0000_0010: the heap is full
        .align  4
        .rept   11
        B       A, unexpected           ; 5 .. 15
        .align  4
        .endr
        B       A, unexpected           ; 16 the display's line interrupt (off)
        .align  4
        B       A, frame                ; 17 the display's frame interrupt
        .align  4
        B       A, unexpected           ; 18 the sound (off)
        .align  4
        B       A, serial               ; 19 the serial port
        .align  4
        .rept   236
        B       A, unexpected           ; 20 .. 255
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

; ---------------------------------------------------------------- serial port: 19
; Every byte that came, into the ring buffer (the serial port's irq is 1 while its
; queue holds a byte, and reading DATA takes one). A full buffer loses the oldest.
serial: DUP                             ; keep T (and S)
        MOVR    T, ST                   ; the flags
        PUSH                            ; (and R)
@more:  LDR     r27, r10                ; DATA: bit 8 = a byte came
        CMP2    r27, r9
        B       LO, @done
        SUB2    r27, r9                 ; the byte
        ADD3    r26, r24, r25
        STRB    r27, r26
        INCR    r25
        AND2    r25, r28                ; 256 bytes, round
        B       A, @more
@done:  STR3    r27, r29, 12            ; EOI
        POP
        MOVR    ST, T
        DROP
        RTI

; ---------------------------------------------------------------- frame: 17
; The vertical blank begins: count the frame.
frame:  DUP
        MOVR    T, ST
        PUSH
        LDR     r27, r30
        INCR    r27
        STR     r27, r30                ; frames + 1
        MOVI2   r27, 2
        STR3    r27, r31, $30           ; IRQ_STATUS: clear FRAME
        STR3    r27, r29, 12            ; EOI
        POP
        MOVR    ST, T
        DROP
        RTI

; ---------------------------------------------------------------- the start
start:  LEA     pstack_top              ; the stacks: in the SDRAM (BSS)
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
        LIT     $5200                   ; ink 82 (green), paper 0 (black), font 0
        LSLI    16
        MOVR    r16, T

        LIT     HEAP + 1                ; LISP: L the first free cell (tagged 01) ...
        MOVR    L, T
        LIT     HEAP_END - 7            ; ... HLIM the last one
        MOVR    HLIM, T

        MOVI2   r8, 1                   ; LED 0: alive
        STR     r8, r13

        ; ---- the interrupts: the serial port's bytes, the display's frames
        LEA     rxbuf
        MOVR    r24, T
        MOVI2   r25, 0
        MOVI2   r19, 0
        LIT     255
        MOVR    r28, T
        LIT     IRQC
        MOVR    r29, T
        LEA     frames
        MOVR    r30, T
        LIT     VIDEO
        MOVR    r31, T
        MOVI2   r1, 0
        STR     r1, r30                 ; frames = 0
        MOVI2   r1, 1
        STR3    r1, r10, 12             ; the serial port: CTRL RXIE
        MOVI2   r1, 2
        STR3    r1, r31, $2C            ; the display: IRQ_CTRL FIE
        STR3    r1, r31, $30            ; (its FRAME flag cleared)
        MOVI2   r1, %1010
        STR3    r1, r29, 4              ; the controller: MASK lines 1 and 3
        SEI

        LIT     TEXT + 8 * 320          ; the loader's lines stay: start at row 8,
        MOVR    r14, T                  ; below them (cls would clear them all)
        MOVI2   r12, 0
        CALL    clear_row
        LEA     banner
        MOVR    r6, T
        CALL    puts
        CALL    beep

; ---------------------------------------------------------------- the echo
loop:   CMP2    r19, r25                ; the ring buffer: a byte?
        B       EQ, loop
        ADD3    r2, r24, r19
        LDRB    r1, r2                  ; the byte
        INCR    r19
        AND2    r19, r28
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
        MOV2    r2, r1                  ; ASCII to the PET's screen code: below $40 the
        MOVI2   r3, $40                 ; same, from $40 on AND $1F (@ A .. Z, and a .. z
        CMP2    r2, r3                  ; as capitals)
        B       LO, @code
        MOVI2   r3, $1F
        AND2    r2, r3
@code:  OR2     r2, r16                 ; the character with its colors
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
frames:     .res 4                      ; the frames since the start
rxbuf:      .res 256                    ; the serial port's ring buffer
pstack:     .res 252
pstack_top: .res 4
rstack:     .res 252
rstack_top: .res 4
