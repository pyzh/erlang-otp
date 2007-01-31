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
/*
 * Common utilities for the different types of db tables.
 * Mostly matching etc.
 */

#ifdef HAVE_CONFIG_H
#  include "config.h"
#endif

#include "sys.h"
#include "erl_vm.h"
#include "global.h"
#include "erl_process.h"
#include "error.h"
#define ERTS_WANT_DB_INTERNAL__
#include "erl_db.h"
#include "bif.h"
#include "big.h"
#include "erl_binary.h"

#include "erl_db_util.h"


/*
** Flags for the guard bif's
*/

/* These are offsets from the DCOMP_* value */
#define DBIF_GUARD 1
#define DBIF_BODY  0

/* These are the DBIF flag bits corresponding to the DCOMP_* value.
 * If a bit is set, the BIF is allowed in that context. */
#define DBIF_TABLE_GUARD (1 << (DCOMP_TABLE + DBIF_GUARD))
#define DBIF_TABLE_BODY  (1 << (DCOMP_TABLE + DBIF_BODY))
#define DBIF_TRACE_GUARD (1 << (DCOMP_TRACE + DBIF_GUARD))
#define DBIF_TRACE_BODY  (1 << (DCOMP_TRACE + DBIF_BODY))
#define DBIF_ALL \
DBIF_TABLE_GUARD | DBIF_TABLE_BODY | DBIF_TRACE_GUARD | DBIF_TRACE_BODY



/*
** Some convenience macros for stacks (DMC == db_match_compile)
*/

#define DMC_DEFAULT_SIZE 25

#define DMC_STACK_TYPE(Type) DMC_##Type##_stack

#define DMC_DECLARE_STACK_TYPE(Type)            \
typedef struct DMC_STACK_TYPE(Type) {		\
    int pos;					\
    int siz;					\
    Type def[DMC_DEFAULT_SIZE];		        \
    Type *data;					\
} DMC_STACK_TYPE(Type)
    
#define DMC_INIT_STACK(Name) \
     (Name).pos = 0; (Name).siz = DMC_DEFAULT_SIZE; (Name).data = (Name).def

#define DMC_STACK_DATA(Name) (Name).data

#define DMC_STACK_NUM(Name) (Name).pos

#define DMC_PUSH(On, What)						\
do {									\
    if ((On).pos >= (On).siz) {						\
	(On).siz *= 2;							\
	(On).data							\
	    = (((On).def == (On).data)					\
	       ? memcpy(erts_alloc(ERTS_ALC_T_DB_MC_STK,		\
				   (On).siz*sizeof(*((On).data))),	\
			(On).def,					\
			DMC_DEFAULT_SIZE*sizeof(*((On).data)))		\
	       : erts_realloc(ERTS_ALC_T_DB_MC_STK,			\
			      (void *) (On).data,			\
			      (On).siz*sizeof(*((On).data))));		\
    }									\
    (On).data[(On).pos++] = What;					\
} while (0)

#define DMC_POP(From) (From).data[--(From).pos]

#define DMC_TOP(From) (From).data[(From).pos - 1]

#define DMC_EMPTY(Name) ((Name).pos == 0)

#define DMC_PEEK(On, At) (On).data[At]     

#define DMC_POKE(On, At, Value) ((On).data[At] = (Value))

#define DMC_CLEAR(Name) (Name).pos = 0

#define DMC_FREE(Name)							\
do {									\
    if ((Name).def != (Name).data)					\
	erts_free(ERTS_ALC_T_DB_MC_STK, (Name).data);			\
} while (0)

static ERTS_INLINE Process *
get_proc(Process *cp, Uint32 cp_locks, Eterm id, Uint32 id_locks)
{
    Process *proc = erts_pid2proc(cp, cp_locks, id, id_locks);
    if (!proc && is_atom(id))
	proc = erts_whereis_process(cp, cp_locks, id, id_locks, 0);
    return proc;
}


static Eterm
set_tracee_flags(Process *tracee_p, Eterm tracer, Uint d_flags, Uint e_flags) {
    Eterm ret;
    Uint  flags = 0;
    
    if (tracer != NIL) {
	flags = (tracee_p->trace_flags & ~d_flags) | e_flags;
	if (! flags) tracer = NIL;
    }
    ret = tracee_p->tracer_proc != tracer || tracee_p->trace_flags != flags
	? am_true : am_false;
    tracee_p->tracer_proc = tracer;
    tracee_p->trace_flags = flags;
    
    return ret;
}
/*
** Assuming all locks on tracee_p on entry
**
** Changes tracee_p->trace_flags and tracee_p->tracer_proc
** according to input disable/enable flags and tracer.
**
** Returns am_true|am_false on success, am_true if value changed,
** returns fail_term on failure. Fails if tracer pid or port is invalid.
*/
static Eterm 
set_match_trace(Process *tracee_p, Eterm fail_term, Eterm tracer,
		Uint d_flags, Uint e_flags) {
    Eterm ret = fail_term;
    Process *tracer_p;
    
    ERTS_SMP_LC_ASSERT(ERTS_PROC_LOCKS_ALL == 
		       erts_proc_lc_my_proc_locks(tracee_p));

    if (is_internal_pid(tracer)
	&& (tracer_p = 
	    erts_pid2proc(tracee_p, ERTS_PROC_LOCKS_ALL,
			  tracer, ERTS_PROC_LOCKS_ALL))) {
	if (tracee_p != tracer_p) {
	    ret = set_tracee_flags(tracee_p, tracer, d_flags, e_flags);
	    tracer_p->trace_flags |= tracee_p->trace_flags ? F_TRACER : 0;
	    erts_smp_proc_unlock(tracer_p, ERTS_PROC_LOCKS_ALL);
	}
    } else if (is_internal_port(tracer)) {
	Port *tracer_port = 
	    erts_id2port(tracer, tracee_p, ERTS_PROC_LOCKS_ALL);
	if (tracer_port) {
	    if (! INVALID_TRACER_PORT(tracer_port, tracer)) {
		ret = set_tracee_flags(tracee_p, tracer, d_flags, e_flags);
	    }
	    erts_smp_port_unlock(tracer_port);
	}
    } else {
	ASSERT(is_nil(tracer));
	ret = set_tracee_flags(tracee_p, tracer, d_flags, e_flags);
    }
    return ret;
}


/* Type checking... */

#define BOXED_IS_TUPLE(Boxed) is_arity_value(*boxed_val((Boxed)))

/*
**
** Types and enum's (compiled matches)
**
*/

/*
** match VM instructions
*/
typedef enum {
    matchArray, /* Only when parameter is an array (DCOMP_TRACE) */
    matchArrayBind, /* ------------- " ------------ */
    matchTuple,
    matchPushT,
    matchPushL,
    matchPop,
    matchBind,
    matchCmp,
    matchEqBin,
    matchEqFloat,
    matchEqBig,
    matchEqRef,
    matchEq,
    matchList,
    matchSkip,
    matchPushC,
    matchConsA, /* Car is below Cdr */
    matchConsB, /* Cdr is below Car (unusual) */
    matchMkTuple,
    matchCall0,
    matchCall1,
    matchCall2,
    matchCall3,
    matchPushV,
    matchPushExpr, /* Push the whole expression we're matching ('$_') */
    matchPushArrayAsList, /* Only when parameter is an Array and 
			     not an erlang term  (DCOMP_TRACE) */
    matchPushArrayAsListU, /* As above but unknown size */
    matchTrue,
    matchOr,
    matchAnd,
    matchOrElse,
    matchAndThen,
    matchSelf,
    matchWaste,
    matchReturn,
    matchProcessDump,
    matchDisplay,
    matchIsSeqTrace,
    matchSetSeqToken,
    matchGetSeqToken,
    matchSetReturnTrace,
    matchSetExceptionTrace,
    matchCatch,
    matchEnableTrace,
    matchDisableTrace,
    matchEnableTrace2,
    matchDisableTrace2,
    matchTryMeElse,
    matchCaller,
    matchHalt,
    matchSilent,
    matchSetSeqTokenFake,
    matchTrace2,
    matchTrace3
} MatchOps;

/*
** Guard bif's
*/

typedef struct dmc_guard_bif {
    Eterm name; /* atom */
    void *biff;
    /*    BIF_RETTYPE (*biff)(); */
    int arity;
    Uint32 flags;
} DMCGuardBif; 

/*
** Error information (for lint)
*/

/*
** Type declarations for stacks
*/
DMC_DECLARE_STACK_TYPE(Eterm);

DMC_DECLARE_STACK_TYPE(Uint);

DMC_DECLARE_STACK_TYPE(unsigned);

/*
** Data about the heap during compilation
*/

typedef struct DMCHeap {
    int size;
    unsigned def[DMC_DEFAULT_SIZE];
    unsigned *data;
    int used;
} DMCHeap;

/*
** Return values from sub compilation steps (guard compilation)
*/

typedef enum dmc_ret { 
    retOk, 
    retFail, 
    retRestart 
} DMCRet; 

/*
** Diverse context information
*/

typedef struct dmc_context {
    int stack_need;
    int stack_used;
    ErlHeapFragment *save;
    ErlHeapFragment *copy;
    Eterm *matchexpr;
    Eterm *guardexpr;
    Eterm *bodyexpr;
    int num_match;
    int current_match;
    int eheap_need;
    Uint cflags;
    DMC_STACK_TYPE(Uint) *labels;
    int is_guard; /* 1 if in guard, 0 if in body */
    int special; /* 1 if the head in the match was a single expression */ 
    DMCErrInfo *err_info;
} DMCContext;

/*
**
** Global variables 
**
*/

/*
** Internal
*/

/* 
** The pseudo process used by the VM (pam).
*/

#define ERTS_DEFAULT_MS_HEAP_SIZE 128

typedef struct {
    Process process;
    Eterm *heap;
    Eterm default_heap[ERTS_DEFAULT_MS_HEAP_SIZE];
} ErtsMatchPseudoProcess;


#ifdef ERTS_SMP
static erts_smp_tsd_key_t match_pseudo_process_key;
#else
static ErtsMatchPseudoProcess *match_pseudo_process;
#endif

static ERTS_INLINE void
cleanup_match_pseudo_process(ErtsMatchPseudoProcess *mpsp, int keep_heap)
{
    if (mpsp->process.mbuf
	|| mpsp->process.off_heap.mso
#ifndef HYBRID /* FIND ME! */
	|| mpsp->process.off_heap.funs
#endif
	|| mpsp->process.off_heap.externals) {
	erts_cleanup_empty_process(&mpsp->process);
    }
#ifdef DEBUG
    else {
	erts_debug_verify_clean_empty_process(&mpsp->process);
    }
#endif
    if (!keep_heap) {
	if (mpsp->heap != &mpsp->default_heap[0]) {
	    /* Have to be done *after* call to erts_cleanup_empty_process() */
	    erts_free(ERTS_ALC_T_DB_MS_RUN_HEAP, (void *) mpsp->heap);
	    mpsp->heap = &mpsp->default_heap[0];
	}
#ifdef DEBUG
	else {
	    int i;
	    for (i = 0; i < ERTS_DEFAULT_MS_HEAP_SIZE; i++) {
#ifdef ARCH_64
		mpsp->default_heap[i] = (Eterm) 0xdeadbeefdeadbeef;
#else
		mpsp->default_heap[i] = (Eterm) 0xdeadbeef;
#endif
	    }
	}
#endif
    }
}

static ErtsMatchPseudoProcess *
create_match_pseudo_process(void)
{
    ErtsMatchPseudoProcess *mpsp;
    mpsp = (ErtsMatchPseudoProcess *)erts_alloc(ERTS_ALC_T_DB_MS_PSDO_PROC,
						sizeof(ErtsMatchPseudoProcess));
    erts_init_empty_process(&mpsp->process);
    mpsp->heap = &mpsp->default_heap[0];
    return mpsp;
}

static ERTS_INLINE ErtsMatchPseudoProcess *
get_match_pseudo_process(Process *c_p, Uint heap_size)
{
    ErtsMatchPseudoProcess *mpsp;
#ifdef ERTS_SMP
    mpsp = (ErtsMatchPseudoProcess *) c_p->scheduler_data->match_pseudo_process;
    if (mpsp)
	cleanup_match_pseudo_process(mpsp, 0);
    else {
	ASSERT(erts_smp_tsd_get(match_pseudo_process_key) == NULL);
	mpsp = create_match_pseudo_process();
	c_p->scheduler_data->match_pseudo_process = (void *) mpsp;
	erts_smp_tsd_set(match_pseudo_process_key, (void *) mpsp);
    }
    ASSERT(mpsp == erts_smp_tsd_get(match_pseudo_process_key));
    mpsp->process.scheduler_data = c_p->scheduler_data;
#else
    mpsp = match_pseudo_process;
    cleanup_match_pseudo_process(mpsp, 0);
#endif
    if (heap_size > ERTS_DEFAULT_MS_HEAP_SIZE)
	mpsp->heap = (Eterm *) erts_alloc(ERTS_ALC_T_DB_MS_RUN_HEAP,
					  heap_size*sizeof(Uint));
    else {
	ASSERT(mpsp->heap == &mpsp->default_heap[0]);
    }
    return mpsp;
}

#ifdef ERTS_SMP
static void
destroy_match_pseudo_process(void)
{
    ErtsMatchPseudoProcess *mpsp;
    mpsp = (ErtsMatchPseudoProcess *)erts_smp_tsd_get(match_pseudo_process_key);
    if (mpsp) {
	cleanup_match_pseudo_process(mpsp, 0);
	erts_free(ERTS_ALC_T_DB_MS_PSDO_PROC, (void *) mpsp);
	erts_smp_tsd_set(match_pseudo_process_key, (void *) NULL);
    }
}
#endif

static
void
match_pseudo_process_init(void)
{
#ifdef ERTS_SMP
    erts_smp_tsd_key_create(&match_pseudo_process_key);
    erts_smp_install_exit_handler(destroy_match_pseudo_process);
#else
    match_pseudo_process = create_match_pseudo_process();
#endif
}

void
erts_match_set_release_result(Process* c_p)
{
    (void) get_match_pseudo_process(c_p, 0); /* Clean it up */
}

/* The trace control word. */

static erts_smp_atomic_t trace_control_word;


Eterm
erts_ets_copy_object(Eterm obj, Process* to)
{
    Uint size = size_object(obj);
    Eterm* hp = HAlloc(to, size);
    Eterm res;

    res = copy_struct(obj, size, &hp, &MSO(to));
#ifdef DEBUG
    if (eq(obj, res) == 0) {
	erl_exit(1, "copy not equal to source\n");
    }
#endif
    return res;
}

/* This needs to be here, before the bif table... */

static Eterm db_set_trace_control_word_fake_1(Process *p, Eterm val);

/*
** The table of callable bif's, i e guard bif's and 
** some special animals that can provide us with trace
** information. This array is sorted on init.
*/
static DMCGuardBif guard_tab[] =
{
    {
	am_is_atom,
	&is_atom_1,
	1,
	DBIF_ALL
    },
    {
	am_is_constant,
	&is_constant_1,
	1,
	DBIF_ALL
    },    
    {
	am_is_float,
	&is_float_1,
	1,
	DBIF_ALL
    },
    {
	am_is_integer,
	&is_integer_1,
	1,
	DBIF_ALL
    },
    {
	am_is_list,
	&is_list_1,
	1,
	DBIF_ALL
    },
    {
	am_is_number,
	&is_number_1,
	1,
	DBIF_ALL
    },
    {
	am_is_pid,
	&is_pid_1,
	1,
	DBIF_ALL
    },
    {
	am_is_port,
	&is_port_1,
	1,
	DBIF_ALL
    },
    {
	am_is_reference,
	&is_reference_1,
	1,
	DBIF_ALL
    },
    {
	am_is_tuple,
	&is_tuple_1,
	1,
	DBIF_ALL
    },
    {
	am_is_binary,
	&is_binary_1,
	1,
	DBIF_ALL
    },
    {
	am_is_function,
	&is_function_1,
	1,
	DBIF_ALL
    },
    {
	am_is_record,
	&is_record_3,
	3,
	DBIF_ALL
    },
    {
	am_abs,
	&abs_1,
	1,
	DBIF_ALL
    },
    {
	am_element,
	&element_2,
	2,
	DBIF_ALL
    },
    {
	am_hd,
	&hd_1,
	1,
	DBIF_ALL
    },
    {
	am_length,
	&length_1,
	1,
	DBIF_ALL
    },
    {
	am_node,
	&node_1,
	1,
	DBIF_ALL
    },
    {
	am_node,
	&node_0,
	0,
	DBIF_ALL
    },
    {
	am_round,
	&round_1,
	1,
	DBIF_ALL
    },
    {
	am_size,
	&size_1,
	1,
	DBIF_ALL
    },
    {
	am_bitsize,
	&bitsize_1,
	1,
	DBIF_ALL
    },
    {
	am_tl,
	&tl_1,
	1,
	DBIF_ALL
    },
    {
	am_trunc,
	&trunc_1,
	1,
	DBIF_ALL
    },
    {
	am_float,
	&float_1,
	1,
	DBIF_ALL
    },
    {
	am_Plus,
	&splus_1,
	1,
	DBIF_ALL
    },
    {
	am_Minus,
	&sminus_1,
	1,
	DBIF_ALL
    },
    {
	am_Plus,
	&splus_2,
	2,
	DBIF_ALL
    },
    {
	am_Minus,
	&sminus_2,
	2,
	DBIF_ALL
    },
    {
	am_Times,
	&stimes_2,
	2,
	DBIF_ALL
    },
    {
	am_Div,
	&div_2,
	2,
	DBIF_ALL
    },
    {
	am_div,
	&intdiv_2,
	2,
	DBIF_ALL
    },
    {
	am_rem,
	&rem_2,
	2,
	DBIF_ALL
    },
    {
	am_band,
	&band_2,
	2,
	DBIF_ALL
    },
    {
	am_bor,
	&bor_2,
	2,
	DBIF_ALL
    },
    {
	am_bxor,
	&bxor_2,
	2,
	DBIF_ALL
    },
    {
	am_bnot,
	&bnot_1,
	1,
	DBIF_ALL
    },
    {
	am_bsl,
	&bsl_2,
	2,
	DBIF_ALL
    },
    {
	am_bsr,
	&bsr_2,
	2,
	DBIF_ALL
    },
    {
	am_Gt,
	&sgt_2,
	2,
	DBIF_ALL
    },
    {
	am_Ge,
	&sge_2,
	2,
	DBIF_ALL
    },
    {
	am_Lt,
	&slt_2,
	2,
	DBIF_ALL
    },
    {
	am_Le,
	&sle_2,
	2,
	DBIF_ALL
    },
    {
	am_Eq,
	&seq_2,
	2,
	DBIF_ALL
    },
    {
	am_Eqeq,
	&seqeq_2,
	2,
	DBIF_ALL
    },
    {
	am_Neq,
	&sneq_2,
	2,
	DBIF_ALL
    },
    {
	am_Neqeq,
	&sneqeq_2,
	2,
	DBIF_ALL
    },
    {
	am_not,
	&not_1,
	1,
	DBIF_ALL
    },
    {
	am_xor,
	&xor_2,
	2,
	DBIF_ALL
    },
    {
	am_get_tcw,
	&db_get_trace_control_word_0,
	0,
	DBIF_TRACE_GUARD | DBIF_TRACE_BODY
    },
    {
	am_set_tcw,
	&db_set_trace_control_word_1,
	1,
	DBIF_TRACE_BODY
    },
    {
	am_set_tcw_fake,
	&db_set_trace_control_word_fake_1,
	1,
	DBIF_TRACE_BODY
    }
};

