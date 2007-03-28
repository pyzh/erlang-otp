/* ``The contents of this file are subject to the Erlang Public License,
 * Version 1.1, (the "License"); you may not use this file except in
 * compliance with the License. You should have received a copy of the
 * Erlang Public License along with this software. If not, it can be
 * retrieved via the world wide web at http://www.erlang.org/.
 * 
 * Software distributed under the License is distributed on an "AS IS"
 * basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
 * the License for the specific language governing rights and limitations
 * under the License.
 * 
 * The Initial Developer of the Original Code is Ericsson Utvecklings AB.
 * Portions created by Ericsson are Copyright 1999, Ericsson Utvecklings
 * AB. All Rights Reserved.''
 * 
 *     $Id$
 */

#ifdef HAVE_CONFIG_H
#  include "config.h"
#endif

#include "sys.h"
#include "erl_vm.h"
#include "global.h"
#include "erl_process.h"
#include "error.h"
#include "bif.h"
#include "big.h"
#include "erl_binary.h"
#include "erl_bits.h"

Uint erts_allocated_binaries;
erts_mtx_t erts_bin_alloc_mtx;

void
erts_init_binary(void)
{
    erts_allocated_binaries = 0;
    erts_mtx_init(&erts_bin_alloc_mtx, "binary_alloc");

    /* Verify Binary alignment... */
    if ((((Uint) &((Binary *) 0)->orig_bytes[0]) % ((Uint) 8)) != 0) {
	/* I assume that any compiler should be able to optimize this
	   away. If not, this test is not very expensive... */
	erl_exit(ERTS_ABORT_EXIT,
		 "Internal error: Address of orig_bytes[0] of a Binary"
		 "is *not* 8-byte aligned\n");
    }
}

/*
 * Create a brand new binary from scratch.
 */

Eterm
new_binary(Process *p, byte *buf, int len)
{
    ProcBin* pb;
    Binary* bptr;

    if (len <= ERL_ONHEAP_BIN_LIMIT) {
	ErlHeapBin* hb = (ErlHeapBin *) HAlloc(p, heap_bin_size(len));
	hb->thing_word = header_heap_bin(len);
	hb->size = len;
	if (buf != NULL) {
	    sys_memcpy(hb->data, buf, len);
	}
	return make_binary(hb);
    }

    /*
     * Allocate the binary struct itself.
     */
    bptr = erts_bin_nrml_alloc(len);
    bptr->flags = 0;
    bptr->orig_size = len;
    erts_refc_init(&bptr->refc, 1);
    if (buf != NULL) {
	sys_memcpy(bptr->orig_bytes, buf, len);
    }

    /*
     * Now allocate the ProcBin on the heap.
     */
    pb = (ProcBin *) HAlloc(p, PROC_BIN_SIZE);
    pb->thing_word = HEADER_PROC_BIN;
    pb->size = len;
    pb->next = MSO(p).mso;
    MSO(p).mso = pb;
    pb->val = bptr;
    pb->bytes = (byte*) bptr->orig_bytes;

    /*
     * Miscellanous updates. Return the tagged binary.
     */
    MSO(p).overhead += pb->size / BINARY_OVERHEAD_FACTOR / sizeof(Eterm);
    return make_binary(pb);
}

/*
 * Create a brand new binary from scratch on the heap.
 */

Eterm
erts_new_heap_binary(Process *p, byte *buf, int len, byte** datap)
{
    ErlHeapBin* hb = (ErlHeapBin *) HAlloc(p, heap_bin_size(len));

    hb->thing_word = header_heap_bin(len);
    hb->size = len;
    if (buf != NULL) {
	sys_memcpy(hb->data, buf, len);
    }
    *datap = (byte*) hb->data;
    return make_binary(hb);
}

