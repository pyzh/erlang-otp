/*
 * tkImgXPM.c --
 *
 *	A photo image file handler for XPM files.
 *
 * Written by:
 *	Jan Nijtmans
 *	NICI (Nijmegen Institute of Cognition and Information)
 *	email: nijtmans@nici.kun.nl
 *	url:   http://www.cogsci.kun.nl/~nijtmans/
 *
 * (with some code stolen from the XPM image type and the GIF handler)
 *
 *
 * <mweilguni@sime.com> Mario Weilguni
 * Jan 1997:
 *      - fixed a bug when reading images with invalid color tables 
 *        (if a pixelchar is not in the colormap)
 *      - added FileWriteXPM, StringWriteXPM and WriteXPM 
 *        (there's a modification in tkImgPhoto.c and tk.h you 
 *        need for these functions. Look for function TkPhotoGetMask)
 *      - modified FileReadXPM, ReadXPM and added StringReadXPM
 *        This makes the XPM reader complete :-)
 *        
 *
 * SCCS: @(#) tkImgXPM.c 0.1 96/11/22 13:56:24
 */

#include "tcl.h"
#include "tk.h"
#include <stdio.h>
#include <ctype.h>
#include <stdlib.h>

#ifdef __WIN32__
#define strncasecmp strnicmp
#endif

#ifndef MAC_TCL
#include <sys/types.h>
#endif

extern int	strncasecmp _ANSI_ARGS_((CONST char *s1,
			    CONST char *s2, size_t n));
extern int	strncmp _ANSI_ARGS_((CONST char *s1, CONST char *s2,
			    size_t nChars));
extern char *	strchr _ANSI_ARGS_((CONST char *string, int c));
extern char *	strstr _ANSI_ARGS_((CONST char *string,
			    CONST char *substring));
extern char *	strrchr _ANSI_ARGS_((CONST char *string, int c));

/* constants used only in this file */

#define XPM_MONO		1
#define XPM_GRAY_4		2
#define XPM_GRAY		3
#define XPM_COLOR		4
#define XPM_SYMBOLIC		5
#define XPM_UNKNOWN		6

#define MAX_BUFFER 4096

/*
 * This structure is needed to access strings in the same 
 * way as a file
 */
typedef struct XPM_DString {
  char *data;  /* the data string          */
  char *p;     /* character at current pos */
} XPM_DString;

/*
 * The format record for the XPM file format:
 */

static int		FileMatchXPM _ANSI_ARGS_((FILE *f, char *fileName,
			    char *formatString, int *widthPtr,
			    int *heightPtr));
static int      	StringMatchXPM _ANSI_ARGS_(( char *string,
		            char *formatString, int *widthPtr, int *heightPtr));
static int	        StringReadXPM _ANSI_ARGS_((Tcl_Interp *interp,
			    char *string, char *formatString,
              		    Tk_PhotoHandle imageHandle, int destX, int destY,
		            int width, int height, int srcX, int srcY));
static int		FileReadXPM  _ANSI_ARGS_((Tcl_Interp *interp,
			    FILE *f, char *fileName, char *formatString,
			    Tk_PhotoHandle imageHandle, int destX, int destY,
			    int width, int height, int srcX, int srcY));
static int		ReadXPM _ANSI_ARGS_((Tcl_Interp *interp, FILE *f,
			    char *fileName, XPM_DString *dataPtr,
			    char *formatString, Tk_PhotoHandle imageHandle,
			    int destX, int destY, int width, int height,
			    int srcX, int srcY));
static int	        StringWriteXPM _ANSI_ARGS_((Tcl_Interp *interp,
               		    Tcl_DString *dataPtr, char *formatString,
		            Tk_PhotoImageBlock *blockPtr));
static int              FileWriteXPM _ANSI_ARGS_((Tcl_Interp *interp,
                            char *fileName, char *formatString,
                            Tk_PhotoImageBlock *blockPtr));
static int		WriteXPM _ANSI_ARGS_((Tcl_Interp *interp,
			    char *fileName, Tcl_DString *dataPtr, char *formatString,
			    Tk_PhotoImageBlock *blockPtr));

