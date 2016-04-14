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

int ds[DS_SIZE];

int scr[SCRATCH_SIZE];
int *heap;

int *ip, *dsp;
int hp=64, sp;

void *rs[RS_SIZE];
void **rsp;

int decimalPlaces = 5;

enum FWPrims {
	VarDecimalPlaces,
	VarNotFound,
	VarInvalidNumber,
	PrimLit,
	PrimWord,
	PrimFind,
	PrimNumber,
	PrimPuts,
	PrimPutn,
	PrimExit,
	PrimCall,
	PrimBegin,
	PrimEnd,
	PrimAs,
	PrimKeeps,
	PrimImm,
	PrimDone,
	PrimCompile,
	PrimCompileLiteral,
	PrimRaise,
	PrimTail,
};

// we use an actual pointer for label, because otherwise
// it's very hard to add labels to words at compile-time!
typedef struct Entry {
	char *label;
	int xt, behav;
} Entry;
Entry dict[DICT_SIZE] = {
	ENTRY("decimal-places", VarDecimalPlaces, PrimCompileLiteral),
	ENTRY("NotFound", VarNotFound, PrimCompileLiteral),
	ENTRY("InvalidNumber", VarInvalidNumber, PrimCompileLiteral),

	ENTRY("[", PrimBegin, PrimCall),
	ENTRY("]", PrimEnd,  PrimCall),
	ENTRY("as", PrimAs, PrimCall),
	ENTRY(":imm", PrimImm, PrimCall),

	ENTRY("exit", PrimExit, PrimCompile),
	ENTRY("putn", PrimPutn, PrimCompile),
	ENTRY(NULL, 0,0),
};
int dictSize;

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
const int monTable[] = {306,337,0,31,61,92,122,153,184,214,245,275};

int makeLilianDate(int y, int m, int d) {
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
int number(const char *word) {
	char *rest;
	unsigned int m, d, i;
	int n = strtol(word, &rest, 10);
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
			if (sscanf(rest, "-%2u-%2u", &m, &d) != 2)
				return 0;
			return makeLilianDate(n, m, d);
			break;
		case ':':  // this is a time
			if (sscanf(rest, ":%2u:%2u", &m, &d) != 2)
				return 0;
			push(n*3600+m*60+d);
			break;
		default:
			return 0;
			break;
	}
	return 1;
}
int dictSearch(const char *word) {
	int i;
	char *lbl;
	for (i=dictSize-1; i>=0; i--) {
		lbl = dict[i].label;
		if (strcmp(word, lbl) == 0) {
			push(dict[i].xt);
			push(dict[i].behav);
			return 1;
		}
	}
	if ( number(word) ) {
		push(PrimCompileLiteral);
		return 1;
	}
	return 0;
}
int keep(int *from, int len) {
	int dst = hp;
	memcpy(heap+hp, from, len*sizeof(int));
	hp += len;
	return dst;
}

void eval(int*);
void op(int o) {
	int i;
	// assert(dsp<=ds+DS_SIZE);
	switch (o) {
		case PrimLit:
			push(*ip++);
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
		case PrimPuts:
			printf("%s", (char*)addr(pop()));
			break;
		case PrimPutn:
			printf("%d", pop());
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
			// compile PrimDone to scr
			compile(PrimDone);
			// eval scr from addr on ds (where we get our xt)
			sp = peek();  // delete evaluated code
			eval(scr+sp);
			// read next word
			op(PrimWord);
			op(PrimKeeps);
			dict[dictSize].label = (char*)addr(pop());
			dict[dictSize].xt = pop();
			dict[dictSize].behav = PrimCompile;
			dictSize++;
			ip = poprs();
			break;
		case PrimKeeps:
			i = hp;
			strcpy((char*)addr(hp), (char*)addr(peek()));
			push(i);
			hp += strlen((char*)addr(pop())) + 4 / sizeof(int);
			break;
		case PrimImm:
			dict[dictSize-1].behav = PrimCall;
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
		fail("Stack underflow after evaluating op %d\n", o);
}
void eval(int *code) {
	// evaluate some code, returning when PrimDone is encoutered
	int o;
	void **rsp0 = rsp;
	pushrs(ip);
	ip=code;
	while (*ip != PrimDone)
		op(*ip++);
//	for (ip=code;*ip!=PrimDone; op(*ip++));
}


int main(int argc, char **argv) {
	int prog[] = {PrimWord, PrimFind, PrimCall, PrimTail, -4};
	dsp = &ds[DS_SIZE];
	rsp = &rs[RS_SIZE];
	heap = malloc(HEAP_SIZE);
	ip = prog;
	push(0);
	for (;dict[dictSize].label != NULL; dictSize++);
	for (;;op(*ip++));
	return 0;
}