/*
** Exported
*/
Eterm db_am_eot;                /* Atom '$end_of_table' */

/*
** Forward decl's
*/


/*
** ... forwards for compiled matches
*/
/* Utility code */
static DMCGuardBif *dmc_lookup_bif(Eterm t, int arity);
#ifdef DMC_DEBUG
static Eterm dmc_lookup_bif_reversed(void *f);
#endif
static int cmp_uint(void *a, void *b);
static int cmp_guard_bif(void *a, void *b);
static int match_compact(ErlHeapFragment *expr, DMCErrInfo *err_info);
static Uint my_size_object(Eterm t);
static Eterm my_copy_struct(Eterm t, Eterm **hp, ErlOffHeap* off_heap);
static Binary *allocate_magic_binary(size_t size);


/* Guard compilation */
static void do_emit_constant(DMCContext *context, DMC_STACK_TYPE(Uint) *text,
			     Eterm t);
static DMCRet dmc_list(DMCContext *context,
		       DMCHeap *heap,
		       DMC_STACK_TYPE(Uint) *text,
		       Eterm t,
		       int *constant);
static DMCRet dmc_tuple(DMCContext *context,
		       DMCHeap *heap,
		       DMC_STACK_TYPE(Uint) *text,
		       Eterm t,
		       int *constant);
static DMCRet dmc_variable(DMCContext *context,
			   DMCHeap *heap,
			   DMC_STACK_TYPE(Uint) *text,
			   Eterm t,
			   int *constant);
static DMCRet dmc_fun(DMCContext *context,
		      DMCHeap *heap,
		      DMC_STACK_TYPE(Uint) *text,
		      Eterm t,
		      int *constant);
static DMCRet dmc_expr(DMCContext *context,
		       DMCHeap *heap,
		       DMC_STACK_TYPE(Uint) *text,
		       Eterm t,
		       int *constant);
static DMCRet compile_guard_expr(DMCContext *context,
				    DMCHeap *heap,
				    DMC_STACK_TYPE(Uint) *text,
				    Eterm t);
/* match expression subroutine */
static DMCRet dmc_one_term(DMCContext *context, 
			   DMCHeap *heap,
			   DMC_STACK_TYPE(Eterm) *stack,
			   DMC_STACK_TYPE(Uint) *text,
			   Eterm c);


#ifdef DMC_DEBUG
static int test_disassemble_next = 0;
static void db_match_dis(Binary *prog);
#define TRACE erts_fprintf(stderr,"Trace: %s:%d\n",__FILE__,__LINE__)
#define FENCE_PATTERN_SIZE 1
#define FENCE_PATTERN 0xDEADBEEFUL
#else
#define TRACE /* Nothing */
#define FENCE_PATTERN_SIZE 0
#endif
static void add_dmc_err(DMCErrInfo *err_info, 
			   char *str,
			   int variable,
			   Eterm term,
			   DMCErrorSeverity severity);

static Eterm dpm_array_to_list(Process *psp, Eterm *arr, int arity);

static Eterm match_spec_test(Process *p, Eterm against, Eterm spec, int trace);

static Eterm seq_trace_fake(Process *p, Eterm arg1);


/*
** Interface routines.
*/

/*
** Pseudo BIF:s to be callable from the PAM VM.
*/

BIF_RETTYPE db_get_trace_control_word_0(Process *p) 
{
    Uint32 tcw = (Uint32) erts_smp_atomic_read(&trace_control_word);
    BIF_RET(erts_make_integer((Uint) tcw, p));
}

BIF_RETTYPE db_set_trace_control_word_1(Process *p, Eterm new) 
{
    Uint val;
    Uint32 old_tcw;
    if (!term_to_Uint(new, &val))
	BIF_ERROR(p, BADARG);
    if (val != ((Uint32)val))
	BIF_ERROR(p, BADARG);
    
    old_tcw = (Uint32) erts_smp_atomic_xchg(&trace_control_word, (long) val);
    BIF_RET(erts_make_integer((Uint) old_tcw, p));
}

static Eterm db_set_trace_control_word_fake_1(Process *p, Eterm new) 
{
    Uint val;
    if (!term_to_Uint(new, &val))
	BIF_ERROR(p, BADARG);
    if (val != ((Uint32)val))
	BIF_ERROR(p, BADARG);
    BIF_RET(db_get_trace_control_word_0(p));
}

/*
** The API used by the tracer (declared in global.h):
*/

/*
** Matchexpr is a list of tuples containing match-code, i e:
**
** Matchexpr = [{Pattern, Guards, Body}, ...]
** Pattern = [ PatternExpr , ...]
** PatternExpr = Constant | PatternTuple | PatternList | Variable
** Constant = Any erlang term
** PatternTuple = { PatternExpr ... }
** PatternList = [ PatternExpr ]
** Variable = '$' ++ <number>
** Guards = [Guard ...]
** Guard = {GuardFunc, GuardExpr, ...}
** GuardExpr = BoundVariable | Guard | GuardList | GuardTuple | ConstExpr
** BoundVariable = Variable (existing in Pattern)  
** GuardList = [ GuardExpr , ... ]
** GuardTuple = {{ GuardExpr, ... }}
** ConstExpr = {const, Constant}
** GuardFunc = is_list | .... | element | ...
** Body = [ BodyExpr, ... ]
** BodyExpr = GuardExpr | { BodyFunc, GuardExpr, ... }
** BodyFunc = return_trace | seq_trace | trace | ...
** - or something like that...
*/


Eterm erts_match_set_get_source(Binary *mpsp)
{
    MatchProg *prog = Binary2MatchProg(mpsp);
    return prog->saved_program;
}

/* This one is for the tracing */
Binary *erts_match_set_compile(Process *p, Eterm matchexpr) {
    Binary *bin;
    Uint sz;
    Eterm *hp;
    
    bin = db_match_set_compile(p, matchexpr, DCOMP_TRACE);
    if (bin != NULL) {
	MatchProg *prog = Binary2MatchProg(bin);
	sz = size_object(matchexpr);
	prog->saved_program_buf = new_message_buffer(sz);
	hp = prog->saved_program_buf->mem;
	prog->saved_program = 
	    copy_struct(matchexpr, sz, &hp, 
			&(prog->saved_program_buf->off_heap));
    }
    return bin;
}

Binary *db_match_set_compile(Process *p, Eterm matchexpr, 
			     Uint flags) 
{
    Eterm l;
    Eterm t;
    Eterm l2;
    Eterm *tp;
    Eterm *hp;
    int n = 0;
    int num_heads;
    int i;
    Binary *mps = NULL;
    int compiled = 0;
    Eterm *matches,*guards, *bodies;
    Eterm *buff;
    Eterm sbuff[15];

    if (!is_list(matchexpr))
	return NULL;
    num_heads = 0;
    for (l = matchexpr; is_list(l); l = CDR(list_val(l)))
	++num_heads;

    if (l != NIL) /* proper list... */
	return NULL;

    if (num_heads > 5) {
	buff = erts_alloc(ERTS_ALC_T_DB_TMP,
			  sizeof(Eterm) * num_heads * 3);
    } else {
	buff = sbuff;
    }

    matches = buff;
    guards = buff + num_heads;
    bodies = buff + (num_heads * 2);

    i = 0;
    for (l = matchexpr; is_list(l); l = CDR(list_val(l))) {
	t = CAR(list_val(l));
	if (!is_tuple(t) || arityval((tp = tuple_val(t))[0]) != 3) {
	    goto error;
	}
	if (!(flags & DCOMP_TRACE) || (!is_list(tp[1]) && 
					!is_nil(tp[1]))) {
	    t = tp[1];
	} else {
	    /* This is when tracing, the parameter is a list,
	       that I convert to a tuple and that is matched 
	       against an array (strange, but gives the semantics
	       of matching against a parameter list) */
	    n = 0;
	    for (l2 = tp[1]; is_list(l2); l2 = CDR(list_val(l2))) {
		++n;
	    }
	    if (l2 != NIL) {
		goto error;
	    }
	    hp = HAlloc(p, n + 1);
	    t = make_tuple(hp);
	    *hp++ = make_arityval((Uint) n);
	    l2 = tp[1];
	    while (n--) {
		*hp++ = CAR(list_val(l2));
		l2 = CDR(list_val(l2));
	    }
	}
	matches[i] = t;
	guards[i] = tp[2];
	bodies[i] = tp[3];
	++i;
    }
    if ((mps = db_match_compile(matches, guards, bodies,
				num_heads,
				flags,
				NULL)) == NULL) {
	goto error;
    }
    compiled = 1;
    if (buff != sbuff) {
	erts_free(ERTS_ALC_T_DB_TMP, buff);
    }
    return mps;

error:
    if (compiled) {
	erts_match_set_free(mps);
    }
    if (buff != sbuff) {
	erts_free(ERTS_ALC_T_DB_TMP, buff);
    }
    return NULL;
}

/* This is used when tracing */
Eterm erts_match_set_lint(Process *p, Eterm matchexpr) {
    return db_match_set_lint(p, matchexpr, DCOMP_TRACE);
}

Eterm db_match_set_lint(Process *p, Eterm matchexpr, Uint flags) 
{
    Eterm l;
    Eterm t;
    Eterm l2;
    Eterm *tp;
    Eterm *hp;
    DMCErrInfo *err_info = db_new_dmc_err_info();
    Eterm ret;
    int n = 0;
    int num_heads;
    Binary *mp;
    Eterm *matches,*guards, *bodies;
    Eterm sbuff[15];
    Eterm *buff = sbuff;
    int i;

    if (!is_list(matchexpr)) {
	add_dmc_err(err_info, "Match programs are not in a list.", 
		    -1, 0UL, dmcError);
	goto done;
    }
    num_heads = 0;
    for (l = matchexpr; is_list(l); l = CDR(list_val(l)))
	++num_heads;

    if (l != NIL)  { /* proper list... */
	add_dmc_err(err_info, "Match programs are not in a proper "
		    "list.", 
		    -1, 0UL, dmcError);
	goto done;
    }

    if (num_heads > 5) {
	buff = erts_alloc(ERTS_ALC_T_DB_TMP,
			  sizeof(Eterm) * num_heads * 3);
    } 

    matches = buff;
    guards = buff + num_heads;
    bodies = buff + (num_heads * 2);

    i = 0;
    for (l = matchexpr; is_list(l); l = CDR(list_val(l))) {
	t = CAR(list_val(l));
	if (!is_tuple(t) || arityval((tp = tuple_val(t))[0]) != 3) {
	    add_dmc_err(err_info, 
			"Match program part is not a tuple of "
			"arity 3.", 
			-1, 0UL, dmcError);
	    goto done;
	}
	if (!(flags & DCOMP_TRACE) || (!is_list(tp[1]) && 
					!is_nil(tp[1]))) {
	    t = tp[1];
	} else {
	    n = 0;
	    for (l2 = tp[1]; is_list(l2); l2 = CDR(list_val(l2))) {
		++n;
	    }
	    if (l2 != NIL) {
		add_dmc_err(err_info, 
			    "Match expression part %T is not a "
			    "proper list.", 
			    -1, tp[1], dmcError);
		
		goto done;
	    }
	    hp = HAlloc(p, n + 1);
	    t = make_tuple(hp);
	    *hp++ = make_arityval((Uint) n);
	    l2 = tp[1];
	    while (n--) {
		*hp++ = CAR(list_val(l2));
		l2 = CDR(list_val(l2));
	    }
	}
	matches[i] = t;
	guards[i] = tp[2];
	bodies[i] = tp[3];
	++i;
    }
    mp = db_match_compile(matches, guards, bodies, num_heads,
			  flags, err_info); 
    if (mp != NULL) {
	erts_match_set_free(mp);
    }
done:
    ret = db_format_dmc_err_info(p, err_info);
    db_free_dmc_err_info(err_info);
    if (buff != sbuff) {
	erts_free(ERTS_ALC_T_DB_TMP, buff);
    }
    return ret;
}
    
Eterm erts_match_set_run(Process *p, Binary *mpsp, 
			 Eterm *args, int num_args, 
			 Uint32 *return_flags) 
{
    Eterm ret;

    ret = db_prog_match(p, mpsp,
			(Eterm) args, 
			num_args, return_flags);
#if defined(HARDDEBUG)
    if (is_non_value(ret)) {
	erts_fprintf(stderr, "Failed\n");
    } else {
	erts_fprintf(stderr, "Returning : %T\n", ret);
    }
#endif
    return ret;
    /* Returns 
     *   THE_NON_VALUE if no match
     *   am_false      if {message,false} has been called,
     *   am_true       if {message,_} has not been called or
     *                 if {message,true} has been called,
     *   Msg           if {message,Msg} has been called.
     */
}

/*
** API Used by other erl_db modules.
*/

void db_initialize_util(void){
    qsort(guard_tab, 
	  sizeof(guard_tab) / sizeof(DMCGuardBif), 
	  sizeof(DMCGuardBif), 
	  (int (*)(const void *, const void *)) &cmp_guard_bif);
    match_pseudo_process_init();
    erts_smp_atomic_init(&trace_control_word, 0);
}



Eterm db_getkey(int keypos, Eterm obj)
{
    if (is_tuple(obj)) {
	Eterm *tptr = tuple_val(obj);
	if (arityval(*tptr) >= keypos)
	    return *(tptr + keypos);
    }
    return THE_NON_VALUE;
}

/*
** Matching compiled (executed by "Pam" :-)
*/

