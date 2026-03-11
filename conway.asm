; =============================================================================
; Game Boy "Hello World" - A beginner's guide to GB assembly
; =============================================================================
; This program displays a graphic on the Game Boy screen.
;
; ARCHITECTURE OVERVIEW:
; The Game Boy has a Sharp LR35902 CPU (similar to the Intel 8080 / Zilog Z80).
; Key registers:
;   a       - 8-bit "accumulator", used for most operations
;   b, c    - 8-bit general purpose (can be paired as 16-bit "bc")
;   d, e    - 8-bit general purpose (can be paired as 16-bit "de")
;   h, l    - 8-bit general purpose (can be paired as 16-bit "hl")
;   sp      - 16-bit stack pointer
;   pc      - 16-bit program counter
;   f       - 8-bit flags register (zero, subtract, half-carry, carry)
;
; MEMORY MAP (simplified):
;   $0000-$7FFF  - ROM (your game code and data)
;   $8000-$9FFF  - Video RAM (tile data + tile maps)
;     $8000-$8FFF  - Tile data block 0
;     $9000-$97FF  - Tile data block 1
;     $9800-$9BFF  - Tile map 0 (32x32 grid of tile indices)
;     $9C00-$9FFF  - Tile map 1
;   $C000-$DFFF  - Work RAM
;   $FF00-$FF7F  - Hardware I/O registers
;   $FF80-$FFFE  - High RAM (HRAM)
;
; KEY CONCEPTS:
; - "Tiles" are 8x8 pixel graphics. Each tile is 16 bytes (2 bits per pixel).
; - The "tilemap" is a 32x32 grid where each byte is an index into the tile data.
; - The screen shows a 20x18 tile window (160x144 pixels) of the tilemap.
; - VBlank is the period when the LCD is not drawing (scanlines 144-153).
;   This is the only safe time to modify VRAM or turn off the LCD.
; =============================================================================

INCLUDE "hardware.inc"

; =============================================================================
; ROM HEADER - Required by the Game Boy at address $0100-$014F
; =============================================================================
; The Game Boy boot ROM jumps to $0100 after startup. The cartridge header at
; $0100-$014F contains metadata (title, checksums, etc.). rgbfix fills this in.
SECTION "Header", ROM0[$100]

	jp EntryPoint            
	ds $150 - @, 0

; =============================================================================
; ENTRY POINT - Program execution starts here
; =============================================================================
EntryPoint:

; --- Disable audio ---------------------------------------------------
	ld a, 0                  
	ld [rNR52], a            

; --- Wait for VBlank -------------------------------------------------
WaitVBlank:
	ld a, [rLY]              
	cp 144                  
	jr c, WaitVBlank         

; --- Turn off the LCD ------------------------------------------------
	ld a, 0
	ld [rLCDC], a

; --- Copy title tile graphics into VRAM ------------------------------
;
; This is a byte-by-byte copy loop using three register pairs:
;   de = source address (points to our Tiles data in ROM)
;   hl = destination address (VRAM at $8000, tile data block 1)
;   bc = byte counter (number of bytes remaining to copy)
	ld de, TitleTiles        ; de = address of Tiles label (source pointer)
	ld hl, $8000             ; hl = $8000 (start of tile block 0 in VRAM)
	ld bc, TitleTiles.End - TitleTiles ; bc = total byte count (assembler calculates this
	                         ; at build time from the label positions)
CopyTiles:
	ld a, [de]               ; Read one byte from the source address in de.
	ld [hli], a              ; Write that byte to the address in hl, THEN
	                         ; increment hl by 1. "[hli]" = "[hl+]" shorthand.
	inc de                   ; Increment source pointer de by 1.
	                         ; (There's no "[dei]" instruction, so we do it
	                         ; manually.)
	dec bc                   ; Decrement the byte counter bc by 1.
	                         ; NOTE: "dec bc" does NOT set the zero flag!
	                         ; (16-bit inc/dec never affect flags on the GB CPU.)
	ld a, b                  ; So we check if bc == 0 manually:
	or a, c                  ; OR b with c. Result is 0 only if BOTH are 0.
	                         ; "or" DOES set the zero flag.
	jr nz, CopyTiles         ; "jr nz" = jump if NOT zero (bc still > 0).
	                         ; If bc != 0, keep copying. Otherwise, fall through.