Tk_PhotoImageFormat tkImgFmtXPM = {
    "XPM",			/* name */
    FileMatchXPM,		/* fileMatchProc */
    StringMatchXPM,		/* stringMatchProc */
    FileReadXPM,		/* fileReadProc */
    StringReadXPM,		/* stringReadProc */
    FileWriteXPM,		/* fileWriteProc */
    StringWriteXPM,		/* stringWriteProc */
};

/*
 * Prototypes for local procedures defined in this file:
 */

static int	ReadXPMFileHeader _ANSI_ARGS_((FILE *f, 
			XPM_DString *dataPtr, int *widthPtr,
			int *heightPtr, int *numColors, int *byteSize));
static char *	GetType _ANSI_ARGS_((char *colorDefn, int *type_ret));
static char *	GetColor _ANSI_ARGS_((char *colorDefn, char *colorName, int *type_ret));
static char *	Gets _ANSI_ARGS_((char *buffer, int size, FILE *f, XPM_DString *dataPtr));

/*
 *----------------------------------------------------------------------
 * Gets
 *
 *      Allows other routines to get their data from files as well
 *      as Tcl_DStrings. If FILE *f == NULL, then data is fetched
 *      from dataPtr, otherwise data is read from FILE *f via fgets().
 *
 * Results:
 *      same as fgets: NULL pointer on any error, otherwise
 *      it returns buffer
 *
 * Side effects:
 *      The access position of the file changes OR
 *      The access pointer dataPtr->p is changed
 *
 *----------------------------------------------------------------------
 */

static char *
Gets(buffer, size, f, dataPtr) 
    char *buffer;
    int size;
    FILE *f;
    struct XPM_DString *dataPtr;
{
    char *p;

    if (f != (FILE *)NULL) {
	/* read data from file */
	return fgets(buffer, size, f);
    } else {
	/* emulate premature EOF */
	if (*dataPtr->p == 0) {
	    return (char *)NULL;
	}

	p = buffer;
	size--;
	while(size--) {
	    if (*dataPtr->p == 0) {
		*p = 0;
		return buffer;
	    } else {
		if (*dataPtr->p == '\n') {
		    *p++ = *dataPtr->p++;
		    *p = 0;
		    return buffer;
		}
	    }
	    *p++ = *dataPtr->p++;
	}
	*p = 0;
	return buffer;
    }
}


/*
 *----------------------------------------------------------------------
 *
 * StringMatchXPM --
 *
 *	This procedure is invoked by the photo image type to see if
 *	a datastring contains image data in XPM format.
 *
 * Results:
 *	The return value is >0 if the first characters in data look
 *	like XPM data, and 0 otherwise.
 *
 * Side effects:
 *	none
 *
 *----------------------------------------------------------------------
 */
static int
StringMatchXPM(string, formatString, widthPtr, heightPtr)
    char *string;               /* The data supplied by the image */
    char *formatString;		/* User-specified format string, or NULL. */
    int *widthPtr, *heightPtr;	/* The dimensions of the image are
				 * returned here if the file is a valid
				 * raw XPM file. */
{
    struct XPM_DString d;
    int numColors, byteSize;

    d.data = string;
    d.p = string;
    return ReadXPMFileHeader(NULL, &d, widthPtr, heightPtr, &numColors, &byteSize);
}


/*
 *----------------------------------------------------------------------
 *
 * FileMatchXPM --
 *
 *	This procedure is invoked by the photo image type to see if
 *	a file contains image data in XPM format.
 *
 * Results:
 *	The return value is >0 if the first characters in file "f" look
 *	like XPM data, and 0 otherwise.
 *
 * Side effects:
 *	The access position in f may change.
 *
 *----------------------------------------------------------------------
 */

static int
FileMatchXPM(f, fileName, formatString, widthPtr, heightPtr)
    FILE *f;			/* The image file, open for reading. */
    char *fileName;		/* The name of the image file. */
    char *formatString;		/* User-specified format string, or NULL. */
    int *widthPtr, *heightPtr;	/* The dimensions of the image are
				 * returned here if the file is a valid
				 * raw XPM file. */
{
    int numColors, byteSize;
    return ReadXPMFileHeader(f, NULL, widthPtr, heightPtr, &numColors, &byteSize);
}