/*
** The actual compiling of the match expression and the guards
*/
Binary *db_match_compile(Eterm *matchexpr, 
			 Eterm *guards, 
			 Eterm *body,
			 int num_progs,
			 Uint flags, 
			 DMCErrInfo *err_info)
{
    DMCHeap heap;
    DMC_STACK_TYPE(Eterm) stack;
    DMC_STACK_TYPE(Uint) text;
    DMC_STACK_TYPE(Uint) labels;
    DMCContext context;
    MatchProg *ret = NULL;
    Eterm t;
    Uint i;
    Uint num_iters;
    int structure_checked;
    DMCRet res;
    int current_try_label;
    Uint max_eheap_need;
    Binary *bp = NULL;
    unsigned clause_start;

    DMC_INIT_STACK(stack);
    DMC_INIT_STACK(text);
    DMC_INIT_STACK(labels);

    context.stack_need = context.stack_used = 0;
    context.save = context.copy = NULL;
    context.num_match = num_progs;
    context.matchexpr = matchexpr;
    context.guardexpr = guards;
    context.bodyexpr = body;
    context.eheap_need = 0;
    context.err_info = err_info;
    context.cflags = flags;
    context.labels = &labels;

    heap.size = DMC_DEFAULT_SIZE;
    heap.data = heap.def;

    /*
    ** Compile the match expression
    */
restart:
    heap.used = 0;
    max_eheap_need = 0;
    for (context.current_match = 0; 
	 context.current_match < num_progs; 
	 ++context.current_match) { /* This loop is long, 
				       too long */
	memset(heap.data, 0, heap.size * sizeof(*heap.data));
	t = context.matchexpr[context.current_match];
	context.stack_used = 0;
	context.eheap_need = 0;
	structure_checked = 0;
	if (context.current_match < num_progs - 1) {
	    DMC_PUSH(text,matchTryMeElse);
	    DMC_PUSH(text,current_try_label = 
		     DMC_STACK_NUM(*(context.labels)));
	    DMC_PUSH(*(context.labels), 0);
	} else {
	    current_try_label = -1;
	}
	clause_start = DMC_STACK_NUM(text); /* the "special" test needs it */
	DMC_PUSH(stack,NIL);
	for (;;) {
	    switch (t & _TAG_PRIMARY_MASK) {
	    case TAG_PRIMARY_BOXED:
		if (!BOXED_IS_TUPLE(t)) {
		    goto simple_term;
		}
		num_iters = arityval(*tuple_val(t));
		if (!structure_checked) { /* i.e. we did not 
					     pop it */
		    DMC_PUSH(text,matchTuple);
		    DMC_PUSH(text,num_iters);
		}
		structure_checked = 0;
		for (i = 1; i <= num_iters; ++i) {
		    if ((res = dmc_one_term(&context, 
					    &heap, 
					    &stack, 
					    &text, 
					    tuple_val(t)[i]))
			!= retOk) {
			if (res == retRestart) {
			    goto restart; /* restart the 
					     surrounding 
					     loop */
			} else goto error;
		    }	    
		}
		break;
	    case TAG_PRIMARY_LIST:
		if (!structure_checked) {
		    DMC_PUSH(text, matchList);
		}
		structure_checked = 0; /* Whatever it is, we did 
					  not pop it */
		if ((res = dmc_one_term(&context, &heap, &stack, 
					&text, CAR(list_val(t))))
		    != retOk) {
		    if (res == retRestart) {
			goto restart;
		    } else goto error;
		}	    
		t = CDR(list_val(t));
		continue;
	    default: /* Nil and non proper tail end's or 
			single terms as match 
			expressions */
	    simple_term:
		structure_checked = 0;
		if ((res = dmc_one_term(&context, &heap, &stack, 
					&text, t))
		    != retOk) {
		    if (res == retRestart) {
			goto restart;
		    } else goto error;
		}	    
		break;
	    }

	    /* The *program's* stack just *grows* while we are 
	       traversing one composite data structure, we can 
	       check the stack usage here */

	    if (context.stack_used > context.stack_need)
		context.stack_need = context.stack_used;

	    /* We are at the end of one composite data structure, 
	       pop sub structures and emit a matchPop instruction 
	       (or break) */
	    if ((t = DMC_POP(stack)) == NIL) {
		break;
	    } else {
		DMC_PUSH(text, matchPop);
		structure_checked = 1; /* 
					* Checked with matchPushT 
					* or matchPushL
					*/
		--(context.stack_used);
	    }
	}
    
	/* 
	** There is one single top variable in the match expression
	** iff the text is tho Uint's and the single instruction 
	** is 'matchBind' or it is only a skip.
	*/
	context.special = 
	    (DMC_STACK_NUM(text) == 2 + clause_start && 
	     DMC_PEEK(text,clause_start) == matchBind) || 
	    (DMC_STACK_NUM(text) == 1 + clause_start && 
	     DMC_PEEK(text, clause_start) == matchSkip);

	if (flags & DCOMP_TRACE) {
	    if (context.special) {
		if (DMC_PEEK(text, clause_start) == matchBind) {
		    DMC_POKE(text, clause_start, matchArrayBind);
		} 
	    } else {
		ASSERT(DMC_STACK_NUM(text) >= 1);
		if (DMC_PEEK(text, clause_start) != matchTuple) {
		    /* If it isn't "special" and the argument is 
		       not a tuple, the expression is not valid 
		       when matching an array*/
		    if (context.err_info) {
			add_dmc_err(context.err_info, 
				    "Match head is invalid in "
				    "this context.", 
				    -1, 0UL,
				    dmcError);
		    }
		    goto error;
		}
		DMC_POKE(text, clause_start, matchArray);
	    }
	}


	/*
	** ... and the guards
	*/
	context.is_guard = 1;
	if (compile_guard_expr
	    (&context,
	     &heap,
	     &text,
	     context.guardexpr[context.current_match]) != retOk) 
	    goto error;
	context.is_guard = 0;
	if ((context.cflags & DCOMP_TABLE) && 
	    !is_list(context.bodyexpr[context.current_match])) {
	    if (context.err_info) {
		add_dmc_err(context.err_info, 
			    "Body clause does not return "
			    "anything.", -1, 0UL,
			    dmcError);
	    }
	    goto error;
	}
	if (compile_guard_expr
	    (&context,
	     &heap,
	     &text,
	     context.bodyexpr[context.current_match]) != retOk) 
	    goto error;

	/*
	 * The compilation does not bail out when error information
	 * is requested, so we need to detect that here...
	 */
	if (context.err_info != NULL && 
	    (context.err_info)->error_added) {
	    goto error;
	}


	/* If the matchprogram comes here, the match is 
	   successfull */
	DMC_PUSH(text,matchHalt);
	/* Fill in try-me-else label if there is one. */ 
	if (current_try_label >= 0) {
	    DMC_POKE(*(context.labels), current_try_label, 
		     DMC_STACK_NUM(text));
	}
	/* So, how much eheap did this part of the match program need? */
	if (context.eheap_need > max_eheap_need) {
	    max_eheap_need = context.eheap_need;
	}
    } /* for (context.current_match = 0 ...) */


    /*
    ** Done compiling
    ** Allocate enough space for the program,
    ** heap size is in 'heap_used', stack size is in 'stack_need'
    ** and text size is simply DMC_STACK_NUM(text).
    ** The "program memory" is allocated like this:
    ** text ----> +-------------+
    **            |             |
    **              ..........
    ** labels --> +             + (labels are offset's from text)
    **              ..........
    **            +-------------+
    **
    **  The heap-eheap-stack block of a MatchProg is nowadays allocated
    **  when the match program is run (see db_prog_match()).
    **
    ** heap ----> +-------------+
    **              ..........
    ** eheap ---> +             +
    **              ..........
    ** stack ---> +             +
    **              ..........
    **            +-------------+
    ** The stack is expected to grow towards *higher* adresses.
    ** A special case is when the match expression is a single binding 
    ** (i.e '$1'), then the field single_variable is set to 1.
    */
    bp = allocate_magic_binary
	((sizeof(MatchProg) - sizeof(Uint)) +
	 (DMC_STACK_NUM(text) * sizeof(Uint)) +
	 (DMC_STACK_NUM(labels) * sizeof(Uint)));
    ret = Binary2MatchProg(bp);
    ret->saved_program_buf = NULL;
    ret->saved_program = NIL;
    ret->term_save = context.save;
    ret->num_bindings = heap.used;
    ret->labels = (Uint *) (ret->text + DMC_STACK_NUM(text));
    ret->single_variable = context.special;
#ifdef DMC_DEBUG
    ret->label_size = DMC_STACK_NUM(labels);
#endif
    sys_memcpy(ret->text, DMC_STACK_DATA(text), 
	       DMC_STACK_NUM(text) * sizeof(Uint));
    sys_memcpy(ret->labels, DMC_STACK_DATA(labels), 
	       DMC_STACK_NUM(labels) * sizeof(Uint));
    ret->heap_size = ((heap.used * sizeof(Eterm)) +
		      (max_eheap_need * sizeof(Eterm)) +
		      (context.stack_need * sizeof(Eterm *)) +
		      (3 * (FENCE_PATTERN_SIZE * sizeof(Eterm *))));
    ret->eheap_offset = heap.used + FENCE_PATTERN_SIZE;
    ret->stack_offset = ret->eheap_offset + max_eheap_need + FENCE_PATTERN_SIZE;
    /* 
     * Fall through to cleanup code, but context.save should not be free'd
     */  
    context.save = NULL;
error: /* Here is were we land when compilation failed. */
    while (context.save != NULL) {
	ErlHeapFragment *ll = context.save->next;
	free_message_buffer(context.save);
	context.save = ll;
    }
    DMC_FREE(stack);
    DMC_FREE(text);
    DMC_FREE(labels);
    if (context.copy != NULL) 
	free_message_buffer(context.copy);
    if (heap.data != heap.def)
	erts_free(ERTS_ALC_T_DB_MS_CMPL_HEAP, (void *) heap.data);
    return bp;
}

/*
** Free a match program (in a binary)
*/
void erts_match_set_free(Binary *bprog)
{
    MatchProg *prog;
    ErlHeapFragment *tmp, *ll;
    if (bprog == NULL)
	return;
    prog = Binary2MatchProg(bprog);
    tmp = prog->term_save; 
    while (tmp != NULL) {
	ll = tmp->next;
	free_message_buffer(tmp);
	tmp = ll;
    }
    if (prog->saved_program_buf != NULL)
	free_message_buffer(prog->saved_program_buf);
    erts_bin_free(bprog);
}

void
erts_match_prog_foreach_offheap(Binary *bprog,
				void (*func)(ErlOffHeap *, void *),
				void *arg)
{
    MatchProg *prog;
    ErlHeapFragment *tmp;
    if (bprog == NULL)
	return;
    prog = Binary2MatchProg(bprog);
    tmp = prog->term_save; 
    while (tmp) {
	(*func)(&(tmp->off_heap), arg);
	tmp = tmp->next;
    }
    if (prog->saved_program_buf)
	(*func)(&(prog->saved_program_buf->off_heap), arg);
}

/*
** This is not the most efficient way to do it, but it's a rare
** and not especially nice case when this is used.
*/
static Eterm dpm_array_to_list(Process *psp, Eterm *arr, int arity)
{
    Eterm *hp = HAlloc(psp, arity * 2);
    Eterm ret = NIL;
    while (--arity >= 0) {
	ret = CONS(hp, arr[arity], ret);
	hp += 2;
    }
    return ret;
}
/*
** Execution of the match program, this is Pam.
** May return THE_NON_VALUE, which is a bailout.
** the para meter 'arity' is only used if 'term' is actually an array,
** i.e. 'DCOMP_TRACE' was specified 
*/
Eterm db_prog_match(Process *c_p, Binary *bprog, Eterm term, 
		    int arity,
		    Uint32 *return_flags)
{
    MatchProg *prog = Binary2MatchProg(bprog);
    Eterm *ep;
    Eterm *tp;
    Eterm t;
    Eterm **sp;
    Eterm *esp;
    Eterm *hp;
    Uint *pc = prog->text;
    Eterm *ehp;
    Eterm ret;
    Uint n = 0; /* To avoid warning. */
    int i;
    unsigned do_catch;
    ErtsMatchPseudoProcess *mpsp;
    Process *psp;
    Process *tmpp;
    Process *current_scheduled;
    ErtsSchedulerData *esdp;
    Eterm (*bif)(Process*, ...);
    int fail_label;
    int atomic_trace;
#ifdef DMC_DEBUG
    unsigned long *heap_fence;
    unsigned long *eheap_fence;
    unsigned long *stack_fence;
    Uint save_op;
#endif /* DMC_DEBUG */

    mpsp = get_match_pseudo_process(c_p, prog->heap_size);
    psp = &mpsp->process;

    /* We need to lure the scheduler into believing in the pseudo process, 
       because of floating point exceptions. Do *after* mpsp is set!!! */

    esdp = ERTS_GET_SCHEDULER_DATA_FROM_PROC(c_p);
    ASSERT(esdp != NULL);
    current_scheduled = esdp->current_process;
    esdp->current_process = psp;
    /* SMP: psp->scheduler_data is set by get_match_pseudo_process */

    atomic_trace = 0;
#define BEGIN_ATOMIC_TRACE(p)                               \
    do {                                                    \
	if (! atomic_trace) {                               \
	    erts_smp_proc_unlock((p), ERTS_PROC_LOCK_MAIN); \
	    erts_smp_block_system(0);                       \
            atomic_trace = !0;                              \
	}                                                   \
    } while (0)
#define END_ATOMIC_TRACE(p)                               \
    do {                                                  \
	if (atomic_trace) {                               \
            erts_smp_release_system();                    \
            erts_smp_proc_lock((p), ERTS_PROC_LOCK_MAIN); \
            atomic_trace = 0;                             \
	}                                                 \
    } while (0)

#ifdef DMC_DEBUG
    save_op = 0;
    heap_fence =  (unsigned long *) mpsp->heap + prog->eheap_offset - 1;
    eheap_fence = (unsigned long *) mpsp->heap + prog->stack_offset - 1;
    stack_fence = (unsigned long *) mpsp->heap + prog->heap_size - 1;
    *heap_fence = FENCE_PATTERN;
    *eheap_fence = FENCE_PATTERN;
    *stack_fence = FENCE_PATTERN;
#endif /* DMC_DEBUG */

#ifdef HARDDEBUG
#define FAIL() {erts_printf("Fail line %d\n",__LINE__); goto fail;}
#else
#define FAIL() goto fail
#endif
#define FAIL_TERM am_EXIT /* The term to set as return when bif fails and
			     do_catch != 0 */

    *return_flags = 0U;

restart:
    ep = &term;
    esp = mpsp->heap + prog->stack_offset;
    sp = (Eterm **) esp;
    hp = mpsp->heap;
    ehp = mpsp->heap + prog->eheap_offset;
    ret = am_true;
    do_catch = 0;
    fail_label = -1;

    for (;;) {
#ifdef DMC_DEBUG
	if (*heap_fence != FENCE_PATTERN) {
	    erl_exit(1, "Heap fence overwritten in db_prog_match after op "
		     "0x%08x, overwritten with 0x%08x.", save_op, *heap_fence);
	}
	if (*eheap_fence != FENCE_PATTERN) {
	    erl_exit(1, "Eheap fence overwritten in db_prog_match after op "
		     "0x%08x, overwritten with 0x%08x.", save_op, 
		     *eheap_fence);
	}
	if (*stack_fence != FENCE_PATTERN) {
	    erl_exit(1, "Stack fence overwritten in db_prog_match after op "
		     "0x%08x, overwritten with 0x%08x.", save_op, 
		     *stack_fence);
	}
	save_op = *pc;
#endif
	switch (*pc++) {
	case matchTryMeElse:
	    n = *pc++;
	    fail_label = prog->labels[n];
	    break;
	case matchArray: /* only when DCOMP_TRACE, is always first
			    instruction. */
	    n = *pc++;
	    if ((int) n != arity)
		FAIL();
	    ep = (Eterm *) *ep;
	    break;
	case matchArrayBind: /* When the array size is unknown. */
	    n = *pc++;
	    hp[n] = dpm_array_to_list(psp, (Eterm *) term, arity);
	    break;
	case matchTuple: /* *ep is a tuple of arity n */
	    if (!is_tuple(*ep))
		FAIL();
	    ep = tuple_val(*ep);
	    n = *pc++;
	    if (arityval(*ep) != n)
		FAIL();
	    ++ep;
	    break;
	case matchPushT: /* *ep is a tuple of arity n, 
			    push ptr to first element */
	    if (!is_tuple(*ep))
		FAIL();
	    tp = tuple_val(*ep);
	    n = *pc++;
	    if (arityval(*tp) != n)
		FAIL();
	    *sp++ = tp + 1;
	    ++ep;
	    break;
	case matchList:
	    if (!is_list(*ep))
		FAIL();
	    ep = list_val(*ep);
	    break;
	case matchPushL:
	    if (!is_list(*ep))
		FAIL();
	    *sp++ = list_val(*ep);
	    ++ep;
	    break;
	case matchPop:
	    ep = *(--sp);
	    break;
	case matchBind:
	    n = *pc++;
	    hp[n] = *ep++;
	    break;
	case matchCmp:
	    n = *pc++;
	    if (!eq(hp[n],*ep))
		FAIL();
	    ++ep;
	    break;
	case matchEqBin:
	    t = (Eterm) *pc++;
	    if (!eq(*ep,t))
		FAIL();
	    ++ep;
	    break;
	case matchEqFloat:
	    if (!is_float(*ep))
		FAIL();
	    if (memcmp(float_val(*ep) + 1, pc, sizeof(double)))
		FAIL();
	    pc += 2;
	    ++ep;
	    break;
	case matchEqRef:
	    if (!is_ref(*ep))
		FAIL();
	    if (!eq(*ep, make_internal_ref(pc)))
		FAIL();
	    i = thing_arityval(*pc);
	    pc += i+1;
	    ++ep;
	    break;
	case matchEqBig:
	    if (!is_big(*ep))
		FAIL();
	    tp = big_val(*ep);
	    if (*tp != *pc)
		FAIL();
	    i = BIG_ARITY(pc);
	    while(i--)
		if (*++tp != *++pc)
		    FAIL();
	    ++pc;
	    ++ep;
	    break;
	case matchEq:
	    t = (Eterm) *pc++; 
	    if (t != *ep++)
		FAIL();
	    break;
	case matchSkip:
	    ++ep;
	    break;
	/* 
	 * Here comes guard instructions 
	 */
	case matchPushC: /* Push constant */
	    *esp++ = *pc++;
	    break;
	case matchConsA:
	    ehp[1] = *--esp;
	    ehp[0] = esp[-1];
	    esp[-1] = make_list(ehp);
	    ehp += 2;
	    break;
	case matchConsB:
	    ehp[0] = *--esp;
	    ehp[1] = esp[-1];
	    esp[-1] = make_list(ehp);
	    ehp += 2;
	    break;
	case matchMkTuple:
	    n = *pc++;
	    t = make_tuple(ehp);
	    *ehp++ = make_arityval(n);
	    while (n--) {
		*ehp++ = *--esp;
	    }
	    *esp++ = t;
	    break;
	case matchCall0:
	    bif = (Eterm (*)(Process*, ...)) *pc++;
	    t = (*bif)(psp);
	    if (is_non_value(t)) {
		if (do_catch)
		    t = FAIL_TERM;
		else
		    FAIL();
	    }
	    *esp++ = t;
	    break;
	case matchCall1:
	    bif = (Eterm (*)(Process*, ...)) *pc++;
	    t = (*bif)(psp, esp[-1]);
	    if (is_non_value(t)) {
		if (do_catch)
		    t = FAIL_TERM;
		else
		    FAIL();
	    }
	    esp[-1] = t;
	    break;
	case matchCall2:
	    bif = (Eterm (*)(Process*, ...)) *pc++;
	    t = (*bif)(psp, esp[-1], esp[-2]);
	    if (is_non_value(t)) {
		if (do_catch)
		    t = FAIL_TERM;
		else
		    FAIL();
	    }
	    --esp;
	    esp[-1] = t;
	    break;
	case matchCall3:
	    bif = (Eterm (*)(Process*, ...)) *pc++;
	    t = (*bif)(psp, esp[-1], esp[-2], esp[-3]);
	    if (is_non_value(t)) {
		if (do_catch)
		    t = FAIL_TERM;
		else
		    FAIL();
	    }
	    esp -= 2;
	    esp[-1] = t;
	    break;
	case matchPushV:
	    *esp++ = hp[*pc++];
	    break;
	case matchPushExpr:
	    *esp++ = term;
	    break;
	case matchPushArrayAsList:
	    n = arity; /* Only happens when 'term' is an array */
	    tp = (Eterm *) term;
	    *esp++  = make_list(ehp);
	    while (n--) {
		*ehp++ = *tp++;
		*ehp = make_list(ehp + 1);
		ehp++; /* As pointed out by Mikael Pettersson the expression
			  (*ehp++ = make_list(ehp + 1)) that I previously
			  had written here has undefined behaviour. */
	    }
	    ehp[-1] = NIL;
	    break;
	case matchPushArrayAsListU:
	    /* This instruction is NOT efficient. */
	    *esp++  = dpm_array_to_list(psp, (Eterm *) term, arity); 
	    break;
	case matchTrue:
	    if (*--esp != am_true)
		FAIL();
	    break;
	case matchOr:
	    n = *pc++;
	    t = am_false;
	    while (n--) {
		if (*--esp == am_true) {
		    t = am_true;
		} else if (*esp != am_false) {
		    esp -= n;
		    if (do_catch) {
			t = FAIL_TERM;
			break;
		    } else {
			FAIL();
		    }
		}
	    }
	    *esp++ = t;
	    break;
	case matchAnd:
	    n = *pc++;
	    t = am_true;
	    while (n--) {
		if (*--esp == am_false) {
		    t = am_false;
		} else if (*esp != am_true) {
		    esp -= n;
		    if (do_catch) {
			t = FAIL_TERM;
			break;
		    } else {
			FAIL();
		    }
		}
	    }
	    *esp++ = t;
	    break;
	case matchOrElse:
	    n = *pc++;
	    if (*--esp == am_true) {
		++esp;
		pc = (prog->text) + prog->labels[n];
	    } else if (*esp != am_false) {
		if (do_catch) {
		    *esp++ = FAIL_TERM;
		    pc = (prog->text) + prog->labels[n];;
		} else {
		    FAIL();
		}
	    }
	    break;
	case matchAndThen:
	    n = *pc++;
	    if (*--esp == am_false) {
		esp++;
		pc = (prog->text) + prog->labels[n];
	    } else if (*esp != am_true) {
		if (do_catch) {
		    *esp++ = FAIL_TERM;
		    pc = (prog->text) + prog->labels[n];;
		} else {
		    FAIL();
		}
	    }
	    break;
	case matchSelf:
	    *esp++ = c_p->id;
	    break;
	case matchWaste:
	    --esp;
	    break;
	case matchReturn:
	    ret = *--esp;
	    break;
	case matchProcessDump: {
	    erts_dsprintf_buf_t *dsbufp = erts_create_tmp_dsbuf(0);
	    print_process_info(ERTS_PRINT_DSBUF, (void *) dsbufp, c_p);
	    *esp++ = new_binary(psp, (byte *)dsbufp->str, (int)dsbufp->str_len);
	    erts_destroy_tmp_dsbuf(dsbufp);
	    break;
	}
	case matchDisplay: /* Debugging, not for production! */
	    erts_printf("%T\n", esp[-1]);
	    esp[-1] = am_true;
	    break;
	case matchSetReturnTrace:
	    *return_flags |= MATCH_SET_RETURN_TRACE;
	    *esp++ = am_true;
	    break;
	case matchSetExceptionTrace:
	    *return_flags |= MATCH_SET_EXCEPTION_TRACE;
	    *esp++ = am_true;
	    break;
	case matchIsSeqTrace:
	    if (SEQ_TRACE_TOKEN(c_p) != NIL)
		*esp++ = am_true;
	    else
		*esp++ = am_false;
	    break;
	case matchSetSeqToken:
	    t = erts_seq_trace(c_p, esp[-1], esp[-2], 0);
	    if (is_non_value(t)) {
		esp[-2] = FAIL_TERM;
	    } else {
		esp[-2] = t;
	    }
	    --esp;
	    break;
	case matchSetSeqTokenFake:
	    t = seq_trace_fake(c_p, esp[-1]);
	    if (is_non_value(t)) {
		esp[-2] = FAIL_TERM;
	    } else {
		esp[-2] = t;
	    }
	    --esp;
	    break;
	case matchGetSeqToken:
	    if (SEQ_TRACE_TOKEN(c_p) == NIL) 
		*esp++ = NIL;
	    else {
 		*esp++ = make_tuple(ehp);
 		ehp[0] = make_arityval(5);
 		ehp[1] = SEQ_TRACE_TOKEN_FLAGS(c_p);
 		ehp[2] = SEQ_TRACE_TOKEN_LABEL(c_p);
 		ehp[3] = SEQ_TRACE_TOKEN_SERIAL(c_p);
 		ehp[4] = SEQ_TRACE_TOKEN_SENDER(c_p);
 		ehp[5] = SEQ_TRACE_TOKEN_LASTCNT(c_p);
		ASSERT(SEQ_TRACE_TOKEN_ARITY(c_p) == 5);
		ASSERT(is_immed(ehp[1]));
		ASSERT(is_immed(ehp[2]));
		ASSERT(is_immed(ehp[3]));
		ASSERT(is_immed(ehp[5]));
		if(!is_immed(ehp[4])) {
		    Eterm *sender = &ehp[4];
		    ehp += 6;
		    *sender = copy_struct(*sender,
					  size_object(*sender),
					  &ehp,
					  &MSO(psp));
		}
		else
		    ehp += 6;

	    } 
	    break;
	case matchEnableTrace:
	    if ( (n = erts_trace_flag2bit(esp[-1]))) {
		BEGIN_ATOMIC_TRACE(c_p);
		set_tracee_flags(c_p, c_p->tracer_proc, 0, n);
		esp[-1] = am_true;
	    } else {
		esp[-1] = FAIL_TERM;
	    }
	    break;
	case matchEnableTrace2:
	    n = erts_trace_flag2bit((--esp)[-1]);
	    esp[-1] = FAIL_TERM;
	    if (n) {
		BEGIN_ATOMIC_TRACE(c_p);
		if ( (tmpp = get_proc(c_p, 0, esp[0], 0))) {
		    /* Always take over the tracer of the current process */
		    set_tracee_flags(tmpp, c_p->tracer_proc, 0, n);
		    esp[-1] = am_true;
		}
	    }
	    break;
	case matchDisableTrace:
	    if ( (n = erts_trace_flag2bit(esp[-1]))) {
		BEGIN_ATOMIC_TRACE(c_p);
		set_tracee_flags(c_p, c_p->tracer_proc, n, 0);
		esp[-1] = am_true;
	    } else {
		esp[-1] = FAIL_TERM;
	    }
	    break;
	case matchDisableTrace2:
	    n = erts_trace_flag2bit((--esp)[-1]);
	    esp[-1] = FAIL_TERM;
	    if (n) {
		BEGIN_ATOMIC_TRACE(c_p);
		if ( (tmpp = get_proc(c_p, 0, esp[0], 0))) {
		    /* Always take over the tracer of the current process */
		    set_tracee_flags(tmpp, c_p->tracer_proc, n, 0);
		    esp[-1] = am_true;
		}
	    }
	    break;
 	case matchCaller:
 	    if (!(c_p->cp) || !(hp = find_function_from_pc(c_p->cp))) {
 		*esp++ = am_undefined;
 	    } else {
 		*esp++ = make_tuple(ehp);
 		ehp[0] = make_arityval(3);
 		ehp[1] = hp[0];
 		ehp[2] = hp[1];
 		ehp[3] = make_small(hp[2]);
 		ehp += 4;
 	    }
 	    break;
	case matchSilent:
	    --esp;
	    if (*esp == am_true) {
		erts_smp_proc_lock(c_p, ERTS_PROC_LOCKS_ALL_MINOR);
		c_p->trace_flags |= F_TRACE_SILENT;
		erts_smp_proc_unlock(c_p, ERTS_PROC_LOCKS_ALL_MINOR);
	    }
	    else if (*esp == am_false) {
		erts_smp_proc_lock(c_p, ERTS_PROC_LOCKS_ALL_MINOR);
		c_p->trace_flags &= ~F_TRACE_SILENT;
		erts_smp_proc_unlock(c_p, ERTS_PROC_LOCKS_ALL_MINOR);
	    }
	    break;
	case matchTrace2:
	    {
		/*    disable         enable                                */
		Uint  d_flags  = 0,   e_flags  = 0;  /* process trace flags */
		Eterm tracer = c_p->tracer_proc;
		/* XXX Atomicity note: Not fully atomic. Default tracer
		 * is sampled from current process but applied to
		 * tracee and tracer later after releasing main
		 * locks on current process, so c_p->tracer_proc
		 * may actually have changed when tracee and tracer
		 * gets updated. I do not think nobody will notice.
		 * It is just the default value that is not fully atomic.
		 * and the real argument settable from match spec
		 * {trace,[],[{{tracer,Tracer}}]} is much, much older.
		 */
		int   cputs = 0;
		
		if (! erts_trace_flags(esp[-1], &d_flags, &tracer, &cputs) ||
		    ! erts_trace_flags(esp[-2], &e_flags, &tracer, &cputs) ||
		    cputs ) {
		    (--esp)[-1] = FAIL_TERM;
		    break;
		}
		erts_smp_proc_lock(c_p, ERTS_PROC_LOCKS_ALL_MINOR);
		(--esp)[-1] = set_match_trace(c_p, FAIL_TERM, tracer,
					      d_flags, e_flags);
		erts_smp_proc_unlock(c_p, ERTS_PROC_LOCKS_ALL_MINOR);
	    }
	    break;
	case matchTrace3:
	    {
		/*    disable         enable                                */
		Uint  d_flags  = 0,   e_flags  = 0;  /* process trace flags */
		Eterm tracer = c_p->tracer_proc;
		/* XXX Atomicity note. Not fully atomic. See above. 
		 * Above it could possibly be solved, but not here.
		 */
		int   cputs = 0;
		Eterm tracee = (--esp)[0];
		
		if (! erts_trace_flags(esp[-1], &d_flags, &tracer, &cputs) ||
		    ! erts_trace_flags(esp[-2], &e_flags, &tracer, &cputs) ||
		    cputs ||
		    ! (tmpp = get_proc(c_p, ERTS_PROC_LOCK_MAIN, 
				       tracee, ERTS_PROC_LOCKS_ALL))) {
		    (--esp)[-1] = FAIL_TERM;
		    break;
		}
		if (tmpp == c_p) {
		    (--esp)[-1] = set_match_trace(c_p, FAIL_TERM, tracer,
						  d_flags, e_flags);
		    erts_smp_proc_unlock(c_p, ERTS_PROC_LOCKS_ALL_MINOR);
		} else {
		    erts_smp_proc_unlock(c_p, ERTS_PROC_LOCK_MAIN);
		    (--esp)[-1] = set_match_trace(tmpp, FAIL_TERM, tracer,
						  d_flags, e_flags);
		    erts_smp_proc_unlock(tmpp, ERTS_PROC_LOCKS_ALL);
		    erts_smp_proc_lock(c_p, ERTS_PROC_LOCK_MAIN);
		}
	    }
	    break;
	case matchCatch:
	    do_catch = 1;
	    break;
	case matchHalt:
	    goto success;
	default:
	    erl_exit(1, "Internal error: unexpected opcode in match program.");
	}
    }
fail:
    *return_flags = 0U;
    if (fail_label >= 0) { /* We failed during a "TryMeElse", 
			      lets restart, with the next match 
			      program */
	pc = (prog->text) + fail_label;
	cleanup_match_pseudo_process(mpsp, 1);
	goto restart;
    }
    ret = THE_NON_VALUE;
success:

#ifdef DMC_DEBUG
    if (*heap_fence != FENCE_PATTERN) {
	erl_exit(1, "Heap fence overwritten in db_prog_match after op "
		 "0x%08x, overwritten with 0x%08x.", save_op, *heap_fence);
    }
    if (*eheap_fence != FENCE_PATTERN) {
	erl_exit(1, "Eheap fence overwritten in db_prog_match after op "
		 "0x%08x, overwritten with 0x%08x.", save_op, 
		 *eheap_fence);
    }
    if (*stack_fence != FENCE_PATTERN) {
	erl_exit(1, "Stack fence overwritten in db_prog_match after op "
		 "0x%08x, overwritten with 0x%08x.", save_op, 
		 *stack_fence);
    }
#endif

    esdp->current_process = current_scheduled;

    END_ATOMIC_TRACE(c_p);
    return ret;
#undef FAIL
#undef FAIL_TERM
#undef BEGIN_ATOMIC_TRACE
#undef END_ATOMIC_TRACE
}


/*
 * Convert a match program to a "magic" binary to return up to erlang
 */
Eterm db_make_mp_binary(Process *p, Binary *mp, Eterm **hpp) {
    ProcBin *pb;
    erts_refc_inc(&mp->refc, 1);
    pb = (ProcBin *) *hpp;
    *hpp += PROC_BIN_SIZE;
    pb->thing_word = HEADER_PROC_BIN;
    pb->size = 0;
    pb->next = MSO(p).mso;
    MSO(p).mso = pb;
    pb->val = mp;
    pb->bytes = (byte*) mp->orig_bytes;
    return make_binary(pb);
}

DMCErrInfo *db_new_dmc_err_info(void) 
{
    DMCErrInfo *ret = erts_alloc(ERTS_ALC_T_DB_DMC_ERR_INFO,
				 sizeof(DMCErrInfo));
    ret->var_trans = NULL;
    ret->num_trans = 0;
    ret->error_added = 0;
    ret->first = NULL;
    return ret;
}

Eterm db_format_dmc_err_info(Process *p, DMCErrInfo *ei)
{
    int ll,sl;
    int vnum;
    DMCError *tmp;
    Eterm *lhp, *shp;
    Eterm ret = NIL, tpl, sev;
    char buff[DMC_ERR_STR_LEN + 20 /* for the number */];

    ll = 0;
    for (tmp = ei->first; tmp != NULL; tmp = tmp->next)
	++ll;
    lhp = HAlloc(p, ll * (2 /*cons cell*/ + 3 /*tuple of arity 2*/));
    for (tmp = ei->first; tmp != NULL; tmp = tmp->next) {
	if (tmp->variable >= 0 && 
	    tmp->variable < ei->num_trans &&
	    ei->var_trans != NULL) {
	    vnum = (int) ei->var_trans[tmp->variable];
	} else {
	    vnum = tmp->variable;
	}
	if (vnum >= 0)
	    sprintf(buff,tmp->error_string, vnum);
	else
	    strcpy(buff,tmp->error_string);
	sl = strlen(buff);
	shp = HAlloc(p, sl * 2);
	sev = (tmp->severity == dmcWarning) ? 
	    am_atom_put("warning",7) :
	    am_error;
	tpl = TUPLE2(lhp, sev, buf_to_intlist(&shp, buff, sl, NIL));
	lhp += 3;
	ret = CONS(lhp, tpl, ret);
	lhp += 2;
    }
    return ret;
}

void db_free_dmc_err_info(DMCErrInfo *ei){
    while (ei->first != NULL) {
	DMCError *ll = ei->first->next;
	erts_free(ERTS_ALC_T_DB_DMC_ERROR, ei->first);
	ei->first = ll;
    }
    if (ei->var_trans)
	erts_free(ERTS_ALC_T_DB_TRANS_TAB, ei->var_trans);
    erts_free(ERTS_ALC_T_DB_DMC_ERR_INFO, ei);
}

#define FIX_BIG_SIZE 16
#define MAX_NEED(x,y) (((x)>(y)) ? (x) : (y))

static Eterm  big_tmp[2];
static Eterm  db_big_buf[FIX_BIG_SIZE];

static Eterm add_counter(Eterm counter, Eterm incr)
{
    Eterm res;
    Sint ires;
    Eterm arg1;
    Eterm arg2;
    Uint sz1;
    Uint sz2;
    Uint need;
    Eterm *ptr;
    int i;

    if (is_small(counter) && is_small(incr)) {
	ires = signed_val(counter) + signed_val(incr);
	if (IS_SSMALL(ires))
	    return make_small(ires);
	else
	    return small_to_big(ires, db_big_buf);
    }
    else {
	switch(i = NUMBER_CODE(counter, incr)) {
	case SMALL_BIG:
	    arg1 = small_to_big(signed_val(counter), big_tmp);
	    arg2 = incr;
	    break;
	case BIG_SMALL:
	    arg1 = counter;
	    arg2 = small_to_big(signed_val(incr), big_tmp);
	    break;
	case BIG_BIG:
	    arg1 = incr;
	    arg2 = counter;
	    break;
	default:
	    return THE_NON_VALUE;
	}
	sz1 = big_size(arg1);
	sz2 = big_size(arg2);
	sz1 = MAX_NEED(sz1,sz2)+1;
	need = BIG_NEED_SIZE(sz1);
	if (need <= FIX_BIG_SIZE)
	    ptr = db_big_buf;
	else {
	    ptr = (Eterm *) erts_alloc_fnf(ERTS_ALC_T_DB_TMP,
					   need*sizeof(Eterm));
	    if (!ptr)
		return NIL;  /* system limit */
	}
	res = big_plus(arg1, arg2, ptr);
	if (is_small(res) || is_nil(res)) {
	    if (ptr != db_big_buf)
		erts_free(ERTS_ALC_T_DB_TMP, (void *) ptr);
	}
	return res;
    }
}

/*
** The actual update of a counter, a lot of parameters are needed:
** p: The calling process (BIF_P), 
** bp: A pointer to the pointer to the object to be updated (extra 
** indirection for the reallocation), this pointer is only used to
** pass information to the realloc function.
** tpl: A pointer to the tuple in the DbTerm.
** keypos: The key position in the DbTerm.
** realloc_fun: A function that does the reallocation, it takes 
** bp, new size, new_value and keypos as parameter. 
** ret: pointer to where the result is put.
** Returns normal DB error code.
*/

int db_do_update_counter(Process *p,
			 DbTableCommon *tb, void *bp /* XDbTerm **bp */, 
			 Eterm *tpl, int counterpos,
			 int (*realloc_fun)(DbTableCommon *,
					    void *,
					    Uint,
					    Eterm,
					    int),
			 Eterm incr,
			 int warp,
			 Eterm *ret)
{
    Eterm counter;
    Eterm *counterp;
    Eterm res; /* In register? */


    if (arityval(*tpl) < counterpos || !(is_small(tpl[counterpos]) ||
					 is_big(tpl[counterpos])))
	return DB_ERROR_BADITEM;

    counterp = tpl + counterpos;
    counter = *counterp;

    if (warp) {
	if (is_small(incr)) {
	    res = incr;
	} else {
	    /* copy to buffer */
	    Eterm *tmp;
	    Eterm *p = big_val(incr);
	    Uint psz = BIG_ARITY(p)+1;
	    if (psz > FIX_BIG_SIZE) {
		tmp = db_big_buf;
	    } else {
		tmp = (Eterm *) erts_alloc_fnf(ERTS_ALC_T_DB_TMP,
					       psz*sizeof(Eterm));
		if (!tmp)
		    return DB_ERROR_SYSRES;
	    }
	    sys_memcpy(tmp, p, psz*sizeof(Eterm));
	    res = make_big(tmp);
	}		
    } else {
	if ((res = add_counter(counter, incr)) == NIL) {
	    return DB_ERROR_SYSRES;
	} else if (is_non_value(res)) {
	    return DB_ERROR_UNSPEC;
	}
    }
    if (is_small(res)) {
	if (is_small(counter)) {
	    *counterp = res;
	} else {
	    if ((*realloc_fun)(tb, bp, 0, res, counterpos) < 0) 
		return DB_ERROR_SYSRES;
	}
	*ret = res;
	return DB_ERROR_NONE;
    } else {
	Eterm *ptr = big_val(res);
	Uint sz = BIG_ARITY(ptr) + 1;
	Eterm *hp;

	if ((*realloc_fun)(tb, bp, sz, res, counterpos) < 0) 
	    return DB_ERROR_SYSRES;
	hp = HAlloc(p, sz);
	sys_memcpy(hp, ptr, sz*sizeof(Eterm));
	res = make_big(hp);
	hp += sz;
	if (ptr != db_big_buf)
	    erts_free(ERTS_ALC_T_DB_TMP, (void *) ptr);
	*ret = res;
	return DB_ERROR_NONE;
    }
}   

/*
** Copy the object into a possibly new DbTerm, 
** offset is the offset of the DbTerm from the start
** of the sysAllocaed structure, The possibly realloced and copied
** structure is returned. Make sure (((char *) old) - offset) is a 
** pointer to a ERTS_ALC_T_DB_TERM allocated data area.
*/
void* db_get_term(DbTableCommon *tb, DbTerm* old, Uint offset, Eterm obj)
{
    int size = size_object(obj);
    void *structp = ((char*) old) - offset;
    DbTerm* p;
    Eterm copy;
    Eterm *top;

    if (old != 0) {
	erts_cleanup_offheap(&old->off_heap);
	if (size == old->size) {
	    p = old;
	} else {
	    Uint new_sz = offset + sizeof(DbTerm) + sizeof(Eterm)*(size-1);
	    Uint old_sz = offset + sizeof(DbTerm) + sizeof(Eterm)*(old->size-1);

	    if (erts_ets_realloc_always_moves) {
		void *nstructp = erts_db_alloc(ERTS_ALC_T_DB_TERM,
					       (DbTable *) tb,
					       new_sz);
		memcpy(nstructp,structp,offset);
		erts_db_free(ERTS_ALC_T_DB_TERM,
			     (DbTable *) tb,
			     structp,
			     old_sz);
		structp = nstructp;
	    } else {
		structp = erts_db_realloc(ERTS_ALC_T_DB_TERM,
					  (DbTable *) tb,
					  structp,
					  old_sz,
					  new_sz);
	    }
	    p = (DbTerm*) ((void *)(((char *) structp) + offset));
	}
    }
    else {
	structp = erts_db_alloc(ERTS_ALC_T_DB_TERM,
				(DbTable *) tb,
				(offset
				 + sizeof(DbTerm)
				 + sizeof(Eterm)*(size-1)));
	p = (DbTerm*) ((void *)(((char *) structp) + offset));
    }
    p->size = size;
    p->off_heap.mso = NULL;
    p->off_heap.externals = NULL;
#ifndef HYBRID /* FIND ME! */
    p->off_heap.funs = NULL;
#endif
    p->off_heap.overhead = 0;

    top = p->v;
    copy = copy_struct(obj, size, &top, &p->off_heap);
    p->tpl = tuple_val(copy);
    return structp;
}


void db_free_term_data(DbTerm* p)
{
    erts_cleanup_offheap(&p->off_heap);
}


/*
** Copy the new counter value into the DbTerm at ((char *) *bp) + offset,
** Allocate new structure of (needed size + offset) if that DbTerm
** is to small. When changing size, the old structure is 
** freed using ERTS_ALC_T_DB_TERM, make sure this can be done
** (((char *) b) - offset is a pointer to a ERTS_ALC_T_DB_TERM area).
** bp is a pure out parameter, i e it does not have to
** point to (((char *) b) - offset) when calling.
*/
int db_realloc_counter(DbTableCommon *tb,
		       void** bp, DbTerm *b, Uint offset, Uint sz, 
		       Eterm new_counter, int counterpos)
{
    DbTerm* new;
    void *newbp;
    Eterm  old_counter;
    Uint  old_sz;
    Uint  new_sz;
    Uint  basic_sz;
    Eterm  copy;
    Eterm *top;
    Eterm *ptr;

    old_counter = b->tpl[counterpos];

    if (is_small(old_counter))
	old_sz = 0;
    else {
	top = big_val(old_counter);
	old_sz = BIG_ARITY(top) + 1;
	if (sz == old_sz) {  /* OK we fit in old space */
	    sys_memcpy(top, big_val(new_counter), sz*sizeof(Eterm));
	    return 0;
	}
    }

    basic_sz = b->size - old_sz;
    new_sz = basic_sz + sz;

    newbp = erts_db_alloc(ERTS_ALC_T_DB_TERM,
			  (DbTable *) tb,
			  sizeof(DbTerm)+sizeof(Eterm)*(new_sz-1)+offset);

    if (newbp == NULL)
	return -1;

    new = (DbTerm*) ((void *)(((char *) newbp) + offset));
    memcpy(newbp, ((char *) b) - offset, offset); 
   
    new->size = new_sz;
    new->off_heap.mso = NULL;
    new->off_heap.externals = NULL;
#ifndef HYBRID /* FIND ME! */
    new->off_heap.funs = NULL;
#endif
    new->off_heap.overhead = 0;
    top = new->v;

    b->tpl[counterpos] = SMALL_ZERO;               /* zap, do not copy */

    /* copy term (except old counter) */
    copy = copy_struct(make_tuple(b->tpl), basic_sz, 
		       &top, &new->off_heap);
    new->tpl = tuple_val(copy);

    db_free_term_data(b);
    /* free old term */
    erts_db_free(ERTS_ALC_T_DB_TERM,
		 (DbTable *) tb,
		 (void *) (((char *) b) - offset),
		 offset + sizeof(DbTerm) + sizeof(Eterm)*(b->size-1));
    *bp = newbp;     /* patch new */

    /* copy new counter */
    if (sz == 0)
	new->tpl[counterpos] = new_counter;  /* must be small !!! */
    else {
	ptr = big_val(new_counter);
	sys_memcpy(top, ptr, sz*sizeof(Eterm));
	new->tpl[counterpos] = make_big(top);
    }
    return 0;
}

/*
** Check if object represents a "match" variable 
** i.e and atom $N where N is an integer 
**
*/

int db_is_variable(Eterm obj)
{
    byte *b;
    int n;
    int N;

    if (is_not_atom(obj))
        return -1;
    b = atom_tab(atom_val(obj))->name;
    if ((n = atom_tab(atom_val(obj))->len) < 2)
        return -1;
    if (*b++ != '$')
        return -1;
    n--;
    /* Handle first digit */
    if (*b == '0')
        return (n == 1) ? 0 : -1;
    if (*b >= '1' && *b <= '9')
        N = *b++ - '0';
    else
        return -1;
    n--;
    while(n--) {
        if (*b >= '0' && *b <= '9') {
            N = N*10 + (*b - '0');
            b++;
        }
        else
            return -1;
    }
    return N;
}


/* check if obj is (or contains) a variable */
/* return 1 if obj contains a variable or underscore */
/* return 0 if obj is fully ground                   */

int db_has_variable(Eterm obj)
{
    switch(obj & _TAG_PRIMARY_MASK) {
    case TAG_PRIMARY_LIST: {
	while (is_list(obj)) {
	    if (db_has_variable(CAR(list_val(obj))))
		return 1;
	    obj = CDR(list_val(obj));
	}
	return(db_has_variable(obj));  /* Non wellformed list or [] */
    }
    case TAG_PRIMARY_BOXED: 
	if (!BOXED_IS_TUPLE(obj)) {
	    return 0;
	} else {
	    Eterm *tuple = tuple_val(obj);
	    int arity = arityval(*tuple++);
	    while(arity--) {
		if (db_has_variable(*tuple))
		    return 1;
		tuple++;
	    }
	    return(0);
	}
    case TAG_PRIMARY_IMMED1:
	if (obj == am_Underscore || db_is_variable(obj) >= 0)
	    return 1;
    }
    return 0;
}

int erts_db_is_compiled_ms(Eterm term)
{
    return (!is_binary(term) || 
	    !(thing_subtag(*binary_val(term)) == REFC_BINARY_SUBTAG) ||
	    !((((ProcBin *) binary_val(term))->val)->flags & 
	      BIN_FLAG_MATCH_PROG)) ? 0 : 1;
}

/* 
** Local (static) utilities.
*/

/*
***************************************************************************
** Compiled matches 
***************************************************************************
*/
/*
** Utility to add an error
*/

static void add_dmc_err(DMCErrInfo *err_info, 
			char *str,
			int variable,
			Eterm term,
			DMCErrorSeverity severity)
{
    /* Linked in in reverse order, to ease the formatting */
    DMCError *e = erts_alloc(ERTS_ALC_T_DB_DMC_ERROR, sizeof(DMCError));
    if (term != 0UL) {
	erts_snprintf(e->error_string, DMC_ERR_STR_LEN, str, term);
    } else {
	strncpy(e->error_string, str, DMC_ERR_STR_LEN);
	e->error_string[DMC_ERR_STR_LEN] ='\0';
    }
    e->variable = variable;
    e->severity = severity;
    e->next = err_info->first;
#ifdef HARDDEBUG
    erts_fprintf(stderr,"add_dmc_err: %s\n",e->error_string);
#endif
    err_info->first = e;
    if (severity >= dmcError)
	err_info->error_added = 1;
}
    
/*
** Handle one term in the match expression (not the guard) 
*/
static DMCRet dmc_one_term(DMCContext *context, 
			   DMCHeap *heap,
			   DMC_STACK_TYPE(Eterm) *stack,
			   DMC_STACK_TYPE(Uint) *text,
			   Eterm c)
{
    Sint n;
    Eterm *hp;
    ErlHeapFragment *tmp_mb;
    Uint sz, sz2, sz3;
    Uint i, j;


    switch (c & _TAG_PRIMARY_MASK) {
    case TAG_PRIMARY_IMMED1:
	if ((n = db_is_variable(c)) >= 0) { /* variable */
	    if (n >= heap->size) {
		/*
		** Ouch, big integer in match variable.
		*/
		Eterm *save_hp;
		ASSERT(heap->data == heap->def);
		sz = sz2 = sz3 = 0;
		for (j = 0; j < context->num_match; ++j) {
		    sz += size_object(context->matchexpr[j]);
		    sz2 += size_object(context->guardexpr[j]);
		    sz3 += size_object(context->bodyexpr[j]);
		}
		context->copy = 
		    new_message_buffer(sz + sz2 + sz3 +
				       context->num_match);
		save_hp = hp = context->copy->mem;
		hp += context->num_match;
		for (j = 0; j < context->num_match; ++j) {
		    context->matchexpr[j] = 
			copy_struct(context->matchexpr[j], 
				    size_object(context->matchexpr[j]), &hp, 
				    &(context->copy->off_heap));
		    context->guardexpr[j] = 
			copy_struct(context->guardexpr[j], 
				    size_object(context->guardexpr[j]), &hp, 
				    &(context->copy->off_heap));
		    context->bodyexpr[j] = 
			copy_struct(context->bodyexpr[j], 
				    size_object(context->bodyexpr[j]), &hp, 
				    &(context->copy->off_heap));
		}
		for (j = 0; j < context->num_match; ++j) {
		    /* the actual expressions can be 
		       atoms in their selves, place them first */
		    *save_hp++ = context->matchexpr[j]; 
		}
		heap->size = match_compact(context->copy, 
					   context->err_info);
		for (j = 0; j < context->num_match; ++j) {
		    /* restore the match terms, as they
		       may be atoms that changed */
		    context->matchexpr[j] = context->copy->mem[j];
		}
		heap->data = erts_alloc(ERTS_ALC_T_DB_MS_CMPL_HEAP,
					heap->size*sizeof(unsigned));
		sys_memset(heap->data, 0, 
			   heap->size * sizeof(unsigned));
		DMC_CLEAR(*stack);
		/*DMC_PUSH(*stack,NIL);*/
		DMC_CLEAR(*text);
		return retRestart;
	    }
	    if (heap->data[n]) { /* already bound ? */
		DMC_PUSH(*text,matchCmp);
		DMC_PUSH(*text,n);
	    } else { /* Not bound, bind! */
		if (n >= heap->used)
		    heap->used = n + 1;
		DMC_PUSH(*text,matchBind);
		DMC_PUSH(*text,n);
		heap->data[n] = 1;
	    }
	} else if (c == am_Underscore) {
	    DMC_PUSH(*text, matchSkip);
	} else { /* Any immediate value */
	    DMC_PUSH(*text, matchEq);
	    DMC_PUSH(*text, (Uint) c);
	}
	break;
    case TAG_PRIMARY_LIST:
	DMC_PUSH(*text, matchPushL);
	++(context->stack_used);
	DMC_PUSH(*stack, c); 
	break;
    case TAG_PRIMARY_BOXED: {
	Eterm hdr = *boxed_val(c);
	switch ((hdr & _TAG_HEADER_MASK) >> _TAG_PRIMARY_SIZE) {
	case (_TAG_HEADER_ARITYVAL >> _TAG_PRIMARY_SIZE):    
	    n = arityval(*tuple_val(c));
	    DMC_PUSH(*text, matchPushT);
	    ++(context->stack_used);
	    DMC_PUSH(*text, n);
	    DMC_PUSH(*stack, c);
	    break;
	case (_TAG_HEADER_REF >> _TAG_PRIMARY_SIZE):
	    n = thing_arityval(*internal_ref_val(c));
	    DMC_PUSH(*text, matchEqRef);
	    DMC_PUSH(*text, *internal_ref_val(c));
	    for (i = 1; i <= n; ++i) {
		DMC_PUSH(*text, (Uint) internal_ref_val(c)[i]);
	    }
	    break;
	case (_TAG_HEADER_POS_BIG >> _TAG_PRIMARY_SIZE):
	case (_TAG_HEADER_NEG_BIG >> _TAG_PRIMARY_SIZE):
	    n = thing_arityval(*big_val(c));
	    DMC_PUSH(*text, matchEqBig);
	    DMC_PUSH(*text, *big_val(c));
	    for (i = 1; i <= n; ++i) {
		DMC_PUSH(*text, (Uint) big_val(c)[i]);
	    }
	    break;
	case (_TAG_HEADER_FLOAT >> _TAG_PRIMARY_SIZE):
	    DMC_PUSH(*text,matchEqFloat);
	    DMC_PUSH(*text, (Uint) float_val(c)[1]);
	    /* XXX: this reads and pushes random junk on ARCH_64 */
	    DMC_PUSH(*text, (Uint) float_val(c)[2]);
	    break;
	default: /* BINARY, FUN, VECTOR, or EXTERNAL */
	    /*
	    ** Make a private copy...
	    */
	    n = size_object(c);
	    tmp_mb = new_message_buffer(n);
	    hp = tmp_mb->mem;
	    DMC_PUSH(*text, matchEqBin);
	    DMC_PUSH(*text, copy_struct(c, n, &hp, &(tmp_mb->off_heap)));
	    tmp_mb->next = context->save;
	    context->save = tmp_mb;
	    break;
	}
	break;
    }
    default:
	erl_exit(1, "db_match_compile: "
		 "Bad object on heap: 0x%08lx\n",
		 (unsigned long) c);
    }
    return retOk;
}

/*
** Match guard compilation
*/

static void do_emit_constant(DMCContext *context, DMC_STACK_TYPE(Uint) *text,
			     Eterm t) 
{
	int sz;
	ErlHeapFragment *emb;
	Eterm *hp;
	Eterm tmp;

	if (IS_CONST(t)) {
	    tmp = t;
	} else {
	    sz = my_size_object(t);
	    emb = new_message_buffer(sz);
	    hp = emb->mem;
	    tmp = my_copy_struct(t,&hp,&(emb->off_heap));
	    emb->next = context->save;
	    context->save = emb;
	}
	DMC_PUSH(*text,matchPushC);
	DMC_PUSH(*text,(Uint) tmp);
	if (++context->stack_used > context->stack_need)
	    context->stack_need = context->stack_used;
}

#define RETURN_ERROR_X(String, X, Y, ContextP, ConstantF)        \
do {                                                            \
if ((ContextP)->err_info != NULL) {				\
    (ConstantF) = 0;						\
    add_dmc_err((ContextP)->err_info, String, X, Y, dmcError);  \
    return retOk;						\
} else 								\
  return retFail;                                                \
} while(0)

#define RETURN_ERROR(String, ContextP, ConstantF) \
     RETURN_ERROR_X(String, -1, 0UL, ContextP, ConstantF)

#define RETURN_VAR_ERROR(String, N, ContextP, ConstantF) \
     RETURN_ERROR_X(String, N, 0UL, ContextP, ConstantF)

#define RETURN_TERM_ERROR(String, T, ContextP, ConstantF) \
     RETURN_ERROR_X(String, -1, T, ContextP, ConstantF)

#define WARNING(String, ContextP) \
add_dmc_err((ContextP)->err_info, String, -1, 0UL, dmcWarning)

#define VAR_WARNING(String, N, ContextP) \
add_dmc_err((ContextP)->err_info, String, N, 0UL, dmcWarning)

#define TERM_WARNING(String, T, ContextP) \
add_dmc_err((ContextP)->err_info, String, -1, T, dmcWarning)

static DMCRet dmc_list(DMCContext *context,
		       DMCHeap *heap,
		       DMC_STACK_TYPE(Uint) *text,
		       Eterm t,
		       int *constant)
{
    int c1;
    int c2;
    int ret;

    if ((ret = dmc_expr(context, heap, text, CAR(list_val(t)), &c1)) != retOk)
	return ret;

    if ((ret = dmc_expr(context, heap, text, CDR(list_val(t)), &c2)) != retOk)
	return ret;

    if (c1 && c2) {
	*constant = 1;
	return retOk;
    } 
    *constant = 0;
    if (!c1) {
	/* The CAR is not a constant, so if the CDR is, we just push it,
	   otherwise it is already pushed. */
	if (c2)
	    do_emit_constant(context, text, CDR(list_val(t)));
	DMC_PUSH(*text, matchConsA);
    } else { /* !c2 && c1 */
	do_emit_constant(context, text, CAR(list_val(t)));
	DMC_PUSH(*text, matchConsB);
    }
    --context->stack_used; /* Two objects on stack becomes one */
    context->eheap_need += 2;
    return retOk;
}

static DMCRet dmc_tuple(DMCContext *context,
		       DMCHeap *heap,
		       DMC_STACK_TYPE(Uint) *text,
		       Eterm t,
		       int *constant)
{
    DMC_STACK_TYPE(Uint) instr_save;
    int all_constant = 1;
    int textpos = DMC_STACK_NUM(*text);
    Eterm *p = tuple_val(t);
    Uint nelems = arityval(*p);
    Uint i;
    int c;
    DMCRet ret;
    Uint lblpos = DMC_STACK_NUM(*(context->labels));


    /*
    ** We remember where we started to layout code, 
    ** assume all is constant and back up and restart if not so.
    ** The tuple should be laid out with the last element first,
    ** so we can memcpy the tuple to the eheap;
    */
    for (i = nelems; i > 0; --i) {
	if ((ret = dmc_expr(context, heap, text, p[i], &c)) != retOk)
	    return ret;
	if (!c && all_constant) {
	    all_constant = 0;
	    if (i < nelems) {
		Uint j;
		Uint txtnum = DMC_STACK_NUM(*text);
		/* oups, we need to relayout the constantants */
		/* save the already laid out instructions */
		DMC_INIT_STACK(instr_save);
		while (DMC_STACK_NUM(*text) > textpos) 
		    DMC_PUSH(instr_save, DMC_POP(*text));
		for (j = nelems; j > i; --j)
		    do_emit_constant(context, text, p[j]);
		while(!DMC_EMPTY(instr_save))
		    DMC_PUSH(*text, DMC_POP(instr_save));
		if (DMC_STACK_NUM(*(context->labels)) != lblpos) {
		    /*
		    ** This is NOT funny... All labels have to be offset
		    ** By how many instructions we inserted during 
		    ** constant emission...
		    */
		    int diff = DMC_STACK_NUM(*text) - txtnum;
		    Uint nlblpos = DMC_STACK_NUM(*(context->labels));
		    for (j = lblpos; j < nlblpos; ++j) {
			DMC_POKE(*(context->labels), j, 
				 (Uint) DMC_PEEK(*(context->labels), j) + 
				 diff);
		    }
		}
		DMC_FREE(instr_save);
	    }
	} else if (c && !all_constant) {
	    /* push a constant */
	    do_emit_constant(context, text, p[i]);
	}
    }
    
    if (all_constant) {
	*constant = 1;
	return retOk;
    }
    DMC_PUSH(*text, matchMkTuple);
    DMC_PUSH(*text, nelems);
    context->stack_used -= (nelems - 1);
    context->eheap_need += (nelems + 1);
    *constant = 0;
    return retOk;
}

static DMCRet dmc_whole_expression(DMCContext *context,
				   DMCHeap *heap,
				   DMC_STACK_TYPE(Uint) *text,
				   Eterm t,
				   int *constant)
{
    if (context->cflags & DCOMP_TRACE) {
	/* Hmmm, convert array to list... */
	if (context->special) {
	   DMC_PUSH(*text, matchPushArrayAsListU);
	} else { 
	    ASSERT(is_tuple(context->matchexpr
			    [context->current_match]));
	    context->eheap_need += 
		arityval(*(tuple_val(context->matchexpr
				     [context->current_match]))) * 2;
	    DMC_PUSH(*text, matchPushArrayAsList);
	}
    } else {
	DMC_PUSH(*text, matchPushExpr);
    }
    ++context->stack_used;
    if (context->stack_used > context->stack_need)
	context->stack_need = context->stack_used;
    *constant = 0;
    return retOk;
}

static DMCRet dmc_variable(DMCContext *context,
			   DMCHeap *heap,
			   DMC_STACK_TYPE(Uint) *text,
			   Eterm t,
			   int *constant)
{
    Uint n = db_is_variable(t);
    ASSERT(n >= 0);
    if (n >= heap->used) 
	RETURN_VAR_ERROR("Variable $%d is unbound.", n, context, *constant);
    if (heap->data[n] == 0U)
	RETURN_VAR_ERROR("Variable $%d is unbound.", n, context, *constant);
    DMC_PUSH(*text, matchPushV);
    DMC_PUSH(*text, n);
    ++context->stack_used;
    if (context->stack_used > context->stack_need)
	context->stack_need = context->stack_used;
    *constant = 0;
    return retOk;
}

static DMCRet dmc_all_bindings(DMCContext *context,
			       DMCHeap *heap,
			       DMC_STACK_TYPE(Uint) *text,
			       Eterm t,
			       int *constant)
{
    int i;
    int heap_used = 0;

    DMC_PUSH(*text, matchPushC);
    DMC_PUSH(*text, NIL);
    for (i = heap->used - 1; i >= 0; --i) { 
	if (heap->data[i]) {
	    DMC_PUSH(*text, matchPushV);
	    DMC_PUSH(*text, i);
	    DMC_PUSH(*text, matchConsB);
	    heap_used += 2;
	}
    }
    ++context->stack_used;
    if ((context->stack_used + 1) > context->stack_need)
	context->stack_need = (context->stack_used + 1);
    context->eheap_need += heap_used;
    *constant = 0;
    return retOk;
}

static DMCRet dmc_const(DMCContext *context,
		       DMCHeap *heap,
		       DMC_STACK_TYPE(Uint) *text,
		       Eterm t,
		       int *constant)
{
    Eterm *p = tuple_val(t);
    Uint a = arityval(*p);

    if (a != 2) {
	RETURN_TERM_ERROR("Special form 'const' called with more than one "
			  "argument in %T.", t, context, *constant);
    }
    *constant = 1;
    return retOk;
}

static DMCRet dmc_and(DMCContext *context,
		      DMCHeap *heap,
		      DMC_STACK_TYPE(Uint) *text,
		      Eterm t,
		      int *constant)
{
    Eterm *p = tuple_val(t);
    Uint a = arityval(*p);
    DMCRet ret;
    int i;
    int c;
    
    if (a < 2) {
	RETURN_TERM_ERROR("Special form 'and' called without arguments "
			  "in %T.", t, context, *constant);
    }
    *constant = 0;
    for (i = a; i > 1; --i) {
	if ((ret = dmc_expr(context, heap, text, p[i], &c)) != retOk)
	    return ret;
	if (c) 
	    do_emit_constant(context, text, p[i]);
    }
    DMC_PUSH(*text, matchAnd);
    DMC_PUSH(*text, (Uint) a - 1);
    context->stack_used -= (a - 2);
    return retOk;
}

static DMCRet dmc_or(DMCContext *context,
		     DMCHeap *heap,
		     DMC_STACK_TYPE(Uint) *text,
		     Eterm t,
		     int *constant)
{
    Eterm *p = tuple_val(t);
    Uint a = arityval(*p);
    DMCRet ret;
    int i;
    int c;
    
    if (a < 2) {
	RETURN_TERM_ERROR("Special form 'or' called without arguments "
			  "in %T.", t, context, *constant);
    }
    *constant = 0;
    for (i = a; i > 1; --i) {
	if ((ret = dmc_expr(context, heap, text, p[i], &c)) != retOk)
	    return ret;
	if (c) 
	    do_emit_constant(context, text, p[i]);
    }
    DMC_PUSH(*text, matchOr);
    DMC_PUSH(*text, (Uint) a - 1);
    context->stack_used -= (a - 2);
    return retOk;
}


static DMCRet dmc_andthen(DMCContext *context,
			  DMCHeap *heap,
			  DMC_STACK_TYPE(Uint) *text,
			  Eterm t,
			  int *constant)
{
    Eterm *p = tuple_val(t);
    Uint a = arityval(*p);
    DMCRet ret;
    int i;
    int c;
    int lbl;
    
    if (a < 2) {
	RETURN_TERM_ERROR("Special form 'andalso/andthen' called without"
			  " arguments "
			  "in %T.", t, context, *constant);
    }
    *constant = 0;
    lbl = DMC_STACK_NUM(*(context->labels));
    DMC_PUSH(*(context->labels), 0);
    for (i = 2; i <= a; ++i) {
	if ((ret = dmc_expr(context, heap, text, p[i], &c)) != retOk)
	    return ret;
	if (c) 
	    do_emit_constant(context, text, p[i]);
	DMC_PUSH(*text, matchAndThen);
	DMC_PUSH(*text, (Uint) lbl);
	--(context->stack_used);
    }
    DMC_PUSH(*text, matchPushC);
    DMC_PUSH(*text, am_true);
    DMC_POKE(*(context->labels), lbl, DMC_STACK_NUM(*text));
    if (++context->stack_used > context->stack_need)
	context->stack_need = context->stack_used;
    return retOk;
}

static DMCRet dmc_orelse(DMCContext *context,
			 DMCHeap *heap,
			 DMC_STACK_TYPE(Uint) *text,
			 Eterm t,
			 int *constant)
{
    Eterm *p = tuple_val(t);
    Uint a = arityval(*p);
    DMCRet ret;
    int i;
    int c;
    int lbl;
    
    if (a < 2) {
	RETURN_TERM_ERROR("Special form 'orelse' called without arguments "
			  "in %T.", t, context, *constant);
    }
    *constant = 0;
    lbl = DMC_STACK_NUM(*(context->labels));
    DMC_PUSH(*(context->labels), 0);
    for (i = 2; i <= a; ++i) {
	if ((ret = dmc_expr(context, heap, text, p[i], &c)) != retOk)
	    return ret;
	if (c) 
	    do_emit_constant(context, text, p[i]);
	DMC_PUSH(*text, matchOrElse);
	DMC_PUSH(*text, (Uint) lbl);
	--(context->stack_used);
    }
    DMC_PUSH(*text, matchPushC);
    DMC_PUSH(*text, am_false);
    DMC_POKE(*(context->labels), lbl, DMC_STACK_NUM(*text));
    if (++context->stack_used > context->stack_need)
	context->stack_need = context->stack_used;
    return retOk;
}

static DMCRet dmc_message(DMCContext *context,
			  DMCHeap *heap,
			  DMC_STACK_TYPE(Uint) *text,
			  Eterm t,
			  int *constant)
{
    Eterm *p = tuple_val(t);
    Uint a = arityval(*p);
    DMCRet ret;
    int c;
    

    if (!(context->cflags & DCOMP_TRACE)) {
	RETURN_ERROR("Special form 'message' used in wrong dialect.",
		     context, 
		     *constant);
    }
    if (context->is_guard) {
	RETURN_ERROR("Special form 'message' called in guard context.",
		     context, 
		     *constant);
    }

    if (a != 2) {
	RETURN_TERM_ERROR("Special form 'message' called with wrong "
			  "number of arguments in %T.", t, context, 
			  *constant);
    }
    *constant = 0;
    if ((ret = dmc_expr(context, heap, text, p[2], &c)) != retOk) {
	return ret;
    }
    if (c) { 
	do_emit_constant(context, text, p[2]);
    }
    DMC_PUSH(*text, matchReturn);
    DMC_PUSH(*text, matchPushC);
    DMC_PUSH(*text, am_true);
    /* Push as much as we remove, stack_need is untouched */
    return retOk;
}

static DMCRet dmc_self(DMCContext *context,
		     DMCHeap *heap,
		     DMC_STACK_TYPE(Uint) *text,
		     Eterm t,
		     int *constant)
{
    Eterm *p = tuple_val(t);
    Uint a = arityval(*p);
    
    if (a != 1) {
	RETURN_TERM_ERROR("Special form 'self' called with arguments "
			  "in %T.", t, context, *constant);
    }
    *constant = 0;
    DMC_PUSH(*text, matchSelf);
    if (++context->stack_used > context->stack_need)
	context->stack_need = context->stack_used;
    return retOk;
}

static DMCRet dmc_return_trace(DMCContext *context,
			       DMCHeap *heap,
			       DMC_STACK_TYPE(Uint) *text,
			       Eterm t,
			       int *constant)
{
    Eterm *p = tuple_val(t);
    Uint a = arityval(*p);
    
    if (!(context->cflags & DCOMP_TRACE)) {
	RETURN_ERROR("Special form 'return_trace' used in wrong dialect.",
		     context, 
		     *constant);
    }
    if (context->is_guard) {
	RETURN_ERROR("Special form 'return_trace' called in "
		     "guard context.", context, *constant);
    }

    if (a != 1) {
	RETURN_TERM_ERROR("Special form 'return_trace' called with "
			  "arguments in %T.", t, context, *constant);
    }
    *constant = 0;
    DMC_PUSH(*text, matchSetReturnTrace); /* Pushes 'true' on the stack */
    if (++context->stack_used > context->stack_need)
	context->stack_need = context->stack_used;
    return retOk;
}

static DMCRet dmc_exception_trace(DMCContext *context,
			       DMCHeap *heap,
			       DMC_STACK_TYPE(Uint) *text,
			       Eterm t,
			       int *constant)
{
    Eterm *p = tuple_val(t);
    Uint a = arityval(*p);
    
    if (!(context->cflags & DCOMP_TRACE)) {
	RETURN_ERROR("Special form 'exception_trace' used in wrong dialect.",
		     context, 
		     *constant);
    }
    if (context->is_guard) {
	RETURN_ERROR("Special form 'exception_trace' called in "
		     "guard context.", context, *constant);
    }

    if (a != 1) {
	RETURN_TERM_ERROR("Special form 'exception_trace' called with "
			  "arguments in %T.", t, context, *constant);
    }
    *constant = 0;
    DMC_PUSH(*text, matchSetExceptionTrace); /* Pushes 'true' on the stack */
    if (++context->stack_used > context->stack_need)
	context->stack_need = context->stack_used;
    return retOk;
}



static DMCRet dmc_is_seq_trace(DMCContext *context,
			       DMCHeap *heap,
			       DMC_STACK_TYPE(Uint) *text,
			       Eterm t,
			       int *constant)
{
    Eterm *p = tuple_val(t);
    Uint a = arityval(*p);
    
    if (!(context->cflags & DCOMP_TRACE)) {
	RETURN_ERROR("Special form 'is_seq_trace' used in wrong dialect.",
		     context, 
		     *constant);
    }
    if (a != 1) {
	RETURN_TERM_ERROR("Special form 'is_seq_trace' called with "
			  "arguments in %T.", t, context, *constant);
    }
    *constant = 0;
    DMC_PUSH(*text, matchIsSeqTrace); 
    /* Pushes 'true' or 'false' on the stack */
    if (++context->stack_used > context->stack_need)
	context->stack_need = context->stack_used;
    return retOk;
}

static DMCRet dmc_set_seq_token(DMCContext *context,
				DMCHeap *heap,
				DMC_STACK_TYPE(Uint) *text,
				Eterm t,
				int *constant)
{
    Eterm *p = tuple_val(t);
    Uint a = arityval(*p);
    DMCRet ret;
    int c;
    

    if (!(context->cflags & DCOMP_TRACE)) {
	RETURN_ERROR("Special form 'set_seq_token' used in wrong dialect.",
		     context, 
		     *constant);
    }
    if (context->is_guard) {
	RETURN_ERROR("Special form 'set_seq_token' called in "
		     "guard context.", context, *constant);
    }

    if (a != 3) {
	RETURN_TERM_ERROR("Special form 'set_seq_token' called with wrong "
			  "number of arguments in %T.", t, context, 
			  *constant);
    }
    *constant = 0;
    if ((ret = dmc_expr(context, heap, text, p[3], &c)) != retOk) {
	return ret;
    }
    if (c) { 
	do_emit_constant(context, text, p[3]);
    }
    if ((ret = dmc_expr(context, heap, text, p[2], &c)) != retOk) {
	return ret;
    }
    if (c) { 
	do_emit_constant(context, text, p[2]);
    }
    if (context->cflags & DCOMP_FAKE_DESTRUCTIVE) {
	DMC_PUSH(*text, matchSetSeqTokenFake);
    } else {
	DMC_PUSH(*text, matchSetSeqToken);
    }
    --context->stack_used; /* Remove two and add one */
    return retOk;
}

static DMCRet dmc_get_seq_token(DMCContext *context,
				DMCHeap *heap,
				DMC_STACK_TYPE(Uint) *text,
				Eterm t,
				int *constant)
{
    Eterm *p = tuple_val(t);
    Uint a = arityval(*p);

    if (!(context->cflags & DCOMP_TRACE)) {
	RETURN_ERROR("Special form 'get_seq_token' used in wrong dialect.",
		     context, 
		     *constant);
    }
    if (context->is_guard) {
	RETURN_ERROR("Special form 'get_seq_token' called in "
		     "guard context.", context, *constant);
    }
    if (a != 1) {
	RETURN_TERM_ERROR("Special form 'get_seq_token' called with "
			  "arguments in %T.", t, context, 
			  *constant);
    }

    *constant = 0;
    DMC_PUSH(*text, matchGetSeqToken);
    context->eheap_need += (6 /* A 5-tuple is built */
			    + EXTERNAL_THING_HEAD_SIZE + 2 /* Sender can
							      be an external
							      pid */);
    if (++context->stack_used > context->stack_need)
 	context->stack_need = context->stack_used;
    return retOk;
}



static DMCRet dmc_display(DMCContext *context,
			  DMCHeap *heap,
			  DMC_STACK_TYPE(Uint) *text,
			  Eterm t,
			  int *constant)
{
    Eterm *p = tuple_val(t);
    Uint a = arityval(*p);
    DMCRet ret;
    int c;
    

    if (!(context->cflags & DCOMP_TRACE)) {
	RETURN_ERROR("Special form 'display' used in wrong dialect.",
		     context, 
		     *constant);
    }
    if (context->is_guard) {
	RETURN_ERROR("Special form 'display' called in guard context.",
		     context, 
		     *constant);
    }

    if (a != 2) {
	RETURN_TERM_ERROR("Special form 'display' called with wrong "
			  "number of arguments in %T.", t, context, 
			  *constant);
    }
    *constant = 0;
    if ((ret = dmc_expr(context, heap, text, p[2], &c)) != retOk) {
	return ret;
    }
    if (c) { 
	do_emit_constant(context, text, p[2]);
    }
    DMC_PUSH(*text, matchDisplay);
    /* Push as much as we remove, stack_need is untouched */
    return retOk;
}

static DMCRet dmc_process_dump(DMCContext *context,
			       DMCHeap *heap,
			       DMC_STACK_TYPE(Uint) *text,
			       Eterm t,
			       int *constant)
{
    Eterm *p = tuple_val(t);
    Uint a = arityval(*p);
    
    if (!(context->cflags & DCOMP_TRACE)) {
	RETURN_ERROR("Special form 'process_dump' used in wrong dialect.",
		     context, 
		     *constant);
    }
    if (context->is_guard) {
	RETURN_ERROR("Special form 'process_dump' called in "
		     "guard context.", context, *constant);
    }

    if (a != 1) {
	RETURN_TERM_ERROR("Special form 'process_dump' called with "
			  "arguments in %T.", t, context, *constant);
    }
    *constant = 0;
    DMC_PUSH(*text, matchProcessDump); /* Creates binary */
    if (++context->stack_used > context->stack_need)
	context->stack_need = context->stack_used;
    return retOk;
}

static DMCRet dmc_enable_trace(DMCContext *context,
			       DMCHeap *heap,
			       DMC_STACK_TYPE(Uint) *text,
			       Eterm t,
			       int *constant)
{
    Eterm *p = tuple_val(t);
    Uint a = arityval(*p);
    DMCRet ret;
    int c;
    

    if (!(context->cflags & DCOMP_TRACE)) {
	RETURN_ERROR("Special form 'enable_trace' used in wrong dialect.",
		     context, 
		     *constant);
    }
    if (context->is_guard) {
	RETURN_ERROR("Special form 'enable_trace' called in guard context.",
		     context, 
		     *constant);
    }

    switch (a) {
    case 2:
	*constant = 0;
	if ((ret = dmc_expr(context, heap, text, p[2], &c)) != retOk) {
	    return ret;
	}
	if (c) { 
	    do_emit_constant(context, text, p[2]);
	}
	DMC_PUSH(*text, matchEnableTrace);
	/* Push as much as we remove, stack_need is untouched */
	break;
    case 3:
	*constant = 0;
	if ((ret = dmc_expr(context, heap, text, p[3], &c)) != retOk) {
	    return ret;
	}
	if (c) { 
	    do_emit_constant(context, text, p[3]);
	}
	if ((ret = dmc_expr(context, heap, text, p[2], &c)) != retOk) {
	    return ret;
	}
	if (c) { 
	    do_emit_constant(context, text, p[2]);
	}
	DMC_PUSH(*text, matchEnableTrace2);
	--context->stack_used; /* Remove two and add one */
	break;
    default:
	RETURN_TERM_ERROR("Special form 'enable_trace' called with wrong "
			  "number of arguments in %T.", t, context, 
			  *constant);
    }
    return retOk;
}

static DMCRet dmc_disable_trace(DMCContext *context,
				DMCHeap *heap,
				DMC_STACK_TYPE(Uint) *text,
				Eterm t,
				int *constant)
{
    Eterm *p = tuple_val(t);
    Uint a = arityval(*p);
    DMCRet ret;
    int c;
    

    if (!(context->cflags & DCOMP_TRACE)) {
	RETURN_ERROR("Special form 'disable_trace' used in wrong dialect.",
		     context, 
		     *constant);
    }
    if (context->is_guard) {
	RETURN_ERROR("Special form 'disable_trace' called in guard context.",
		     context, 
		     *constant);
    }

    switch (a) {
    case 2:
	*constant = 0;
	if ((ret = dmc_expr(context, heap, text, p[2], &c)) != retOk) {
	    return ret;
	}
	if (c) { 
	    do_emit_constant(context, text, p[2]);
	}
	DMC_PUSH(*text, matchDisableTrace);
	/* Push as much as we remove, stack_need is untouched */
	break;
    case 3:
	*constant = 0;
	if ((ret = dmc_expr(context, heap, text, p[3], &c)) != retOk) {
	    return ret;
	}
	if (c) { 
	    do_emit_constant(context, text, p[3]);
	}
	if ((ret = dmc_expr(context, heap, text, p[2], &c)) != retOk) {
	    return ret;
	}
	if (c) { 
	    do_emit_constant(context, text, p[2]);
	}
	DMC_PUSH(*text, matchDisableTrace2);
	--context->stack_used; /* Remove two and add one */
	break;
    default:
	RETURN_TERM_ERROR("Special form 'disable_trace' called with wrong "
			  "number of arguments in %T.", t, context, 
			  *constant);
    }
    return retOk;
}

static DMCRet dmc_trace(DMCContext *context,
			DMCHeap *heap,
			DMC_STACK_TYPE(Uint) *text,
			Eterm t,
			int *constant)
{
    Eterm *p = tuple_val(t);
    Uint a = arityval(*p);
    DMCRet ret;
    int c;
    

    if (!(context->cflags & DCOMP_TRACE)) {
	RETURN_ERROR("Special form 'trace' used in wrong dialect.",
		     context, 
		     *constant);
    }
    if (context->is_guard) {
	RETURN_ERROR("Special form 'trace' called in guard context.",
		     context, 
		     *constant);
    }

    switch (a) {
    case 3:
	*constant = 0;
	if ((ret = dmc_expr(context, heap, text, p[3], &c)) != retOk) {
	    return ret;
	}
	if (c) { 
	    do_emit_constant(context, text, p[3]);
	}
	if ((ret = dmc_expr(context, heap, text, p[2], &c)) != retOk) {
	    return ret;
	}
	if (c) { 
	    do_emit_constant(context, text, p[2]);
	}
	DMC_PUSH(*text, matchTrace2);
	--context->stack_used; /* Remove two and add one */
	break;
    case 4:
	*constant = 0;
	if ((ret = dmc_expr(context, heap, text, p[4], &c)) != retOk) {
	    return ret;
	}
	if (c) { 
	    do_emit_constant(context, text, p[4]);
	}
	if ((ret = dmc_expr(context, heap, text, p[3], &c)) != retOk) {
	    return ret;
	}
	if (c) { 
	    do_emit_constant(context, text, p[3]);
	}
	if ((ret = dmc_expr(context, heap, text, p[2], &c)) != retOk) {
	    return ret;
	}
	if (c) { 
	    do_emit_constant(context, text, p[2]);
	}
	DMC_PUSH(*text, matchTrace3);
	context->stack_used -= 2; /* Remove three and add one */
	break;
    default:
	RETURN_TERM_ERROR("Special form 'trace' called with wrong "
			  "number of arguments in %T.", t, context, 
			  *constant);
    }
    return retOk;
}



static DMCRet dmc_caller(DMCContext *context,
 			 DMCHeap *heap,
 			 DMC_STACK_TYPE(Uint) *text,
 			 Eterm t,
 			 int *constant)
{
    Eterm *p = tuple_val(t);
    Uint a = arityval(*p);
     
    if (!(context->cflags & DCOMP_TRACE)) {
	RETURN_ERROR("Special form 'caller' used in wrong dialect.",
		     context, 
		     *constant);
    }
    if (context->is_guard) {
 	RETURN_ERROR("Special form 'caller' called in "
 		     "guard context.", context, *constant);
    }
  
    if (a != 1) {
 	RETURN_TERM_ERROR("Special form 'caller' called with "
 			  "arguments in %T.", t, context, *constant);
    }
    *constant = 0;
    DMC_PUSH(*text, matchCaller); /* Creates binary */
    context->eheap_need += 4;     /* A 3-tuple is built */
    if (++context->stack_used > context->stack_need)
 	context->stack_need = context->stack_used;
    return retOk;
}


  
static DMCRet dmc_silent(DMCContext *context,
 			 DMCHeap *heap,
 			 DMC_STACK_TYPE(Uint) *text,
 			 Eterm t,
 			 int *constant)
{
    Eterm *p = tuple_val(t);
    Uint a = arityval(*p);
    DMCRet ret;
    int c;
     
    if (!(context->cflags & DCOMP_TRACE)) {
	RETURN_ERROR("Special form 'silent' used in wrong dialect.",
		     context, 
		     *constant);
    }
    if (context->is_guard) {
 	RETURN_ERROR("Special form 'silent' called in "
 		     "guard context.", context, *constant);
    }
  
    if (a != 2) {
	RETURN_TERM_ERROR("Special form 'silent' called with wrong "
			  "number of arguments in %T.", t, context, 
			  *constant);
    }
    *constant = 0;
    if ((ret = dmc_expr(context, heap, text, p[2], &c)) != retOk) {
	return ret;
    }
    if (c) { 
	do_emit_constant(context, text, p[2]);
    }
    DMC_PUSH(*text, matchSilent);
    DMC_PUSH(*text, matchPushC);
    DMC_PUSH(*text, am_true);
    /* Push as much as we remove, stack_need is untouched */
    return retOk;
}
  


static DMCRet dmc_fun(DMCContext *context,
		       DMCHeap *heap,
		       DMC_STACK_TYPE(Uint) *text,
		       Eterm t,
		       int *constant)
{
    Eterm *p = tuple_val(t);
    Uint a = arityval(*p);
    int c;
    int i;
    DMCRet ret;
    DMCGuardBif *b;
 
    /* Special forms. */
    switch (p[1]) {
    case am_const:
	return dmc_const(context, heap, text, t, constant);
    case am_and:
	return dmc_and(context, heap, text, t, constant);
    case am_or:
	return dmc_or(context, heap, text, t, constant);
    case am_andalso:
    case am_andthen:
	return dmc_andthen(context, heap, text, t, constant);
    case am_orelse:
	return dmc_orelse(context, heap, text, t, constant);
    case am_self:
	return dmc_self(context, heap, text, t, constant);
    case am_message:
	return dmc_message(context, heap, text, t, constant);
    case am_is_seq_trace:
	return dmc_is_seq_trace(context, heap, text, t, constant);
    case am_set_seq_token:
	return dmc_set_seq_token(context, heap, text, t, constant);
    case am_get_seq_token:
	return dmc_get_seq_token(context, heap, text, t, constant);
    case am_return_trace:
	return dmc_return_trace(context, heap, text, t, constant);
    case am_exception_trace:
	return dmc_exception_trace(context, heap, text, t, constant);
    case am_display:
	return dmc_display(context, heap, text, t, constant);
    case am_process_dump:
	return dmc_process_dump(context, heap, text, t, constant);
    case am_enable_trace:
	return dmc_enable_trace(context, heap, text, t, constant);
    case am_disable_trace:
	return dmc_disable_trace(context, heap, text, t, constant);
    case am_trace:
	return dmc_trace(context, heap, text, t, constant);
    case am_caller:
 	return dmc_caller(context, heap, text, t, constant);
    case am_silent:
 	return dmc_silent(context, heap, text, t, constant);
    case am_set_tcw:
	if (context->cflags & DCOMP_FAKE_DESTRUCTIVE) {
	    b = dmc_lookup_bif(am_set_tcw_fake, ((int) a) - 1);
	} else {
	    b = dmc_lookup_bif(p[1], ((int) a) - 1);
	}
	break;
    default:
	b = dmc_lookup_bif(p[1], ((int) a) - 1);
    }


    if (b == NULL) {
	if (context->err_info != NULL) {
	    /* Ugly, should define a better RETURN_TERM_ERROR interface... */
	    char buff[100];
	    sprintf(buff, "Function %%T/%d does_not_exist.", (int)a - 1);
	    RETURN_TERM_ERROR(buff, p[1], context, *constant);
	} else {
	    return retFail;
	}
    } 
    ASSERT(b->arity == ((int) a) - 1);
    if (! (b->flags & 
	   (1 << 
	    ((context->cflags & DCOMP_DIALECT_MASK) + 
	      (context->is_guard ? DBIF_GUARD : DBIF_BODY))))) {
	/* Body clause used in wrong context. */
	if (context->err_info != NULL) {
	    /* Ugly, should define a better RETURN_TERM_ERROR interface... */
	    char buff[100];
	    sprintf(buff, 
		    "Function %%T/%d cannot be called in this context.",
		    (int)a - 1);
	    RETURN_TERM_ERROR(buff, p[1], context, *constant);
	} else {
	    return retFail;
	}
    }	

    *constant = 0;

    for (i = a; i > 1; --i) {
	if ((ret = dmc_expr(context, heap, text, p[i], &c)) != retOk)
	    return ret;
	if (c) 
	    do_emit_constant(context, text, p[i]);
    }
    switch (b->arity) {
    case 0:
	DMC_PUSH(*text, matchCall0);
	break;
    case 1:
	DMC_PUSH(*text, matchCall1);
	break;
    case 2:
	DMC_PUSH(*text, matchCall2);
	break;
    case 3:
	DMC_PUSH(*text, matchCall3);
	break;
    default:
	erl_exit(1,"ets:match() internal error, "
		 "guard with more than 3 arguments.");
    }
    DMC_PUSH(*text, (Uint) b->biff);
    context->stack_used -= (((int) a) - 2);
    if (context->stack_used > context->stack_need)
 	context->stack_need = context->stack_used;
    return retOk;
}

static DMCRet dmc_expr(DMCContext *context,
		       DMCHeap *heap,
		       DMC_STACK_TYPE(Uint) *text,
		       Eterm t,
		       int *constant)
{
    DMCRet ret;
    Eterm tmp;
    Eterm *p;


    switch (t & _TAG_PRIMARY_MASK) {
    case TAG_PRIMARY_LIST:
	if ((ret = dmc_list(context, heap, text, t, constant)) != retOk)
	    return ret;
	break;
    case TAG_PRIMARY_BOXED:
	if (!BOXED_IS_TUPLE(t)) {
	    goto simple_term;
	}
	p = tuple_val(t);
#ifdef HARDDEBUG
	erts_fprintf(stderr,"%d %d %d %d\n",arityval(*p),is_tuple(tmp = p[1]),
		     is_atom(p[1]),db_is_variable(p[1]));
#endif
	if (arityval(*p) == 1 && is_tuple(tmp = p[1])) {
	    if ((ret = dmc_tuple(context, heap, text, tmp, constant)) != retOk)
		return ret;
	} else if (arityval(*p) >= 1 && is_atom(p[1]) && 
		   !(db_is_variable(p[1]) >= 0)) {
	    if ((ret = dmc_fun(context, heap, text, t, constant)) != retOk)
		return ret;
	} else
	    RETURN_TERM_ERROR("%T is neither a function call, nor a tuple "
			      "(tuples are written {{ ... }}).", t,
			      context, *constant);
	break;
    case TAG_PRIMARY_IMMED1:
	if (db_is_variable(t) >= 0) {
	    if ((ret = dmc_variable(context, heap, text, t, constant)) 
		!= retOk)
		return ret;
	    break;
	} else if (t == am_DollarUnderscore) {
	    if ((ret = dmc_whole_expression(context, heap, text, t, constant)) 
		!= retOk)
		return ret;
	    break;
	} else if (t == am_DollarDollar) {
	    if ((ret = dmc_all_bindings(context, heap, text, t, constant)) 
		!= retOk)
		return ret;
	    break;
	}	    
	/* Fall through */
    default:
    simple_term:
	*constant = 1;
    }
    return retOk;
}

    
static DMCRet compile_guard_expr(DMCContext *context,
				 DMCHeap *heap,
				 DMC_STACK_TYPE(Uint) *text,
				 Eterm l)
{
    DMCRet ret;
    int constant;
    Eterm t;

    if (l != NIL) {
	if (!is_list(l))
	    RETURN_ERROR("Match expression is not a list.", 
			 context, constant);
	if (!(context->is_guard)) {
	    DMC_PUSH(*text, matchCatch);
	}
	while (is_list(l)) {
	    constant = 0;
	    t = CAR(list_val(l));
	    if ((ret = dmc_expr(context, heap, text, t, &constant)) !=
		retOk)
		return ret;
	    if (constant) {
		do_emit_constant(context, text, t);
	    }
	    l = CDR(list_val(l));
	    if (context->is_guard) {
		DMC_PUSH(*text,matchTrue);
	    } else {
		DMC_PUSH(*text,matchWaste);
	    }
	    --context->stack_used;
	}
	if (l != NIL) 
	    RETURN_ERROR("Match expression is not a proper list.",
			 context, constant);
	if (!(context->is_guard) && (context->cflags & DCOMP_TABLE)) {
	    ASSERT(matchWaste == DMC_TOP(*text));
	    (void) DMC_POP(*text);
	    DMC_PUSH(*text, matchReturn); /* Same impact on stack as 
					     matchWaste */
	}
    }
    return retOk;
}




/*
** Match compilation utility code
*/

/*
** Handling of bif's in match guard expressions
*/

static DMCGuardBif *dmc_lookup_bif(Eterm t, int arity)
{
    /*
    ** Place for optimization, bsearch is slower than inlining it...
    */
    DMCGuardBif node = {0,NULL,0};
    node.name = t;
    node.arity = arity;
    return bsearch(&node, 
		   guard_tab, 
		   sizeof(guard_tab) / sizeof(DMCGuardBif),
		   sizeof(DMCGuardBif), 
		   (int (*)(const void *, const void *)) &cmp_guard_bif); 
}

#ifdef DMC_DEBUG
static Eterm dmc_lookup_bif_reversed(void *f)
{
    int i;
    for (i = 0; i < (sizeof(guard_tab) / sizeof(DMCGuardBif)); ++i)
	if (f == guard_tab[i].biff)
	    return guard_tab[i].name;
    return am_undefined;
}
#endif

/* For sorting. */
static int cmp_uint(void *a, void *b) 
{
    if (*((unsigned *)a) <  *((unsigned *)b))
	return -1;
    else
	return (*((unsigned *)a) >  *((unsigned *)b));
}

static int cmp_guard_bif(void *a, void *b)
{
    int ret;
    if (( ret = ((int) atom_val(((DMCGuardBif *) a)->name)) -
	 ((int) atom_val(((DMCGuardBif *) b)->name)) ) == 0) {
	ret = ((DMCGuardBif *) a)->arity - ((DMCGuardBif *) b)->arity;
    }
    return ret;
}

/*
** Compact the variables in a match expression i e make {$1, $100, $1000} 
** become {$0,$1,$2}.
*/
static int match_compact(ErlHeapFragment *expr, DMCErrInfo *err_info)
{
    int i, j, a, n, x;
    DMC_STACK_TYPE(unsigned) heap;
    Eterm *p;
    char buff[25] = "$"; /* large enough for 64 bit to */
    int ret;

    DMC_INIT_STACK(heap);

    p = expr->mem;
    i = expr->size;
    while (i--) {
	if (is_thing(*p)) {
	    a = thing_arityval(*p);
	    ASSERT(a <= i);
	    i -= a;
	    p += a;
	} else if (is_atom(*p) && (n = db_is_variable(*p)) >= 0) {
	    x = DMC_STACK_NUM(heap);
	    for (j = 0; j < x && DMC_PEEK(heap,j) != n; ++j) 
		;
	    
	    if (j == x)
		DMC_PUSH(heap,n);
	}
	++p;
    }
    qsort(DMC_STACK_DATA(heap), DMC_STACK_NUM(heap), sizeof(unsigned), 
	  (int (*)(const void *, const void *)) &cmp_uint);

    if (err_info != NULL) { /* lint needs a translation table */
	err_info->var_trans = erts_alloc(ERTS_ALC_T_DB_TRANS_TAB,
					 sizeof(unsigned)*DMC_STACK_NUM(heap));
	sys_memcpy(err_info->var_trans, DMC_STACK_DATA(heap),
		   DMC_STACK_NUM(heap) * sizeof(unsigned));
	err_info->num_trans = DMC_STACK_NUM(heap);
    }

    p = expr->mem;
    i = expr->size;
    while (i--) {
	if (is_thing(*p)) {
	    a = thing_arityval(*p);
	    i -= a;
	    p += a;
	} else if (is_atom(*p) && (n = db_is_variable(*p)) >= 0) {
	    x = DMC_STACK_NUM(heap);
#ifdef HARDDEBUG
	    erts_fprintf(stderr, "%T");
#endif
	    for (j = 0; j < x && DMC_PEEK(heap,j) != n; ++j) 
		;
	    ASSERT(j < x);
	    sprintf(buff+1,"%u", (unsigned) j);
	    /* Yes, writing directly into terms, they ARE off heap */
	    *p = am_atom_put(buff, strlen(buff));
	}
	++p;
    }
    ret = DMC_STACK_NUM(heap);
    DMC_FREE(heap);
    return ret;
}

