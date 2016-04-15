#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <assert.h>

#define DS_SIZE 1024
#define RS_SIZE 1024
#define DICT_SIZE 1024

#define SCRATCH_SIZE 16384
#define MAX_WORD_LEN 31
#define SCANW "%31s"
#define HEAP_SIZE (1024*1024*16)

#define ENTRY(lab, x, bh) { .label=(lab), .xt=(x), .behav=(bh) }

#ifdef NDEBUG
#define debug(...)
#else
#define debug(...) do { fprintf(stderr, __VA_ARGS__); } while (0)
#endif

#ifdef TRACE
#define trace(o) do { long mO=(o); fprintf(stderr, "%p: %d %s", ip, mO, dictRevSrch(mO)); } while (0)
#else
#define trace(o)
#endif

long ds[DS_SIZE];

long scr[SCRATCH_SIZE];
long *heap;

long *ip, *dsp;
long hp=64, sp;

void *rs[RS_SIZE];
void **rsp;

long decimalPlaces = 5;

enum FWPrims {
	VarDecimalPlaces, VarNotFound, VarInvalidNumber,

	PrimLit,

	PrimKey, PrimWord,

	PrimFind, PrimNumber,

	PrimPutc, PrimPuts, PrimPutn,

	PrimExit, PrimCall, PrimTail, PrimTailToS, PrimDone,

	PrimBegin, PrimEnd, PrimAs, PrimImm, PrimEval,

	PrimDup, PrimDrop, PrimOver, PrimSwap,

	PrimGet, PrimSet,

	PrimEq, PrimEqs,
	PrimQM, PrimUntil,

	PrimKeeps,
	PrimCompile,
	PrimCompileLiteral,
	PrimRaise,
};

// we use an actual pointer for label, because otherwise
// it's very hard to add labels to words at compile-time!
typedef struct Entry {
	char *label;
	long xt, behav;
} Entry;
Entry dict[DICT_SIZE] = {
	ENTRY("decimal-places", VarDecimalPlaces, PrimCompileLiteral),
	ENTRY("NotFound", VarNotFound, PrimCompileLiteral),
	ENTRY("InvalidNumber", VarInvalidNumber, PrimCompileLiteral),

	ENTRY("'", PrimLit, PrimCompile),

	ENTRY("[", PrimBegin, PrimCall),
	ENTRY("]", PrimEnd,  PrimCall),
	ENTRY("as", PrimAs, PrimCall),
	ENTRY(":imm", PrimImm, PrimCall),
	ENTRY(";;", PrimEval, PrimCall),

	ENTRY("key",  PrimKey,  PrimCompile),
	ENTRY("word", PrimWord, PrimCompile),
	ENTRY("keeps", PrimKeeps, PrimCompile),

	ENTRY("dup", PrimDup, PrimCompile),
	ENTRY("swap", PrimSwap, PrimCompile),
	ENTRY("drop", PrimDrop, PrimCompile),
	ENTRY("over", PrimOver, PrimCompile),
	ENTRY("_ret", PrimDone, PrimCompile),

	ENTRY("?", PrimQM, PrimCompile),
	ENTRY("until", PrimUntil, PrimCompile),
	ENTRY("call", PrimCall, PrimCompile),

	ENTRY("=", PrimEq, PrimCompile),
	ENTRY("eqs", PrimEqs, PrimCompile),

	ENTRY("exit", PrimExit, PrimCompile),
	ENTRY("putn", PrimPutn, PrimCompile),
	ENTRY("putc", PrimPutc, PrimCompile),
	ENTRY("puts", PrimPuts, PrimCompile),
	ENTRY(NULL, 0,0),
};
long dictSize;

#define push(v)  do { *(--dsp) = (v); } while (0)
#define pop()    (*(dsp++))
#define peek()   (*(dsp))

#define pushrs(v) do { *(--rsp) = (v); } while (0)
#define poprs()   (*(rsp++))

#define addr(n) (heap+(n))
#define compile(v) do { scr[sp++] = v; } while (0)

// define wbuf to be somewhere in the heap
#define wbuf (hp+1024)

#define fail(...) do { printf(__VA_ARGS__); exit(1); } while (0)

#define LILIAN_CORRECTION 6346
const long monTable[] = {306,337,0,31,61,92,122,153,184,214,245,275};

