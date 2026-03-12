; =============================================================================
; Conway's Game of Life for Game Boy - Written in Z80-style assembly
; =============================================================================
; A Game Boy implementation of Conway's Game of Life, built as a learning
; exercise for GB assembly programming (DevCon hackathon project).
;
; Features:
;   - Title screen with custom graphic (press Start to begin)
;   - Random initial seed based on how long you wait on the title screen
;   - 20x18 cell grid rendered to the Game Boy's 160x144 pixel screen
;   - Press Select during gameplay to reset with a new random pattern
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
;
; The VRAM tilemap is 32 columns wide, but the screen only shows 20.
; Our source tilemap data is packed (20 bytes per row), so after copying
; 20 bytes we must skip 12 bytes in VRAM to reach the next visible row.
;
; Registers:
;   de = source pointer (ROM tilemap data, packed 20 cols)
;   hl = destination pointer (VRAM tilemap at $9800, 32 cols wide)
;   c  = row counter (18 rows)
;   b  = column counter (20 columns per row)
	ld de, TitleTilemap      ; de = address of our tilemap data in ROM
	ld hl, $9800             ; hl = $9800 (start of tile map 0 in VRAM)
    ld c, 18                 ; 18 visible rows
CopyTilemap:
    ld b, 20                 ; 20 visible columns per row
CopyTilemapCol:
	ld a, [de]               ; Read one tilemap byte from ROM
	ld [hli], a              ; Write it to VRAM, advance hl
	inc de                   ; Advance source pointer
    dec b                    ; dec b sets zero flag directly (unlike dec bc)
    jr nz, CopyTilemapCol   ; Loop until all 20 columns copied
.RowComplete:
    push de                  ; Save de (we need it, but add only works with hl)
    ld  de, 12               ; 32 (VRAM width) - 20 (visible) = 12 to skip
    add hl, de               ; Jump hl past the 12 off-screen tilemap columns
    pop de                   ; Restore source pointer
    dec c                    ; Next row
    jr nz, CopyTilemap       ; Loop until all 18 rows copied

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

; -- Pause on title screen and seed RNG ----------------------------------------
; While waiting for the player to press Start, we run a tight counter loop.
; The value of b when Start is pressed becomes our random seed - this gives us
; unpredictable randomness based on human timing.
ld b,0
Title:
    inc b                    ; Increment counter each frame we wait
    ld a, JOYP_GET_BUTTONS   ; Select button matrix (as opposed to d-pad)
    ld [rP1], a              ; Write to joypad register to select which buttons to read
    ld a, [rP1]              ; Read back the button states
    and a, (1 << B_JOYP_START) ; Isolate the Start button bit
                             ; B_JOYP_START is a bit NUMBER, so we shift 1 left by that amount
                             ; to create a bitmask. Joypad is active-low: 0 = pressed.
    jr nz, Title             ; If bit is 1 (not pressed), keep looping
EndTitle:
    ld a, b                  ; Use the counter value as our seed
    or 1                     ; Ensure seed is never zero (LFSR would get stuck at 0)
    ld [seed], a             ; Store into WRAM seed variable


; =============================================================================
; TRANSITION FROM TITLE SCREEN TO GAME
; =============================================================================
; We need to: turn off LCD, clear VRAM (remove title graphics), load game
; tiles, initialize the cell grid in WRAM, then turn LCD back on.

TitleEnd:
.waitVBlank:
    ld a, [rLY]              ; Wait for VBlank before turning off LCD
    cp 144                   ; (turning off LCD mid-frame can damage real hardware)
    jr c, .waitVBlank
    ld a, 0
    ld [rLCDC], a            ; LCD off - safe to freely write VRAM now

