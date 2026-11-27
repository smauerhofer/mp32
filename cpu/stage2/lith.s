; lith.s: the program of lith_tb.v, a test of LITH (T[31:24] = a constant, nothing
; else changes) through the whole pipeline, and of the assembler's LIT of 32 bits
; (LIT24 + LITH).
;
; lith.hex holds its CODE bytes from address 0, one per line, padded to 1 KB:
;   mp32as -o build/lith.o -l build/lith.lst lith.s
;   mp32ld -C lith.cfg -o build/lith.bin build/lith.o
;   python3 -c "..." (see lith_tb.v)
;
; What lith_tb.v checks at the end:
;   r1  = $12345678   LIT24 then LITH at once, T used at once
;   r2  = $00FFFFFF   LITH over a negative LIT8: only the top byte changes
;   r3  = r5          PSP before and after LITH: the stack does not move
;   r4  = $80000000   LITH $80 over 0
;   r6  = 7           S kept
;   r7  = $FF000001
;   r8  = 3           the flags (C and Z) as they were before LITH
;   r11 = $113BCCDD   LITH right after a load into T (the load-use wait)
;   r12 = $CAFEBABE   LIT $CAFEBABE: the assembler's 6 bytes, padded to a new line
;   r13 = $FE345678   LITH right after MOVR T, r1 (forwarding)

start:
        LIT16   $200
        MOVR    PSP, T          ; the parameter stack: from $200 down
        LIT16   $3F0
        MOVR    RSP, T          ; the return stack: from $3F0 down

        ; ---- 1: LIT24 + LITH back to back, the result used at once
        LIT24   $345678
        LITH    $12
        MOVR    r1, T           ; $12345678

        ; ---- 2: over a negative LIT8 (sign-extended): only bits 31..24 change
        LIT8    -1
        LITH    $00
        MOVR    r2, T           ; $00FFFFFF

        ; ---- 3: the stack does not move, S stays
        LIT8    7
        DUP                     ; S = 7
        MOVR    T, PSP
        MOVR    r3, T           ; PSP before
        LIT8    0
        LITH    $80
        MOVR    r4, T           ; $80000000
        MOVR    T, PSP
        MOVR    r5, T           ; PSP after
        MOV2    r6, S           ; 7

        ; ---- 4: the flags stay
        LIT8    3
        MOVR    ST, T           ; C = 1, Z = 1
        LIT24   1
        LITH    $FF
        MOVR    r7, T           ; $FF000001
        MOVR    T, ST
        MOVR    r8, T           ; 3

        ; ---- 5: right after a load into T
        LIT24   $3BCCDD
        LITH    $AA
        MOVR    r9, T           ; $AA3BCCDD
        LIT16   $100
        MOVR    r10, T
        MOVR    T, r9
        STR     T, r10          ; the word at $100 = $AA3BCCDD
        LIT8    0
        LDR     T, r10
        LITH    $11
        MOVR    r11, T          ; $113BCCDD

        ; ---- 6: the assembler's LIT of 32 bits, where it would cross a line
        .align  16
        .rept   12
        NOP
        .endr
        LIT     $CAFEBABE       ; 4 NOPs of padding, then LIT24 + LITH
        MOVR    r12, T

        ; ---- 7: right after a register moved into T
        MOVR    T, r1
        LITH    $FE
        MOVR    r13, T          ; $FE345678

        .align  16
done:   CJMPL   A, done
