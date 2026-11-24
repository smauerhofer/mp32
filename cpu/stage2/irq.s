; irq.s: the program of irq_tb.v, a test of interrupts and exceptions through the
; whole processor (cpu.v).
;
; irq.hex holds its CODE bytes from address 0, one per line, padded to 2 KB: the bytes
; of the listing of
;   mp32as -o build/irq.o -l build/irq.lst irq.s
;
; Two vector tables: at 0 (VEC after reset: irq_tb.v gives the processor
; RESET_PC = VEC_RESET = 0) and at $400; halfway the program moves VEC there. They are
; the same but for INTR 48, the system call: T = T * 2 from the first, T * 4 from the
; second.
;
; The main program runs a loop 301 times that uses the flags between instructions,
; calls, stack frames, CONS (with a trap to the GC handler every 16), a critical section
; with CLI .. SEI, a system call (INTR 48), an undefined opcode (exception 1) and
; EXC 3. The test bench runs it twice, without interrupts and with two devices that
; interrupt at random (vectors 16 and 17), and both runs must end the same.
;
; The device handlers keep T, S, R and the flags, count in r20 / r24, tell their
; device they are done (a store to DEV + 0 / DEV + 4), and return with EOI and RTI.
; They nest (see below). They use r20 .. r29 only; the main program never does. A
; handler that runs inside the critical section (r9 = 1) stores to DEV + 12: an error.
;
; What irq_tb.v checks at the end (besides both runs being the same):
;   r10 = 19      undefined opcodes run (every 16th time round)
;   r11 = 19      EXC 3 run
;   r12 = $400    VEC read back after the move
;   r13 = 4510    the system calls: 151 * 10 + 150 * 20
;   r20, r24      the interrupts the test bench raised on each device
;   r23           how often device 0 interrupted device 1's handler

DEV  = $800                     ; +0, +4: device 0, 1 done; +8: the end; +12: an error;
                                ; +16 the interrupt controller (irqc.v): +16 PENDING,
                                ; +20 MASK, +24 NUMBER, +28 ISR / EOI
HEAP = $1000                    ; CONS: 16 cells, then the GC handler starts again

; ---------------------------------------------------------------- vector table 0
        B       A, start        ; 0: reset
        .align  4
        B       A, undef        ; 1: an undefined opcode
        .align  4
        B       A, bad          ; 2
        .align  4
        B       A, exc3         ; 3: EXC 3
        .align  4
        B       A, gc           ; 4: CONS, the heap is full
        .align  4
        .rept   11
        B       A, bad          ; 5 .. 15
        .align  4
        .endr
        B       A, dev0         ; 16: device 0
        .align  4
        B       A, dev1         ; 17: device 1
        .align  4
        .rept   30
        B       A, bad          ; 18 .. 47
        .align  4
        .endr
        B       A, sys1         ; 48: the system call
        .align  4

; ---------------------------------------------------------------- the handlers
bad:    MOVI2   r26, 1          ; an interrupt or exception nobody expects
        STR3    r26, r22, 12
@halt:  B       A, @halt

undef:  INCR    R               ; skip the undefined opcode (1 byte here)
        INCR    r10
        RET

exc3:   INCR    R               ; skip EXC 3 (2 bytes)
        INCR    R
        INCR    r11
        RET

gc:     MOV2    L, r14          ; the heap starts again (T and S are the CONS's)
        INCR    r15
        RET                     ; to the CONS, which allocates now

sys1:   LSLI    1               ; T = T * 2
        RET

; The device handlers nest: each sets I again once it has served its device, waits a
; while, then clears I, writes EOI to the interrupt controller and returns. Device 0
; (line 0) is of the higher priority: it may interrupt device 1's handler (counted in
; r23), never the other way round, and no handler is interrupted by its own device
; (irqc.v: the line in service). A handler that sees either stores to DEV + 12.
dev0:   DUP                     ; keep T, S
        MOVR    T, ST           ; and the flags
        PUSH                    ; (and R)
        MOVI2   r21, 0
        CMP2    r9, r21         ; in the critical section?
        B       EQ, @ok
        STR3    r9, r22, 12     ; an error
@ok:    CMP2    r26, r21        ; in its own handler?
        B       EQ, @ok2
        STR3    r26, r22, 12    ; an error
@ok2:   CMP2    r27, r21        ; in device 1's handler: nested
        B       EQ, @ok3
        INCR    r23
@ok3:   INCR    r20
        STR     r20, r22        ; device 0: done
        MOVI2   r26, 1
        SEI                     ; nothing may come now (line 0 is the highest)
        MOVI2   r29, 4
@w:     DECR    r29
        B       NE, @w
        CLI
        MOVI2   r26, 0
        STR3    r20, r22, 28    ; EOI
        POP
        MOVR    ST, T
        DROP
        RTI

