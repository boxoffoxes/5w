#include <asm/unistd.h>
#include <asm/mman.h>

.set dlink, 0

.set CELL_BITS, 2
.set CELL_SIZE, (1<<CELL_BITS)

.set DS_SIZE, (256*CELL_SIZE)
.set BUFFER_SIZE, 4096
.set WORD_BUFFER_SIZE, 256
.set SCRATCH_SIZE, (128*1024)  # 128k
.set HEAP_PAGE_SIZE, SCRATCH_SIZE  # ditto

.set INS_CALL,    0xe8
.set INS_LEA,     0x8d
.set INS_RET,     0xc3
.set INS_NOP,     0x90


# headers
.macro publish label name behav=bCompiled
	.section .data
	.align CELL_SIZE
hdr_\label:
	.long dlink, \label, \behav
	.ifeqs "\name",""
		.asciz "\label"
	.else
		.asciz "\name"
	.endif
	.align CELL_SIZE, 0
.set dlink, hdr_\label
.endm

.set XT_OFFS, CELL_SIZE
.set BEHAVIOUR_OFFS, 2*CELL_SIZE
.set LABEL_OFFS, 3*CELL_SIZE

# Register allocations
#
# %eax - ToS
# %esi - DSP
# %esp - return stack ptr
# %edi - Addr reg

.macro quot label name behav
	.section .text
	.align CELL_SIZE
\label:
.endm
.macro endq tail
	.ifeqs "\tail", ""
		ret
	.else
		jmp \tail
	.endif
.endm

.macro dup
	lea -4(%esi), %esi
	mov %eax, (%esi)
.endm
.macro swap
	xchg %eax, (%esi)
.endm
.macro nip
	lea 4(%esi), %esi
.endm
.macro drop
	lodsl
.endm
.macro over
	dup
	mov 4(%esi), %eax
.endm
.macro lit val
	dup
	movl \val, %eax
.endm
.macro pushrs
	push %eax
	drop
.endm
.macro poprs
	dup
	pop %eax
.endm
.macro npop to
	# pop next-on-stack
	mov (%esi), \to
	nip
.endm

.macro trash
	# destroy ToRS
	lea 4(%esp), %esp
.endm

.macro comparison ins
	mov %eax, %ecx
	npop %edx
	xor %eax, %eax
	cmpl %ecx, %edx
	\ins %al
	dec %eax
.endm

.macro call_c sym, nargs
	dup   # make sure arg1 is on the stack
	xchg %esi, %esp   # save having to move our args
	lea \nargs*CELL_SIZE(%esp), %ebp    # we start behaving like a C program...
	call \sym
	add $\nargs*CELL_SIZE, %esp      # drop the args
	xchg %esi, %esp
.endm


# buffers
.lcomm ibuf, BUFFER_SIZE
.lcomm dstack, DS_SIZE
.lcomm obuf, BUFFER_SIZE
.lcomm wbuf, WORD_BUFFER_SIZE
.lcomm dmz, 4   # we append 4 null bytes to wbuf
# .lcomm staging, BUFFER_SIZE
.lcomm fixup, BUFFER_SIZE
.lcomm data, BUFFER_SIZE


# constants
# variables
.lcomm scratch, CELL_SIZE

.lcomm ibuf_pos, CELL_SIZE
.lcomm ibuf_fill, CELL_SIZE
.lcomm obuf_pos, CELL_SIZE

.lcomm in_channel, CELL_SIZE
.lcomm out_channel, CELL_SIZE

.lcomm rs0, CELL_SIZE
.lcomm hp, CELL_SIZE
.lcomm hpg, CELL_SIZE  # current heap page
.lcomm fxp, CELL_SIZE  # fixup table pointer
.lcomm dp, CELL_SIZE   # current data area pointer

# exceptions
.lcomm MMapFailed, CELL_SIZE
.lcomm EndOfFile, CELL_SIZE