/*
 *----------------------------------------------------------------------
 *
 * ReadXPM --
 *
 *	This procedure is called by the photo image type to read
 *	XPM format data from a file or string and write it into a
 *	given photo image.
 *
 * Results:
 *	A standard TCL completion code.  If TCL_ERROR is returned
 *	then an error message is left in interp->result.
 *
 * Side effects:
 *	The access position in file f is changed (if read from file)
 *	and new data is added to the image given by imageHandle.
 *
 *----------------------------------------------------------------------
 */

typedef struct myblock {
    Tk_PhotoImageBlock pub;
    int dummy; /* extra space for offset[3], if not included already
		  in Tk_PhotoImageBlock */
} myblock;

static int
ReadXPM(interp, f, fileName, dataPtr, formatString, imageHandle, destX, destY,
	width, height, srcX, srcY)
    Tcl_Interp *interp;		/* Interpreter to use for reporting errors. */
    FILE *f;			/* The image file, open for reading. */
    char *fileName;		/* The name of the image file. */
    struct XPM_DString *dataPtr;
    char *formatString;		/* User-specified format string, or NULL. */
    Tk_PhotoHandle imageHandle;	/* The photo image to write into. */
    int destX, destY;		/* Coordinates of top-left pixel in
				 * photo image to be written to. */
    int width, height;		/* Dimensions of block of photo image to
				 * be written to. */
    int srcX, srcY;		/* Coordinates of top-left pixel to be used
				 * in image being read. */
{
    int fileWidth = 0, fileHeight = 0, numColors = 0, byteSize = 0;
    int h, type;
    unsigned char *pixelPtr;
    myblock block;
    Tcl_HashTable colorTable;
    Tk_Window tkwin = Tk_MainWindow(interp);
    Display *display = Tk_Display(tkwin);
    Colormap colormap = Tk_Colormap(tkwin);
    int depth = Tk_Depth(tkwin);
    char *p;
    char buffer[MAX_BUFFER];
    int i, isMono;
    int color1;
    unsigned int data;
    Tcl_HashEntry *hPtr;

    Tcl_InitHashTable(&colorTable, TCL_ONE_WORD_KEYS);

    switch ((Tk_Visual(tkwin))->class) {
      case StaticGray:
      case GrayScale:
	isMono = 1;
	break;
      default:
	isMono = 0;
    }

    type = ReadXPMFileHeader(f, dataPtr, &fileWidth, &fileHeight, &numColors, &byteSize);
    if (type == 0) {
	Tcl_AppendResult(interp, "couldn't read raw XPM header from file \"",
		fileName, "\"", NULL);
	return TCL_ERROR;
    }
    if ((fileWidth <= 0) || (fileHeight <= 0)) {
	Tcl_AppendResult(interp, "XPM image file \"", fileName,
		"\" has dimension(s) <= 0", (char *) NULL);
	return TCL_ERROR;
    }
    if ((byteSize < 1) || (byteSize > 4)) {
	Tcl_AppendResult(interp, "XPM image file \"", fileName,
		"\" has invalid byte size (should be 1, 2, 3 or 4)", (char *) NULL);
	return TCL_ERROR;
    }

    if ((srcX + width) > fileWidth) {
	width = fileWidth - srcX;
    }
    if ((srcY + height) > fileHeight) {
	height = fileHeight - srcY;
    }
    if ((width <= 0) || (height <= 0)
	|| (srcX >= fileWidth) || (srcY >= fileHeight)) {
	return TCL_OK;
    }

    for (i=0; i<numColors; i++) {
	char * colorDefn;		/* the color definition line */
	char * colorName;		/* temp place to hold the color name
					 * defined for one type of visual */
	char * useName;			/* the color name used for this
					 * color. If there are many names
					 * defined, choose the name that is
					 * "best" for the target visual
					 */
	XColor color;
	int found;

	p = Gets(buffer,MAX_BUFFER,f,dataPtr);
	while (((p = strchr(p,'\"')) == NULL) || ((strstr(p,"/*")) != NULL)) {
	    p = Gets(buffer,MAX_BUFFER,f,dataPtr);
	    if (p == NULL) {
		return TCL_ERROR;
	    }
	    p = buffer;
	}
	colorDefn = p + byteSize + 1;
	colorName = (char*)ckalloc(strlen(colorDefn));
	useName   = (char*)ckalloc(strlen(colorDefn));
	found     = 0;
	color1 = 0;
	data = 0;

	while (colorDefn && *colorDefn) {
	    int type;

	    if ((colorDefn=GetColor(colorDefn, colorName, &type)) == NULL) {
		break;
	    }
	    if (colorName[0] == '\0') {
		continue;
	    }

	    switch (type) {
	      case XPM_MONO:
		if (isMono && depth == 1) {
		    strcpy(useName, colorName);
		    found = 1; goto gotcolor;
		}
		break;
	      case XPM_GRAY_4:
		if (isMono && depth == 4) {
		    strcpy(useName, colorName);
		    found = 1; goto gotcolor;
		}
		break;
	      case XPM_GRAY:
		if (isMono && depth > 4) {
		    strcpy(useName, colorName);
		    found = 1; goto gotcolor;
		}
		break;
	      case XPM_COLOR:
		if (!isMono) {
		    strcpy(useName, colorName);
		    found = 1; goto gotcolor;
		}
		break;
	    }
	    if (type != XPM_SYMBOLIC && type != XPM_UNKNOWN) {
		if (!found) {			/* use this color as default */
		    strcpy(useName, colorName);
		    found = 1;
		}
	    }
	}

      gotcolor:

	memcpy(&color1, p+1, byteSize);
	p = useName;
	while ((*p != 0) && (*p != '"') && (*p != ' ') && (*p != 't')) {
	    p++;
	}
	*p = 0;

	data = 0;
	if (strncasecmp(useName, "none",5)) {
	  if (XParseColor(display, colormap, useName, &color) == 0) {
	    color.red = color.green = color.blue = 0;
	  }
	  ((unsigned char *) &data)[0] = color.red>>8;
	  ((unsigned char *) &data)[1] = color.green>>8;
	  ((unsigned char *) &data)[2] = color.blue>>8;
	  ((unsigned char *) &data)[3] = 255;
	}

	hPtr = Tcl_CreateHashEntry(&colorTable, (char *) color1, &found);
	Tcl_SetHashValue(hPtr, (char *) data);

	ckfree(colorName);
	ckfree(useName);
    }

    Tk_PhotoGetImage(imageHandle, &block.pub);
	 /* in case Tk_PhotoGetImage doesn't set this */
    block.pub.offset[3] = (block.pub.pixelSize > 3) ? 3 : 0;
    block.pub.width = width;
    block.pub.pitch = block.pub.pixelSize * fileWidth;
    block.pub.height = 1;
    block.pub.pixelPtr = (unsigned char *) ckalloc((unsigned) block.pub.pixelSize * width);

    Tk_PhotoExpand(imageHandle, destX + width, destY + height);

    i = srcY;
    while (i-- > 0) {
	p = Gets(buffer,MAX_BUFFER,f,dataPtr);
	while (((p = strchr(p,'\"')) == NULL) || ((strstr(p,"/*")) != NULL)) {
	    p = Gets(buffer,MAX_BUFFER,f,dataPtr);
	    if (p == NULL) {
		return TCL_ERROR;
	    }
	    p = buffer;
	}
    }


    for (h = height; h > 0; h--) {
	p = Gets(buffer,MAX_BUFFER,f,dataPtr);
	while (((p = strchr(p,'\"')) == NULL) || ((strstr(p,"/*")) != NULL)) {
	    p = Gets(buffer,MAX_BUFFER,f,dataPtr);
	    if (p == NULL) {
		return TCL_ERROR;
	    }
	    p = buffer;
	}
	p += byteSize * srcX + 1;
	pixelPtr = block.pub.pixelPtr;
	
	for (i = 0; i < width; ) {
	    unsigned int col;

	    memcpy((char *) &color1, p, byteSize);
	    hPtr = Tcl_FindHashEntry(&colorTable, (char *) color1);

	    /* 
	     * if hPtr == NULL, we have an invalid color entry in the XPM 
	     * file. We use transparant as default color
	     */
	    if (hPtr != (Tcl_HashEntry *)NULL) 
	        col = (int)Tcl_GetHashValue(hPtr);
	    else 
	        col = (int)0;
	    
	    /*
	     * we've found a non-transparent pixel, let's search the next
	     * transparent pixel and copy this block to the image
	     */
	    if (col) {
	        int len = 0, j;
		
		j = i;
		pixelPtr = block.pub.pixelPtr;
		do {
		    memcpy(pixelPtr, &col, block.pub.pixelSize);
		    pixelPtr += block.pub.pixelSize;
		    i++;
		    len++;
		    p += byteSize;
		    
		    if (i < width) {
		        memcpy((char *) &color1, p, byteSize);
			hPtr = Tcl_FindHashEntry(&colorTable, (char *) color1);
			if (hPtr != (Tcl_HashEntry *)NULL) 
			    col = (int)Tcl_GetHashValue(hPtr);
			else 
			    col = (int)0;
		    }
		} while ((i < width) && col);
		Tk_PhotoPutBlock(imageHandle, &block.pub, destX+j, destY, len, 1);
	    } else {
	        p += byteSize;
	        i++;
	    }
	}
	destY++;
    }

    Tcl_DeleteHashTable(&colorTable);

    ckfree((char *) block.pub.pixelPtr);
    return TCL_OK;
}


