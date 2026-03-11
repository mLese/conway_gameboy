# Game Boy ROM Makefile
# Toolchain: RGBDS (Rogue Game Boy Development System)
#   - rgbasm:  assembler   (.asm -> .o)
#   - rgblink: linker      (.o   -> .gb)
#   - rgbfix:  header fixer (patches checksums & padding into the .gb)

ROM = conway

.PHONY: all clean

all: $(ROM).gb

# Step 1: Assemble - convert assembly source into an object file
$(ROM).o: $(ROM).asm hardware.inc
	rgbasm -o $@ $(ROM).asm

# Step 2: Link - combine object files into a raw Game Boy ROM
$(ROM).gb: $(ROM).o
	rgblink -o $@ $<
	rgbfix -v -p 0xFF $@

# -v     = validate and fix the header (checksums, logo, etc.)
# -p 0xFF = pad the ROM to a power-of-2 size, filling with 0xFF bytes

clean:
	rm -f $(ROM).o $(ROM).gb
