#include <asm/unistd.h>

.set dlink, 0

.set CELL_BITS, 2
.set CELL_SIZE, (1<<CELL_BITS)

.set DS_SIZE, (256*CELL_SIZE)
.set BUFFER_SIZE, 4096
.set WORD_BUFFER_SIZE, 256
.set SCRATCH_SIZE, (128*1024)  # 128k
.set SCRATCH_OFFSET, SCRATCH_SIZE


.set INS_CALL,    0xe8
.set INS_LEA,     0x8d
.set INS_RET,     0xc3

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

.macro fixup where
	# create a fixup entry
	mov \where, fxp
	addl $CELL_SIZE, fxp
.endm

# buffers
.lcomm ibuf, BUFFER_SIZE
.lcomm dstack, DS_SIZE
.lcomm obuf, BUFFER_SIZE
.lcomm wbuf, WORD_BUFFER_SIZE
.lcomm dmz, 4   # we append 4 bytes to wbuf
.lcomm staging, BUFFER_SIZE
.lcomm fixup, BUFFER_SIZE
.lcomm heap, BUFFER_SIZE   # TODO: Use brk/mmap

# constants
# variables
.lcomm ibuf_pos, CELL_SIZE
.lcomm ibuf_fill, CELL_SIZE

.lcomm in_channel, CELL_SIZE
.lcomm out_channel, CELL_SIZE

.lcomm rs0, CELL_SIZE
.lcomm hp, CELL_SIZE
.lcomm fxp, CELL_SIZE  # fixup table pointer

# exceptions

# bootstrap code
.section .text
.align CELL_SIZE
.globl _start
_start:
	mov %esp, rs0
	movl $heap, hp
	movl $1, in_channel
	movl $0, out_channel
	movl $fixup, fxp
jmp reset

.section .data
.align CELL_SIZE, 0
hello_world:
	.asciz "Hello world!\n"
.align CELL_SIZE, 0
blah:
	.asciz "cheese"
.align CELL_SIZE, 0

quot reset
	mov rs0, %esp  # flush RS
	mov $dstack+DS_SIZE, %esi
	mov $staging, %edi
	movl $0, ibuf_fill
	call begin
endq compiler

quot compiler
	call word
	call find
	call eval
endq compiler

quot begin "[" behav=bImmed
	lit %edi
	fixup $0
endq
quot _apply_fixes  # tmp -- tmp
	mov %eax, %edx 
	mov fxp, %ecx
	sub hp, %edx   // %edx contains the distance code is being moved
1:
	sub $CELL_SIZE, %ecx
	sub %edx, (%ecx)   # TODO: WORK-IN-PROGRESS
	jmp 1b
endq
quot end "]" behav=bImmed  # tmp -- addr
	# keep a copy of start addr for later (this
	#   will be our new %edi after moving the
	#   current quot
	push %eax
	# write `ret` to end current quot
	movb $INS_RET, (%edi) # TODO: TCO
	inc %edi
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
	# restore saved regs and push new quot addr
	pop %esi
	mov hp, %eax # new quot addr
	mov %edi, hp
	pop %edi
	# over-write old location with `quote <new_loc>`
	movl $0x89fc768d, (%edi)
	movl $0x0000b806, 4(%edi)
	lea 6(%edi), %edi
	stosl
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

quot emit # c --
	lit $1    # length char is nos
	mov %esi, %edx
	lit %edx  # using the stack as a buffer
	lit out_channel
	lit $__NR_write
	call syscall3
	drop  # return val
	drop  # original char
endq
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


quot read_in  # len buf -- n
	lit in_channel
	lit $__NR_read
endq syscall3

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
	# TODO handle EOF
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
	fixup %edi
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