/*
 *----------------------------------------------------------------------
 *
 * FileReadXPM --
 *
 *	This procedure is called by the photo image type to read
 *	XPM format data from a file and write it into a given
 *	photo image.
 *
 * Results:
 *	A standard TCL completion code.  If TCL_ERROR is returned
 *	then an error message is left in interp->result.
 *
 * Side effects:
 *	The access position in file f is changed, and new data is
 *	added to the image given by imageHandle.
 *
 *----------------------------------------------------------------------
 */

static int
FileReadXPM(interp, f, fileName, formatString, imageHandle, destX, destY,
	width, height, srcX, srcY)
    Tcl_Interp *interp;		/* Interpreter to use for reporting errors. */
    FILE *f;			/* The image file, open for reading. */
    char *fileName;		/* The name of the image file. */
    char *formatString;		/* User-specified format string, or NULL. */
    Tk_PhotoHandle imageHandle;	/* The photo image to write into. */
    int destX, destY;		/* Coordinates of top-left pixel in
				 * photo image to be written to. */
    int width, height;		/* Dimensions of block of photo image to
				 * be written to. */
    int srcX, srcY;		/* Coordinates of top-left pixel to be used
				 * in image being read. */
{
  return ReadXPM(interp, f, fileName, NULL, formatString, imageHandle,
		 destX, destY, width, height, srcX, srcY);
}


