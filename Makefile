ASSEMBLER32=gcc -static -m32 -g -nostdlib
STEM=5w_stc
TARGET=$(STEM)
DICT=$(STEM)_dict.h
# PROF_TARGET=$(STEM)-profile


all: $(TARGET)

# Misc/all-words


sloc: $(TARGET).S
	grep -v '^\s*\(\|#[^a-z].*\)$$' $< | wc -l
#	cat $< | grep -v '^\s*$$' | grep -v '^\s*#[^a-z]' | grep -v '^\s*//' | wc -l

%: %.S
	$(ASSEMBLER32) -o $@ $<


