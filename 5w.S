#include <asm/unistd.h>
#include <asm/mman.h>

#define MKSCANF(len) "%" #len "s"

.set CELL_BITS, 2
.set CELL_SIZE, (1<<CELL_BITS)

.set DS_SIZE, (256*CELL_SIZE)
.set BUFFER_SIZE, 4096
.set MAX_WORD_LEN, 255
.set WORD_BUFFER_SIZE, MAX_WORD_LEN+1
.set SCRATCH_SIZE, (128*1024)  # 128k
.set SCRATCH_OFFSET, SCRATCH_SIZE

.set BEHAVIOUR_OFFS, 1*CELL_SIZE
.set XT_OFFS       , 2*CELL_SIZE
.set LABEL_OFFS    , 3*CELL_SIZE

.macro word label codeword name behav=bCompiled
	.section .data
label_\label:
	.ifeqs "\name", ""
		.asciz "\label"
	.else
		.asciz "\name"
	.endif
	.align CELL_SIZE
\label:
	.long \codeword

	.section .dict.label
		.long label_\label
	.section .dict.xt
		.long \label
	.section .dict.behav
		.long \behav
	.section .data
.endm

.macro code label name behav
	word \label prim_\label "\name" \behav
	.section .text
	.align CELL_SIZE
prim_\label:
.endm
.macro next
	lodsl
	jmp *(%eax)
.endm

.macro quot label name behav
	word \label doWord "\name" \behav
.endm
.macro endq tail
	.ifeqs "\tail", ""
		.long done
	.else
		.long tail, \tail
	.endif
.endm

.macro data label name
	word \label doData "\name" \behav
	.long (9999f-.)>>CELL_BITS
.endm
.macro endd
	.align CELL_SIZE, 0
9999:
.endm

.macro var label val=0 name
	word \label doVar "\name"
var_\label:
	.long \val
.endm
.macro const label val name
	word \label doConst "\name"
const_\label:
	.long \val
.endm
.macro exception label
	word \label doVar 
exc_\label:
	.long 0
	.long label_\label
.endm


.macro pushrs reg
	lea -CELL_SIZE(%ebp), %ebp
	movl \reg, (%ebp)
.endm
.macro poprs reg
	mov (%ebp), \reg
	lea CELL_SIZE(%ebp), %ebp
.endm
.macro align_dp
	add $CELL_SIZE-1, %edi
	and $0xfffffffc, %edi
.endm
.macro comparison ins
	pop %eax
	pop %edx
	xor %ecx, %ecx
	cmpl %eax, %edx
	\ins %cl
	dec %ecx
	push %ecx
.endm


.macro ccall sym, nargs
	pushrs %ebx   # make space for RSP
	mov %ebp, %ebx
	lea \nargs*CELL_SIZE(%esp), %ebp    # pretend we're a C program...
	call \sym
	add $\nargs*CELL_SIZE, %esp      # drop the args
	mov %ebx, %ebp
	poprs %ebx
	# result is in %eax if you need it
.endm
	
# the Dictionary™
.section .dict.label, "aw"
.align CELL_SIZE
names:

.section .dict.xt, "aw"
.align CELL_SIZE
xts:

.section .dict.behav, "aw"
.align CELL_SIZE
behavs:

# buffers
.lcomm ibuf, BUFFER_SIZE
.lcomm dstack, DS_SIZE
.lcomm obuf, BUFFER_SIZE
.lcomm wbuf, WORD_BUFFER_SIZE
.lcomm scratch, SCRATCH_SIZE
.lcomm heap, BUFFER_SIZE  # TODO: fixme

# constants
# variables
var hp  # heap pointer
var rs0
var ds0
# exceptions
# strings
.section .data
.align CELL_SIZE
scanf_word: .asciz MKSCANF(MAX_WORD_LEN)
.align CELL_SIZE
printf_c: .asciz "%c"
.align CELL_SIZE
printf_d: .asciz "%d"
.align CELL_SIZE
printf_s: .asciz "%s"
.align CELL_SIZE
hello_world: .asciz "hello world\n"

# bootstrap code
.section .text
.align CELL_SIZE
.globl main
main:
	mov %esp, %ebp
	mov %ebp, var_rs0
	mov $dstack+DS_SIZE, %esp
	mov %esp, var_ds0
	mov $cold_start, %esi
	movl $heap, var_hp
next

.align CELL_SIZE
cold_start:
	.long reset

quot reset
	.long rs0, get, rspSet         # clear RS
	.long lit, 0, ibuf_fill, set   # flush input buffer
	.long lit, scratch, there      # flush the scratch area
	.long begin                    # start compiling