long makeLilianDate(long y, long m, long d) {
	// Lilian date is a count of days since the 
	// start of the Gregorian calendar, where
	// 15 Oct 1582 is day 1 (note _not_ day 0!)
	y -= 1600; // maths is easier if we start from multiple of 400
	if (m>12 || m<1)
		return 0;
	// we count years from 1st March to make leap 
	// years easier to handle, so if Jan or Feb
	// we subtract 1 from the year
	y -= m<3 ? 1 : 0;
	m = monTable[m-1];  // days since 1st March to start of current month
	m = m+d; // total days since 1st march
	// Now leap-years...
	d = y / 100;  // d is now num missed 100yr leap-days
	d -= d/4;     // correction for 400yr leap-days
	// now convert years to days...
	// 1461 = 365.25 * 4
	// LILIAN_CORRECTION is the number of days from the 
	// start of the Gregorian calendar to 1 Mar 1600
	y = (y * 1461) / 4 + m + LILIAN_CORRECTION - d;
	push(y);
	return 1;
}
long number(const char *word) {
	char *rest;
	unsigned long m, d, i;
	long n = strtol(word, &rest, 10);
	if (word == rest)
		return 0;
	switch (*rest) {
		case '\0':  // entire string consumed...
			push(n);
			break;
		case 'x':   // hex?
			m = strtol(rest+1, &rest, 16);
			if (n || *rest != '\0')  // ...if preceded by zero
				return 0;
			push(m);
			break;
		case '.':  // this is a decimal (NOT a float!)
			rest++;
			for (i=1; i<=decimalPlaces; i++) {
				unsigned char c = *rest++;
				if (c == '\0') {
					rest--;
				} else {
					c -= '0';
					if (c>9)
						return 0;
				}
				n = n * 10 + c;
			}
			push(n);
			break;
		case '-':  // this is a date
			if (sscanf(rest, "-%2lu-%2lu", &m, &d) != 2)
				return 0;
			return makeLilianDate(n, m, d);
			break;
		case ':':  // this is a time
			if (sscanf(rest, ":%2lu:%2lu", &m, &d) != 2)
				return 0;
			push(n*3600+m*60+d);
			break;
		default:
			return 0;
			break;
	}
	return 1;
}

int esc=0;
char strEsc(char c) {
	switch (c*esc) {
		case 0: break;  // esc not set
		case  '0': c = '\0'; break;
		case  'n': c = '\n'; break;
		case  't': c = '\t'; break;
		case  '"': c = '"' ; break;
		case '\\': c = '\\'; break;
		default: fail("invalid escape sequence '\\%c'\n", c);
	}
	esc = c == '\\' && !esc ? 1 : 0;
	return c;
}
void mkStr(char *word) {
	int len = strlen(word), c, loc=hp;
	char *dst = (char*)addr(hp), *src = word;
	while (c = *src == '\0' ? getc(stdin) : *src++) {
		if (c == '"' && !esc)
			break;
		if ( (c=strEsc(c)) != '\\' ) {
			*dst++ = c;
			len++;
		}
	}
	hp += (len + 4) / sizeof(long);
	push(loc);
}
char *dictRevSrch(int xt) {
	long i;
	for (i=dictSize-1; i>=0; i--) {
		if (dict[i].xt == xt)
			return dict[i].label;
	}
	return "";
}
long dictSearch(char *word) {
	long i;
	char *lbl;
	for (i=dictSize-1; i>=0; i--) {
		lbl = dict[i].label;
		if (strcmp(word, lbl) == 0) {
			push(dict[i].xt);
			push(dict[i].behav);
			return 1;
		}
	}
	if ( word[0] == '\'' ) {
		// char literal
		push(word[1]);
		push(PrimCompileLiteral);
		return 1;
	} else if (word[0] == '"') {
		// string literal
		mkStr(word+1);
		push(PrimCompileLiteral);
		return 1;
	} else if ( number(word) ) {
		push(PrimCompileLiteral);
		return 1;
	}
	return 0;
}
long keep(long *from, long len) {
	long dst = hp;
	memcpy(heap+hp, from, len*sizeof(long));
	hp += len;
	return dst;
}