#if !defined(HEAP_FRAG_ELIM_TEST)
/* Like new_binary, but uses ArithAlloc. */
/* Silly name. Come up with something better. */
Eterm new_binary_arith(Process *p, byte *buf, int len)
{
    ProcBin* pb;
    Binary* bptr;

    if (len <= ERL_ONHEAP_BIN_LIMIT) {
	ErlHeapBin* hb = (ErlHeapBin *) ArithAlloc(p, heap_bin_size(len));
	hb->thing_word = header_heap_bin(len);
	hb->size = len;
	if (buf != NULL) {
	    sys_memcpy(hb->data, buf, len);
	}
	return make_binary(hb);
    }

    /*
     * Allocate the binary struct itself.
     */
    bptr = erts_bin_nrml_alloc(len);
    bptr->flags = 0;
    bptr->orig_size = len;
    erts_refc_init(&bptr->refc, 1);
    if (buf != NULL) {
	sys_memcpy(bptr->orig_bytes, buf, len);
    }

    /*
     * Now allocate the ProcBin on the heap.
     */
    pb = (ProcBin *) ArithAlloc(p, PROC_BIN_SIZE);
    pb->thing_word = HEADER_PROC_BIN;
    pb->size = len;
    pb->next = MSO(p).mso;
    MSO(p).mso = pb;
    pb->val = bptr;
    pb->bytes = (byte*) bptr->orig_bytes;

    /*
     * Miscellanous updates. Return the tagged binary.
     */
    MSO(p).overhead += pb->size / BINARY_OVERHEAD_FACTOR / sizeof(Eterm);
    return make_binary(pb);
}
#endif

Eterm
erts_realloc_binary(Eterm bin, size_t size)
{
    Eterm* bval = binary_val(bin);

    if (thing_subtag(*bval) == HEAP_BINARY_SUBTAG) {
	binary_size(bin) = size;
    } else {			/* REFC */
	ProcBin* pb = (ProcBin *) bval;
	Binary* newbin = erts_bin_realloc(pb->val, size);
	newbin->orig_size = size;
	pb->val = newbin;
	pb->size = size;
	pb->bytes = (byte*) newbin->orig_bytes;
	bin = make_binary(pb);
    }
    return bin;
}

byte*
erts_get_aligned_binary_bytes(Eterm bin, byte** base_ptr)
{
    byte* bytes;
    Eterm* real_bin;
    Uint byte_size;
    Uint offs = 0;
    Uint bit_offs = 0;
    
    if (is_not_binary(bin)) {
	return NULL;
    }
    byte_size = binary_size(bin);
    real_bin = binary_val(bin);
    if (*real_bin == HEADER_SUB_BIN) {
	ErlSubBin* sb = (ErlSubBin *) real_bin;
	if (sb->bitsize) {
	    return NULL;
	}
	offs = sb->offs;
	bit_offs = sb->bitoffs;
	real_bin = binary_val(sb->orig);
    }
    if (*real_bin == HEADER_PROC_BIN) {
	bytes = ((ProcBin *) real_bin)->bytes + offs;
    } else {
	bytes = (byte *)(&(((ErlHeapBin *) real_bin)->data)) + offs;
    }
    if (bit_offs) {
	byte* buf = (byte *) erts_alloc(ERTS_ALC_T_TMP, byte_size);

	erts_copy_bits(bytes, bit_offs, 1, buf, 0, 1, byte_size*8);
	*base_ptr = buf;
	bytes = buf;
    }
    return bytes;
}

static Eterm
bin_bytes_to_list(Eterm previous, Eterm* hp, byte* bytes, Uint size, Uint bitoffs)
{
    if (bitoffs == 0) {
	while (size) {
	    previous = CONS(hp, make_small(bytes[--size]), previous);
	    hp += 2;
	}
    } else {
	byte present;
	byte next;
	next = bytes[size];
	while (size) {
	    present = next;
	    next = bytes[--size];
	    previous = CONS(hp, make_small(((present >> (8-bitoffs)) |
					    (next << bitoffs)) & 255), previous);
	    hp += 2;
	}
    }
    return previous;
}