endq compiler

exception Stack

quot _q_dsck_001
	.long Stack, raise
endq
quot dsck
	.long dsp, lit, dstack, lit, obuf, btw
		.long quote, nop
		.long quote, _q_dsck_001
	.long if
endq

quot compiler
	.long dsck
	.long word, find, call
endq compiler


######################################################################
### behaviours for words  ############################################

.section .text
.align CELL_SIZE
doWord:
	pushrs %esi
	lea 4(%eax), %esi
next
.align CELL_SIZE
doData:
	lea 8(%eax), %eax
	push %eax
next
.align CELL_SIZE
doVar:
	lea 4(%eax), %eax
	push %eax
next
.align CELL_SIZE
doConst:
	push 4(%eax)
next

######################################################################
### Primitive words ##################################################

# Syscall primitives for OS interface

code fficall  # arg1 ... argn sym nargs 
	pop %eax
	pop %edx
	pushrs %ebx   # make space for RSP
	mov %ebp, %ebx
	lea (%esp, %eax, CELL_SIZE), %ebp    # pretend we're a C program...
	call *%edx
	mov %ebp, %esp
	# add $\nargs*CELL_SIZE, %esp      # drop the args
	mov %ebx, %ebp
	poprs %ebx
	push %eax # result
next
code syscall1
	pushrs %ebx
	pop %eax
	pop %ebx
	int $0x80
	push %eax
	poprs %ebx
next
code syscall3  # arg3 arg2 arg1 id -- result
	pushrs %ebx
	pop %eax
	pop %ebx
	pop %ecx
	pop %edx
	int $0x80
	push %eax
	poprs %ebx
next
code syscall6  # arg6 arg5 arg4 arg3 arg2 arg1 id -- result
	pushrs %ebx
	pop %eax
	mov %esp, %ebx
	int $0x80
	add $(6*CELL_SIZE), %esp
	push %eax
	poprs %ebx
next


code sub "-"  # x y -- x-y
	pop %eax
	sub %eax, (%esp)
next

# return-stack shuffling
code rspSet "rsp!"  # addr -- 
	pop %ebp
next
code push
	pop %eax
	pushrs %eax
next
code pop
	poprs %eax
	push %eax
next
code stash
	mov (%esp), %eax
	pushrs %eax
next

# data-stack shuffling
code dup
	push (%esp)
next
code swap
	pop %eax
	pop %edx
	push %eax
	push %edx
next
code drop
	pop %eax
next
code nip
	pop %eax
	mov %eax, (%esp)
next
code over
	push 4(%esp)
next

# literals
code lit
	lodsl
	push %eax
next
code quote
	lodsl
	push %eax
next

# call and return
code call
	pop %eax
	jmp *(%eax)
next
code tail
	lodsl
	lea 4(%eax), %esi
next
code tail_tos
	pop %eax
	lea 4(%eax), %esi
next

# There are two return words, so that we can distinguish an in-line return from
# the end of a quotation.

code done
	# done marks end-of-quotation
	poprs %esi
next
code ret
	# ret is for mid-quotation returns. Is this really needed?
	poprs %esi
next

# Quotation creation
code begin "["  behav=bImmed
	push %edi
	mov $doWord, %eax
	stosl
next
code end  "]"  behav=bImmed  # tmp --
	# write `done` to end current quot. TODO: tco
	movl $done, (%edi)
	# save IP and set src from ToS (temp addr left by begin)
	pushrs %esi
	mov (%esp), %esi
	# set dst from heap-ptr
	mov var_hp, %edi   # heap-ptr to dst
	# call _keep to copy quot
	call _keep          # new location in %edx!
	# update hp
	mov %edi, var_hp
	# restore saved IP
	poprs %esi
	# set dst to start of moved quotation (from ToS)
	pop %edi
	# over-write old location with `quote <new_loc>`
	movl $quote, (%edi)
	mov %edx, 4(%edi)
	lea 8(%edi), %edi
next


# Register access
code dsp
	push %esp
next

# Reading and writing via the address register
code compile_lit
	mov $lit, %eax
	stosl
	pop %eax
	stosl
next
code comma ","
	pop %eax
	stosl
next
code here  # -- addr
	push %edi
next
code there  # addr --
	pop %edi
next

# General memory access
code get "@"  # addr -- x
	pop %eax
	push (%eax)
next
code set "!"  # x addr --
	pop %eax
	pop %edx
	mov %edx, (%eax)
