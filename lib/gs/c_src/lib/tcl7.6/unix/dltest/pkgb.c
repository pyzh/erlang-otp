/* 
 * pkgb.c --
 *
 *	This file contains a simple Tcl package "pkgb" that is intended
 *	for testing the Tcl dynamic loading facilities.  It can be used
 *	in both safe and unsafe interpreters.
 *
 * Copyright (c) 1995 Sun Microsystems, Inc.
 *
 * See the file "license.terms" for information on usage and redistribution
 * of this file, and for a DISCLAIMER OF ALL WARRANTIES.
 *
 * SCCS: @(#) pkgb.c 1.4 96/02/15 12:30:34
 */
#include "tcl.h"

/*
 * Prototypes for procedures defined later in this file:
 */

#ifdef __cplusplus
#   define dummy1 /* */
#   define dummy2 /* */
#   define dummy3 /* */
#endif

static int	Pkgb_SubCmd _ANSI_ARGS_((ClientData dummy1,
		    Tcl_Interp *interp, int argc, char **argv));
static int	Pkgb_UnsafeCmd _ANSI_ARGS_((ClientData dummy1,
		    Tcl_Interp *interp, int dummy2, char **dummy3));


/*
 *----------------------------------------------------------------------
 *
 * Pkgb_SubCmd --
 *
 *	This procedure is invoked to process the "pkgb_sub" Tcl command.
 *	It expects two arguments and returns their difference.
 *
 * Results:
 *	A standard Tcl result.
 *
 * Side effects:
 *	See the user documentation.
 *
 *----------------------------------------------------------------------
 */

static int
#ifdef _USING_PROTOTYPES_
Pkgb_SubCmd (
    ClientData dummy1,			/* Not used. */
    Tcl_Interp *interp,			/* Current interpreter. */
    int argc,				/* Number of arguments. */
    char **argv)			/* Argument strings. */
#else
Pkgb_SubCmd(dummy1, interp, argc, argv)
    ClientData dummy1;			/* Not used. */
    Tcl_Interp *interp;			/* Current interpreter. */
    int argc;				/* Number of arguments. */
    char **argv;			/* Argument strings. */
#endif
{
    int first, second;

    if (argc != 3) {
	Tcl_AppendResult(interp, "wrong # args: should be \"", argv[0],
		" num num\"", (char *) NULL);
	return TCL_ERROR;
    }
    if ((Tcl_GetInt(interp, argv[1], &first) != TCL_OK)
	    || (Tcl_GetInt(interp, argv[2], &second) != TCL_OK)) {
	return TCL_ERROR;
    }
    sprintf(interp->result, "%d", first - second);
    return TCL_OK;
}

/*
 *----------------------------------------------------------------------
 *
 * Pkgb_UnsafeCmd --
 *
 *	This procedure is invoked to process the "pkgb_unsafe" Tcl command.
 *	It just returns a constant string.
 *
 * Results:
 *	A standard Tcl result.
 *
 * Side effects:
 *	See the user documentation.
 *
 *----------------------------------------------------------------------
 */

static int
#ifdef _USING_PROTOTYPES_
Pkgb_UnsafeCmd (
    ClientData dummy1,			/* Not used. */
    Tcl_Interp *interp,			/* Current interpreter. */
    int dummy2,				/* Not used. */
    char **dummy3)			/* Not used. */
#else
Pkgb_UnsafeCmd (dummy1, interp, dummy2, dummy3)
    ClientData dummy1;			/* Not used. */
    Tcl_Interp *interp;			/* Current interpreter. */
    int dummy2;				/* Not used. */
    char **dummy3;			/* Not used. */
#endif
{
    interp->result = "unsafe command invoked";
    return TCL_OK;
}

/*
 *----------------------------------------------------------------------
 *
 * Pkgb_Init --
 *
 *	This is a package initialization procedure, which is called
 *	by Tcl when this package is to be added to an interpreter.
 *
 * Results:
 *	None.
 *
 * Side effects:
 *	None.
 *
 *----------------------------------------------------------------------
 */

int
#ifdef _USING_PROTOTYPES_
Pkgb_Init (
    Tcl_Interp *interp)		/* Interpreter in which the package is
				 * to be made available. */
#else
Pkgb_Init(interp)
    Tcl_Interp *interp;		/* Interpreter in which the package is
				 * to be made available. */
#endif
{
    int code;

    code = Tcl_PkgProvide(interp, "Pkgb", "2.3");
    if (code != TCL_OK) {
	return code;
    }
    Tcl_CreateCommand(interp, "pkgb_sub", Pkgb_SubCmd, (ClientData) 0,
	    (Tcl_CmdDeleteProc *) NULL);
    Tcl_CreateCommand(interp, "pkgb_unsafe", Pkgb_UnsafeCmd, (ClientData) 0,
	    (Tcl_CmdDeleteProc *) NULL);
    return TCL_OK;
}

/*
 *----------------------------------------------------------------------
 *
 * Pkgb_SafeInit --
 *
 *	This is a package initialization procedure, which is called
 *	by Tcl when this package is to be added to an unsafe interpreter.
 *
 * Results:
 *	None.
 *
 * Side effects:
 *	None.
 *
 *----------------------------------------------------------------------
 */

int
#ifdef _USING_PROTOTYPES_
Pkgb_SafeInit (
    Tcl_Interp *interp)		/* Interpreter in which the package is
				 * to be made available. */
#else
Pkgb_SafeInit(interp)
    Tcl_Interp *interp;		/* Interpreter in which the package is
				 * to be made available. */
#endif
{
    Tcl_CreateCommand(interp, "pkgb_sub", Pkgb_SubCmd, (ClientData) 0,
	    (Tcl_CmdDeleteProc *) NULL);
    return TCL_OK;
}