; --- Copy the title tilemap into VRAM --------------------------------
; The tilemap tells the GPU which tile to draw in each grid cell.
; Each byte in the map is an index into the tile data we just loaded.
; Same copy loop pattern as above, just different source/destination.
	ld de, TitleTilemap      ; de = address of our tilemap data in ROM
	ld hl, $9800             ; hl = $9800 (start of tile map 0 in VRAM)
    ld c, 18
CopyTilemap:
    ld b, 20                 ; 20 columns
CopyTilemapCol:
	ld a, [de]               ; Read one tilemap byte from ROM
	ld [hli], a              ; Write it to VRAM, advance hl
	inc de                   ; Advance source pointer
    dec b
    jr nz, CopyTilemapCol
.RowComplete:
    push de
    ld  de, 12
    add hl, de
    pop de
    dec c
    jr nz, CopyTilemap

; --- Turn the LCD back on --------------------------------------------
	ld a, LCDC_ON | LCDC_BG_ON | LCDC_BLOCK01 ; Combine two flags using bitwise OR:
	                         ;   LCDC_ON   = bit 7 (enable LCD)
	                         ;   LCDC_BG_ON = bit 0 (enable background layer)
                             ;   LCDC_BLOCK01 use unsigned tile data
	                         ; These constants are defined in hardware.inc.
	ld [rLCDC], a            ; Write to LCD Control to turn the screen on
	                         ; with background rendering enabled.

; --- Set the color palette --------------------------------------------
	ld a, %11100100         ; "%" prefix = binary literal.
	                         ; The BG palette maps 2-bit pixel values to shades:
	                         ;   bits 1-0 = color 0 = %00 = lightest (white)
	                         ;   bits 3-2 = color 1 = %01 = light gray
	                         ;   bits 5-4 = color 2 = %10 = dark gray
	                         ;   bits 7-6 = color 3 = %11 = darkest (black)
	                         ; %11100100 maps: 0->white, 1->lgray, 2->dgray, 3->black
	ld [rBGP], a             ; rBGP = Background Palette register

; -- Pause on title screen and seed rng ----------------------------------------
ld b,0
Title:
    inc b
    ld a, JOYP_GET_BUTTONS
    ld [rP1], a 
    ld a, [rP1]
    and a, (1 << B_JOYP_START)
    jr nz, Title
EndTitle:
    ld a, b
    or 1
    ld [seed], a


; -- Setup LCD and Tileset for main program
TitleEnd:
.waitVBlank:
    ld a, [rLY]              
    cp 144 
    jr c, .waitVBlank
    ld a, 0
    ld [rLCDC], a           

ld de, $2000
ld hl, $8000
ZeroOutVram:
    ld a, 0
    ld [hli], a
    dec de
    ld a, d
    or a, e
    jr nz, ZeroOutVram

    ld de, Tiles 
    ld hl, $9000             
    ld bc, Tiles.End - Tiles 
CopyMainTiles:
    ld a, [de]
    ld [hli], a
    inc de
    dec bc
    ld a, b
    or a, c
    jr nz, CopyMainTiles

    ld hl, CurrentGen
    ld de, 22 * 20 * 2
ZeroOutWram:
    ld a, 0
    ld [hli], a
    dec de
    ld a, d
    or a, e
    jr nz, ZeroOutWram

    ld hl, CurrentGen + 23
    ld c, 0 ; row
SeedGeneration1:
SeedRow:
    ld d, 0 ; column
    SeedColumn:
    call Random
    and 1
    ld [hli], a
    inc d
    ld a, d
    cp 20
    jr nz, SeedColumn
    
    inc hl ; handle padding
    inc hl
    inc c
    ld a, c
    cp 18
    jr nz, SeedRow

TurnLCDOn:
    ld a, LCDC_ON | LCDC_BG_ON
    ld [rLCDC], a
    ld a, %11100100
    ld [rBGP], a

; --- Main loop -----------------------------------------------
Main:
ld hl,$9800
ld de,CurrentGen + 23 ; skip entire first "buffer" row as well as the first buffer byte in row 1
ld c,0
;.waitVBlankEnd:
;    ld a, [rLY]
;    cp 144
;    jr nc, .waitVBlankEnd
.waitVBlank:
    ld a, [rLY]
    cp 144 
    jr c, .waitVBlank

    ld b, 0 ; column counter
.loadTiles:
    ld a, [de]
    ld [hli], a
    inc de
    inc b
    ld a, b
    cp 20
    jr c, .loadTiles ; write 20 tiles

    push de
    ld de, 12 ; skip the 12 invisible columns
    add hl, de
    pop de
    inc de ; add 2 to de to skip end and start buffer slots in each row
    inc de
    inc c
    ld a, c
    cp 18
    jr c, .waitVBlank; increment row and loop forever if we're finished