# bootstrap code
.section .text
.align CELL_SIZE
.globl main
main:
	mov %esp, rs0
	movl $1, in_channel
	movl $0, out_channel
	movl $fixup, fxp
	mov $dstack+DS_SIZE, %esi
	# allocate scratch page
	lit $SCRATCH_SIZE
	call code_buffer
	mov %eax, scratch
	drop
	# ...and first heap page
	lit $HEAP_PAGE_SIZE
	call code_buffer
	mov %eax, hpg
	mov %eax, hp
	drop
	movl $bye, EndOfFile
/*	call brk_addr
	lit $dp
	call set */
	movl $data, dp
	lit $'Z'
	call emit
	lit $'\n'
	call emit
jmp reset

quot reset
	mov rs0, %esp  # flush RS
	mov scratch, %edi
	movl $0, ibuf_fill
	call begin
endq compiler

quot compiler
	call word
	call find
	call eval
endq compiler

quot _add_fixup # a? -- 
	mov fxp, %edx
	mov %eax, (%edx)
	add $CELL_SIZE, fxp
	drop
endq

quot align_hp # --
	lit hp
	movl $0x90909090, (%eax)
	add $3, %eax
	and $(~(CELL_SIZE-1)), %eax
	mov %eax, hp
	drop
endq
quot begin "[" behav=bImmed
	lit %edi
	lit $0
	call _add_fixup
endq
quot _apply_fixes  # tmp offs -- tmp
	# destructively apply fixups. Might want to preserve
	# them for compilation purposes?
	mov %eax, %edx
	mov fxp, %ecx
1:
	sub $CELL_SIZE, %ecx
	mov (%ecx), %eax
	test %eax, %eax
	jz 2f
	sub %edx, (%eax)
	jmp 1b
2:	
	mov %ecx, fxp
	drop
endq
quot end "]" behav=bImmed  # tmp --
	# keep a copy of start addr for later (this
	#   will be our new %edi after moving the
	#   current quot
	push %eax
	# write `ret` to end current quot
	movb $INS_RET, (%edi) # TODO: TCO
	inc %edi
	# calculate move distance
	dup
	neg %eax
	add hp, %eax
	# apply fixups
	call _apply_fixes
	# calculate byte length to move
	sub %eax, %edi
	mov %edi, %ecx
	# set dest from heap-ptr
	mov hp, %edi
	# save DSP and set src from ToS (temp addr left by begin)
	push %esi
	mov %eax, %esi
	# move quotation to heap
	rep movsb
	# restore saved regs
	pop %esi
	mov hp, %eax # new quot addr for stosl
	mov %edi, hp
	pop %edi
	# over-write old location with `quote <new_loc>`
	movl $0x89fc768d, (%edi)
	movl $0x0000b806, 4(%edi)
	lea 6(%edi), %edi
	stosl
	drop
endq align_hp
quot as  behav=bImmed  # tmp -- tmp
	# how we name code and data...
	movb $INS_RET, (%edi)
	push %eax  # Eval from the start of the most recent quot
	call eval  # this must leave an address on the stack
	pop %edi   # Erase the executed code.
	call word  # get the name
	call header # make a header
endq

quot header # xt str --
	push %edi
	swap
	mov dp, %edi
	lit dict
	mov %edi, dict
	stosl
	drop
	stosl
	mov $bCompiled, %eax
	stosl
	drop
	call keeps
	drop
endq

quot udivmod  # u -- d r
	mov %eax, %ebx
	drop
	xor %edx, %edx
	divl %ebx
	lit %edx
endq


quot keeps  # str -- addr
	# move a temporary string to a permanent location
	dup
	call lens
	mov %eax, %ecx
	drop
	inc %ecx
	push %edi
	push %esi
	mov dp, %edi
	mov %eax, %esi
	rep movsb
	mov %edi, dp
	mov %edi, %eax
	pop %esi
	pop %edi
endq

quot bye behav=bImmed
	lit $0
endq exit

quot exit
	lit $__NR_exit
endq syscall1

quot syscall1 # arg no -- result
	# call number already in %eax
	npop %ebx
	int $0x80