/*
 *----------------------------------------------------------------------
 *
 * StringReadXPM --
 *
 *	This procedure is called by the photo image type to read
 *	XPM format data from a string and write it into a given
 *	photo image.
 *
 * Results:
 *	A standard TCL completion code.  If TCL_ERROR is returned
 *	then an error message is left in interp->result.
 *
 * Side effects:
 *	New data is added to the image given by imageHandle.
 *
 *----------------------------------------------------------------------
 */

static int
StringReadXPM(interp, string, formatString, imageHandle, destX, destY,
	width, height, srcX, srcY)
    Tcl_Interp *interp;		/* Interpreter to use for reporting errors. */
    char *string;
    char *formatString;		/* User-specified format string, or NULL. */
    Tk_PhotoHandle imageHandle;	/* The photo image to write into. */
    int destX, destY;		/* Coordinates of top-left pixel in
				 * photo image to be written to. */
    int width, height;		/* Dimensions of block of photo image to
				 * be written to. */
    int srcX, srcY;		/* Coordinates of top-left pixel to be used
				 * in image being read. */
{
  struct XPM_DString data;

  data.data = string;
  data.p = string;
  return ReadXPM(interp, NULL, "", &data, formatString, imageHandle,
		 destX, destY, width, height, srcX, srcY);
}


/*
 *----------------------------------------------------------------------
 *
 * ReadXPMFileHeader --
 *
 *	This procedure reads the XPM header from the beginning of a
 *	XPM file and returns information from the header.
 *
 * Results:
 *	The return value is 1 if file "f" appears to start with a valid
 *      XPM header, and 0 otherwise.  If the header is valid,
 *	then *widthPtr and *heightPtr are modified to hold the
 *	dimensions of the image and *numColors holds the number of
 *	colors and byteSize the number of bytes used for 1 pixel.
 *
 * Side effects:
 *	The access position in f advances.
 *
 *----------------------------------------------------------------------
 */