void eval(long*);
void op(long o) {
	long i;
	trace(o);
	// assert(dsp<=ds+DS_SIZE);
	switch (o) {
		case PrimLit:
			push(*ip++);
			break;
		case PrimKey:
			push(getc(stdin));
			break;
		case PrimWord:
			if ( scanf(SCANW, (char*)addr(wbuf)) < 0 )
				exit(1);
			push( wbuf );
			break;
		case PrimFind:   // str -- xt behav
			if ( !dictSearch( (char*) addr(pop()) ) ) {
				push(VarNotFound);
				op(PrimRaise);
			}
			break;
		case PrimNumber:  // str -- n
			if ( !number( (char*) addr(pop()) ) ) {
				push(VarInvalidNumber);
				op(PrimRaise);
			}
			break;
		case PrimPutc:
			printf("%c", (int) pop());
			break;
		case PrimPuts:
			printf("%s", (char*)addr(pop()));
			break;
		case PrimPutn:
			printf("%ld", pop());
			break;
		case PrimExit:
			exit(pop());
			break;
		case PrimCall:
			op(pop());
			break;
		case PrimDone:
			ip = poprs();
			break;

		/* word creation words */
		case PrimBegin:
			push(sp);
			break;
		case PrimEnd:
			compile(PrimDone);
			i = keep(scr+peek(), sp-peek());
			sp = pop();
			compile(PrimLit);
			compile(i);
			break;
		case PrimAs: // --
			// eval scr from addr on ds (where we get our xt)
			op(PrimEval);
			// read next word
			op(PrimWord);
			op(PrimKeeps);
			dict[dictSize].label = (char*)addr(pop());
			dict[dictSize].xt = pop();
			dict[dictSize].behav = PrimCompile;
			dictSize++;
			break;
		case PrimKeeps:
			i = hp;
			strcpy((char*)addr(hp), (char*)addr(peek()));
			push(i);
			hp += strlen((char*)addr(pop())) + 4 / sizeof(long);
			break;
		case PrimImm:  // make previously defined word immediate
			dict[dictSize-1].behav = PrimCall;
			break;

		case PrimDup:
			push(peek());
			break;
		case PrimDrop:
			dsp++;
			break;
		case PrimOver:
			push(*(dsp+2));
			break;
		case PrimSwap:
			do {
				int tos = pop(), nos = pop();
				push(tos);
				push(nos);
			} while (0);
			break;

		case PrimGet:
			push(heap[pop()]);
			break;
		case PrimSet:
			heap[pop()] = pop();
			break;

		case PrimEq:
			if (pop() == pop())
				push(-1);
			else
				push(0);
			break;
		case PrimEqs:
			if (strcmp((char*)addr(pop()), (char*)addr(pop()))==0)
				push(-1);
			else
				push(0);
			break;

		case PrimQM:
			do {
				int e=pop(), t=pop();
				if (pop())
					push(t);
				else
					push(e);
			} while (0);
			break;
		case PrimUntil:
			do {
				int body=pop(), pred=pop();
				eval(addr(pred));
				while (!pop()) {
					eval(addr(body));
					eval(addr(pred));
				}
			} while (0);
			break;

		case PrimEval:
			compile(PrimDone); // compile PrimDone to scr
			sp = peek();  // evaluated code is not kept
			eval(scr+sp);
			break;

		case PrimCompileLiteral:
			compile(PrimLit);
			// deliberate fallthough!
		case PrimCompile:
			compile(pop());
			break;
		case PrimTail:
			ip = ip + *ip; 
			break;
		case PrimTailToS:
			ip = addr(pop());
			break;
		case PrimRaise:
			printf("Unhandled Exception\n");
			exit(1);
			break;
		default:
			pushrs(ip);
			ip = addr(o);
			break;
	}
	if (dsp > ds+HEAP_SIZE)
		fail("Stack underflow after evaluating op %ld\n", o);
}
void eval(long *code) {
	// evaluate some code, returning when PrimDone is encoutered
	long o;
	void **rsp0 = rsp;
	pushrs(ip);
	ip=code;
	while (rsp < rsp0)
		op(*ip++);
//	for (ip=code;*ip!=PrimDone; op(*ip++));
}


long main(long argc, char **argv) {
	long prog[] = {PrimWord, PrimFind, PrimCall, PrimTail, -4};
	dsp = ds+DS_SIZE;
	rsp = rs+RS_SIZE;
	heap = malloc(HEAP_SIZE);
	ip = prog;
	push(0);
	for (;dict[dictSize].label != NULL; dictSize++);
	for (;;op(*ip++));
	return 0;
}