endq
quot syscall3  # arg3 arg2 arg1 no -- result
	npop %ebx
	npop %ecx
	npop %edx
	int $0x80
endq
quot syscall6  # arg6 arg5 arg4 arg3 arg2 arg1 n -- result
	mov %esi, %ebx
	int $0x80
	add $(6*CELL_SIZE), %esi
endq

quot lens  # str -- len
	xor %ecx, %ecx  # zero counter
	mov %edi, %edx  # save %edi
	mov %eax, %edi  # string addr into %edi
	dec %ecx        # counter to -1
	xor %eax, %eax  # clear %eax
	repnz scasb     # repeat until (%edi) is \0
	not %ecx        
	mov %ecx, %eax
	mov %edx, %edi
	dec %eax        # because we counted the \0
endq

pct_c: .asciz "%c"

quot emit  # c --
	lit $pct_c
	call_c printf, 2
	drop
endq

/* quot emit # c --
	lit $1    # length char is nos
	mov %esi, %edx
	lit %edx  # using the stack as a buffer
	lit out_channel
	lit $__NR_write
	call syscall3
	drop  # return val
	drop  # original char
endq
*/
quot put # str len -- 
	swap
	lit out_channel  # stdout -- TODO
	lit $__NR_write
	call syscall3
	drop  # don't care what the return val was
endq
quot puts  # str --
	dup
	call lens
endq put

quot setinc "@+"   # n addr -- addr+4
	npop %edx
	mov %edx, (%eax)
	lea 4(%eax), %eax
endq
quot setbinc "@b+" # c addr -- addr+1
	npop %edx
	mov %dl, (%eax)
	inc %eax
endq

quot putsign # n -- u
	mov %eax, %edx
	and $(0x80000000), %edx
	test %edx, %edx
	jz 1f
	lit $'-'
	call emit
	neg %eax
1:
endq
quot putn  # n -- 
	call putsign
	xor %ecx, %ecx
1:
	dec %ecx
	test %eax, %eax
	jz 2f
	lit $10
	call udivmod
	add $'0', %eax
	swap
	jmp 1b
2:
	not %ecx
	drop
3:
	dec %ecx
	push %ecx
	call emit
	pop %ecx
	test %ecx, %ecx
	jnz 3b
endq

quot btw "btw?"   # x lower upper -- bool
	mov %eax, %edx  # upper
	drop            # lower into %eax
	npop %ecx       # x
	sub %eax, %edx  # upper-lower -> %edx
	sub %eax, %ecx  # x-lower     -> %ecx
	xor %eax, %eax  # 
	cmp %edx, %ecx
	seta %al
	dec %eax
endq
quot eq "="
	comparison setne
endq


quot get "@"  # addr -- val
	mov (%eax), %eax
endq
quot set "!"  # val addr --
	npop %edx
	mov %edx, (%eax)
	drop
endq

quot raise
	mov (%eax), %eax
	test %eax, %eax
	jz unhandled
endq eval

quot unhandled
	lit $str_failed
	call puts
	lit $1
endq exit

.section .data
.align CELL_SIZE
str_failed:
	.asciz "Unhandled exception\n"

quot case  # x x q -- q() | x y q -- x
	# Pop q and y from stack. if x == y then drop x and run q 
	# before returning from containing quotation, otherwise 
	# leave x and continue execution of containing quot
	# q is in %eax
	mov %eax, %ecx  # move q off the stack
	drop      # y -> %eax
	npop %edx # x
	cmp %eax, %edx
	jne 1f
	drop  # discard y  (see `match` for preserving version)
	trash  # we don't return to caller after a match
	jmp *%ecx
1:
	xchg %eax, %edx  # we want to keep x, not y
endq
quot otherwise  # x q -- q()
	mov %eax, %edx
	drop
	drop
	# trash  # we don't return to the caller -- but tail-call optimisation deals with that
endq *%edx