next
code setbinc "!b+"  # byte addr -- addr+1
	pop %eax
	pop %edx
	movb %dl, (%eax)
	inc %eax
	push %eax
next

.section .text
.align CELL_SIZE
_keep:
	# expects src-addr in %esi and dst-addr in %edi
	# leaves new location in %edx
	# clobbers %ecx and %eax
	xor %ecx, %ecx
	mov %edi, %edx
1:
	lodsl
	cmp $done, %eax
	stosl
	jz 2f
	loop 1b
2:
ret
# Mem-copying
code keep  # quot -- addr
	# copy a `done`-terminated quotation to the heap
	xchg %esi, (%esp)
	call _keep
	pop %esi
	push %edx
next
code keeps # str --
	# copy a null-terminated temporary string to the heap
	xchg %esi, (%esp)
	xor %ecx, %ecx
1:
	lodsb
	test %al, %al
	jz 2f
	stosb
	loop 1b
2:
	mov $0, %edi
	align_dp
	pop %esi
next

# arithmetic
code add "+"
	pop %eax
	add %eax, (%esp)
next


# logical operators
code btw "btw?"   # n lower upper -- bool
	pop %edx  # upper bound
	pop %ecx  # lower bound
	pop %eax  # n
	sub %ecx, %edx
	sub %ecx, %eax
	xor %ecx, %ecx
	cmp %edx, %eax
	seta %cl
	dec %ecx
	push %ecx
next
code ule "u<="
	# unsigned less-or-equal
	comparison seta
next

# Conditionals
code qm "?"  # bool v1 v2 -- v
	# "question-mark" if bool is true return v1 else return v2
	xor %edx, %edx
	xor %ecx, %ecx
	mov 8(%esp), %eax  # cond
	test %eax, %eax
	setnz %dl
	setz %cl
	# one reg is set to zero and the other to -1
	dec %edx
	dec %ecx
	# ...these are then and-ed with the possible return values
	and (%esp), %edx  # else
	and 4(%esp), %ecx # then
	# ...and added (because one is zero)
	addl %ecx, %edx
	lea 8(%esp), %esp
	mov %edx, (%esp)
next
code case  # x x q -- q() | x y q -- x
	# Pop q and y from stack. if x == y then drop x and run q 
	# before returning from containing quotation, otherwise 
	# leave x and continue execution of containing quot
	xor %eax, %eax
	pop %edx  # q
	pop %ecx  # y
	cmp (%esp), %ecx
	jne 1f
	pop %ecx  # discard x  (see `match` for preserving version)
	lea 4(%edx), %esi  # set PC to first instr of q
1:
next
code match  # x x q -- q(x) | x y q -- x
	# Pop q and y from stack. if x == y then run q on x
	# before returning from containing quotation, otherwise 
	# leave x and continue execution of containing quot
	xor %eax, %eax
	pop %edx  # q
	pop %ecx  # y
	cmp (%esp), %ecx
	jne 1f
	lea 4(%edx), %esi  # set PC to first instr of q
1:
next
quot otherwise  # x q -- ?
	# nip x from stack and run q, before returning from
	# containing quotation
	.long nip, tail_tos
endq

######################################################################
### Now for our non-primitive quotations... ##########################

# quitting the program
quot exit
	.long lit, __NR_exit, syscall1
endq
quot exit1
	.long lit, 1, exit
endq

# exceptions
quot raise
	.long dup, get
	.long lit, 0,   quote, unhandled,      case
	.long drop, call
endq
unhandled_exception:
	.asciz "Unhandled exception: "
.align CELL_SIZE, 0
quot unhandled  # exc -- 
	.long lit, unhandled_exception, puts
	.long lit, CELL_SIZE, add, puts, nl
	.long exit1
endq

# Memory mapping and allocation
exception MmapFailed
quot _q_mmap_01
	.long MmapFailed, raise
endq
quot mmap  # fd flags prot len -- addr
	.long push, push, push, push
	#     offs    fd   flag prot len  addr
	.long lit, 0, pop, pop, pop, pop, lit, 0
	/*, lit, __NR_mmap, syscall6 */
	.long lit, mmap, lit, 6, fficall
	.long dup,  quote, _q_mmap_01,   if_true  # mmap returns -1 on failure
endq
quot buffer  # len -- addr
	.long push
	.long lit, -1   # fd ignored for memory buffers
	.long lit, (MAP_PRIVATE|MAP_ANONYMOUS)  # map opts
	.long lit, (PROT_WRITE|PROT_READ)       # protections
	.long pop, mmap
