#include <asm/unistd.h>
#include <asm/mman.h>

.set CELL_BITS, 2
.set CELL_SIZE, (1<<CELL_BITS)

.set DS_SIZE, (256*CELL_SIZE)
.set BUFFER_SIZE, 4096
.set WORD_BUFFER_SIZE, 256
.set SCRATCH_SIZE, (128*1024)  # 128k
.set SCRATCH_OFFSET, SCRATCH_SIZE

.set BEHAVIOUR_OFFS, 1*CELL_SIZE
.set XT_OFFS       , 2*CELL_SIZE
.set LABEL_OFFS    , 3*CELL_SIZE

.macro word label codeword
	.section .data
	.align CELL_SIZE
\label:
	.long \codeword
.endm

.macro code label name
	word \label prim_\label
	.section .text
	.align CELL_SIZE
prim_\label:
.endm
.macro next
	lodsl
	jmp *(%eax)
.endm

.macro quot label name
	word \label doWord
.endm
.macro endq
	.long done
.endm

.macro data label name
	word \label doData
	.long (9999f-.)>>CELL_BITS
.endm
.macro endd
	.align CELL_SIZE, 0
9999:
.endm

.macro var label val=0 name
	word \label doVar
var_\label:
	.long \val
.endm
.macro const label val name
	word \label doConst
const_\label:
	.long \val
.endm
.macro exception label
	word \label doVar
exc_\label:
	.long 0
	.asciz "\label"
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

# buffers
.lcomm ibuf, BUFFER_SIZE
.lcomm dstack, DS_SIZE
.lcomm obuf, BUFFER_SIZE
.lcomm wbuf, WORD_BUFFER_SIZE

# constants
# variables
var hp  # heap pointer
# exceptions

# bootstrap code
.section .text
.align CELL_SIZE
.globl _start
_start:
	mov %esp, %ebp
	mov $dstack+DS_SIZE, %esp
	mov $cold_start, %esi
next

hello_world:
	.asciz "Hello world!\n"

.align CELL_SIZE
cold_start:
	.long word, find, call
	.long word, puts
	.long lit, hello_world, puts
	.long lit, 0, exit 


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
code syscall6
	pushrs %ebx
	pop %eax
	mov %esp, %ebx
	int $0x80
	add $(6*CELL_SIZE), %esp
	push %eax
	poprs %ebx
next



# return-stack shuffling
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
	# ret is for mid-quotation returns. Perhaps remove?
	poprs %esi
next

# Quotation creation
var nesting
code begin "["
	# TODO: re-write to reflect new create-and-copy semantics
	incl var_nesting
	push %edi
	mov $doWord, %eax
	stosl
next
code end  "]"
	# 1. write `done` to end current quot
	mov $done, %eax
	stosl
	# 2. decrement `nesting`
	decl var_nesting
	# 3. save IP and set src from ToS (temp addr left by begin)
	pushrs %esi
	mov (%esp), %esi
	# 4. set dst from heap-ptr
	mov var_hp, %edi   # heap-ptr to dst
	# 5. call _keep to copy quot
	call _keep          # new location in %edx!
	# 6. restore saved IP
	poprs %esi
	# 7. set dst to start of moved quotation (from ToS)
	pop %edi
	# 8. over-write old location with `quote <new_loc>`
	movl $quote, (%edi)
	mov %edx, 4(%edi)
	lea 8(%edi), %edi
	# 9. if `nesting` is 0 update dst to new scratch addr
	# TODO: allocate scratch as a separate area!
	mov var_nesting, %eax
	test %eax, %eax
	jnz 1f
	mov $SCRATCH_OFFSET, %edx
	mov var_hp, %eax
	lea (%eax, %edx), %edi
	mov $doWord, %eax
	stosl
1:
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
	.long lit, 0, pop, pop, pop, pop, lit, 0, lit, __NR_mmap, syscall6
	.long dup, lit, -200, lit, -1, btw,  quote, _q_mmap_01,   if_true
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
quot emit  # c --
	.long dsp, lit, 1, swap, out_channel, get, lit, __NR_write, syscall3, drop
endq
quot put   # s n -- 
	.long swap, out_channel, get, lit, __NR_write, syscall3, drop
endq
quot puts  # s -- 
	.long dup, lens, put
endq



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

# header creation and access
quot .behaviour
	.long lit, BEHAVIOUR_OFFS, add
endq
quot .xt
	.long lit, XT_OFFS, add
endq
quot .label
	.long lit, LABEL_OFFS, add
endq



# dictionary search
var dict
exception NotFound
quot _q_find_01
	.long NotFound, raise
endq
quot _q_find_02  # str dict -- str dict'
	.long get, lit, 0, quote, _q_find_01, case
	.long over, over, .label, eqs
endq
quot find  # str -- xt behav 
	.long dict,  quote, _q_find_02,  until
	.long dup, .xt, get,  swap, .behaviour, get
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