quot code_buffer  # size -- addr
	mov %eax, %edx                           # save len for later
	xor %eax, %eax                           # push off
	dup                                      # push dummy file descriptor
	lit $(MAP_PRIVATE|MAP_ANONYMOUS)         # push flags
	lit $(PROT_READ|PROT_WRITE|PROT_EXEC)    # push prot
	lit %edx                                 # push len
	lit $0                                   # push addr (not needed)
	lit $__NR_mmap                           # push syscall number
	call syscall6
	dup
	lit $-200     # mmap returns error codes between -200 and -1
	lit $-1
	call btw
	drop      # ditch the boolean
	jz 1f     # call succeeded - no error
	lit $MMapFailed
	call raise
1:
endq

quot _q_read_in_01
	lit $EndOfFile
endq raise
quot read_in  # len buf -- n
	lit in_channel
	lit $__NR_read
	call syscall3
	lit $0
		lit $_q_read_in_01
	call case
endq

quot _q_key_01  # --
	lit $BUFFER_SIZE
	lit $ibuf
	call read_in
	
	mov %eax, ibuf_fill
	drop
	movl $ibuf, ibuf_pos
endq key
quot _q_key_02  # -- byte
	# WARNING: does no buffer bounds checking.
	lit $0
	mov ibuf_pos, %edx
	decl ibuf_fill
	incl ibuf_pos
	mov (%edx), %al
endq
quot key  # -- byte
	lit ibuf_fill
	lit $0
		lit $_q_key_01
	call case
		lit $_q_key_02
endq otherwise

quot word  # -- word
	# TODO: no test for too-long words
	lit $0  # something for the first drop
1:  # drop spaces
	drop
	call key
	cmp $' ', %eax
	jbe 1b
	push %edi
	mov $wbuf, %edi
2:
	stosb
	drop
	call key
	cmp $' ', %eax
	jbe 3f
	jmp 2b
3:
	xor %eax, %eax
	stosl
	drop
	pop %edi
	lit $wbuf
endq

quot cmps  # s1 s2 -- bool
	push %edi
	npop %edi  # warning: uses %esi as stack pointer!
	push %esi
	mov %eax, %esi
	xor %eax, %eax
	xor %ecx, %ecx
1:
	lodsb
	cmp (%edi), %al
	jne 2f
	inc %edi
	test %al, %al
	jnz 1b
2:
	setnz %al
	dec %eax
	pop %esi
	pop %edi
endq

quot number
endq

quot find_word  # str -- entry
	lit $dict
1:
	mov (%eax), %eax
	test %eax, %eax
	jz 2f  # end of dict
	push %eax
	lea LABEL_OFFS(%eax), %eax
	over
	call cmps
	test %eax, %eax
	pop %eax
	jz 1b
2:
	nip
endq

.section .data
.align CELL_SIZE
msg_not_found:
	.asciz " is not a dictionary word or number\n"

quot not_found
	lit $wbuf
	call puts
	lit $msg_not_found
	call puts
endq reset

quot find
	call find_word
	test %eax, %eax
	jz not_found
	mov BEHAVIOUR_OFFS(%eax), %edx
	mov XT_OFFS(%eax), %eax
	dup
	mov %edx, %eax
endq

quot eval  #  q -- 
	mov %eax, %edx
	drop
endq *%edx

quot bImmed
endq eval
quot bCompiled  # xt -- 
	# store call instruction
	movb $INS_CALL, (%edi)
	inc %edi
	# calculate offset
	lit %edi
	call _add_fixup
	lea 4(%edi), %edx
	sub %edx, %eax
	# store
	stosl
	drop
endq


#include "5w_stc_dict.h"

.section .data
.align CELL_SIZE
dict:
	.long dlink

gdlab:
	.space BUFFER_SIZE*4   # dictionary labels (max 15 chars + \0)
ldlab: .space BUFFER_SIZE*4   # local dictionary labels (max 15 chars + \0)

gdxt: .space BUFFER_SIZE      # dictionary XTs
ldxt: .space BUFFER_SIZE      # local dictionary XTs

