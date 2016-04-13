#include <string.h>
#include <stdio.h>
#include <stdlib.h>

#define DS_SIZE 1024
#define RS_SIZE 1024
#define DICT_SIZE 1024

#define SCRATCH_SIZE 16384
#define MAX_WORD_LEN 31
#define SCANW "%31s"
#define HEAP_SIZE (1024*1024*16)

#define ENTRY(lab, x, bh) { .label=(lab), .xt=(x), .behav=(bh) }

int ds[DS_SIZE];
int rs[RS_SIZE];

int scr[SCRATCH_SIZE];
int *heap;

int *ip, *dsp, *rsp;
int hp, sp;

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
	PrimDone,
	PrimCompile,
	PrimCompileLiteral,
	PrimRaise,
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
};
int dictSize = 2;

#define push(v)  do { *(--dsp) = (v); } while (0)
#define pop()    (*(dsp++))
#define peek()   (*(dsp))

#define addr(n) (heap+(n))

#define compile(v) do { scr[sp++] = v; } while (0)

// define wbuf to be somewhere in the heap
#define wbuf (hp+1024)

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
		push(PrimPutn);
		return 1;
	}
	return 0;
}

void procOpcode(int op) {
	switch (op) {
		case PrimLit:
			push(*ip++);
			break;
		case PrimWord:
			if ( scanf(SCANW, addr(wbuf)) < 0 )
				exit(1);
			push( wbuf );
			break;
		case PrimFind:   // str -- xt behav
			if ( !dictSearch( (char*) addr(pop()) ) ) {
				push(VarNotFound);
				procOpcode(PrimRaise);
			}
			break;
		case PrimNumber:  // str -- n
			if ( !number( (char*) addr(pop()) ) ) {
				push(VarInvalidNumber);
				procOpcode(PrimRaise);
			}
			break;
		case PrimPuts:
			printf("%s", addr(pop()));
			break;
		case PrimPutn:
			printf("%d", pop());
			break;
		case PrimExit:
			exit(pop());
			break;
		case PrimCall:
			procOpcode(pop());
			break;
		case PrimDone:
			break;
		case PrimBegin:
			push(sp);
			break;
		case PrimEnd:
			compile(PrimDone);
			break;
		case PrimCompileLiteral:
			compile(PrimLit);
			// deliberate fallthough!
		case PrimCompile:
			compile(pop());
			break;
		case PrimRaise:
			printf("Unhandled Exception\n");
			exit(1);
			break;
		default:
			break;
	}
}


int main(int argc, char **argv) {
	int prog[] = {PrimWord, PrimFind, PrimCall, PrimLit, 17, PrimExit};
	dsp = &ds[DS_SIZE];
	rsp = &rs[RS_SIZE];
	heap = malloc(HEAP_SIZE);
	ip = prog;
	for (;;procOpcode(*ip++));
	return 0;
}