BIF_RETTYPE binary_to_list_1(BIF_ALIST_1)
{
    Eterm real_bin;
    Uint offset;
    Uint size;
    Uint bitsize;
    Uint bitoffs;
    byte* bytes;
    Eterm previous = NIL;
    Eterm* hp;

    if (is_not_binary(BIF_ARG_1)) {
	BIF_ERROR(BIF_P, BADARG);
    }
    size = binary_size(BIF_ARG_1);
    ERTS_GET_REAL_BIN(BIF_ARG_1, real_bin, offset, bitoffs, bitsize);
    bytes = binary_bytes(real_bin)+offset;
    if (bitsize == 0) {
	hp = HAlloc(BIF_P, 2 * size);
    } else {
      if (size == 0) {
	hp = HAlloc(BIF_P, 2);
	BIF_RET(CONS(hp,BIF_ARG_1,NIL));
      }
      else
	{
	  ErlSubBin* last;
	  hp = HAlloc(BIF_P, ERL_SUB_BIN_SIZE+2+2*size);
	  last = (ErlSubBin *) hp;
	  last->thing_word = HEADER_SUB_BIN;
	  last->size = 0;
	  last->bitsize = bitsize;
	  last->offs = offset+size;
	  last->bitoffs = bitoffs;
	  last->orig = real_bin;
	  hp += ERL_SUB_BIN_SIZE;
	  previous = CONS(hp, make_binary(last), previous);
	  hp += 2;
	}
    }
    BIF_RET(bin_bytes_to_list(previous, hp, bytes, size, bitoffs));
}

BIF_RETTYPE binary_to_list_3(BIF_ALIST_3)
{
    byte* bytes;
    Uint size;
    Uint bitoffs;
    Uint bitsize;
    Uint i;
    Uint start;
    Uint stop;
    Eterm* hp;

    if (is_not_binary(BIF_ARG_1)) {
    error:
	BIF_ERROR(BIF_P, BADARG);
    }
    if (!term_to_Uint(BIF_ARG_2, &start) || !term_to_Uint(BIF_ARG_3, &stop)) {
	goto error;
    }
    size = binary_size(BIF_ARG_1);
    ERTS_GET_BINARY_BYTES(BIF_ARG_1, bytes, bitoffs, bitsize);
    if (start < 1 || start > size || stop < 1 ||
	stop > size || stop < start ) {
	goto error;
    }
    i = stop-start+1;
    hp = HAlloc(BIF_P, 2*i);
    BIF_RET(bin_bytes_to_list(NIL, hp, bytes+start-1, i, bitoffs));
}


/* Turn a possibly deep list of ints (and binaries) into */
/* One large binary object                               */

BIF_RETTYPE list_to_binary_1(BIF_ALIST_1)
{
    Eterm bin;
    int i,offset;
    byte* bytes;
    ErlSubBin* sb1; 
    Eterm* hp;
    
    if (is_nil(BIF_ARG_1)) {
	BIF_RET(new_binary(BIF_P,(byte*)"",0));
    }
    if (is_not_list(BIF_ARG_1)) {
    error:
	BIF_ERROR(BIF_P, BADARG);
    }
    if ((i = io_list_len(BIF_ARG_1)) < 0) {
	goto error;
    }
    bin = new_binary(BIF_P, (byte *)NULL, i);
    bytes = binary_bytes(bin);
    offset = io_list_to_buf2(BIF_ARG_1, (char*) bytes, i);
    if (offset < 0) {
	goto error;
    } else if (offset > 0) {
	hp = HAlloc(BIF_P, ERL_SUB_BIN_SIZE);
	sb1 = (ErlSubBin *) hp;
	sb1->thing_word = HEADER_SUB_BIN;
	sb1->size = i-1;
	sb1->offs = 0;
	sb1->orig = bin;
	sb1->bitoffs = 0;
	sb1->bitsize = offset;
	hp += ERL_SUB_BIN_SIZE;
	bin = make_binary(sb1);
    }
    
    BIF_RET(bin);
}