#define UCHAR(c) ((unsigned char) (c))

static int
ReadXPMFileHeader(f, dataPtr, widthPtr, heightPtr, numColors, byteSize)
    FILE *f;			/* Image file to read the header from */
    struct XPM_DString *dataPtr;
    int *widthPtr, *heightPtr;	/* The dimensions of the image are
				 * returned here. */
    int *numColors;		/* the number of colors is returned here */
    int *byteSize;		/* number of bytes per pixel */
{
    char buffer[MAX_BUFFER];
    char *p;

    p = Gets(buffer,MAX_BUFFER,f,dataPtr);
    if (p == NULL) {
	return 0;
    }
    p = buffer;
    while (*p && isspace(UCHAR(*p))) {
	p++;
    }
    if (strncmp("/* XPM", p, 6) != 0) {
	return 0;
    }
    while ((p = strchr(p,'{')) == NULL) {
	p = Gets(buffer,MAX_BUFFER,f,dataPtr);
	if (p == NULL) {
	    return 0;
	}
	p = buffer;
    }
    while ((p = strchr(p,'"')) == NULL) {
	p = Gets(buffer,MAX_BUFFER,f,dataPtr);
	if (p == NULL) {
	    return 0;
	}
	p = buffer;
    }
    p++;
    while (p && *p && isspace(UCHAR(*p))) {
	p++;
    }
    *widthPtr = strtoul(p, &p, 0);
    if (p == NULL) {
	return 0;
    }
    while (p && *p && isspace(UCHAR(*p))) {
	p++;
    }
    *heightPtr = strtoul(p, &p, 0);
    if (p == NULL) {
	return 0;
    }
    while (p && *p && isspace(UCHAR(*p))) {
	p++;
    }
    *numColors = strtoul(p, &p, 0);
    if (p == NULL) {
	return 0;
    }
    while (p && *p && isspace(UCHAR(*p))) {
	p++;
    }
    *byteSize = strtoul(p, &p, 0);
    if (p == NULL) {
	return 0;
    }
    return 1;
}

static char * GetType(colorDefn, type_ret)
    char * colorDefn;
    int  * type_ret;
{
    char * p = colorDefn;

    /* skip white spaces */
    while (*p && isspace(*p)) {
	p ++;
    }

    /* parse the type */
    if (p[0] != '\0' && p[0] == 'm' &&
	p[1] != '\0' && isspace(p[1])) {
	*type_ret = XPM_MONO;
	p += 2;
    }
    else if (p[0] != '\0' && p[0] == 'g' &&
	     p[1] != '\0' && p[1] == '4' &&
	     p[2] != '\0' && isspace(p[2])) {
	*type_ret = XPM_GRAY_4;
	p += 3;
    }
    else if (p[0] != '\0' && p[0] == 'g' &&
	     p[1] != '\0' && isspace(p[1])) {
	*type_ret = XPM_GRAY;
	p += 2;
    }
    else if (p[0] != '\0' && p[0] == 'c' &&
	     p[1] != '\0' && isspace(p[1])) {
	*type_ret = XPM_COLOR;
	p += 2;
    }
    else if (p[0] != '\0' && p[0] == 's' &&
	     p[1] != '\0' && isspace(p[1])) {
	*type_ret = XPM_SYMBOLIC;
	p += 2;
    }
    else {
	*type_ret = XPM_UNKNOWN;
	return NULL;
    }

    return p;
}

/* colorName is guaranteed to be big enough */
static char * GetColor(colorDefn, colorName, type_ret)
    char * colorDefn;
    char * colorName;		/* if found, name is copied to this array */
    int  * type_ret;
{
    int type;
    char * p;

    if (!colorDefn) {
	return NULL;
    }

    if ((colorDefn = GetType(colorDefn, &type)) == NULL) {
	/* unknown type */
	return NULL;
    }
    else {
	*type_ret = type;
    }

    /* skip white spaces */
    while (*colorDefn && isspace(*colorDefn)) {
	colorDefn ++;
    }

    p = colorName;

    while (1) {
	int dummy;

	while (*colorDefn && !isspace(*colorDefn)) {
	    *p++ = *colorDefn++;
	}

	if (!*colorDefn) {
	    break;
	}

	if (GetType(colorDefn, &dummy) == NULL) {
	    /* the next string should also be considered as a part of a color
	     * name */
	    
	    while (*colorDefn && isspace(*colorDefn)) {
		*p++ = *colorDefn++;
	    }
	} else {
	    break;
	}
	if (!*colorDefn) {
	    break;
	}
    }

    /* Mark the end of the colorName */
    *p = '\0';

    return colorDefn;
}