endq


# input

var ibuf_fill
var ibuf_pos
const IbufSize BUFFER_SIZE

code _next_ibuf_byte
	xor %eax, %eax
	mov var_ibuf_pos, %edx
	decl var_ibuf_fill
	incl var_ibuf_pos
	mov (%edx), %al
	push %eax
next

quot _q_key_01
	.long IbufSize, lit, ibuf, read_in, ibuf_fill, set
	.long lit, ibuf, ibuf_pos, set, tail, key
endq
quot _q_key_02
	.long _next_ibuf_byte
endq
quot key
	.long ibuf_fill, get
	.long lit, 0,   quote, _q_key_01,   case
	.long           quote, _q_key_02,   otherwise
endq
quot _q_word_01  # c -- c bool
	.long drop, key, dup, is_space
endq
quot _q_word_02  # c addr -- c addr bool
	.long setbinc, push, key, dup, is_space, pop, swap
endq
quot word     # -- word
	.long lit, 0,     quote, _q_word_01,   while
	.long lit, wbuf,  quote, _q_word_02,   until
	.long lit, 0, swap, set, drop, lit, wbuf
endq

# string functions
code lens  # str -- length
	xor %eax, %eax
	xor %ecx, %ecx
	mov %edi, %edx
	dec %ecx
	pop %edi
	repne scasb
	mov %edx, %edi
	not %ecx
	push %ecx
next
code eqs  # str str -- bool
	# Are strings equal?
	pushrs %esi
	xor %ecx, %ecx
	pop %edx
	pop %esi
1:
	lodsl
	cmp (%edx), %eax  # current cell equal?
	setne %cl
	jne 2f            # nope? then exit
	lea 4(%edx), %edx # incr %edx to next cell
	shr $12, %eax     # strings must be zero-padded to a full cell!
	test %eax, %eax  # last byte is zero?
	jz 2f            # if yes, then exit
	jmp 1b
2:
	dec %ecx
	push %ecx
	poprs %esi
next

# output
code emit
	push $printf_c
	ccall printf nargs=2
next
/* quot emit  # c --
	.long dsp, lit, 1, swap, out_channel, get, lit, __NR_write, syscall3, drop
endq */
quot put   # s n -- 
	.long swap, out_channel, get, lit, __NR_write, syscall3, drop
endq
code putn  # n -- 
	push $printf_d
	ccall printf nargs=2
next
code puts  # s --
	push $printf_s
	ccall printf nargs=2
next
/* quot puts  # s -- 
	.long dup, lens, put
endq */



# Looping and flow control
quot _q_until_01
	.long drop
endq
quot _q_until_02
	.long tail, until
endq
quot until
	.long stash, call, pop, swap
	.long    quote, _q_until_01
	.long    quote, _q_until_02
	.long if
endq
quot _q_while_01
	.long tail, while
endq
quot while
	.long stash, call, pop, swap
	.long    quote, _q_while_01
	.long    quote, _q_until_01  # save on the duplication!
	.long if
endq
quot if
	.long qm, call
endq
quot if_true
	.long quote, nop, if
endq

/* 
[	
	dict [	get  0 [ raise NotFound ] case
		 	over over .label eqs?
		 :: str dict -- str dict bool ] until
	nip   dup .xt get   swap .behaviour get
:: str -- xt behav ] as find
*/

# misc

quot nop
endq

quot is_space
	.long lit, 32, ule
endq
quot nl
	.long lit, '\n', emit
endq

var out_channel 0
var in_channel 1
var err_channel 2

quot read_in  # len buf -- n
	.long in_channel, get
	.long lit, __NR_read, syscall3
endq

exception NotFound
code _q_find_01  # str -- ind
	xor %ecx, %ecx
1:
	mov $names, %eax
	mov (%eax, %ecx, CELL_SIZE), %eax
	test %eax, %eax
	jz 2f
	push (%esp)   # dup
	push %eax
	pushrs %ecx
	ccall strcmp nargs=2
	poprs %ecx
	inc %ecx
	test %eax, %eax
	jnz 1b
2:
	mov %ecx, (%esp)
next
quot find
	.long _q_find_01, call	
	.long putn, nl
endq

quot bCompiled  # xt -- 
	.long comma
endq
quot bImmed     # xt --
	.long call
endq

var dict_size


# null-terminate dicts. TODO: temporary measure
# until we move dicts to a more permanent location
# at load
.section .dict.names
	.long 0
.section .dict.xts
	.long 0
.section .dict.behavs
	.long 0

