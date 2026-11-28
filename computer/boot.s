; boot.s: the boot loader of the mp32 computer, in the block RAM at $F000_0000 (loaded
; with the FPGA: the linker writes build/boot.hex for BRAM_INIT). The processor starts
; here after reset.
;
; It loads the operating system into the SDRAM and starts it, in four phases. The
; LEDs and the speaker say how far it got (LED0 is the one nearest the USB-C port):
;
;   0. all six LEDs off
;   1. initialize the processor: the stacks, the registers, the screen
;      -> LED0 on, a short beep (0.1 s)
;   2. find a boot method: the first place that holds an image with a good header,
;      in this order:
;        - the SPI flash, at $400000 (the bitstream is at 0; see FLASH_IMAGE)
;        - the microSD card, from block 8 (the raw card, no file system; SD_LBA)
;        S2 held at reset: neither, the serial port at once
;        - the serial port: it waits for an image to come, as long as it takes
;      -> LED1 on
;      failed (the image from the serial port has a bad header):
;      -> LED1 blinks at 1 Hz, 2 long beeps (0.5 s, with the LED), and it stops
;   3. load the operating system: copy the payload, add its words up
;      -> LED2 blinks at 2 Hz while it loads, then stays on
;      failed (a read error, or the sum is wrong):
;      -> LED2 blinks at 1 Hz, 3 long beeps, and it stops
;   4. jump to the operating system (LED0 .. LED2 stay on until it changes them)
;
; Once it stopped, only S1 (or a new bitstream) starts it again. A place without an
; image, or with a bad header, in phase 2 is no failure: the next place is tried.
;
; The image (made by mp32img, see ../toolchain/src/Mp32.Core/BootImage.cs): a header
; of 8 little-endian words, then the payload.
;
;   +0  "mp32"  +4 load  +8 size  +12 entry  +16 sum  +20 0  +24 0  +28 check
;
; A good header: the eight words add up to 0; load is 1 KB aligned; size is a
; multiple of 4, not 0; the payload fits below the screen; entry is in it. Phase 3
; copies the payload to load .. load + size - 1 and compares the sum of its words
; with sum. What happens is reported on the serial port and the screen.
;
; ---------------------------------------------------------------- the handover
; With a good image it waits until the serial port has sent everything, then:
;
;   VEC = load              the payload begins with its vector table
;   PC  = entry             normally load: entry 0 of that table, the reset
;   r1  = where it came from: 1 the flash, 2 the card, 3 the serial port
;   r2  = size
;   I   = 0                 interrupts off, every device's interrupt off, MASK 0
;
; Everything else is as the loader left it: the stacks (PSP, RSP) still point into the
; block RAM, the card's and the flash's chip selects are off, the screen shows what the
; loader wrote, LED0 .. LED2 are on, the amplifier is on. The operating system sets up
; its own stacks first.
;
; The loader does not use interrupts. Its vector table (at $F000_0000, VEC after
; reset) only catches what should not happen: an undefined opcode, an exception, an
; interrupt; each says so, lights all six LEDs and stops.
;
; The I/O (see iodec.v):
;   $FFFF_0000  UART: +0 DATA (write: send; read: bit 8 = a byte came, bits 7..0 the
;               byte), +4 STATUS (bit 2 TXE: all sent)
;   $FFFF_0100  microSD (../sdcard/sdcard.v): +0 DATA, +4 DATA32, +8 CTRL, +12 DATA32LE
;   $FFFF_0200  +0 LEDS: bits 5..0, 1 = lit; +8 TICKS: the processor's clock, 42 MHz
;   $FFFF_0300  the sound (../audio/audio.v): +8 CTRL (bit 0 ON), +16 TONE, +20 LEN
;   $FFFF_0500  SPI flash: as the microSD
;   $0078_0000  the screen's text: 60 rows of 80 words (code, font, paper, ink); the
;               code is the character itself, Latin-1 (font 0,
;               ../display2/tools/make_startfonts.py)
;
; Registers kept across the whole loader:
;   r9  $100  r10 UART  r11 text  r12 column * 4  r13 LEDs  r14 the row's address
;   r16 the colors of a character (ink 82, paper 0, font 0)  r17 320 (a row)
;   r18 the end of the text  r20 the source (1 flash, 2 card, 3 serial port)
;   r21 the source's SPI device (flash or card)  r22 the card: words left in the block
;       (-1: none);
;       the serial port: what putc writes to (0 both, 1 the screen only, 2 the serial
;       port only, see phase 3)
;   r23 the card: the next block  r24 the card: 1 = block addresses (SDHC), 0 = bytes
;   r25 -1 (four bytes of $FF to send)  r31 0
;   r26 load  r27 size  r28 entry  r29 sum (from the header, phase 2 on)
; payload uses r0, r7, r8, r15, r19, r30; the routines below it use r1 .. r6.