/*
 *----------------------------------------------------------------------
 *
 * FileWriteXPM
 *
 *	Writes a XPM image to a file. Just calls WriteXPM
 *      with appropriate arguments.
 *
 * Results:
 *	Returns the return value of WriteXPM
 *
 * Side effects:
 *	A file is (hopefully) created on success.
 *
 *----------------------------------------------------------------------
 */
static int
FileWriteXPM(interp, fileName, formatString, blockPtr)
    Tcl_Interp *interp;
    char *fileName;
    char *formatString;
    Tk_PhotoImageBlock *blockPtr;
{
    return WriteXPM(interp, fileName, (Tcl_DString *)NULL, formatString, blockPtr);
}


/*
 *----------------------------------------------------------------------
 *
 * StringWriteXPM
 *
 *	Writes a XPM image to a string. Just calls WriteXPM
 *      with appropriate arguments.
 *
 * Results:
 *	Returns the return value of WriteXPM
 *
 * Side effects:
 *	The Tcl_DString dataPtr is modified on success.
 *
 *----------------------------------------------------------------------
 */
static int	        
StringWriteXPM(interp, dataPtr, formatString, blockPtr) 
    Tcl_Interp *interp;
    Tcl_DString *dataPtr;
    char *formatString;
    Tk_PhotoImageBlock *blockPtr;
{
  return WriteXPM(interp, (char *) NULL, dataPtr, formatString, blockPtr);
}


/*
 * Yes, I know these macros are dangerous. But it should work fine
 */
#define WRITE(buf) { if (f) fputs(buf, f); else Tcl_DStringAppend(dataPtr, buf, -1);}

/*
 *----------------------------------------------------------------------
 *
 * WriteXPM
 *
 *	This procedure writes a XPM image to the file filename 
 *      (if filename != NULL) or to dataPtr.
 *
 * Results:
 *	Returns TCL_OK on success, or TCL_ERROR on error.
 *      Possible failures are:
 *      1. cannot access file (permissions or path not found)
 *      2. TkPhotoGetMask fails to retrieve the region mask
 *         for the image (should not happen)
 *
 * Side effects:
 *	varies (see StringWriteXPM and FileWriteXPM)
 *
 *----------------------------------------------------------------------
 */
