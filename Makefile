ASSEMBLER32=gcc -static -nostdlib -m32 -g 
STEM=5w
TARGET=$(STEM)
# PROF_TARGET=$(STEM)-profile


all: $(TARGET)

# Misc/all-words

sloc: $(TARGET).S
	cat $< | grep -v '^\s*$$' | grep -v '^\s*#[^a-z]' | grep -v '^\s*//' | wc -l

%: %.S
	$(ASSEMBLER32) -o $@ $<


inc/sys_defs.h :
	cpp -dM $< > $@