dev1:   DUP
        MOVR    T, ST
        PUSH
        MOVI2   r21, 0
        CMP2    r9, r21         ; in the critical section?
        B       EQ, @ok
        STR3    r9, r22, 12
@ok:    CMP2    r26, r21        ; in device 0's handler: a lower priority must not
        B       EQ, @ok2
        STR3    r26, r22, 12
@ok2:   CMP2    r27, r21        ; in its own handler?
        B       EQ, @ok3
        STR3    r27, r22, 12
@ok3:   INCR    r24
        STR     r24, r25        ; device 1: done
        MOVI2   r27, 1
        SEI                     ; device 0 may come in now
        MOVI2   r28, 8
@w:     DECR    r28
        B       NE, @w
        CLI
        MOVI2   r27, 0
        STR3    r24, r22, 28    ; EOI
        POP
        MOVR    ST, T
        DROP
        RTI

sys2:   LSLI    2               ; T = T * 4
        RET

; ---------------------------------------------------------------- vector table $400
        .align  1024
        B       A, start        ; 0
        .align  4
        B       A, undef        ; 1
        .align  4
        B       A, bad          ; 2
        .align  4
        B       A, exc3         ; 3
        .align  4
        B       A, gc           ; 4
        .align  4
        .rept   11
        B       A, bad          ; 5 .. 15
        .align  4
        .endr
        B       A, dev0         ; 16
        .align  4
        B       A, dev1         ; 17
        .align  4
        .rept   30
        B       A, bad          ; 18 .. 47
        .align  4
        .endr
        B       A, sys2         ; 48: here T * 4
        .align  4

; ---------------------------------------------------------------- the program
start:  LIT16   $600
        MOVR    PSP, T          ; the parameter stack: from $600 down
        LIT16   $7F0
        MOVR    RSP, T          ; the return stack: from $7F0 down
        LIT16   DEV
        MOVR    r22, T
        MOVR    r8, T
        LIT16   DEV + 4
        MOVR    r25, T
        LIT16   HEAP + 1
        MOVR    r14, T
        MOVR    L, T            ; the first cell, tagged
        LIT16   HEAP + 1 + 8 * 15
        MOVR    HLIM, T         ; 16 cells
        MOVI2   r2, 1
        MOVI2   r3, 0
        MOVI2   r6, 0
        MOVI2   r7, 0
        MOVI2   r9, 0
        MOVI2   r10, 0
        MOVI2   r11, 0
        MOVI2   r13, 0
        MOVI2   r15, 0
        MOVI2   r20, 0
        MOVI2   r24, 0
        MOVI2   r23, 0
        MOVI2   r26, 0
        MOVI2   r27, 0
        MOVI2   r0, 3
        STR3    r0, r22, 20     ; the interrupt controller: MASK = lines 0, 1
        MOVR    T, VEC
        MOVR    r12, T          ; 0 after reset
        LIT16   300
        MOVR    r1, T           ; 301 times round
        SEI

loop:   ; ---- the flags between instructions
        MOV2    r4, r2
        ADD2    r2, r2
        ADD2    r2, r4          ; r2 * 3
        ADD2    r2, r1          ; + the counter: C ...
        ADC2    r3, r1          ; ... into r3
        MOV2    r5, r2
        XOR2    r5, r3
        CMP2    r5, r2
        B       CC, @x
        INCR    r6
@x:     ; ---- a call with a stack frame
        LIT8    7
        CALL    frame           ; T = 7 + r1
        ADD3    r7, r7, T
        ; ---- every 8th time a critical section
        MOVI2   r0, 7
        AND2    r0, r1
        B       NE, @nc
        CLI
        MOVI2   r9, 1
        ADD2    r3, r2
        ADC2    r3, r2
        MOVI2   r9, 0
        SEI
@nc:    ; ---- the system call
        LIT8    5
        INTR    48              ; T = 10 (or 20 through the second table)
        ADD3    r13, r13, T
        ; ---- every 16th time an undefined opcode and EXC 3
        MOVI2   r0, 15
        AND2    r0, r1
        B       NE, @nu
        .byte   $3F             ; not an opcode: exception 1
        EXC     3
@nu:    ; ---- CONS (car = T, cdr = r1), then its cdr
        DUP
        MOV2    T, r1
        CONS
        CDR
        ADD3    r7, r7, T
        ; ---- halfway: VEC moves to the second table
        LIT16   150
        CMPR    T, r1
        B       NE, @nv
        LIT16   $400
        MOVR    VEC, T
        MOVR    T, VEC
        MOVR    r12, T
@nv:    NEXT    r1, loop

        MOVI2   r0, 1
        STR3    r0, r8, 8       ; the end
end:    B       A, end

frame:  ENTER   2
        ADDR    T, r1
        LEAVE
        RET