static int
WriteXPM(interp, fileName, dataPtr, formatString, blockPtr)
    Tcl_Interp *interp;
    char *fileName;
    Tcl_DString *dataPtr;
    char *formatString;    
    Tk_PhotoImageBlock *blockPtr;
{
    int x, y, i;
    int found;
    FILE *f = (FILE *) NULL;
    Tcl_HashTable colors;
    Tcl_HashEntry *entry;
    Tcl_HashSearch search;
    unsigned char *pp;
    int ncolors, chars_per_pixel;
    int greenOffset, blueOffset, alphaOffset;
    union {
	ClientData value;
	char component[3];
    } col;
    union {
	ClientData value;
	char component[5];
    } temp;
    char buffer[256];

    /*
     * xpm_chars[] must be 64 chars long
     */
    static char xpm_chars[] =
	    ".#abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";

    greenOffset = blockPtr->offset[1] - blockPtr->offset[0];
    blueOffset = blockPtr->offset[2] - blockPtr->offset[0];
    alphaOffset = blockPtr->offset[0];
    if (alphaOffset < blockPtr->offset[1]) alphaOffset = blockPtr->offset[1];
    if (alphaOffset < blockPtr->offset[2]) alphaOffset = blockPtr->offset[2];
    if (++alphaOffset < blockPtr->pixelSize) {
	alphaOffset -= blockPtr->offset[0];
    } else {
	alphaOffset = 0;
    }

    /* open the output file (if needed) */
    if (fileName) {
      f = fopen(fileName, "w");
      if (f == (FILE *)NULL) {
	Tcl_AppendResult(interp, ": cannot open file for writing",
		(char *)NULL);
	return TCL_ERROR;
      }
    }

    /* compute image name */
    if (f) {
	char *p;
	p = strrchr(fileName, '/');
	if (p) {
	    fileName = p;
	}
	p = strrchr(fileName, '\\');
	if (p) {
	    fileName = p;
	}
	p = strrchr(fileName, ':');
	if (p) {
	    fileName = p;
	}
	p = strchr(fileName, '.');
	if (p) {
	    *p = 0;
	}
	fprintf(f, "/* XPM */\nstatic char * %s[] = {\n", fileName);
    } else {
	Tcl_DStringAppend(dataPtr,
		"/* XPM */\nstatic char * unknown[] = {\n", -1);
    }

    /*
     * Compute size of colortable
     */
    Tcl_InitHashTable(&colors, TCL_ONE_WORD_KEYS);
    ncolors = 0;
    col.value = 0;
    for (y = 0; y < blockPtr->height; y++) {
	pp = blockPtr->pixelPtr + y * blockPtr->pitch + blockPtr->offset[0];
	for (x = blockPtr->width; x >0; x--) {
	    if (!alphaOffset || pp[alphaOffset]) {
		col.component[0] = pp[0];
		col.component[1] = pp[greenOffset];
		col.component[2] = pp[blueOffset];
		if (Tcl_FindHashEntry(&colors, (char *) col.value) == NULL) {
		    ncolors++;
		    entry = Tcl_CreateHashEntry(&colors, (char *) col.value,
		    	    &found);
		}
	    }
	    pp += blockPtr->pixelSize;
	}
    }

    /* compute number of characters per pixel */
    chars_per_pixel = 1;
    i = ncolors;
    while(i > 64) {
	chars_per_pixel++;
	i /= 64;
    }

    /* write image info into XPM */
    sprintf(buffer, "\"%d %d %d %d\",\n", blockPtr->width, blockPtr->height,
	    ncolors+(alphaOffset != 0), chars_per_pixel);
    WRITE(buffer);

    /* write transparent color id if transparency is available*/
    if (alphaOffset) {
	strcpy(temp.component, "    ");
	temp.component[chars_per_pixel] = 0;
 	sprintf(buffer, "\"%s s None c None\",\n", temp.component);
	WRITE(buffer);
    }

    /* write colormap strings */
    entry = Tcl_FirstHashEntry(&colors, &search); 
    y = 0;
    temp.component[chars_per_pixel] = 0;
    while(entry) {
	/* compute a color identifier for color #y */
	for (i = 0, x = y++; i < chars_per_pixel; i++, x /= 64) 
	    temp.component[i] = xpm_chars[x & 63];

	/* 
	 * and put it in the hashtable 
	 * this is a little bit tricky
	 */
	Tcl_SetHashValue(entry, (char *) temp.value);
	pp = (unsigned char *)&entry->key.oneWordValue;
	sprintf(buffer, "\"%s c #%02x%02x%02x\",\n", 
		temp.component, pp[0], pp[1], pp[2]);
	WRITE(buffer);
	entry = Tcl_NextHashEntry(&search);
    }

    /* write image itself */
    pp = blockPtr->pixelPtr + blockPtr->offset[0];
    buffer[chars_per_pixel] = 0;
    for (y = 0; y < blockPtr->height; y++) {
	WRITE("\"");
	for (x = 0; x < blockPtr->width; x++) {
	    if (!alphaOffset || pp[alphaOffset]) {
		col.component[0] = pp[0];
		col.component[1] = pp[greenOffset];
		col.component[2] = pp[blueOffset];
		entry = Tcl_FindHashEntry(&colors, (char *) col.value);
		temp.value = Tcl_GetHashValue(entry);
		memcpy(buffer, temp.component, chars_per_pixel);
	    } else {
		/* make transparent pixel */
		memcpy(buffer, "    ", chars_per_pixel);
	    }
	    pp += blockPtr->pixelSize;	
	    WRITE(buffer);
	}
	if (y == blockPtr->height - 1) {
	    WRITE("\"};");
	} else {
	    WRITE("\",\n");
	}
    }

    /* Delete the hash table */
    Tcl_DeleteHashTable(&colors);    

    /* close the file */
    if (f) {
	fclose(f);
    }
    return TCL_OK;
}
