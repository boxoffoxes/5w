ASSEMBLER32=gcc -static -m32 -g 
STEM=5w_stc
TARGET=$(STEM)
DICT=$(STEM)_dict.h
# PROF_TARGET=$(STEM)-profile


all: $(TARGET)

# Misc/all-words


sloc: $(TARGET).S
	grep -v '^\s*\(\|#[^a-z].*\)$$' $< | wc -l
#	cat $< | grep -v '^\s*$$' | grep -v '^\s*#[^a-z]' | grep -v '^\s*//' | wc -l

%_dict.h : %.S
	grep '^\(quot\|code\)\s\+[^_]' $< | awk '$$1="publish"' > $@

%: %.S %_dict.h
	$(ASSEMBLER32) -o $@ $<