.drawingFinished:
    ; when drawing has finished do the computation for next generation
    ld a, LOW(NextGen + 23)
    ld [nextGenPtr], a
    ld a, HIGH(NextGen + 23)
    ld [nextGenPtr + 1], a
    call ComputeNextGeneration

    ; now we have the new generation so copy next gen to current
    ld de, CurrentGen 
    ld hl, NextGen 
    ld bc, 22 * 20 
.copyNewGeneration:
    ld a, [hli]
    ld [de], a
    inc de
    dec bc
    ld a, b
    or a, c
    jr nz, .copyNewGeneration
    jp Main

.done:
    ;jr .done
    ;jp Main

ComputeNextGeneration:
    ld de, CurrentGen + 23  ; start at first active cell
    ld c, 18 ; current row
    
    .computeRow:
    ld b, 20 ; current column

    .computeColumn:
        ; for each cell we need to check -23, -22, -21, -1, +1, +21, +22, +23
        ld a, 0 ; accumulator for counting "alive" cells
        
        ; -23
        ld h, d
        ld l, e
        push bc
        ld bc, $FFE9
        add hl, bc
        add a, [hl]
        pop bc

        ; -22
        inc hl
        add a, [hl]

        ; -21
        inc hl
        add a, [hl]

        ; -1
        ld h, d
        ld l, e
        dec hl
        add a, [hl]

        ; +1
        inc hl
        inc hl
        add a, [hl]

        ; +21
        ld h, d
        ld l, e
        push bc
        ld bc, $17
        add hl, bc
        add a, [hl]
        pop bc

        ; +22
        inc hl
        add a, [hl]

        ; +23
        inc hl
        add a, [hl]

        cp 3
        jr z, .alive

        cp 2
        jr nz, .dead

        push af
        ld a, [de]
        or a
        jr z, .deadPop
        pop af
        jr .alive

        .deadPop:
        pop af
        jr .dead

        .dead:
        ld a, 0
        jr .writeCell

        .alive:
        ld a, 1

        ; update the next gen buffer
        .writeCell:
        push de                 ; save current gen pointer
        push af

        ld a, [nextGenPtr]
        ld l, a
        ld a, [nextGenPtr + 1]
        ld h, a

        pop af
        ld [hli], a

        ld a, l
        ld [nextGenPtr], a
        ld a, h
        ld [nextGenPtr + 1], a

        pop de

        inc de
        dec b
        jr nz, .computeColumn
    dec c
    jr z, .done
    inc de
    inc de

    ld a, [nextGenPtr]
    ld l, a
    ld a, [nextGenPtr + 1]
    ld h, a

    inc hl
    inc hl

    ld a, l
    ld [nextGenPtr], a
    ld a, h
    ld [nextGenPtr +1 ], a
    jr  .computeRow
    .done:
        ret


; Linear feedback shift register (LFSR). Shift and XOR a 16 bit seed with math magic to get random numbers.
Random:
    ld a, [seed + 0]    ; load low byte of seed
    ld b, a
    ld a, [seed + 1]    ; load high byte of seed

    srl a               ; shift high byte right, bit 0 goes to carry
    rr b                ; shift low byte right, carry comes in from top

    ld [seed + 1], a
    ld a, b
    ld [seed + 0], a

    jr nc, .noFeedback
    ld a, [seed + 1]
    xor $B4
    ld [seed + 1], a
.noFeedback:
    ld a, b
    ret

SECTION "Game State", WRAM0
CurrentGen:
    ds 22 * 20  ; 440 bytes (22 wide x 20 tall; 20x18 with ring of padding)
NextGen:
    ds 22 * 20  ; 440 bytes
nextGenPtr:
    ds 2
seed:
    ds 2

SECTION "Title Tile Data", ROM0

TitleTiles:
    INCBIN "tiles.bin"
.End:

SECTION "Title Tilemap", ROM0

TitleTilemap:
    INCBIN "tilemap.bin"
.End:

SECTION "Tile data", ROM0

Tiles:
	db $ff,$00, $ff,$00, $ff,$00, $ff,$00, $ff,$00, $ff,$00, $ff,$00, $ff,$00
	db $00,$ff, $00,$ff, $00,$ff, $00,$ff, $00,$ff, $00,$ff, $00,$ff, $00,$ff
.End:
