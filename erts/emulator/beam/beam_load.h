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
#include "beam_opcodes.h"

Eterm exported_from_module(Process* p, Eterm mod);
Eterm functions_in_module(Process* p, Eterm mod);
Eterm attributes_for_module(Process* p, Eterm mod);
Eterm compilation_info_for_module(Process* p, Eterm mod);
int beam_make_current_old(Eterm module);

typedef struct gen_op_entry {
   char* name;
   int arity;
   int specific;
   int num_specific;
   int transform;
   int min_window;
} GenOpEntry;

extern GenOpEntry gen_opc[];
extern void** beam_ops;

extern Eterm beam_debug_apply[];
extern Eterm* em_call_error_handler;
extern Eterm* em_apply_bif;

typedef struct {
    Eterm* start;		/* Pointer to start of module. */
    Eterm* end;			/* Points one word beyond last function in module. */
} Range;

/*
 * The following variables keep a sorted list of address ranges for
 * each module.  It allows us to quickly find a function given an
 * instruction pointer.
 */

extern Range* modules;
extern int num_loaded_modules;
extern int allocated_modules;

/*
 * Index into start of code chunks which contains additional information
 * about the loaded module.
 *
 * First number of functions.
 */

#define MI_NUM_FUNCTIONS     0

/*
 * The attributes retrieved by Mod:module_info(attributes).
 */

#define MI_ATTR_PTR          1
#define MI_ATTR_SIZE_ON_HEAP 2

/*
 * The compilation information retrieved by Mod:module_info(compile).
 */

#define MI_COMPILE_PTR          3
#define MI_COMPILE_SIZE_ON_HEAP 4

#define MI_LAMBDA_PTR		5
#define MI_NUM_LAMBDAS		6

/*
 * Start of function pointer table.  This table contains pointers to
 * all functions in the module plus an additional pointer just beyoynd
 * the end of the last functioin.
 *
 * The actual loaded code (for the first function) start just beyond
 * this table.
 */

#define MI_FUNCTIONS         7
