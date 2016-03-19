#include <asm/unistd.h>

.set dlink, 0

.set CELL_BITS, 2
.set CELL_SIZE, (1<<CELL_BITS)

.set DS_SIZE, (256*CELL_SIZE)
.set BUFFER_SIZE, 4096
.set WORD_BUFFER_SIZE, 256
.set SCRATCH_SIZE, (128*1024)  # 128k
.set SCRATCH_OFFSET, SCRATCH_SIZE

# headers
.macro publish label name behav=0
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

.macro quot label
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

# buffers
.lcomm ibuf, BUFFER_SIZE
.lcomm dstack, DS_SIZE
.lcomm obuf, BUFFER_SIZE
.lcomm wbuf, WORD_BUFFER_SIZE
.lcomm dmz, 4   # we append 4 bytes to wbuf


# constants
# variables
.lcomm ibuf_pos, CELL_SIZE
.lcomm ibuf_fill, CELL_SIZE

.lcomm in_channel, CELL_SIZE
.lcomm out_channel, CELL_SIZE

# exceptions

# bootstrap code
.section .text
.align CELL_SIZE
.globl _start
_start:
	mov $dstack+DS_SIZE, %esi
	movl $1, in_channel
	movl $0, out_channel
jmp _cold_start

.section .data
.align CELL_SIZE, 0
hello_world:
	.asciz "Hello world!\n"
.align CELL_SIZE, 0
blah:
	.asciz "cheese"
.align CELL_SIZE, 0

quot _cold_start
	lit $hello_world
	call puts
	lit $7
	call word
	call find
	call eval
endq exit

quot exit
	lit $__NR_exit
endq syscall1
publish exit

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
	trash  # we don't return to the caller
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
	call otherwise
.byte 0xc3

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

quot not_found
	lit $42
endq exit
quot find
	call find_word
	test %eax, %eax
	jz not_found
	mov XT_OFFS(%eax), %eax
endq

quot eval
	mov %eax, %edx
	drop
endq *%edx


.section .data
.align CELL_SIZE
dict:
	.long dlink