/* Turn a possibly deep list of ints (and binaries) into */
/* One large binary object                               */

BIF_RETTYPE iolist_to_binary_1(BIF_ALIST_1)
{
    Eterm bin;
    int i, offset;
    byte* bytes;
    ErlSubBin* sb1; 
    Eterm* hp;

    if (is_binary(BIF_ARG_1)) {
	BIF_RET(BIF_ARG_1);
    }
    if (is_nil(BIF_ARG_1)) {
	BIF_RET(new_binary(BIF_P,(byte*)"",0));
    }
    if (is_not_list(BIF_ARG_1)) {
    error:
	BIF_ERROR(BIF_P, BADARG);
    }
    if ((i = io_list_len(BIF_ARG_1)) < 0) {
	goto error;
    }
    bin = new_binary(BIF_P, (byte *)NULL, i);
    bytes = binary_bytes(bin);
    if ((offset = io_list_to_buf(BIF_ARG_1, (char*) bytes, i)) < 0) {
	goto error;
    } else if (offset > 0) {
	hp = HAlloc(BIF_P, ERL_SUB_BIN_SIZE);
	sb1 = (ErlSubBin *) hp;
	sb1->thing_word = HEADER_SUB_BIN;
	sb1->size = i-1;
	sb1->offs = 0;
	sb1->orig = bin;
	sb1->bitoffs = 0;
	sb1->bitsize = offset;
	hp += ERL_SUB_BIN_SIZE;
	bin = make_binary(sb1);
    }
    BIF_RET(bin);
}

BIF_RETTYPE split_binary_2(BIF_ALIST_2)
{
    Uint pos;
    ErlSubBin* sb1;
    ErlSubBin* sb2;
    size_t orig_size;
    Eterm orig;
    Uint offset;
    Uint bit_offset;
    Uint bit_size;
    Eterm* hp;

    if (is_not_binary(BIF_ARG_1)) {
    error:
	BIF_ERROR(BIF_P, BADARG);
    }
    if (!term_to_Uint(BIF_ARG_2, &pos)) {
	goto error;
    }
    if ((orig_size = binary_size(BIF_ARG_1)) < pos) {
	goto error;
    }
    hp = HAlloc(BIF_P, 2*ERL_SUB_BIN_SIZE+3);
    ERTS_GET_REAL_BIN(BIF_ARG_1, orig, offset, bit_offset, bit_size);
    sb1 = (ErlSubBin *) hp;
    sb1->thing_word = HEADER_SUB_BIN;
    sb1->size = pos;
    sb1->offs = offset;
    sb1->orig = orig;
    sb1->bitoffs = bit_offset;
    sb1->bitsize = 0;
    hp += ERL_SUB_BIN_SIZE;

    sb2 = (ErlSubBin *) hp;
    sb2->thing_word = HEADER_SUB_BIN;
    sb2->size = orig_size - pos;
    sb2->offs = offset + pos;
    sb2->orig = orig;
    sb2->bitoffs = bit_offset;
    sb2->bitsize = bit_size;	/* The extra bits go into the second binary. */
    hp += ERL_SUB_BIN_SIZE;

    return TUPLE2(hp, make_binary(sb1), make_binary(sb2));
}

void
erts_cleanup_mso(ProcBin* pb)
{
    while (pb != NULL) {
	ProcBin* next = pb->next;
	if (erts_refc_dectest(&pb->val->refc, 0) == 0) {
	    if (pb->val->flags & BIN_FLAG_MATCH_PROG) {
		erts_match_set_free(pb->val);
	    } else {
		erts_bin_free(pb->val);
	    }
	}
	pb = next;
    }
}
