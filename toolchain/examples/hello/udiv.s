; udiv.s - unsigned 32 / 32 division with DIVS (cpu/isa.md, DIVS).
;
;   udiv ( n d -- q )

        .export udiv

        .code
udiv:   SWAP                    ; ( d n )
        MOVR    TMPL, T         ; TMPL = n, the low word of the dividend
        LIT     0               ; T = 0, the high word; S = d, the divisor
        LSR                     ; C = 0 (T stays 0)
        .rept   33
        DIVS
        .endr
        MOVR    T, TMPL         ; the quotient
        NIP                     ; ( q )
        RET
