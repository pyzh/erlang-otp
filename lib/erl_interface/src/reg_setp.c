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
#include <stdlib.h>
#include "eihash.h"
#include "eireg.h"

extern ei_reg_obj *ei_reg_make(ei_reg *reg, int attr);

extern int ei_reg_setpval(ei_reg *reg, const char *key, const void *p, 
		      int size)
{
  ei_hash *tab;
  ei_reg_obj *obj=NULL;

  if (size < 0) return -1;
  if (!key || !reg) return -1; /* return EI_BADARG; */
  tab = reg->tab;

  if ((obj=ei_hash_lookup(tab,key))) {
    /* object with same name already exists */
    switch (ei_reg_typeof(obj)) {
    case EI_INT:
      break;
    case EI_FLT:
      break;
    case EI_STR:
      if (obj->size > 0) free(obj->val.s);
      break;
    case EI_BIN:
      if (obj->size > 0) free(obj->val.p);
      break;
    default:
      return -1;
      /* return EI_UNKNOWN; */
    }
  }
  else {
    /* object is new */
    if (!(obj=ei_reg_make(reg,EI_BIN))) return -1; /* return EI_NOMEM; */
    ei_hash_insert(tab,key,obj);
  }

  obj->attr = EI_BIN | EI_DIRTY;
  obj->val.p=(void *)p;
  obj->size=size;

  return 0;
}
