/* 
 * tclWinTest.c --
 *
 *	Contains commands for platform specific tests on Windows.
 *
 * Copyright (c) 1996 Sun Microsystems, Inc.
 *
 * See the file "license.terms" for information on usage and redistribution
 * of this file, and for a DISCLAIMER OF ALL WARRANTIES.
 *
 * SCCS: @(#) tclWinTest.c 1.1 96/03/26 12:50:46
 */

#include "tclInt.h"
#include "tclPort.h"

/*
 * Forward declarations of procedures defined later in this file:
 */
int			TclplatformtestInit _ANSI_ARGS_((Tcl_Interp *interp));

/*
 *----------------------------------------------------------------------
 *
 * TclplatformtestInit --
 *
 *	Defines commands that test platform specific functionality for
 *	Windows platforms.
 *
 * Results:
 *	A standard Tcl result.
 *
 * Side effects:
 *	Defines new commands.
 *
 *----------------------------------------------------------------------
 */

int
#ifdef _USING_PROTOTYPES_
TclplatformtestInit(
    Tcl_Interp *interp)		/* Interpreter to add commands to. */
#else
TclplatformtestInit(interp)
    Tcl_Interp *interp;		/* Interpreter to add commands to. */
#endif
{
    if (Tcl_PkgRequire(interp, "Tcl", TCL_VERSION, 1) == NULL) {
	return TCL_ERROR;
    }
    if (Tcl_PkgProvide(interp, "Tclptest", TCL_VERSION) != TCL_OK) {
        return TCL_ERROR;
    }
    /*
     * Add commands for platform specific tests for Windows here.
     */
    
    return TCL_OK;
}

/*
 *----------------------------------------------------------------------
 *
 * Tclptest_Init --
 *
 *	Defines commands that test platform specific functionality for
 *	Windows platforms.
 *
 * Results:
 *	A standard Tcl result.
 *
 * Side effects:
 *	Defines new commands.
 *
 *----------------------------------------------------------------------
 */

int
#ifdef _USING_PROTOTYPES_
Tclptest_Init (
    Tcl_Interp *interp)		/* Interpreter to add commands to. */
#else
Tclptest_Init(interp)
    Tcl_Interp *interp;		/* Interpreter to add commands to. */
#endif
{
    return TclplatformtestInit(interp);
}