TEXT        = $780000
TEXT_END    = $780000 + 60 * 320
RAM_END     = $780000                   ; an image must end here (the screen)
FLASH_IMAGE = $400000                   ; where the image is in the flash
SD_LBA      = 8                         ; the card's block where the image begins: FORTH's
                                        ; block 1 (block 0 is FORTH's volume block)
SD          = -$FF00                    ; $FFFF_0100: the microSD card
FLASH       = -$FB00                    ; $FFFF_0500: the SPI flash
SOUND       = -$FD00                    ; $FFFF_0300: the sound
SD_SLOW     = 52 << 8                   ; CTRL: DIV 52, 396 kHz (the card's start)

LED0        = 1
LED1        = 2
LED2        = 4

HALF_S      = 21000000 >> 8             ; 0.5 s of TICKS, / 256 (LIT, then LSLI 8)
QUARTER_S   = 10500000 >> 8             ; 0.25 s
SHORT_BEEP  = 4688                      ; 0.1 s of samples (46,875 a second)
LONG_BEEP   = 23438                     ; 0.5 s

        .code
; ---------------------------------------------------------------- the vector table
reset:  B       A, start                ; 0  $F000_0000: reset
        .align  4
        B       A, undefined            ; 1  an undefined opcode
        .align  4
        .rept   46
        B       A, unexpected           ; 2 .. 47
        .align  4
        .endr

; ---------------------------------------------------------------- what should not happen
undefined:
        LEA     msg_undefined
        B       A, halt
unexpected:
        LEA     msg_unexpected
halt:   MOVR    r6, T                   ; say so, and stop
        CALL    puts
        MOVI2   r1, $3F                 ; all LEDs
        STR     r1, r13
@stop:  B       A, @stop

; ================================================================ 0. the LEDs off
start:  LIT     -$FE00                  ; $FFFF_0200: the LEDs
        MOVR    r13, T
        MOVI2   r1, 0
        STR     r1, r13

; ================================================================ 1. the processor
        LEA     pstack_top              ; the stacks: in the block RAM (BSS)
        MOVR    PSP, T
        LEA     rstack_top
        MOVR    RSP, T

        LIT     -$10000                 ; $FFFF_0000: the UART
        MOVR    r10, T
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
        MOVI2   r25, -1
        MOVI2   r31, 0
        MOVI2   r20, 0                  ; no source yet: putc writes to both
        MOVI2   r22, 0
        LIT     -$6000                  ; $FFFF_A000: the video unit
        MOVR    r1, T
        STR3    r31, r1, $38            ; SCROLL 0: no text window, rows as they are
                                        ; (FORTH may have left one: a reset)
        CALL    cls
        LEA     msg_banner
        MOVR    r6, T
        CALL    puts

        MOVI2   r1, LED0
        STR     r1, r13
        LIT     SHORT_BEEP
        MOVR    r1, T
        CALL    tone                    ; (it plays by itself)

; ================================================================ 2. a boot method
        MOVI2   r1, LED0 | LED1
        STR     r1, r13
        LDR3    r1, r13, 4              ; BUTTONS: S2 held? then the serial port only
        MOVI2   r2, 2                   ; (an image on the flash or the card that
        AND2    r1, r2                  ; does not work is passed over)
        B       NE, @s2

; ---- the flash
        MOVI2   r20, 1
        LEA     msg_flash
        MOVR    r6, T
        CALL    puts
        CALL    flash_open
        CALL    header
        CMP2    r1, r31
        B       EQ, phase3
        CALL    puts                    ; why not (r6)
        CALL    flash_close

; ---- the microSD card
        MOVI2   r20, 2
        LEA     msg_sd
        MOVR    r6, T
        CALL    puts
        CALL    sd_init
        CMP2    r1, r31
        B       NE, @no_card
        LIT     SD_LBA
        MOVR    r23, T
        CALL    sd_block
        CMP2    r1, r31
        B       NE, @read_error
        CALL    header
        CMP2    r1, r31
        B       EQ, phase3
        CALL    puts
        CALL    sd_end                  ; (the rest of block 0 out first)
        B       A, @serial
@read_error:
        CALL    sd_close
        LEA     msg_read_error
        MOVR    r6, T
        CALL    puts
        B       A, @serial
@no_card:
        LEA     msg_no_card
        MOVR    r6, T
        CALL    puts
        B       A, @serial
@s2:    LEA     msg_s2
        MOVR    r6, T
        CALL    puts

; ---- the serial port: waits for an image
@serial:
        MOVI2   r20, 3
        MOVI2   r22, 0                  ; putc: to both (r22 was the card's)
        LEA     msg_serial
        MOVR    r6, T
        CALL    puts
        MOV2    r21, r10
        CALL    header
        CMP2    r1, r31
        B       EQ, phase3
        MOV2    r7, r6                  ; "serial port: bad header"
        LEA     msg_serial_port
        MOVR    r6, T
        CALL    puts
        MOV2    r6, r7
        CALL    puts
        MOVI2   r26, LED0               ; failed: LED1 blinks, 2 long beeps
        MOVI2   r27, LED1
        MOVI2   r28, 2
        B       A, stop

; ================================================================ 3. load it
; From the serial port, the image comes in while the loader would say what it does:
; the board's USB serial bridge (the BL616) loses bytes that go to the PC while bytes
; come from it. So then the line goes to the screen only while the image comes in
; (with its dots), and to the serial port once it is all there (without the dots).
phase3: MOVI2   r1, 3
        CMP2    r20, r1
        B       NE, @say
        MOVI2   r22, 1                  ; the serial port: the screen only, for now
@say:   CALL    say_loading
        CALL    payload
        MOVI2   r3, 3
        CMP2    r20, r3
        B       NE, @said
        MOV2    r7, r1                  ; (payload's answer: r1, r6)
        MOV2    r8, r6
        MOVI2   r22, 2                  ; the image is in: the same line, to the
        CALL    say_loading             ; serial port only
        MOVI2   r22, 0                  ; from now on to both
        MOV2    r1, r7
        MOV2    r6, r8
@said:  CMP2    r1, r31
        B       EQ, @loaded
        CALL    puts                    ; why (r6)
        CALL    close
        MOVI2   r26, LED0 | LED1        ; failed: LED2 blinks, 3 long beeps
        MOVI2   r27, LED2
        MOVI2   r28, 3
        B       A, stop
@loaded:
        MOVI2   r1, LED0 | LED1 | LED2
        STR     r1, r13

; ================================================================ 4. start it
        LEA     msg_start               ; "ok, start at <entry>"
        MOVR    r6, T
        CALL    puts
        MOV2    r6, r28
        CALL    puthex
        MOVI2   r1, 13
        CALL    putc
        MOVI2   r1, 10
        CALL    putc
        CALL    close
@txe:   LDR3    r1, r10, 4              ; wait until the UART has sent all
        MOVR    T, r1
        TTAG    4, 4
        B       NE, @txe
        MOVR    T, r26                  ; VEC = load
        MOVR    VEC, T
        MOV2    r1, r20                 ; r1 = the source, r2 = the size
        MOV2    r2, r27
        MOVR    T, r28
        MOVR    PC, T                   ; go

; ================================================================ header
; Phase 2 at the source r20 (opened): its image's header. r1 = 0: a good one, with
; r26 load, r27 size, r28 entry, r29 sum; the source stands at the payload. Or r1 != 0
; and r6 = why not: "no image", "bad header", "read error".
header: CALL    get_magic
        CMP2    r1, r31
        B       EQ, @magic
        LEA     msg_no_image
        B       A, @fail
@magic: LIT     $3233                   ; r30: the header's words added up
        LSLI    16
        MOVR    r30, T
        LIT     $706D
        MOVR    r1, T
        OR2     r30, r1
        CALL    get32                   ; +4 load
        CMP2    r1, r31
        B       NE, @ioerr
        MOV2    r26, r2
        ADD2    r30, r2
        CALL    get32                   ; +8 size
        CMP2    r1, r31
        B       NE, @ioerr
        MOV2    r27, r2
        ADD2    r30, r2
        CALL    get32                   ; +12 entry
        CMP2    r1, r31
        B       NE, @ioerr
        MOV2    r28, r2
        ADD2    r30, r2
        CALL    get32                   ; +16 sum
        CMP2    r1, r31
        B       NE, @ioerr
        MOV2    r29, r2
        ADD2    r30, r2
        MOVI2   r19, 3                  ; +20, +24, +28 check
@hdr:   CALL    get32
        CMP2    r1, r31
        B       NE, @ioerr
        ADD2    r30, r2
        DECR    r19
        B       NE, @hdr

        CMP2    r30, r31                ; the eight words add up to 0
        B       NE, @bad
        LIT     $3FF                    ; load 1 KB aligned
        MOVR    r1, T
        AND2    r1, r26
        B       NE, @bad
        MOVR    T, r27                  ; size: not 0, a multiple of 4
        B       TZ, @bad
        TTAG    3, 0
        B       NE, @bad
        ADD3    r1, r26, r27            ; load + size <= RAM_END
        B       CS, @bad
        LIT     RAM_END
        MOVR    r2, T
        CMP2    r2, r1
        B       LO, @bad
        SUB3    r1, r28, r26            ; load <= entry < load + size
        B       LO, @bad
        CMP2    r1, r27
        B       HS, @bad
        MOVI2   r1, 0
        RET
@ioerr: LEA     msg_read_error
        B       A, @fail
@bad:   LEA     msg_bad_header
@fail:  MOVR    r6, T
        MOVI2   r1, 1
        RET

; ================================================================ payload
; Phase 3: the payload from the source to r26, size r27, its words added up and
; compared with r29. LED2 blinks at 2 Hz meanwhile; LED0 and LED1 stay on. r1 = 0: it
; is there; or r1 != 0 and r6 = why not: "read error", "bad checksum".
payload:
        MOV2    r15, r26                ; where the next word goes
        MOVR    T, r27
        LSRI    2
        MOVR    r19, T                  ; words to go
        MOVI2   r7, 0                   ; their sum
        LIT     16384                   ; a dot every 64 KB
        MOVR    r8, T
        MOVI2   r30, LED0 | LED1 | LED2 ; the LEDs, LED2 on first
        STR     r30, r13
        LDR3    r0, r13, 8              ; r0: when LED2 changes next
        LIT     QUARTER_S
        LSLI    8
        MOVR    r1, T
        ADD2    r0, r1
@word:  CALL    get32
        CMP2    r1, r31
        B       NE, @ioerr
        STR     r2, r15
        ADD2    r7, r2
        INCWR   r15
        LDR3    r1, r13, 8              ; time for LED2?
        SUB2    r1, r0
        B       MI, @noblink
        MOVI2   r1, LED2
        XOR2    r30, r1
        STR     r30, r13
        LIT     QUARTER_S
        LSLI    8
        MOVR    r1, T
        ADD2    r0, r1
@noblink:
        DECR    r8
        B       NE, @nodot
        MOVI2   r1, '.'
        CALL    putc
        LIT     16384
        MOVR    r8, T
@nodot: DECR    r19
        B       NE, @word
        CMP2    r7, r29                 ; the sum
        B       NE, @badsum
        MOVI2   r1, 0
        RET
@badsum:
        LEA     msg_bad_sum
        B       A, @fail
@ioerr: LEA     msg_read_error
@fail:  MOVR    r6, T
        MOVI2   r1, 1
        RET

; close: the flash or the card (r20) deselected. Uses r1, r2.
close:  MOVI2   r1, 1
        CMP2    r20, r1
        B       EQ, flash_close
        MOVI2   r1, 2
        CMP2    r20, r1
        B       EQ, sd_end
        RET

; ================================================================ failed: stop
; stop: LED r27 blinks at 1 Hz, with LEDs r26 on; the first r28 times it is on, a
; long beep sounds. For ever.
stop:   LDR3    r0, r13, 8              ; r0: the next half second
@blink: OR3     r1, r26, r27            ; on ...
        STR     r1, r13
        CMP2    r28, r31
        B       EQ, @quiet
        DECR    r28
        LIT     LONG_BEEP               ; ... with a beep
        MOVR    r1, T
        CALL    tone
@quiet: CALL    half
        STR     r26, r13                ; ... off
        CALL    half
        B       A, @blink

; half: wait until r0 + 0.5 s; r0 = that. Uses r1.
half:   LIT     HALF_S
        LSLI    8
        MOVR    r1, T
        ADD2    r0, r1
@wait:  LDR3    r1, r13, 8              ; TICKS
        SUB2    r1, r0
        B       MI, @wait
        RET

; tone: the amplifier on, and the sound's tone (442 Hz, height 4000) for r1 samples.
; It plays by itself: tone returns at once. Uses r2 .. r4.
tone:   LIT     SOUND + 8               ; CTRL: ON
        MOVR    r2, T
        MOVI2   r3, 1
        STR     r3, r2
        LIT     SOUND + 16              ; TONE: height 4000, half a period 53 samples
        MOVR    r2, T
        LIT     4000
        LSLI    16
        MOVR    r3, T
        MOVI2   r4, 53
        OR2     r3, r4
        STR     r3, r2
        LIT     SOUND + 20              ; LEN
        MOVR    r2, T
        STR     r1, r2
        RET

; ---------------------------------------------------------------- get32, get_magic
; get32: the next word of the image in r2 (little-endian), r1 = 0; or r1 != 0 when
; the source could not be read. Uses r1 .. r6.
get32:  MOVI2   r1, 1
        CMP2    r20, r1
        B       EQ, flash_get32
        MOVI2   r1, 2
        CMP2    r20, r1
        B       EQ, sd_get32
        B       A, ser_get32

; get_magic: r1 = 0 when the image's first word is "mp32". The flash and the card:
; the first word must be it. The serial port: everything before it is skipped.
get_magic:
        LIT     $3233                   ; r29 = "mp32" (load sets r29 later)
        LSLI    16
        MOVR    r29, T
        LIT     $706D
        MOVR    r1, T
        OR2     r29, r1
        MOVI2   r1, 3
        CMP2    r20, r1
        B       EQ, @serial
        CALL    get32
        CMP2    r1, r31
        B       NE, @done
        MOVI2   r1, 0
        CMP2    r2, r29
        B       EQ, @done
        MOVI2   r1, 1
@done:  RET
@serial:                                ; the last four bytes, slid along
        MOVI2   r5, 0
@next:  CALL    ser_getb                ; r1
        MOVR    T, r5
        LSRI    8
        MOVR    r5, T
        MOVR    T, r1
        LSLI    24
        MOVR    r1, T
        OR2     r5, r1
        CMP2    r5, r29
        B       NE, @next
        MOVI2   r1, 0
        RET

; ================================================================ the SPI flash
; flash_open: wake the flash (it may be powered down), then start a READ at
; FLASH_IMAGE; the bytes then come one after the other for as long as CS stays on.
flash_open:
        LIT     FLASH
        MOVR    r21, T
        MOVI2   r1, 1                   ; CS on (DIV 0: 21 MHz)
        STR3    r1, r21, 8
        LIT     $AB                     ; release from deep power-down
        MOVR    r1, T
        STR3    r1, r21, 0
        LDR3    r1, r21, 0              ; (waits for the byte)
        MOVI2   r1, 0                   ; CS off
        STR3    r1, r21, 8
        LIT     200                     ; tRES1: 3 us
        MOVR    r1, T
@wait:  DECR    r1
        B       NE, @wait
        MOVI2   r1, 1                   ; CS on
        STR3    r1, r21, 8
        LIT     $30000 | (FLASH_IMAGE >> 8)   ; READ ($03) and the address
        LSLI    8
        MOVR    r1, T
        STR3    r1, r21, 4              ; DATA32: $03, then the address, high byte first
        RET

flash_get32:
        STR3    r25, r21, 12            ; four clocks of a byte each ...
        LDR3    r2, r21, 12             ; ... and the bytes, little-endian
        MOVI2   r1, 0
        RET

flash_close:
        LIT     FLASH
        MOVR    r1, T
        MOVI2   r2, 0
        STR3    r2, r1, 8               ; CS off
        RET

; ================================================================ the microSD card
; spi_byte: send r1 (bits 7..0) to the SPI device r21, r1 = the byte that came back.
spi_byte:
        STR     r1, r21
        LDR     r1, r21
        RET

; sd_cmd: command r1 (0 .. 63) with the argument r2 and the CRC byte r3; r1 = the
; card's answer R1 (bit 7 = 1: no answer). Uses r1 .. r6.
sd_cmd: MOV2    r4, r1
        MOVI2   r1, -1                  ; a byte of $FF first
        CALL    spi_byte
        MOVI2   r5, $40
        OR3     r1, r4, r5
        CALL    spi_byte
        STR3    r2, r21, 4              ; the argument, high byte first
        MOV2    r1, r3
        CALL    spi_byte
        MOVI2   r5, 16                  ; the answer: within 8 bytes, give it 16
@poll:  MOVI2   r1, -1
        CALL    spi_byte
        MOVR    T, r1
        TTAG    $80, 0
        B       EQ, @got
        DECR    r5
        B       NE, @poll
@got:   RET

; sd_init: the card into SPI mode and ready; r24 = 1 for block addresses (SDHC, SDXC),
; 0 for byte addresses (SDSC). r1 = 0, or != 0 when there is no card or it did not
; get ready. Uses r1 .. r6, r22, r23.
sd_init:
        LIT     SD
        MOVR    r21, T
        LIT     SD_SLOW                 ; CS off, 396 kHz
        MOVR    r1, T
        STR3    r1, r21, 8
        MOVI2   r6, 10                  ; 80 clocks with CS off
@clocks:
        MOVI2   r1, -1
        CALL    spi_byte
        DECR    r6
        B       NE, @clocks
        LIT     SD_SLOW | 1             ; CS on
        MOVR    r1, T
        STR3    r1, r21, 8

        MOVI2   r1, 0                   ; CMD0: go idle (SPI mode)
        MOVI2   r2, 0
        LIT     $95
        MOVR    r3, T
        CALL    sd_cmd
        MOVI2   r2, 1
        CMP2    r1, r2
        B       NE, @fail               ; no card

        MOVI2   r1, 8                   ; CMD8: 2.7 .. 3.6 V, pattern $AA
        LIT     $1AA
        MOVR    r2, T
        LIT     $87
        MOVR    r3, T
        CALL    sd_cmd
        MOVI2   r22, 0                  ; ACMD41's argument: 0 for a version 1 card
        MOVI2   r2, 1
        CMP2    r1, r2
        B       NE, @acmd41             ; illegal command: version 1
        STR3    r25, r21, 4             ; R7: four more bytes
        LDR3    r1, r21, 4
        LIT     $FFF
        MOVR    r2, T
        AND2    r1, r2
        LIT     $1AA
        MOVR    r2, T
        CMP2    r1, r2
        B       NE, @fail               ; not our voltage
        LIT     $4000                   ; HCS: we take SDHC
        LSLI    16
        MOVR    r22, T

@acmd41:
        LIT     3000                    ; about a second
        MOVR    r23, T
@try:   MOVI2   r1, 55                  ; CMD55: an application command follows
        MOVI2   r2, 0
        MOVI2   r3, $65
        CALL    sd_cmd
        MOVI2   r1, 41                  ; ACMD41: start
        MOV2    r2, r22
        MOVI2   r3, $77
        CALL    sd_cmd
        MOVR    T, r1
        B       TZ, @ready
        DECR    r23
        B       NE, @try
        B       A, @fail                ; never got ready

@ready: MOVI2   r24, 0
        MOVR    T, r22
        B       TZ, @sdsc               ; version 1: SDSC
        MOVI2   r1, 58                  ; CMD58: the OCR
        MOVI2   r2, 0
        MOVI2   r3, -3                  ; $FD (the low byte is sent)
        CALL    sd_cmd
        STR3    r25, r21, 4
        LDR3    r1, r21, 4              ; the OCR, bit 31 first
        MOVR    T, r1
        LSLI    1                       ; CCS (bit 30) into N
        B       PL, @sdsc
        MOVI2   r24, 1                  ; SDHC: block addresses
        B       A, @fast
@sdsc:  MOVI2   r1, 16                  ; CMD16: blocks of 512 bytes
        LIT     512
        MOVR    r2, T
        MOVI2   r3, 1
        CALL    sd_cmd
@fast:  MOVI2   r1, 0                   ; CS off, 21 MHz from now on
        STR3    r1, r21, 8
        MOVI2   r1, -1
        CALL    spi_byte
        MOVI2   r1, 0
        RET
@fail:  CALL    sd_close
        MOVI2   r1, 1
        RET

; sd_block: start reading block r23 (CMD17) and wait for its data; r22 = 128 words to
; go. r1 = 0, or != 0 when the card said no or never sent the block. Uses r1 .. r6.
sd_block:
        MOVI2   r22, -1                 ; no block being read (yet)
        MOVI2   r1, 1                   ; CS on, 21 MHz
        STR3    r1, r21, 8
        MOVR    T, r23                  ; the address: the block, or its first byte
        MOVR    r2, T
        CMP2    r24, r31
        B       NE, @addr
        LSLI    9
        MOVR    r2, T
@addr:  MOVI2   r1, 17                  ; CMD17: read one block
        MOVI2   r3, 1
        CALL    sd_cmd
        CMP2    r1, r31
        B       NE, @fail
        LIT     200000                  ; the data token $FE: within 100 ms
        MOVR    r4, T
        LIT     $FE
        MOVR    r5, T
@token: MOVI2   r1, -1
        CALL    spi_byte
        CMP2    r1, r5
        B       EQ, @data
        DECR    r4
        B       NE, @token
@fail:  MOVI2   r1, 1
        RET
@data:  LIT     128
        MOVR    r22, T
        MOVI2   r1, 0
        RET

; sd_get32: the next word of the card; at the end of a block, its CRC and the next
; block first.
sd_get32:
        CMP2    r22, r31
        B       NE, @word
        MOVI2   r1, -1                  ; the block's CRC (not checked)
        CALL    spi_byte
        MOVI2   r1, -1
        CALL    spi_byte
        INCR    r23
        CALL    sd_block
        CMP2    r1, r31
        B       NE, @err
@word:  STR3    r25, r21, 12
        LDR3    r2, r21, 12
        DECR    r22
        MOVI2   r1, 0
@err:   RET

; sd_end: the rest of the block being read (r22 words, if r22 >= 0) and its CRC
; clocked out, then sd_close. A card that is deselected in the middle of a block goes
; on sending it when it is selected again, and takes no command until it is done.
; Uses r1, r2, r22.
sd_end: CMPI2   r22, 0
        B       LT, sd_close
@w:     CMP2    r22, r31
        B       EQ, @crc
        STR3    r25, r21, 12
        LDR3    r2, r21, 12
        DECR    r22
        B       A, @w
@crc:   MOVI2   r1, -1
        CALL    spi_byte
        MOVI2   r1, -1
        CALL    spi_byte
        MOVI2   r22, -1

; sd_close: CS off, and a byte of clocks so the card lets go of MISO.
sd_close:
        LIT     SD
        MOVR    r1, T
        MOVI2   r2, 0
        STR3    r2, r1, 8
        STR     r25, r1
        LDR     r2, r1
        RET

; ================================================================ the serial port
; ser_getb: wait for a byte, r1 = the byte. Uses r1 only.
ser_getb:
        LDR     r1, r10                 ; DATA: bit 8 = a byte came
        CMP2    r1, r9
        B       LO, ser_getb
        SUB2    r1, r9
        RET

; ser_get32: the next four bytes, little-endian, in r2; r1 = 0.
ser_get32:
        CALL    ser_getb
        MOV2    r2, r1
        CALL    ser_getb
        MOVR    T, r1
        LSLI    8
        MOVR    r1, T
        OR2     r2, r1
        CALL    ser_getb
        MOVR    T, r1
        LSLI    16
        MOVR    r1, T
        OR2     r2, r1
        CALL    ser_getb
        MOVR    T, r1
        LSLI    24
        MOVR    r1, T
        OR2     r2, r1
        MOVI2   r1, 0
        RET

; ================================================================ the screen and the UART
; say_loading: "loading <size> bytes to <load> ", with putc. Uses r1 .. r6.
say_loading:
        LEA     msg_loading
        MOVR    r6, T
        CALL    puts
        MOV2    r6, r27
        CALL    puthex
        LEA     msg_bytes_to
        MOVR    r6, T
        CALL    puts
        MOV2    r6, r26
        CALL    puthex
        MOVI2   r1, ' '
        CALL    putc
        RET

; putc: the byte in r1 to the serial port and to the screen. Uses r2 .. r4. While
; the image comes in on the serial port (r20 = 3), r22 picks: 1 the screen only, 2
; the serial port only, 0 both.
putc:   MOVI2   r3, 3
        CMP2    r20, r3
        B       NE, @both
        MOVI2   r3, 1
        CMP2    r22, r3
        B       EQ, @screen             ; 1: the screen only
        STR     r1, r10
        MOVI2   r3, 2
        CMP2    r22, r3
        B       EQ, putc_done           ; 2: the serial port only
        B       A, @screen
@both:  STR     r1, r10                 ; the UART (waits while its queue is full)
@screen:
        MOVI2   r3, 13
        CMP2    r1, r3
        B       EQ, newline             ; CR: a new line
        MOVI2   r3, 10
        CMP2    r1, r3
        B       EQ, putc_done           ; LF: only the serial port
        OR3     r2, r1, r16             ; the character (Latin-1, font 0) with its colors
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

; puts: the string at r6 (ending with a 0), with putc. Uses r1 .. r6.
puts:   LDRB    r1, r6
        MOVR    T, r1
        B       TZ, puts_done
        CALL    putc
        INCR    r6
        B       A, puts
puts_done:
        RET

; puthex: r6 as 8 hex digits, with putc. Uses r1 .. r6.
puthex: MOVI2   r5, 8
@digit: MOVR    T, r6
        LSRI    28
        MOVR    r1, T
        MOVI2   r2, 10
        CMP2    r1, r2
        B       LO, @num
        MOVI2   r2, 'A' - '0' - 10
        ADD2    r1, r2
@num:   MOVI2   r2, '0'
        ADD2    r1, r2
        CALL    putc
        MOVR    T, r6
        LSLI    4
        MOVR    r6, T
        DECR    r5
        B       NE, @digit
        RET

; cls: the whole screen blank, the cursor at the top left. Uses r2 .. r4.
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
msg_banner:     .asciiz "mp32 boot\r\n"
msg_flash:      .asciiz "flash: "
msg_sd:         .asciiz "sd card: "
msg_serial:     .asciiz "serial port: send the image\r\n"
msg_serial_port: .asciiz "serial port: "
msg_loading:    .asciiz "loading "
msg_bytes_to:   .asciiz " bytes to "
msg_start:      .asciiz "ok, start at "
msg_no_image:   .asciiz "no image\r\n"
msg_bad_header: .asciiz "bad header\r\n"
msg_bad_sum:    .asciiz "bad checksum\r\n"
msg_read_error: .asciiz "read error\r\n"
msg_no_card:    .asciiz "no card\r\n"
msg_s2:         .asciiz "S2: the flash and the card passed over\r\n"
msg_undefined:  .asciiz "\r\nundefined opcode\r\n"
msg_unexpected: .asciiz "\r\nunexpected interrupt or exception\r\n"

        .bss
pstack:     .res 252
pstack_top: .res 4
rstack:     .res 252
rstack_top: .res 4