/*
** Simple size object that takes care of function calls and constant tuples
*/
static Uint my_size_object(Eterm t) 
{
    Uint sum = 0;
    Eterm tmp;
    Eterm *p;
    switch (t & _TAG_PRIMARY_MASK) {
    case TAG_PRIMARY_LIST:
	sum += 2 + my_size_object(CAR(list_val(t))) + 
	    my_size_object(CDR(list_val(t)));
	break;
    case TAG_PRIMARY_BOXED:
	if ((((*boxed_val(t)) & 
	      _TAG_HEADER_MASK) >> _TAG_PRIMARY_SIZE) !=
	    (_TAG_HEADER_ARITYVAL >> _TAG_PRIMARY_SIZE)) {
	    goto simple_term;
	}

	if (arityval(*tuple_val(t)) == 1 && is_tuple(tmp = tuple_val(t)[1])) {
	    Uint i,n;
	    p = tuple_val(tmp);
	    n = arityval(p[0]);
	    sum += 1 + n;
	    for (i = 1; i <= n; ++i)
		sum += my_size_object(p[i]);
	} else if (arityval(*tuple_val(t)) == 2 &&
		   is_atom(tmp = tuple_val(t)[1]) &&
		   tmp == am_const) {
	    sum += size_object(tuple_val(t)[2]);
	} else {
	    erl_exit(1,"Internal error, sizing unrecognized object in "
		     "(d)ets:match compilation.");
	}
	break;
    default:
    simple_term:
	sum += size_object(t);
	break;
    }
    return sum;
}

static Eterm my_copy_struct(Eterm t, Eterm **hp, ErlOffHeap* off_heap)
{
    Eterm ret = NIL, a, b;
    Eterm *p;
    Uint sz;
    switch (t & _TAG_PRIMARY_MASK) {
    case TAG_PRIMARY_LIST:
	a = my_copy_struct(CAR(list_val(t)), hp, off_heap);
	b = my_copy_struct(CDR(list_val(t)), hp, off_heap);
	ret = CONS(*hp, a, b);
	*hp += 2;
	break;
    case TAG_PRIMARY_BOXED:
	if (BOXED_IS_TUPLE(t)) {
	    if (arityval(*tuple_val(t)) == 1 && 
		is_tuple(a = tuple_val(t)[1])) {
		Uint i,n;
		Eterm *savep = *hp;
		ret = make_tuple(savep);
		p = tuple_val(a);
		n = arityval(p[0]);
		*hp += n + 1;
		*savep++ = make_arityval(n);
		for(i = 1; i <= n; ++i) 
		    *savep++ = my_copy_struct(p[i], hp, off_heap);
	    } else if (arityval(*tuple_val(t)) == 2 && 
		       is_atom(a = tuple_val(t)[1]) &&
		       a == am_const) {
		/* A {const, XXX} expression */
		b = tuple_val(t)[2];
		sz = size_object(b);
		ret = copy_struct(b,sz,hp,off_heap);
	    } else {
		erl_exit(1, "Trying to constant-copy non constant expression "
			 "0x%08x in (d)ets:match compilation.", (unsigned long) t);
	    }
	} else {
	    sz = size_object(t);
	    ret = copy_struct(t,sz,hp,off_heap);
	}
	break;
    default:
	ret = t;
    }
    return ret;
}

static Binary *allocate_magic_binary(size_t size)
{
    Binary* bptr;
    bptr = erts_bin_nrml_alloc(size);
    bptr->flags = BIN_FLAG_MATCH_PROG;
    bptr->orig_size = size;
    erts_refc_init(&bptr->refc, 0);
    return bptr;
}
    


/*
** Compiled match bif interface
*/
/*
** erlang:match_spec_test(MatchAgainst, MatchSpec, Type) -> 
**   {ok, Return, Flags, Errors} | {error, Errors}
** MatchAgainst -> if Type == trace: list() else tuple()
** MatchSpec -> MatchSpec with body corresponding to Type
** Type -> trace | table (only trace implemented in R5C)
** Return -> if Type == trace TraceReturn else {BodyReturn, VariableBindings}
** TraceReturn -> {true | false | term()} 
** BodyReturn -> term()
** VariableBindings -> [term(), ...] 
** Errors -> [OneError, ...]
** OneError -> {error, string()} | {warning, string()}
** Flags -> [Flag, ...]
** Flag -> return_trace (currently only flag)
*/
BIF_RETTYPE match_spec_test_3(BIF_ALIST_3)
{
    Eterm res;
#ifdef DMC_DEBUG
    if (BIF_ARG_3 == am_atom_put("dis",3)) {
	test_disassemble_next = 1;
	BIF_RET(am_true);
    } else
#endif
    if (BIF_ARG_3 == am_trace) {
	res = match_spec_test(BIF_P, BIF_ARG_1, BIF_ARG_2, 1);
	if (is_value(res)) {
	    BIF_RET(res);
	}
    } else if (BIF_ARG_3 == am_table) {
	res = match_spec_test(BIF_P, BIF_ARG_1, BIF_ARG_2, 0);
	if (is_value(res)) {
	    BIF_RET(res);
	}
    } 
    BIF_ERROR(BIF_P, BADARG);
}

static Eterm match_spec_test(Process *p, Eterm against, Eterm spec, int trace)
{
    Eterm lint_res;
    Binary *mps;
    Eterm res;
    Eterm ret;
    Eterm flg;
    Eterm *hp;
    Eterm *arr;
    int n;
    Eterm l;
    Uint32 ret_flags;
    Uint sz;
    Eterm *save_cp;

    if (trace && !(is_list(against) || against == NIL)) {
	return THE_NON_VALUE;
    }
    if (trace) {
	lint_res = db_match_set_lint(p, spec, DCOMP_TRACE | DCOMP_FAKE_DESTRUCTIVE);
	mps = db_match_set_compile(p, spec, DCOMP_TRACE | DCOMP_FAKE_DESTRUCTIVE);
    } else {
	lint_res = db_match_set_lint(p, spec, DCOMP_TABLE | DCOMP_FAKE_DESTRUCTIVE);
	mps = db_match_set_compile(p, spec, DCOMP_TABLE | DCOMP_FAKE_DESTRUCTIVE);
    }
    
    if (mps == NULL) {
	hp = HAlloc(p,3);
	ret = TUPLE2(hp, am_error, lint_res);
    } else {
#ifdef DMC_DEBUG
	if (test_disassemble_next) {
	    test_disassemble_next = 0;
	    db_match_dis(mps);
	}
#endif /* DMC_DEBUG */
	l = against;
	n = 0;
	while (is_list(l)) {
	    ++n;
	    l = CDR(list_val(l));
	}
	if (trace) {
	    if (n)
		arr = erts_alloc(ERTS_ALC_T_DB_TMP, sizeof(Eterm) * n);
	    else 
		arr = NULL;
	    l = against;
	    n = 0;
	    while (is_list(l)) {
		arr[n] = CAR(list_val(l));
		++n;
		l = CDR(list_val(l));
	    }
	} else {
	    n = 0;
	    arr = (Eterm *) against;
	}
	
	/* We are in the context of a BIF, 
	   {caller} should return 'undefined' */
	save_cp = p->cp;
	p->cp = NULL;
	res = erts_match_set_run(p, mps, arr, n, &ret_flags);
	p->cp = save_cp;
	if (is_non_value(res)) {
	    res = am_false;
	}
	sz = size_object(res);
	if (ret_flags & MATCH_SET_EXCEPTION_TRACE) sz += 2;
	if (ret_flags & MATCH_SET_RETURN_TRACE) sz += 2;
	hp = HAlloc(p, 5 + sz);
	res = copy_struct(res, sz, &hp, &MSO(p));
	flg = NIL;
	if (ret_flags & MATCH_SET_EXCEPTION_TRACE) {
	    flg = CONS(hp, am_exception_trace, flg);
	    hp += 2;
	}
	if (ret_flags & MATCH_SET_RETURN_TRACE) {
	    flg = CONS(hp, am_return_trace, flg);
	    hp += 2;
	}
	if (trace && arr != NULL) {
	    erts_free(ERTS_ALC_T_DB_TMP, arr);
	}
	erts_match_set_free(mps);
	ret = TUPLE4(hp, am_atom_put("ok",2), res, flg, lint_res);
    }
    return ret;
}

static Eterm seq_trace_fake(Process *p, Eterm arg1)
{
    Eterm result = seq_trace_info_1(p,arg1);
    if (is_tuple(result) && *tuple_val(result) == 2) {
	return (tuple_val(result))[2];
    }
    return result;
}
    
#ifdef DMC_DEBUG
/*
** Disassemble match program
*/
static void db_match_dis(Binary *bp)
{
    MatchProg *prog = Binary2MatchProg(bp);
    Uint *t = prog->text;
    Uint n;
    Eterm p;
    int first;
    ErlHeapFragment *tmp;

    while (t < prog->labels) {
	switch (*t) {
	case matchTryMeElse:
	    ++t;
	    n = *t;
	    ++t;
	    erts_printf("TryMeElse\t%bpu\n", n);
	    break;
	case matchArray:
	    ++t;
	    n = *t;
	    ++t;
	    erts_printf("Array\t%bpu\n", n);
	    break;
	case matchArrayBind:
	    ++t;
	    n = *t;
	    ++t;
	    erts_printf("ArrayBind\t%bpu\n", n);
	    break;
	case matchTuple:
	    ++t;
	    n = *t;
	    ++t;
	    erts_printf("Tuple\t%bpu\n", n);
	    break;
	case matchPushT:
	    ++t;
	    n = *t;
	    ++t;
	    erts_printf("PushT\t%bpu\n", n);
	    break;
	case matchPushL:
	    ++t;
	    erts_printf("PushL\n");
	    break;
	case matchPop:
	    ++t;
	    erts_printf("Pop\n");
	    break;
	case matchBind:
	    ++t;
	    n = *t;
	    ++t;
	    erts_printf("Bind\t%bpu\n", n);
	    break;
	case matchCmp:
	    ++t;
	    n = *t;
	    ++t;
	    erts_printf("Cmp\t%bpu\n", n);
	    break;
	case matchEqBin:
	    ++t;
	    p = (Eterm) *t;
	    ++t;
	    erts_printf("EqBin\t%p (%T)\n", t, p);
	    break;
	case matchEqRef:
	    ++t;
	    n = thing_arityval(*t);
	    ++t;
	    erts_printf("EqRef\t(%d) {", (int) n);
	    first = 1;
	    while (n--) {
		if (first)
		    first = 0;
		else
		    erts_printf(", ");
#ifdef ARCH_64
		erts_printf("0x%016bpx", *t);
#else
		erts_printf("0x%08bpx", *t);
#endif
		++t;
	    }
	    erts_printf("}\n");
	    break;
	case matchEqBig:
	    ++t;
	    n = thing_arityval(*t);
	    ++t;
	    erts_printf("EqBig\t(%d) {", (int) n);
	    first = 1;
	    while (n--) {
		if (first)
		    first = 0;
		else
		    erts_printf(", ");
#ifdef ARCH_64
		erts_printf("0x%016bpx", *t);
#else
		erts_printf("0x%08bpx", *t);
#endif
		++t;
	    }
	    erts_printf("}\n");
	    break;
	case matchEqFloat:
	    ++t;
	    {
		double num;
		memcpy(&num,t, 2 * sizeof(*t));
		t += 2;
		erts_printf("EqFloat\t%f\n", num);
	    }
	    break;
	case matchEq:
	    ++t;
	    p = (Eterm) *t;
	    ++t;
	    erts_printf("Eq  \t%T\n", p);
	    break;
	case matchList:
	    ++t;
	    erts_printf("List\n");
	    break;
	case matchHalt:
	    ++t;
	    erts_printf("Halt\n");
	    break;
	case matchSkip:
	    ++t;
	    erts_printf("Skip\n");
	    break;
	case matchPushC:
	    ++t;
	    p = (Eterm) *t;
	    ++t;
	    erts_printf("PushC\t%T\n", p);
	    break;
	case matchConsA:
	    ++t;
	    erts_printf("ConsA\n");
	    break;
	case matchConsB:
	    ++t;
	    erts_printf("ConsB\n");
	    break;
	case matchMkTuple:
	    ++t;
	    n = *t;
	    ++t;
	    erts_printf("MkTuple\t%bpu\n", n);
	    break;
	case matchOr:
	    ++t;
	    n = *t;
	    ++t;
	    erts_printf("Or\t%bpu\n", n);
	    break;
	case matchAnd:
	    ++t;
	    n = *t;
	    ++t;
	    erts_printf("And\t%bpu\n", n);
	    break;
	case matchOrElse:
	    ++t;
	    n = *t;
	    ++t;
	    erts_printf("OrElse\t%bpu\n", n);
	    break;
	case matchAndThen:
	    ++t;
	    n = *t;
	    ++t;
	    erts_printf("AndThen\t%bpu\n", n);
	    break;
	case matchCall0:
	    ++t;
	    p = dmc_lookup_bif_reversed((void *) *t);
	    ++t;
	    erts_printf("Call0\t%T\n", p);
	    break;
	case matchCall1:
	    ++t;
	    p = dmc_lookup_bif_reversed((void *) *t);
	    ++t;
	    erts_printf("Call1\t%T\n", p);
	    break;
	case matchCall2:
	    ++t;
	    p = dmc_lookup_bif_reversed((void *) *t);
	    ++t;
	    erts_printf("Call2\t%T\n", p);
	    break;
	case matchCall3:
	    ++t;
	    p = dmc_lookup_bif_reversed((void *) *t);
	    ++t;
	    erts_printf("Call3\t%T\n", p);
	    break;
	case matchPushV:
	    ++t;
	    n = (Uint) *t;
	    ++t;
	    erts_printf("PushV\t%bpu\n", n);
	    break;
	case matchTrue:
	    ++t;
	    erts_printf("True\n");
	    break;
	case matchPushExpr:
	    ++t;
	    erts_printf("PushExpr\n");
	    break;
	case matchPushArrayAsList:
	    ++t;
	    erts_printf("PushArrayAsList\n");
	    break;
	case matchPushArrayAsListU:
	    ++t;
	    erts_printf("PushArrayAsListU\n");
	    break;
	case matchSelf:
	    ++t;
	    erts_printf("Self\n");
	    break;
	case matchWaste:
	    ++t;
	    erts_printf("Waste\n");
	    break;
	case matchReturn:
	    ++t;
	    erts_printf("Return\n");
	    break;
	case matchProcessDump:
	    ++t;
	    erts_printf("ProcessDump\n");
	    break;
	case matchDisplay:
	    ++t;
	    erts_printf("Display\n");
	    break;
	case matchIsSeqTrace:
	    ++t;
	    erts_printf("IsSeqTrace\n");
	    break;
	case matchSetSeqToken:
	    ++t;
	    erts_printf("SetSeqToken\n");
	    break;
	case matchSetSeqTokenFake:
	    ++t;
	    erts_printf("SetSeqTokenFake\n");
	    break;
	case matchGetSeqToken:
	    ++t;
	    erts_printf("GetSeqToken\n");
	    break;
	case matchSetReturnTrace:
	    ++t;
	    erts_printf("SetReturnTrace\n");
	    break;
	case matchSetExceptionTrace:
	    ++t;
	    erts_printf("SetReturnTrace\n");
	    break;
	case matchCatch:
	    ++t;
	    erts_printf("Catch\n");
	    break;
	case matchEnableTrace:
	    ++t;
	    erts_printf("EnableTrace\n");
	    break;
	case matchDisableTrace:
	    ++t;
	    erts_printf("DisableTrace\n");
	    break;
	case matchEnableTrace2:
	    ++t;
	    erts_printf("EnableTrace2\n");
	    break;
	case matchDisableTrace2:
	    ++t;
	    erts_printf("DisableTrace2\n");
	    break;
	case matchTrace2:
	    ++t;
	    erts_printf("Trace2\n");
	    break;
	case matchTrace3:
	    ++t;
	    erts_printf("Trace3\n");
	    break;
 	case matchCaller:
 	    ++t;
 	    erts_printf("Caller\n");
 	    break;
	default:
	    erts_printf("??? (0x%08x)\n", *t);
	    ++t;
	    break;
	}
    }
    erts_printf("\n\nterm_save: {");
    first = 1;
    for (tmp = prog->term_save; tmp; tmp = tmp->next) {
	if (first)
	    first = 0;
	else
	    erts_printf(", ");
	erts_printf("0x%08x", (unsigned long) tmp);
    }
    erts_printf("}\n");
    erts_printf("num_bindings: %d\n", prog->num_bindings);
    erts_printf("heap_size: %bpu\n", prog->heap_size);
    erts_printf("eheap_offset: %bpu\n", prog->eheap_offset);
    erts_printf("stack_offset: %bpu\n", prog->stack_offset);
    erts_printf("labels: 0x%08x\n", (unsigned long) prog->labels);
    t = prog->labels;
    for (n = 0; n < prog->label_size; ++n) {
	erts_printf("labels[%d] = %d\n", (int) n, (int) *t);
	++t;
    }
    erts_printf("text: 0x%08x\n", (unsigned long) prog->text);
    erts_printf("stack_size: %d (words)\n", prog->heap_size-prog->stack_offset);
    
}

#endif /* DMC_DEBUG */