; --- Clear all of VRAM ($8000-$9FFF = $2000 bytes) --------------------------
; This removes leftover title screen tile data and tilemap so we start clean.
; Without this, old title tiles would show as garbage on the game screen.
ld de, $2000                 ; $2000 = 8192 bytes (size of entire VRAM)
ld hl, $8000                 ; Start of VRAM
ZeroOutVram:
    ld a, 0
    ld [hli], a              ; Write 0 to [hl], then hl++
    dec de                   ; Decrement byte counter
    ld a, d                  ; Check if de == 0 (16-bit dec doesn't set flags)
    or a, e
    jr nz, ZeroOutVram

; --- Load game tiles into VRAM block 1 ($9000) ------------------------------
; Game tiles go to $9000 (block 1) which uses signed tile indexing.
; Tile 0 in the tilemap will reference $9000. This is different from the title
; screen which used $8000 (block 0, unsigned indexing with LCDC_BLOCK01 flag).
    ld de, Tiles             ; Source: our 2 game tiles (dead=white, alive=black)
    ld hl, $9000             ; Destination: tile block 1 in VRAM
    ld bc, Tiles.End - Tiles ; Byte count (32 bytes = 2 tiles x 16 bytes each)
CopyMainTiles:
    ld a, [de]
    ld [hli], a
    inc de
    dec bc
    ld a, b
    or a, c
    jr nz, CopyMainTiles

; --- Zero out both WRAM buffers (CurrentGen + NextGen) -----------------------
; Each buffer is 22x20 = 440 bytes. We zero both (880 bytes total) so the
; padding border ring is guaranteed to be 0 (dead cells).
    ld hl, CurrentGen
    ld de, 22 * 20 * 2       ; 440 * 2 = 880 bytes for both buffers
ZeroOutWram:
    ld a, 0
    ld [hli], a
    dec de
    ld a, d
    or a, e
    jr nz, ZeroOutWram

; --- Seed the initial generation with random cells ---------------------------
; The grid is 22 wide x 20 tall in memory, but only the interior 20x18 cells
; are active. The outer ring of padding stays 0 (dead) to simplify neighbor
; counting at the edges.
;
; Memory layout of one buffer (22 bytes per row, 20 rows):
;   Row 0:  [0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0]  <- padding row
;   Row 1:  [0 X X X X X X X X X X X X X X X X X X X X 0]  <- first active row
;            ^                                           ^
;            padding col                                 padding col
;   ...
;   Row 18: [0 X X X X X X X X X X X X X X X X X X X X 0]  <- last active row
;   Row 19: [0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0]  <- padding row
;
; First active cell is at offset 23: skip row 0 (22 bytes) + 1 padding byte.
    ld hl, CurrentGen + 23   ; Point to first interior cell
    ld c, 0                  ; Row counter
SeedGeneration1:
SeedRow:
    ld d, 0                  ; Column counter
    SeedColumn:
    call Random              ; Get a pseudo-random number in a
    and 1                    ; Mask to 0 or 1 (dead or alive)
    ld [hli], a              ; Write cell value, advance pointer
    inc d
    ld a, d
    cp 20                    ; 20 columns per row
    jr nz, SeedColumn

    inc hl                   ; Skip 2 bytes of right-padding + next row's left-padding
    inc hl                   ; (1 byte right pad of this row + 1 byte left pad of next row)
    inc c
    ld a, c
    cp 18                    ; 18 rows total
    jr nz, SeedRow

; --- Turn LCD on for the game ------------------------------------------------
TurnLCDOn:
    ld a, LCDC_ON | LCDC_BG_ON ; No LCDC_BLOCK01 flag = use signed tile addressing
                             ; from $9000 (block 1). Tile index 0 = $9000, 1 = $9010.
    ld [rLCDC], a
    ld a, %11100100          ; Standard palette: 0=white, 1=lgray, 2=dgray, 3=black
    ld [rBGP], a

; =============================================================================
; MAIN GAME LOOP
; =============================================================================
; The main loop has three phases each iteration:
;   1. RENDER  - Copy CurrentGen cells to VRAM tilemap (one row per VBlank)
;   2. INPUT   - Check if Select is pressed to reset
;   3. COMPUTE - Calculate next generation, copy NextGen -> CurrentGen, repeat
;
Main:
ld hl,$9800                  ; hl = VRAM tilemap start (destination for rendering)
ld de,CurrentGen + 23        ; de = first active cell in WRAM (skip padding row + left pad)
ld c,0                       ; c = row counter (0..17)

; --- Phase 1: RENDER (copy cell data to VRAM tilemap) -----------------------
; We render one row per VBlank period. The LCD draws scanlines 0-143, then
; enters VBlank at scanline 144. We wait for VBlank, then quickly write one
; row of 20 tile indices to the tilemap. Each cell value (0 or 1) is also a
; tile index: tile 0 = dead (white), tile 1 = alive (black).
.waitVBlank:
    ld a, [rLY]              ; rLY = current scanline the LCD is drawing
    cp 144                   ; Scanline 144+ = VBlank period
    jr c, .waitVBlank        ; Keep waiting until we're in VBlank

    ld b, 0                  ; b = column counter for this row
.loadTiles:
    ld a, [de]               ; Read cell value from CurrentGen (0=dead, 1=alive)
    ld [hli], a              ; Write as tile index to VRAM tilemap, advance hl
    inc de                   ; Advance source pointer
    inc b
    ld a, b
    cp 20                    ; 20 visible columns per row
    jr c, .loadTiles         ; Keep writing until row is complete

    ; The VRAM tilemap is 32 tiles wide, but the screen only shows 20.
    ; Skip the 12 off-screen columns to get to the next visible row.
    push de                  ; Save de (can't do add with de as destination)
    ld de, 12
    add hl, de               ; Advance hl past 12 invisible tilemap columns
    pop de                   ; Restore de

    inc de                   ; Skip 2 padding bytes in WRAM buffer:
    inc de                   ;   1 byte right-pad of current row + 1 byte left-pad of next row
    inc c                    ; Increment row counter
    ld a, c
    cp 18                    ; 18 rows to render
    jr c, .waitVBlank        ; If more rows remain, wait for next VBlank and draw them

; --- Phase 2: INPUT CHECK ---------------------------------------------------
; After all rows are rendered, check if Select is pressed to restart the game.
    ld a, JOYP_GET_BUTTONS   ; Select button matrix
    ld [rP1], a
    ld a, [rP1]              ; Read button states (active-low: 0 = pressed)
    and a, (1 << B_JOYP_SELECT) ; Isolate Select button
    jp z, TitleEnd           ; If Select pressed (bit=0), jump back to reinitialize

; --- Phase 3: COMPUTE next generation --------------------------------------
.drawingFinished:
    ; Initialize the NextGen write pointer to the first active cell.
    ; We store this pointer in WRAM because we don't have enough registers
    ; to track it alongside the CurrentGen read pointer during computation.
    ld a, LOW(NextGen + 23)  ; Low byte of NextGen's first active cell address
    ld [nextGenPtr], a
    ld a, HIGH(NextGen + 23) ; High byte
    ld [nextGenPtr + 1], a   ; Stored as little-endian (low byte first)
    call ComputeNextGeneration ; Compute all cells into NextGen buffer

    ; --- Swap buffers: copy NextGen -> CurrentGen ---------------------------
    ; We do a full copy rather than pointer swap because both buffers need
    ; stable addresses for the rendering and computation code.
    ld de, CurrentGen        ; de = destination (CurrentGen)
    ld hl, NextGen           ; hl = source (NextGen)
    ld bc, 22 * 20           ; 440 bytes (entire buffer including padding)
.copyNewGeneration:
    ld a, [hli]              ; Read from NextGen
    ld [de], a               ; Write to CurrentGen
    inc de
    dec bc
    ld a, b
    or a, c
    jr nz, .copyNewGeneration
    jp Main                  ; Loop back to render the new generation

.done:

; =============================================================================
; ComputeNextGeneration - Apply Game of Life rules to all active cells
; =============================================================================
; Iterates over every interior cell (20x18) in CurrentGen, counts its 8
; neighbors, applies the birth/survival rules, and writes the result to NextGen.
;
; Registers used:
;   de = pointer to current cell in CurrentGen (read)
;   b  = column countdown (20 -> 0)
;   c  = row countdown (18 -> 0)
;   a  = neighbor count accumulator / general scratch
;   hl = scratch pointer for neighbor lookups / NextGen writes
;
; Conway's Game of Life rules:
;   - A dead cell with exactly 3 neighbors becomes alive (birth)
;   - A live cell with 2 or 3 neighbors stays alive (survival)
;   - All other cells die or stay dead
;
ComputeNextGeneration:
    ld de, CurrentGen + 23   ; de = first active cell (row 1, col 1)
    ld c, 18                 ; c = row countdown

    .computeRow:
    ld b, 20                 ; b = column countdown

    .computeColumn:
        ; --- Count all 8 neighbors of the cell at [de] ----------------------
        ; Neighbor positions relative to current cell in a 22-wide buffer:
        ;
        ;   [de-23] [de-22] [de-21]     (row above)
        ;   [de- 1]  [de]   [de+ 1]     (same row)
        ;   [de+21] [de+22] [de+23]     (row below)
        ;
        ; Since cells are 0 (dead) or 1 (alive), we can simply add all
        ; neighbor values to get the live neighbor count.
        ;
        ; For negative offsets we use two's complement:
        ;   -23 = $FFE9, -1 = $FFFF (dec hl shortcut)
        ; For positive offsets, +21 = $0015, +22 = $0016, +23 = $0017.
        ; Adjacent neighbors are reached with inc hl from the previous one.

        ld a, 0              ; a = neighbor count, starts at 0

        ; Neighbor at offset -23 (upper-left)
        ld h, d              ; Copy de -> hl (can't do ld hl, de directly)
        ld l, e
        push bc              ; Save loop counters (we need bc for 16-bit add)
        ld bc, $FFE9         ; bc = -23 in two's complement
        add hl, bc           ; hl = de - 23
        add a, [hl]          ; Add neighbor's value (0 or 1) to count
        pop bc               ; Restore loop counters

        ; Neighbor at offset -22 (directly above)
        inc hl               ; hl = de - 22 (just one byte after previous)
        add a, [hl]

        ; Neighbor at offset -21 (upper-right)
        inc hl               ; hl = de - 21
        add a, [hl]

        ; Neighbor at offset -1 (left)
        ld h, d              ; Reset hl back to de
        ld l, e
        dec hl               ; hl = de - 1
        add a, [hl]

        ; Neighbor at offset +1 (right)
        inc hl               ; hl = de (skip current cell)
        inc hl               ; hl = de + 1
        add a, [hl]

        ; Neighbor at offset +21 (lower-left)
        ld h, d              ; Reset hl back to de
        ld l, e
        push bc              ; Need bc for 16-bit addition
        ld bc, $15           ; 21 in hex
        add hl, bc           ; hl = de + 21
        add a, [hl]
        pop bc

        ; +22 (directly below)
        inc hl
        add a, [hl]

        ; +23 (below-right)
        inc hl
        add a, [hl]

        ; --- Apply Game of Life rules to the neighbor count in a -------------
        cp 3                 ; Exactly 3 neighbors?
        jr z, .alive         ; -> Cell is alive (birth or survival)

        cp 2                 ; Exactly 2 neighbors?
        jr nz, .dead         ; If not 2, cell dies (< 2 underpopulation, > 3 overpop)

        ; If count == 2, cell survives ONLY if it's currently alive
        push af              ; Save the neighbor count
        ld a, [de]           ; Read current cell state from CurrentGen
        or a                 ; Check if alive (nonzero)
        jr z, .deadPop       ; If cell is dead (0) with 2 neighbors -> stays dead
        pop af               ; Cell is alive with 2 neighbors -> survives
        jr .alive

        .deadPop:
        pop af               ; Clean up the stack before jumping to dead
        jr .dead

        .dead:
        ld a, 0              ; Cell will be dead in next generation
        jr .writeCell

        .alive:
        ld a, 1              ; Cell will be alive in next generation

        ; --- Write result to NextGen buffer ----------------------------------
        ; We use a WRAM pointer variable (nextGenPtr) because we've run out
        ; of register pairs. de is already used for CurrentGen, bc for loop
        ; counters, and hl for neighbor lookups.
        .writeCell:
        push de              ; Save CurrentGen pointer
        push af              ; Save the cell value (0 or 1)

        ld a, [nextGenPtr]   ; Load NextGen write pointer from WRAM
        ld l, a              ; (stored as little-endian: low byte first)
        ld a, [nextGenPtr + 1]
        ld h, a              ; hl = current NextGen write address

        pop af               ; Restore cell value
        ld [hli], a          ; Write cell to NextGen, advance pointer

        ld a, l              ; Store updated pointer back to WRAM
        ld [nextGenPtr], a
        ld a, h
        ld [nextGenPtr + 1], a

        pop de               ; Restore CurrentGen pointer

        ; --- Advance to next cell in the row ---------------------------------
        inc de               ; Move to next cell in CurrentGen
        dec b                ; Decrement column counter
        jr nz, .computeColumn ; More columns in this row? Keep going

    ; --- End of row - advance to next row ------------------------------------
    dec c                    ; Decrement row counter
    jr z, .done              ; If all 18 rows done, we're finished

    ; Skip padding bytes at end of current row and start of next row
    inc de                   ; Skip right-padding byte in CurrentGen
    inc de                   ; Skip left-padding byte of next row

    ; Also skip padding in the NextGen write pointer
    ld a, [nextGenPtr]
    ld l, a
    ld a, [nextGenPtr + 1]
    ld h, a

    inc hl                   ; Skip right-padding byte in NextGen
    inc hl                   ; Skip left-padding byte of next row

    ld a, l
    ld [nextGenPtr], a
    ld a, h
    ld [nextGenPtr +1 ], a
    jr  .computeRow          ; Process next row

    .done:
        ret                  ; Return to caller (Main loop)


; =============================================================================
; Random - 16-bit Linear Feedback Shift Register (LFSR)
; =============================================================================
; Generates pseudo-random numbers by shifting a 16-bit seed and applying
; XOR feedback when a 1 bit is shifted out. The feedback polynomial ($B4)
; determines the sequence length and distribution.
;
; How it works:
;   1. Shift the entire 16-bit seed right by 1 bit
;   2. The bit shifted out goes into the carry flag
;   3. If carry = 1, XOR the high byte with $B4 (feedback tap)
;   4. If carry = 0, do nothing (no feedback)
;   This produces a long, non-repeating sequence of pseudo-random values.
;
; IMPORTANT: The seed must be stored BEFORE checking carry, because the
; srl/rr instructions set the carry flag but subsequent ld instructions
; would not preserve it if we checked carry first.
;
; Returns: a = low byte of shifted seed (pseudo-random value)
;
Random:
    ld a, [seed + 0]         ; Load low byte of 16-bit seed
    ld b, a                  ; Stash in b
    ld a, [seed + 1]         ; Load high byte of seed

    srl a                    ; Shift high byte right: bit 0 -> carry, 0 -> bit 7
    rr b                     ; Rotate low byte right: carry -> bit 7, bit 0 -> carry
                             ; Together these form a 16-bit right shift

    ld [seed + 1], a         ; Store shifted high byte FIRST (before checking carry!)
    ld a, b
    ld [seed + 0], a         ; Store shifted low byte

    jr nc, .noFeedback       ; If the bit shifted out was 0, skip feedback
    ld a, [seed + 1]         ; Otherwise, XOR high byte with feedback polynomial
    xor $B4                  ; $B4 = %10110100 - chosen for maximal-length sequence
    ld [seed + 1], a
.noFeedback:
    ld a, b                  ; Return the low byte as our random number
    ret

; =============================================================================
; WRAM - Work RAM variables
; =============================================================================
; The Game Boy has 8KB of Work RAM ($C000-$DFFF) for runtime data.
; `ds N` reserves N bytes without initializing them (values are undefined
; until we zero them in code).

SECTION "Game State", WRAM0
CurrentGen:
    ds 22 * 20  ; 440 bytes - current generation grid (22 wide x 20 tall)
                ; Interior 20x18 cells with a 1-cell ring of dead padding
NextGen:
    ds 22 * 20  ; 440 bytes - next generation (written during computation)
nextGenPtr:
    ds 2        ; 16-bit write pointer into NextGen (little-endian)
                ; Used because we don't have a free register pair during computation
seed:
    ds 2        ; 16-bit LFSR seed for random number generation

; =============================================================================
; ROM DATA - Graphics embedded in the ROM
; =============================================================================

; --- Title screen graphics ---------------------------------------------------
; Generated with: AI image tool -> ImageMagick (4-color dither) -> rgbgfx
; rgbgfx converts a PNG into Game Boy tile format + tilemap

SECTION "Title Tile Data", ROM0

TitleTiles:
    INCBIN "tiles.bin"       ; Raw tile pixel data for the title screen image
.End:

SECTION "Title Tilemap", ROM0

TitleTilemap:
    INCBIN "tilemap.bin"     ; 20x18 grid of tile indices for the title image
.End:

; --- Game of Life tiles (2 tiles: dead and alive) ----------------------------
; Each tile is 8x8 pixels, 16 bytes (2 bytes per row, 2 bits per pixel).
; Game Boy tiles use 2 bitplanes: for each row of 8 pixels, byte 1 is the
; low bit and byte 2 is the high bit of each pixel's 2-bit color value.
;
; Tile 0 (dead cell) - all white:
;   Each row: $FF,$00 -> low bits all 1, high bits all 0 -> color %01 (light gray)
;   With palette %11100100: color 1 = light gray
;
; Tile 1 (alive cell) - all black:
;   Each row: $00,$FF -> low bits all 0, high bits all 1 -> color %10 (dark gray)
;   With palette %11100100: color 2 = dark gray

SECTION "Tile data", ROM0

Tiles:
	db $ff,$00, $ff,$00, $ff,$00, $ff,$00, $ff,$00, $ff,$00, $ff,$00, $ff,$00
	db $00,$ff, $00,$ff, $00,$ff, $00,$ff, $00,$ff, $00,$ff, $00,$ff, $00,$ff
.End:
