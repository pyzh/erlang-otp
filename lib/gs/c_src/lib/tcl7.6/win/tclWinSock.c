/* 
 * tclWinSock.c --
 *
 *	This file contains Windows-specific socket related code.
 *
 * Copyright (c) 1995-1996 Sun Microsystems, Inc.
 *
 * See the file "license.terms" for information on usage and redistribution
 * of this file, and for a DISCLAIMER OF ALL WARRANTIES.
 *
 * SCCS: @(#) tclWinSock.c 1.54 96/11/15 16:11:29
 */

#include "tclInt.h"
#include "tclPort.h"

/*
 * The following structure contains pointers to all of the WinSock API entry
 * points used by Tcl.  It is initialized by InitSockets.  Since we
 * dynamically load Winsock.dll on demand, we must use this function table
 * to refer to functions in the socket API.
 */

static struct {
    HINSTANCE handle;
    SOCKET (PASCAL FAR *accept)(SOCKET s, struct sockaddr FAR *addr,
	    int FAR *addrlen);
    int (PASCAL FAR *bind)(SOCKET s, const struct sockaddr FAR *addr,
	    int namelen);
    int (PASCAL FAR *closesocket)(SOCKET s);
    int (PASCAL FAR *connect)(SOCKET s, const struct sockaddr FAR *name,
	    int namelen);
    int (PASCAL FAR *ioctlsocket)(SOCKET s, long cmd, u_long FAR *argp);
    int (PASCAL FAR *getsockopt)(SOCKET s, int level, int optname,
	    char FAR * optval, int FAR *optlen);
    u_short (PASCAL FAR *htons)(u_short hostshort);
    unsigned long (PASCAL FAR *inet_addr)(const char FAR * cp);
    char FAR * (PASCAL FAR *inet_ntoa)(struct in_addr in);
    int (PASCAL FAR *listen)(SOCKET s, int backlog);
    u_short (PASCAL FAR *ntohs)(u_short netshort);
    int (PASCAL FAR *recv)(SOCKET s, char FAR * buf, int len, int flags);
    int (PASCAL FAR *send)(SOCKET s, const char FAR * buf, int len, int flags);
    int (PASCAL FAR *setsockopt)(SOCKET s, int level, int optname,
	    const char FAR * optval, int optlen);
    int (PASCAL FAR *shutdown)(SOCKET s, int how);
    SOCKET (PASCAL FAR *socket)(int af, int type, int protocol);
    struct hostent FAR * (PASCAL FAR *gethostbyname)(const char FAR * name);
    struct hostent FAR * (PASCAL FAR *gethostbyaddr)(const char FAR *addr,
            int addrlen, int addrtype);
    int (PASCAL FAR *gethostname)(char FAR * name, int namelen);
    int (PASCAL FAR *getpeername)(SOCKET sock, struct sockaddr FAR *name,
            int FAR *namelen);
    struct servent FAR * (PASCAL FAR *getservbyname)(const char FAR * name,
	    const char FAR * proto);
    int (PASCAL FAR *getsockname)(SOCKET sock, struct sockaddr FAR *name,
            int FAR *namelen);
    int (PASCAL FAR *WSAStartup)(WORD wVersionRequired, LPWSADATA lpWSAData);
    int (PASCAL FAR *WSACleanup)(void);
    int (PASCAL FAR *WSAGetLastError)(void);
    int (PASCAL FAR *WSAAsyncSelect)(SOCKET s, HWND hWnd, u_int wMsg,
	    long lEvent);
} winSock = {
    (HINSTANCE) NULL,			/* handle. */
    NULL,				/* accept. */
    NULL,				/* bind. */
    NULL,				/* closesocket. */
    NULL,				/* connect. */
    NULL,				/* ioctlsocket. */
    NULL,				/* getsockopt. */
    NULL,				/* htons. */
    NULL,				/* inet_addr. */
    NULL,				/* inet_ntoa. */
    NULL,				/* listen. */
    NULL,				/* ntohs. */
    NULL,				/* recv. */
    NULL,				/* send. */
    NULL,				/* setsockopt. */
    NULL,				/* socket. */
    NULL,				/* gethostbyname. */
    NULL,				/* gethostbyaddr. */
    NULL,				/* gethostname. */
    NULL,				/* getpeername. */
    NULL,				/* getservbyname. */
    NULL,				/* getsockname. */
    NULL,				/* WSAStartup. */
    NULL,				/* WSACleanup. */
    NULL,				/* WSAGetLastError. */
    NULL				/* WSAASyncSelect. */
};

/*
 * The following define declares a new user message for use on the
 * socket window.
 */

#define SOCKET_MESSAGE	WM_USER+1

/*
 * The following structure is used to store the data associated with
 * each socket.  A Tcl_File of type TCL_WIN_SOCKET will contain a
 * pointer to one of these structures in the clientdata slot.
 */

typedef struct SocketInfo {
    SOCKET socket;		   /* Windows SOCKET handle. */
    int flags;			   /* Bit field comprised of the flags
				    * described below.  */
    int watchMask;		   /* OR'ed combination of TCL_READABLE and
				    * TCL_WRITABLE as set by Tcl_WatchFile. */
    int eventMask;		   /* OR'ed combination of FD_READ, FD_WRITE,
                                    * FD_CLOSE, FD_ACCEPT and FD_CONNECT. */
    int occurredMask;		   /* OR'ed combination of the above flags
                                    * for those events that have actually
                                    * occurred on the socket. */
    Tcl_File file;		   /* The file handle for the socket. */
    Tcl_TcpAcceptProc *acceptProc; /* Proc to call on accept. */
    ClientData acceptProcData;	   /* The data for the accept proc. */
    struct SocketInfo *nextPtr;	   /* The next socket on the global socket
				    * list. */
} SocketInfo;

/*
 * This defines the minimum buffersize maintained by the kernel.
 */

#define TCP_BUFFER_SIZE 4096

/*
 * The following macros may be used to set the flags field of
 * a SocketInfo structure. We leave the first three bits open
 * for TCL_READABLE, TCL_WRITABLE and TCL_EXCEPTION
 */

#define SOCKET_WATCH		(1<<4)	/* TclWinWatchSocket has been called
					 * since the last time we entered
                                         * Tcl_WaitForEvent. */
#define SOCKET_REGISTERED	(1<<5)	/* A valid WSAAsyncSelect handler is
					 * registered. */
#define SOCKET_ASYNCH		(1<<6)	/* The socket is in asynch mode. */
#define SOCKET_CLOSED		(1<<7)	/* The socket had an FD_CLOSE event. */
#define SOCKET_EOF		(1<<8)	/* A zero read happened on
					 * the socket. */
#define SOCKET_ASYNC_CONNECT	(1<<9)	/* This socket uses async connect. */

/*
 * Every open socket has an entry on the following list.
 */

static SocketInfo *socketList = NULL;

/*
 * Static functions defined in this file.
 */

static void		CleanupSockets _ANSI_ARGS_((ClientData clientData));
static SocketInfo *	CreateSocket _ANSI_ARGS_((Tcl_Interp *interp,
			    int port, char *host, int server, char *myaddr,
			    int myport, int async));
static int		CreateSocketAddress _ANSI_ARGS_(
			    (struct sockaddr_in *sockaddrPtr,
			    char *host, int port));
static int		InitSockets _ANSI_ARGS_((void));
static SocketInfo *	NewSocketInfo _ANSI_ARGS_((Tcl_File file));
static void		SocketFreeProc _ANSI_ARGS_((ClientData clientData));
static LRESULT CALLBACK	SocketProc _ANSI_ARGS_((HWND hwnd, UINT message,
			    WPARAM wParam, LPARAM lParam));
static void		TcpAccept _ANSI_ARGS_((ClientData data, int mask));
static int		TcpBlockProc _ANSI_ARGS_((ClientData instanceData,
			    int mode));
static int		TcpCloseProc _ANSI_ARGS_((ClientData instanceData,
	            	    Tcl_Interp *interp));
static int		TcpGetOptionProc _ANSI_ARGS_((ClientData instanceData,
		            char *optionName, Tcl_DString *optionValue));
static int		TcpInputProc _ANSI_ARGS_((ClientData instanceData,
	            	    char *buf, int toRead, int *errorCode));
static int		TcpOutputProc _ANSI_ARGS_((ClientData instanceData,
	            	    char *buf, int toWrite, int *errorCode));
static void		TcpWatchProc _ANSI_ARGS_((ClientData instanceData,
		            int mask));
static int		TcpReadyProc _ANSI_ARGS_((ClientData instanceData,
		            int mask));
static Tcl_File		TcpGetProc _ANSI_ARGS_((ClientData instanceData,
		            int direction));
static int		WaitForConnect _ANSI_ARGS_((SocketInfo *infoPtr,
		            int *errorCodePtr));

/*
 * This structure describes the channel type structure for TCP socket
 * based IO.
 */

static Tcl_ChannelType tcpChannelType = {
    "tcp",		/* Type name. */
    TcpBlockProc,	/* Set socket into blocking/non-blocking mode. */
    TcpCloseProc,	/* Close proc. */
    TcpInputProc,	/* Input proc. */
    TcpOutputProc,	/* Output proc. */
    NULL,		/* Seek proc. */
    NULL,		/* Set option proc. */
    TcpGetOptionProc,	/* Get option proc. */
    TcpWatchProc,	/* Initialize notifier to watch this channel. */
    TcpReadyProc,	/* Are events present? */
    TcpGetProc,		/* Get a Tcl_File from channel. */
};

/*
 * Socket notification window.  This window is used to receive socket
 * notification events.
 */

static HWND socketWindow = NULL;

/*
 * Window class for creating the socket notification window.
 */

static ATOM socketClass;

/*
 * Define version of Winsock required by Tcl.
 */

#define WSA_VERSION_REQD MAKEWORD(1,1)

/*
 *----------------------------------------------------------------------
 *
 * InitSockets --
 *
 *	Initialize the socket module.  Attempts to load the wsock32.dll
 *	library and set up the winSock function table.  If successful,
 *	registers the event window for the socket notifier code.
 *
 * Results:
 *	Returns 1 on successful initialization, 0 on failure.
 *
 * Side effects:
 *	Dynamically loads wsock32.dll, and registers a new window
 *	class and creates a window for use in asynchronous socket
 *	notification.
 *
 *----------------------------------------------------------------------
 */

static int
InitSockets()
{
    WSADATA wsaData;
    WNDCLASS class;
    HINSTANCE handle;

    /*
     * Load the socket DLL and initialize the function table.
     */

    handle = (HINSTANCE) dlopen("wsock32.dll", 0);
    if (handle == NULL) {
        return 0;
    }
    winSock.handle = handle;
    winSock.accept = (SOCKET (PASCAL FAR *)(SOCKET s,
            struct sockaddr FAR *addr, int FAR *addrlen))
        GetProcAddress(handle, "accept");
    winSock.bind = (int (PASCAL FAR *)(SOCKET s,
            const struct sockaddr FAR *addr, int namelen))
        GetProcAddress(handle, "bind");
    winSock.closesocket = (int (PASCAL FAR *)(SOCKET s))
        GetProcAddress(handle, "closesocket");
    winSock.connect = (int (PASCAL FAR *)(SOCKET s,
            const struct sockaddr FAR *name, int namelen))
        GetProcAddress(handle, "connect");
    winSock.ioctlsocket = (int (PASCAL FAR *)(SOCKET s, long cmd,
            u_long FAR *argp)) GetProcAddress(handle, "ioctlsocket");
    winSock.getsockopt = (int (PASCAL FAR *)(SOCKET s,
            int level, int optname, char FAR * optval, int FAR *optlen))
        GetProcAddress(handle, "getsockopt");
    winSock.htons = (u_short (PASCAL FAR *)(u_short hostshort))
        GetProcAddress(handle, "htons");
    winSock.inet_addr = (unsigned long (PASCAL FAR *)(const char FAR *cp))
        GetProcAddress(handle, "inet_addr");
    winSock.inet_ntoa = (char FAR * (PASCAL FAR *)(struct in_addr in))
        GetProcAddress(handle, "inet_ntoa");
    winSock.listen = (int (PASCAL FAR *)(SOCKET s, int backlog))
        GetProcAddress(handle, "listen");
    winSock.ntohs = (u_short (PASCAL FAR *)(u_short netshort))
        GetProcAddress(handle, "ntohs");
    winSock.recv = (int (PASCAL FAR *)(SOCKET s, char FAR * buf,
            int len, int flags)) GetProcAddress(handle, "recv");
    winSock.send = (int (PASCAL FAR *)(SOCKET s, const char FAR * buf,
            int len, int flags)) GetProcAddress(handle, "send");
    winSock.setsockopt = (int (PASCAL FAR *)(SOCKET s, int level,
            int optname, const char FAR * optval, int optlen))
        GetProcAddress(handle, "setsockopt");
    winSock.shutdown = (int (PASCAL FAR *)(SOCKET s, int how))
        GetProcAddress(handle, "shutdown");
    winSock.socket = (SOCKET (PASCAL FAR *)(int af, int type,
            int protocol)) GetProcAddress(handle, "socket");
    winSock.gethostbyaddr = (struct hostent FAR * (PASCAL FAR *)
            (const char FAR *addr, int addrlen, int addrtype))
        GetProcAddress(handle, "gethostbyaddr");
    winSock.gethostbyname = (struct hostent FAR * (PASCAL FAR *)
            (const char FAR *name))
        GetProcAddress(handle, "gethostbyname");
    winSock.gethostname = (int (PASCAL FAR *)(char FAR * name,
            int namelen)) GetProcAddress(handle, "gethostname");
    winSock.getpeername = (int (PASCAL FAR *)(SOCKET sock,
            struct sockaddr FAR *name, int FAR *namelen))
        GetProcAddress(handle, "getpeername");
    winSock.getservbyname = (struct servent FAR * (PASCAL FAR *)
            (const char FAR * name, const char FAR * proto))
        GetProcAddress(handle, "getservbyname");
    winSock.getsockname = (int (PASCAL FAR *)(SOCKET sock,
            struct sockaddr FAR *name, int FAR *namelen))
        GetProcAddress(handle, "getsockname");
    winSock.WSAStartup = (int (PASCAL FAR *)(WORD wVersionRequired,
            LPWSADATA lpWSAData)) GetProcAddress(handle, "WSAStartup");
    winSock.WSACleanup = (int (PASCAL FAR *)(void))
        GetProcAddress(handle, "WSACleanup");
    winSock.WSAGetLastError = (int (PASCAL FAR *)(void))
        GetProcAddress(handle, "WSAGetLastError");
    winSock.WSAAsyncSelect = (int (PASCAL FAR *)(SOCKET s, HWND hWnd,
            u_int wMsg, long lEvent))
        GetProcAddress(handle, "WSAAsyncSelect");

    /*
     * Now check that all fields are properly initialized. If not, return
     * zero to indicate that we failed to initialize properly.
     */

    if ((winSock.handle == NULL) ||
            (winSock.accept == NULL) ||
            (winSock.bind == NULL) ||
            (winSock.closesocket == NULL) ||
            (winSock.connect == NULL) ||
            (winSock.ioctlsocket == NULL) ||
            (winSock.getsockopt == NULL) ||
            (winSock.htons == NULL) ||
            (winSock.inet_addr == NULL) ||
            (winSock.inet_ntoa == NULL) ||
            (winSock.listen == NULL) ||
            (winSock.ntohs == NULL) ||
            (winSock.recv == NULL) ||
            (winSock.send == NULL) ||
            (winSock.setsockopt == NULL) ||
            (winSock.socket == NULL) ||
            (winSock.gethostbyname == NULL) ||
            (winSock.gethostbyaddr == NULL) ||
            (winSock.gethostname == NULL) ||
            (winSock.getpeername == NULL) ||
            (winSock.getservbyname == NULL) ||
            (winSock.getsockname == NULL) ||
            (winSock.WSAStartup == NULL) ||
            (winSock.WSACleanup == NULL) ||
            (winSock.WSAGetLastError == NULL) ||
            (winSock.WSAAsyncSelect == NULL)) {
        CloseHandle(handle);
        winSock.handle = NULL;
        return 0;
    }
    
    /*
     * Initialize the winsock library and check the version number.
     */

    if ((*winSock.WSAStartup)(WSA_VERSION_REQD, &wsaData) != 0) {
        CloseHandle(handle);
        winSock.handle = NULL;
	return 0;
    }
    if (wsaData.wVersion != WSA_VERSION_REQD) {
	(*winSock.WSACleanup)();
        CloseHandle(handle);
        winSock.handle = NULL;
	return 0;
    }

    /*
     * Register the async notification window class and window.
     */

    class.style = 0;
    class.cbClsExtra = 0;
    class.cbWndExtra = 0;
    class.hInstance = TclWinGetTclInstance();
    class.hbrBackground = NULL;
    class.lpszMenuName = NULL;
    class.lpszClassName = "TclSocket";
    class.lpfnWndProc = SocketProc;
    class.hIcon = NULL;
    class.hCursor = NULL;

    socketClass = RegisterClass(&class);
    if (!socketClass) {
	TclWinConvertError(GetLastError());
	(*winSock.WSACleanup)();
        CloseHandle(handle);
        winSock.handle = NULL;
	return 0;
    }
    socketWindow = CreateWindowEx(0, (LPCTSTR)socketClass, "TclSocket",
	    WS_OVERLAPPED, 0, 0, 0, 0, NULL, NULL,
	    TclWinGetTclInstance(), NULL);
    if (socketWindow == NULL) {
	TclWinConvertError(GetLastError());
	UnregisterClass((LPCTSTR)socketClass, TclWinGetTclInstance());
	(*winSock.WSACleanup)();
        CloseHandle(handle);
        winSock.handle = NULL;
	return 0;
    }

    Tcl_CreateExitHandler(CleanupSockets, (ClientData) NULL);
    return 1;
}

/*
 *----------------------------------------------------------------------
 *
 * CleanupSockets --
 *
 *	Callback invoked during exit clean up to release the WinSock
 *      DLL.
 *
 * Results:
 *	None.
 *
 * Side effects:
 *	Releases the WinSock DLL.
 *
 *----------------------------------------------------------------------
 */

    /* ARGSUSED */
static void
CleanupSockets(clientData)
    ClientData clientData;              /* Not used. */
{
    DestroyWindow(socketWindow);
    UnregisterClass((LPCTSTR)socketClass, TclWinGetTclInstance());
    (*winSock.WSACleanup)();
    CloseHandle(winSock.handle);
    winSock.handle = NULL;
}

/*
 *----------------------------------------------------------------------
 *
 * TcpBlockProc --
 *
 *	Sets a socket into blocking or non-blocking mode.
 *
 * Results:
 *	0 if successful, errno if there was an error.
 *
 * Side effects:
 *	Modifies subsequent behavior of the socket.
 *
 *----------------------------------------------------------------------
 */

static int
TcpBlockProc(instanceData, mode)
    ClientData	instanceData;	/* The socket to block/un-block. */
    int mode;			/* TCL_MODE_BLOCKING or
                                 * TCL_MODE_NONBLOCKING. */
{
    SocketInfo *infoPtr = (SocketInfo *) instanceData;
    u_long flag;

    flag = (mode == TCL_MODE_BLOCKING) ? 0 : 1;
    return (*winSock.ioctlsocket) (infoPtr->socket, FIONBIO, &flag);
}

/*
 *----------------------------------------------------------------------
 *
 * TcpCloseProc --
 *
 *	This procedure is called by the generic IO level to perform
 *	channel type specific cleanup on a socket based channel
 *	when the channel is closed.
 *
 * Results:
 *	0 if successful, the value of errno if failed.
 *
 * Side effects:
 *	Closes the socket.
 *
 *----------------------------------------------------------------------
 */

    /* ARGSUSED */
static int
TcpCloseProc(instanceData, interp)
    ClientData instanceData;	/* The socket to close. */
    Tcl_Interp *interp;		/* Unused. */
{
    SocketInfo *infoPtr = (SocketInfo *) instanceData;
    int errorCode = 0;

    /*
     * Check that WinSock is initialized; do not call it if not, to
     * prevent system crashes. This can happen at exit time if the exit
     * handler for WinSock ran before other exit handlers that want to
     * use sockets.
     */

    if (winSock.handle != NULL) {
        
	/*
         * Clean up the OS socket handle.
         */
    
        (void) ((*winSock.shutdown)(infoPtr->socket, 1));
        if ((*winSock.closesocket)(infoPtr->socket) == SOCKET_ERROR) {
            TclWinConvertWSAError((*winSock.WSAGetLastError)());
            errorCode = errno;
        }
    }

    /*
     * Delete a file handler that may be active for this socket.
     * Channel handlers are already deleted in the generic IO close
     * code which called this function.
     */
    
    Tcl_DeleteFileHandler(infoPtr->file);

    /*
     * Free the file handle.  As a side effect, this will call the
     * SocketFreeProc to release the SocketInfo associated with this file.
     */

    Tcl_FreeFile(infoPtr->file);

    return errorCode;
}

/*
 *----------------------------------------------------------------------
 *
 * SocketFreeProc --
 *
 *	This callback is invoked by Tcl_FreeFile in order to delete
 *	the notifier data associated with a file handle.
 *
 * Results:
 *	None.
 *
 * Side effects:
 *	Removes the SocketInfo from the global socket list.
 *
 *----------------------------------------------------------------------
 */

static void
SocketFreeProc(clientData)
    ClientData clientData;
{
    SocketInfo *infoPtr = (SocketInfo *) clientData;

    /*
     * Remove the socket from socketList.
     */

    if (infoPtr == socketList) {
	socketList = infoPtr->nextPtr;
    } else {
	SocketInfo *p;
	for (p = socketList; p != NULL; p = p->nextPtr) {
	    if (p->nextPtr == infoPtr) {
		p->nextPtr = infoPtr->nextPtr;
		break;
	    }
	}
    }
    ckfree((char *) infoPtr);
}

/*
 *----------------------------------------------------------------------
 *
 * NewSocketInfo --
 *
 *	This function allocates and initializes a new SocketInfo
 *	structure.
 *
 * Results:
 *	Returns a newly allocated SocketInfo.
 *
 * Side effects:
 *	Adds the socket to the global socket list.
 *
 *----------------------------------------------------------------------
 */

static SocketInfo *
NewSocketInfo(file)
    Tcl_File file;
{
    SocketInfo *infoPtr;

    infoPtr = (SocketInfo *) ckalloc((unsigned) sizeof(SocketInfo));
    infoPtr->socket = (SOCKET) Tcl_GetFileInfo(file, NULL);
    infoPtr->flags = 0;
    infoPtr->watchMask = 0;
    infoPtr->eventMask = 0;
    infoPtr->occurredMask = 0;
    infoPtr->file = file;
    infoPtr->acceptProc = NULL;
    infoPtr->nextPtr = socketList;
    socketList = infoPtr;

    Tcl_SetNotifierData(file, SocketFreeProc, (ClientData) infoPtr);
    return infoPtr;
}

/*
 *----------------------------------------------------------------------
 *
 * CreateSocket --
 *
 *	This function opens a new socket and initializes the
 *	SocketInfo structure.
 *
 * Results:
 *	Returns a new SocketInfo, or NULL with an error in interp.
 *
 * Side effects:
 *	Adds a new socket to the socketList.
 *
 *----------------------------------------------------------------------
 */

static SocketInfo *
CreateSocket(interp, port, host, server, myaddr, myport, async)
    Tcl_Interp *interp;		/* For error reporting; can be NULL. */
    int port;			/* Port number to open. */
    char *host;			/* Name of host on which to open port. */
    int server;			/* 1 if socket should be a server socket,
				 * else 0 for a client socket. */
    char *myaddr;		/* Optional client-side address */
    int myport;			/* Optional client-side port */
    int async;			/* If nonzero, connect client socket
                                 * asynchronously. Unused. */
{
    int status;				/* Of socket operations. */
    u_long flag;			/* Indicates nonblocking mode. */
    int asyncConnect = 0;		/* Will be 1 if async connect is
                                         * in progress. */
    struct sockaddr_in sockaddr;	/* Socket address */
    struct sockaddr_in mysockaddr;	/* Socket address for client */
    SOCKET sock;
    SocketInfo *infoPtr;		/* The returned value. */

    /*
     * Check that WinSock is initialized; do not call it if not, to
     * prevent system crashes. This can happen at exit time if the exit
     * handler for WinSock ran before other exit handlers that want to
     * use sockets.
     */
    
    if (winSock.handle == NULL) {
        return NULL;
    }
    
    if (! CreateSocketAddress(&sockaddr, host, port)) {
	goto addressError;
    }
    if ((myaddr != NULL || myport != 0) &&
	    ! CreateSocketAddress(&mysockaddr, myaddr, myport)) {
	goto addressError;
    }

    sock = (*winSock.socket)(AF_INET, SOCK_STREAM, 0);
    if (sock == INVALID_SOCKET) {
	goto addressError;
    }

    /*
     * Set kernel space buffering
     */

    TclSockMinimumBuffers(sock, TCP_BUFFER_SIZE);

    if (server) {

	/*
         * Set the socket into nonblocking mode.
         */
    
        status = (*winSock.ioctlsocket)(sock, FIONBIO, &flag);
        if (status == SOCKET_ERROR) {
            goto bindError;
        }

	/*
	 * Bind to the specified port.  Note that we must not call setsockopt
	 * with SO_REUSEADDR because Microsoft allows addresses to be reused
	 * even if they are still in use.
         *
         * Bind should not be affected by the socket having already been
         * set into nonblocking mode. If there is trouble, this is one place
         * to look for bugs.
	 */
    
	status = (*winSock.bind)(sock, (struct sockaddr *) &sockaddr,
		sizeof(sockaddr));

        /*
         * Set the maximum number of pending connect requests to the
         * max value allowed on each platform (Win32 and Win32s may be
         * different, and there may be differences between TCP/IP stacks).
         */
        
	if (status != SOCKET_ERROR) {
	    (*winSock.listen)(sock, SOMAXCONN);
	}
    } else {

        /*
         * This is a client socket.
         */
        
	if (myaddr != NULL || myport != 0) { 
	    status = (*winSock.bind)(sock, (struct sockaddr *) &mysockaddr,
		    sizeof(struct sockaddr));
	    if (status < 0) {
		goto bindError;
	    }
	}            
    
        if (async) {

	    /*
             * Set the socket into nonblocking mode if the connect should
             * be done asynchronously.
             */

            flag = 1;
        } else {

            /*
             * Make sure the socket is in blocking mode initially:
             */

            flag = 0;
        }
        status = (*winSock.ioctlsocket)(sock, FIONBIO, &flag);
        if (status == SOCKET_ERROR) {
            goto bindError;
        }

	status = (*winSock.connect)(sock, (struct sockaddr *) &sockaddr,
		sizeof(sockaddr));

        /*
         * Ignore errors due to async connect.
         */
        
        if (status == SOCKET_ERROR) {
            TclWinConvertWSAError((*winSock.WSAGetLastError)());
            if ((async) && (Tcl_GetErrno() == EWOULDBLOCK)) {
                asyncConnect = 1;
                status = 0;
            } else {
                goto bindError;
            }
        } else if (async) {

            /*
             * We succeeded in making an async connect, so switch the
             * socket back into blocking mode.
             */
            
            flag = 0;
            (void) (*winSock.ioctlsocket)(sock, FIONBIO, &flag);
        }
    }
    
bindError:
    if (status == SOCKET_ERROR) {
	TclWinConvertWSAError((*winSock.WSAGetLastError)());
        if (interp != NULL) {
            Tcl_AppendResult(interp, "couldn't open socket: ",
                    Tcl_PosixError(interp), (char *) NULL);
        }
        (*winSock.closesocket)(sock);
        return NULL;
    }

    /*
     * Add this socket to the global list of sockets.
     */

    infoPtr = NewSocketInfo(Tcl_GetFile((ClientData) sock, TCL_WIN_SOCKET));
    if (asyncConnect) {
        infoPtr->flags |= SOCKET_ASYNC_CONNECT;
    }
    return infoPtr;

addressError:
    TclWinConvertWSAError((*winSock.WSAGetLastError)());
    if (interp != NULL) {
	Tcl_AppendResult(interp, "couldn't open socket: ",
		Tcl_PosixError(interp), (char *) NULL);
    }
    return NULL;
}

/*
 *----------------------------------------------------------------------
 *
 * CreateSocketAddress --
 *
 *	This function initializes a sockaddr structure for a host and port.
 *
 * Results:
 *	1 if the host was valid, 0 if the host could not be converted to
 *	an IP address.
 *
 * Side effects:
 *	Fills in the *sockaddrPtr structure.
 *
 *----------------------------------------------------------------------
 */

static int
CreateSocketAddress(sockaddrPtr, host, port)
    struct sockaddr_in *sockaddrPtr;	/* Socket address */
    char *host;				/* Host.  NULL implies INADDR_ANY */
    int port;				/* Port number */
{
    struct hostent *hostent;		/* Host database entry */
    struct in_addr addr;		/* For 64/32 bit madness */

    /*
     * Check that WinSock is initialized; do not call it if not, to
     * prevent system crashes. This can happen at exit time if the exit
     * handler for WinSock ran before other exit handlers that want to
     * use sockets.
     */

    if (winSock.handle == NULL) {
        errno = EFAULT;
        return 0;
    }
    
    (void) memset((char *) sockaddrPtr, '\0', sizeof(struct sockaddr_in));
    sockaddrPtr->sin_family = AF_INET;
    sockaddrPtr->sin_port = (*winSock.htons)((short) (port & 0xFFFF));
    if (host == NULL) {
	addr.s_addr = INADDR_ANY;
    } else {
        addr.s_addr = (*winSock.inet_addr)(host);
        if (addr.s_addr == INADDR_NONE) {
            hostent = (*winSock.gethostbyname)(host);
            if (hostent != NULL) {
                memcpy((char *) &addr,
                        (char *) hostent->h_addr_list[0],
                        (size_t) hostent->h_length);
            } else {
#ifdef	EHOSTUNREACH
                errno = EHOSTUNREACH;
#else
#ifdef ENXIO
                errno = ENXIO;
#endif
#endif
		return 0;	/* Error. */
	    }
	}
    }

    /*
     * NOTE: On 64 bit machines the assignment below is rumored to not
     * do the right thing. Please report errors related to this if you
     * observe incorrect behavior on 64 bit machines such as DEC Alphas.
     * Should we modify this code to do an explicit memcpy?
     */

    sockaddrPtr->sin_addr.s_addr = addr.s_addr;
    return 1;	/* Success. */
}

/*
 *----------------------------------------------------------------------
 *
 * WaitForConnect --
 *
 *	Waits for a connection on an asynchronously opened socket to
 *	be completed.
 *
 * Results:
 *	None.
 *
 * Side effects:
 *	The socket is connected after this function returns.
 *
 *----------------------------------------------------------------------
 */

static int
WaitForConnect(infoPtr, errorCodePtr)
    SocketInfo *infoPtr;	/* Information about this socket. */
    int *errorCodePtr;		/* Where to store errors? */
{
    int state;			/* Of calling TclWaitForFile. */
    u_long flag = 0;		/* To switch socket into blocking mode
                                 * once we are connected. */

    /*
     * If an asynchronous connect is in progress, attempt to wait for it
     * to complete before reading.
     */
    
    if (infoPtr->flags & SOCKET_ASYNC_CONNECT) {
        Tcl_SetErrno(0);
        state = TclWaitForFile(infoPtr->file, TCL_WRITABLE | TCL_EXCEPTION, 0);
        if (state & TCL_EXCEPTION) {
            return -1;
        }
        if (state & TCL_WRITABLE) {
            infoPtr->flags &= (~(SOCKET_ASYNC_CONNECT));

            /*
             * Once connected, put the socket into blocking mode.
             */
                  
            (void) (*winSock.ioctlsocket) (infoPtr->socket, FIONBIO, &flag);
        } else {
            *errorCodePtr = EWOULDBLOCK;
            Tcl_SetErrno(EWOULDBLOCK);
            return -1;
        }
    }
    return 0;
}

/*
 *----------------------------------------------------------------------
 *
 * Tcl_OpenTcpClient --
 *
 *	Opens a TCP client socket and creates a channel around it.
 *
 * Results:
 *	The channel or NULL if failed.  An error message is returned
 *	in the interpreter on failure.
 *
 * Side effects:
 *	Opens a client socket and creates a new channel.
 *
 *----------------------------------------------------------------------
 */

Tcl_Channel
Tcl_OpenTcpClient(interp, port, host, myaddr, myport, async)
    Tcl_Interp *interp;			/* For error reporting; can be NULL. */
    int port;				/* Port number to open. */
    char *host;				/* Host on which to open port. */
    char *myaddr;			/* Client-side address */
    int myport;				/* Client-side port */
    int async;				/* If nonzero, should connect
                                         * client socket asynchronously. */
{
    Tcl_Channel chan;
    SocketInfo *infoPtr;
    char channelName[20];

    if (TclHasSockets(interp) != TCL_OK) {
	return NULL;
    }

    /*
     * Create a new client socket and wrap it in a channel.
     */

    infoPtr = CreateSocket(interp, port, host, 0, myaddr, myport, async);
    if (infoPtr == NULL) {
	return NULL;
    }

    sprintf(channelName, "sock%d", infoPtr->socket);

    chan = Tcl_CreateChannel(&tcpChannelType, channelName,
	    (ClientData) infoPtr, (TCL_READABLE | TCL_WRITABLE));
    if (Tcl_SetChannelOption(interp, chan, "-translation", "auto crlf") ==
            TCL_ERROR) {
        Tcl_Close((Tcl_Interp *) NULL, chan);
        return (Tcl_Channel) NULL;
    }
    if (Tcl_SetChannelOption(NULL, chan, "-eofchar", "") == TCL_ERROR) {
        Tcl_Close((Tcl_Interp *) NULL, chan);
        return (Tcl_Channel) NULL;
    }
    return chan;
}

/*
 *----------------------------------------------------------------------
 *
 * Tcl_MakeTcpClientChannel --
 *
 *	Creates a Tcl_Channel from an existing client TCP socket.
 *
 * Results:
 *	The Tcl_Channel wrapped around the preexisting TCP socket.
 *
 * Side effects:
 *	None.
 *
 * NOTE: Code contributed by Mark Diekhans (markd@grizzly.com)
 *
 *----------------------------------------------------------------------
 */

Tcl_Channel
Tcl_MakeTcpClientChannel(sock)
    ClientData sock;		/* The socket to wrap up into a channel. */
{
    SocketInfo *infoPtr;
    char channelName[20];
    Tcl_Channel chan;

    if (TclHasSockets(NULL) != TCL_OK) {
	return NULL;
    }

    /*
     * Set kernel space buffering and non-blocking.
     */

    TclSockMinimumBuffers((SOCKET) sock, TCP_BUFFER_SIZE);

    infoPtr = NewSocketInfo (Tcl_GetFile((ClientData) sock,
                                         TCL_WIN_SOCKET));

    sprintf(channelName, "sock%d", infoPtr->socket);

    chan = Tcl_CreateChannel(&tcpChannelType, channelName,
	    (ClientData) infoPtr, (TCL_READABLE | TCL_WRITABLE));
    if (Tcl_SetChannelOption((Tcl_Interp *) NULL, chan,
                             "-translation", "auto crlf") ==
            TCL_ERROR) {
        Tcl_Close((Tcl_Interp *) NULL, chan);
        return (Tcl_Channel) NULL;
    }
    if (Tcl_SetChannelOption(NULL, chan, "-eofchar", "") == TCL_ERROR) {
        Tcl_Close((Tcl_Interp *) NULL, chan);
        return (Tcl_Channel) NULL;
    }
    return chan;
}

/*
 *----------------------------------------------------------------------
 *
 * Tcl_OpenTcpServer --
 *
 *	Opens a TCP server socket and creates a channel around it.
 *
 * Results:
 *	The channel or NULL if failed.  An error message is returned
 *	in the interpreter on failure.
 *
 * Side effects:
 *	Opens a server socket and creates a new channel.
 *
 *----------------------------------------------------------------------
 */

Tcl_Channel
Tcl_OpenTcpServer(interp, port, host, acceptProc, acceptProcData)
    Tcl_Interp *interp;			/* For error reporting - may be
                                         * NULL. */
    int port;				/* Port number to open. */
    char *host;				/* Name of local host. */
    Tcl_TcpAcceptProc *acceptProc;	/* Callback for accepting connections
                                         * from new clients. */
    ClientData acceptProcData;		/* Data for the callback. */
{
    Tcl_Channel chan;
    SocketInfo *infoPtr;
    char channelName[20];

    if (TclHasSockets(interp) != TCL_OK) {
	return NULL;
    }

    /*
     * Create a new client socket and wrap it in a channel.
     */

    infoPtr = CreateSocket(interp, port, host, 1, NULL, 0, 0);
    if (infoPtr == NULL) {
	return NULL;
    }

    infoPtr->acceptProc = acceptProc;
    infoPtr->acceptProcData = acceptProcData;

    /*
     * Set up the callback mechanism for accepting connections
     * from new clients. The caller will use Tcl_TcpRegisterCallback
     * to register a callback to call when a new connection is
     * accepted.
     */

    Tcl_CreateFileHandler(infoPtr->file, TCL_READABLE, TcpAccept,
            (ClientData) infoPtr);

    sprintf(channelName, "sock%d", infoPtr->socket);

    chan = Tcl_CreateChannel(&tcpChannelType, channelName,
	    (ClientData) infoPtr, 0);
    if (Tcl_SetChannelOption(interp, chan, "-eofchar", "") == TCL_ERROR) {
        Tcl_Close((Tcl_Interp *) NULL, chan);
        return (Tcl_Channel) NULL;
    }

    return chan;
}

/*
 *----------------------------------------------------------------------
 *
 * TcpAccept --
 *	Accept a TCP socket connection.  This is called by the event loop,
 *	and it in turns calls any registered callbacks for this channel.
 *
 * Results:
 *	None.
 *
 * Side effects:
 *	Evals the Tcl script associated with the server socket.
 *
 *----------------------------------------------------------------------
 */

	/* ARGSUSED */
static void
TcpAccept(data, mask)
    ClientData data;			/* Callback token. */
    int mask;				/* Not used. */
{
    SOCKET newSocket;
    SocketInfo *infoPtr = (SocketInfo *) data;
    SocketInfo *newInfoPtr;
    struct sockaddr_in addr;
    int len;
    Tcl_Channel chan;
    char channelName[20];

    /*
     * Check that WinSock is initialized; do not call it if not, to
     * prevent system crashes. This can happen at exit time if the exit
     * handler for WinSock ran before other exit handlers that want to
     * use sockets.
     */

    if (winSock.handle == NULL) {
        return;
    }
    
    len = sizeof(struct sockaddr_in);
    newSocket = (*winSock.accept)(infoPtr->socket, (struct sockaddr *)&addr,
	    &len);

    infoPtr->flags &= (~(TCL_READABLE));

    if (newSocket == INVALID_SOCKET) {
        return;
    }

    /*
     * Clear the inherited event mask.
     */

    (*winSock.WSAAsyncSelect)(newSocket, socketWindow, 0, 0);

    /*
     * Add this socket to the global list of sockets.
     */

    newInfoPtr = NewSocketInfo(Tcl_GetFile((ClientData) newSocket,
	    TCL_WIN_SOCKET));

    sprintf(channelName, "sock%d", newSocket);
    chan = Tcl_CreateChannel(&tcpChannelType, channelName,
	    (ClientData) newInfoPtr, (TCL_READABLE | TCL_WRITABLE));
    if (Tcl_SetChannelOption(NULL, chan, "-translation", "auto crlf") ==
            TCL_ERROR) {
        Tcl_Close((Tcl_Interp *) NULL, chan);
        return;
    }
    if (Tcl_SetChannelOption(NULL, chan, "-eofchar", "") == TCL_ERROR) {
        Tcl_Close((Tcl_Interp *) NULL, chan);
        return;
    }

    /*
     * Invoke the accept callback procedure.
     */

    if (infoPtr->acceptProc != NULL) {
	(infoPtr->acceptProc) (infoPtr->acceptProcData, chan,
		(*winSock.inet_ntoa)(addr.sin_addr),
		(*winSock.ntohs)(addr.sin_port));
    }
}

/*
 *----------------------------------------------------------------------
 *
 * TcpInputProc --
 *
 *	This procedure is called by the generic IO level to read data from
 *	a socket based channel.
 *
 * Results:
 *	The number of bytes read or -1 on error.
 *
 * Side effects:
 *	Consumes input from the socket.
 *
 *----------------------------------------------------------------------
 */

static int
TcpInputProc(instanceData, buf, toRead, errorCodePtr)
    ClientData instanceData;		/* The socket state. */
    char *buf;				/* Where to store data. */
    int toRead;				/* Maximum number of bytes to read. */
    int *errorCodePtr;			/* Where to store error codes. */
{
    SocketInfo *infoPtr = (SocketInfo *) instanceData;
    int state;
    int bytesRead;
    
    *errorCodePtr = 0;

    /*
     * Check that WinSock is initialized; do not call it if not, to
     * prevent system crashes. This can happen at exit time if the exit
     * handler for WinSock ran before other exit handlers that want to
     * use sockets.
     */

    if (winSock.handle == NULL) {
        *errorCodePtr = EFAULT;
        return -1;
    }

    /*
     * First check to see if EOF was already detected, to prevent
     * calling the socket stack after the first time EOF is detected.
     */

    if (infoPtr->flags & SOCKET_EOF) {
	return 0;
    }

    /*
     * Check to see if the socket is connected, if it is allow the read,
     * otherwise behave as if we had EWOULDBLOCK.
     */
    
    state = WaitForConnect(infoPtr, errorCodePtr);
    if (state != 0) {
        return -1;
    }
    
    /*
     * No EOF, and it is connected, so try to read more from the socket.
     */

    bytesRead = (*winSock.recv)(infoPtr->socket, buf, toRead, 0);
    if (bytesRead == SOCKET_ERROR) {
	TclWinConvertWSAError((*winSock.WSAGetLastError)());
        *errorCodePtr = errno;
        bytesRead = -1;
    }

    /*
     * Ensure that the socket stays readable if we have received a
     * SOCKET_CLOSED message but have not yet read all the data.
     */

    if (bytesRead == 0) {
        infoPtr->flags |= SOCKET_EOF;
    }
    if (!(infoPtr->flags & SOCKET_CLOSED)) {
        infoPtr->flags &= (~(TCL_READABLE));
    }

    return bytesRead;
}

/*
 *----------------------------------------------------------------------
 *
 * TcpOutputProc --
 *
 *	This procedure is called by the generic IO level to write data
 *	to a socket based channel.
 *
 * Results:
 *	The number of bytes written or -1 on failure.
 *
 * Side effects:
 *	Produces output on the socket.
 *
 *----------------------------------------------------------------------
 */

static int
TcpOutputProc(instanceData, buf, toWrite, errorCodePtr)
    ClientData instanceData;		/* The socket state. */
    char *buf;				/* Where to get data. */
    int toWrite;			/* Maximum number of bytes to write. */
    int *errorCodePtr;			/* Where to store error codes. */
{
    SocketInfo *infoPtr = (SocketInfo *) instanceData;
    int bytesWritten;
    int state;

    *errorCodePtr = 0;

    /*
     * Check that WinSock is initialized; do not call it if not, to
     * prevent system crashes. This can happen at exit time if the exit
     * handler for WinSock ran before other exit handlers that want to
     * use sockets.
     */

    if (winSock.handle == NULL) {
        *errorCodePtr = EFAULT;
        return -1;
    }
    
    /*
     * Check to see if the socket is connected, if it is allow the write,
     * otherwise behave as if we had EWOULDBLOCK.
     */
    
    state = WaitForConnect(infoPtr, errorCodePtr);
    if (state != 0) {
        return -1;
    }
    bytesWritten = (*winSock.send)(infoPtr->socket, buf, toWrite, 0);
    if (bytesWritten == SOCKET_ERROR) {
	TclWinConvertWSAError((*winSock.WSAGetLastError)());
	if (errno == EWOULDBLOCK) {
	    infoPtr->flags &= (~(TCL_WRITABLE));
	}
        *errorCodePtr = errno;
        return -1;
    }

    /*
     * Clear the writable bit in the flags.  If an async handler
     * is still registered for this socket, then it will generate a new
     * event if there is still data available.  When the event is
     * processed, the writable bit will be turned back on.
     */

    infoPtr->flags &= (~(TCL_WRITABLE));

    return bytesWritten;
}

/*
 *----------------------------------------------------------------------
 *
 * TcpGetOptionProc --
 *
 *	Computes an option value for a TCP socket based channel, or a
 *	list of all options and their values.
 *
 *	Note: This code is based on code contributed by John Haxby.
 *
 * Results:
 *	A standard Tcl result. The value of the specified option or a
 *	list of all options and	their values is returned in the
 *	supplied DString.
 *
 * Side effects:
 *	None.
 *
 *----------------------------------------------------------------------
 */

static int
TcpGetOptionProc(instanceData, optionName, dsPtr)
    ClientData instanceData;		/* Socket state. */
    char *optionName;			/* Name of the option to
                                         * retrieve the value for, or
                                         * NULL to get all options and
                                         * their values. */
    Tcl_DString *dsPtr;			/* Where to store the computed
                                         * value; initialized by caller. */
{
    SocketInfo *infoPtr;
    struct sockaddr_in sockname;
    struct sockaddr_in peername;
    struct hostent *hostEntPtr;
    SOCKET sock;
    int size = sizeof(struct sockaddr_in);
    size_t len = 0;
    char buf[128];

    /*
     * Check that WinSock is initialized; do not call it if not, to
     * prevent system crashes. This can happen at exit time if the exit
     * handler for WinSock ran before other exit handlers that want to
     * use sockets.
     */

    if (winSock.handle == NULL) {
        return TCL_ERROR;
    }
    
    infoPtr = (SocketInfo *) instanceData;
    sock = (int) infoPtr->socket;
    if (optionName != (char *) NULL) {
        len = strlen(optionName);
    }

    if ((len == 0) ||
            ((len > 1) && (optionName[1] == 'p') &&
                    (strncmp(optionName, "-peername", len) == 0))) {
        if ((*winSock.getpeername)(sock, (struct sockaddr *) &peername, &size)
                >= 0) {
            if (len == 0) {
                Tcl_DStringAppendElement(dsPtr, "-peername");
                Tcl_DStringStartSublist(dsPtr);
            }
            Tcl_DStringAppendElement(dsPtr,
                    (*winSock.inet_ntoa)(peername.sin_addr));
            hostEntPtr = (*winSock.gethostbyaddr)(
                (char *) &(peername.sin_addr), sizeof(peername.sin_addr),
                AF_INET);
            if (hostEntPtr != (struct hostent *) NULL) {
                Tcl_DStringAppendElement(dsPtr, hostEntPtr->h_name);
            } else {
                Tcl_DStringAppendElement(dsPtr,
                        (*winSock.inet_ntoa)(peername.sin_addr));
            }
            sprintf(buf, "%d", (*winSock.ntohs)(peername.sin_port));
            Tcl_DStringAppendElement(dsPtr, buf);
            if (len == 0) {
                Tcl_DStringEndSublist(dsPtr);
            } else {
                return TCL_OK;
            }
        }
    }

    if ((len == 0) ||
            ((len > 1) && (optionName[1] == 's') &&
                    (strncmp(optionName, "-sockname", len) == 0))) {
        if ((*winSock.getsockname)(sock, (struct sockaddr *) &sockname, &size)
                >= 0) {
            if (len == 0) {
                Tcl_DStringAppendElement(dsPtr, "-sockname");
                Tcl_DStringStartSublist(dsPtr);
            }
            Tcl_DStringAppendElement(dsPtr,
                    (*winSock.inet_ntoa)(sockname.sin_addr));
            hostEntPtr = (*winSock.gethostbyaddr)(
                (char *) &(sockname.sin_addr), sizeof(peername.sin_addr),
                AF_INET);
            if (hostEntPtr != (struct hostent *) NULL) {
                Tcl_DStringAppendElement(dsPtr, hostEntPtr->h_name);
            } else {
                Tcl_DStringAppendElement(dsPtr,
                        (*winSock.inet_ntoa)(sockname.sin_addr));
            }
            sprintf(buf, "%d", (*winSock.ntohs)(sockname.sin_port));
            Tcl_DStringAppendElement(dsPtr, buf);
            if (len == 0) {
                Tcl_DStringEndSublist(dsPtr);
            } else {
                return TCL_OK;
            }
        }
    }

    if (len > 0) {
        Tcl_SetErrno(EINVAL);
        return TCL_ERROR;
    }

    return TCL_OK;
}

/*
 *----------------------------------------------------------------------
 *
 * TcpWatchProc --
 *
 *	Initialize the notifier to watch Tcl_Files from this channel.
 *
 * Results:
 *	None.
 *
 * Side effects:
 *	Sets up the notifier so that a future event on the channel will
 *	be seen by Tcl.
 *
 *----------------------------------------------------------------------
 */

static void
TcpWatchProc(instanceData, mask)
    ClientData instanceData;		/* The socket state. */
    int mask;				/* Events of interest; an OR-ed
                                         * combination of TCL_READABLE,
                                         * TCL_WRITABEL and TCL_EXCEPTION. */
{
    SocketInfo *infoPtr = (SocketInfo *) instanceData;

    Tcl_WatchFile(infoPtr->file, mask);
}

/*
 *----------------------------------------------------------------------
 *
 * TcpReadyProc --
 *
 *	Called by the notifier to check whether events of interest are
 *	present on the channel.
 *
 * Results:
 *	Returns OR-ed combination of TCL_READABLE, TCL_WRITABLE and
 *	TCL_EXCEPTION to indicate which events of interest are present.
 *
 * Side effects:
 *	None.
 *
 *----------------------------------------------------------------------
 */

static int
TcpReadyProc(instanceData, mask)
    ClientData instanceData;		/* The socket state. */
    int mask;				/* Events of interest; an OR-ed
                                         * combination of TCL_READABLE,
                                         * TCL_WRITABLE and TCL_EXCEPTION. */
{
    SocketInfo *infoPtr = (SocketInfo *) instanceData;

    return Tcl_FileReady(infoPtr->file, mask);
}

/*
 *----------------------------------------------------------------------
 *
 * TcpGetProc --
 *
 *	Called from Tcl_GetChannelFile to retrieve Tcl_Files from inside
 *	a TCP socket based channel.
 *
 * Results:
 *	The appropriate Tcl_File or NULL if not present. 
 *
 * Side effects:
 *	None.
 *
 *----------------------------------------------------------------------
 */

	/* ARGSUSED */
static Tcl_File
TcpGetProc(instanceData, direction)
    ClientData instanceData;		/* The socket state. */
    int direction;			/* Which Tcl_File to retrieve? */
{
    SocketInfo *statePtr = (SocketInfo *) instanceData;

    return statePtr->file;
}

/*
 *----------------------------------------------------------------------
 *
 * TclWinWatchSocket --
 *
 *	This function imlements the socket specific portion of the
 *	Tcl_WatchFile function in the notifier.
 *
 * Results:
 *	None.
 *
 * Side effects:
 *	The watched socket will be placed into non-blocking mode, and
 *	an entry on the asynch handler list will be created if necessary. 
 *
 *----------------------------------------------------------------------
 */

void
TclWinWatchSocket(file, mask)
    Tcl_File file;		/* Socket to watch. */
    int mask;			/* OR'ed combination of TCL_READABLE,
				 * TCL_WRITABLE, and TCL_EXCEPTION:
				 * indicates conditions to wait for
				 * in select. */
{
    SocketInfo *infoPtr = (SocketInfo *) Tcl_GetNotifierData(file, NULL);
    Tcl_Time dontBlock;

    dontBlock.sec = 0; dontBlock.usec = 0;

    /*
     * Create socket info on demand if necessary.  We should only enter this
     * code if the socket was created outside of Tcl.  Since this may be
     * the first time that the socket code has been called, we need to invoke
     * TclHasSockets to ensure that everything is initialized properly.
     */

    if (infoPtr == NULL) {
	if (TclHasSockets(NULL) != TCL_OK) {
	    return;
	}
	infoPtr = NewSocketInfo(file);
    }

    infoPtr->flags |= SOCKET_WATCH;
        
    /*
     * If the new mask includes more conditions than the current mask,
     * then we mark the socket as unregistered so it will be reregistered
     * the next time we enter Tcl_WaitForEvent.
     */

    mask |= infoPtr->watchMask;
    if (infoPtr->watchMask != mask) {
	infoPtr->flags &= (~(SOCKET_REGISTERED));
	infoPtr->watchMask = mask;
    }

    /*
     * Check if any bits are set on the flags. If there are, this
     * means that the socket already had events on it, and we need to
     * check it immediately. To do this, set the maximum block time to
     * zero.
     */

    if ((infoPtr->flags & (TCL_READABLE|TCL_WRITABLE|TCL_EXCEPTION)) != 0) {
        Tcl_SetMaxBlockTime(&dontBlock);
    }
}

/*
 *----------------------------------------------------------------------
 *
 * TclWinNotifySocket --
 *
 *	Set up event notifiers for any sockets that are being watched.
 *	Also, clean up any sockets that are no longer being watched.
 *
 * Results:
 *	None.
 *
 * Side effects:
 *	Adds and removes asynch select handlers.
 *
 *----------------------------------------------------------------------
 */

void
TclWinNotifySocket()
{
    SocketInfo *infoPtr;

    /*
     * Check that WinSock is initialized; do not call it if not, to
     * prevent system crashes. This can happen at exit time if the exit
     * handler for WinSock ran before other exit handlers that want to
     * use sockets.
     */

    if (winSock.handle == NULL) {
        return;
    }

    if (socketList == NULL) {
	return;
    }

    /*
     * Establish or remove any notifiers.
     */

    for (infoPtr = socketList; infoPtr != NULL; infoPtr = infoPtr->nextPtr) {
	if (infoPtr->flags & SOCKET_WATCH) {
	    if (!(infoPtr->flags & SOCKET_REGISTERED)) {
		int events = 0;
                
		if (infoPtr->watchMask & TCL_READABLE) {
		    events |= (FD_READ | FD_ACCEPT | FD_CLOSE);
		}
                if (infoPtr->watchMask & TCL_WRITABLE) {
		    events |= (FD_WRITE | FD_CONNECT);
		}

                /*
                 * If we are interested in any events, mark the
                 * socket as registered.
                 */

                if (events != 0) {
                    infoPtr->flags |= SOCKET_REGISTERED;
                }

                /*
                 * If the new event interest mask does not match what is
                 * currently set into the socket, set the new mask.
                 */

                if (events != infoPtr->eventMask) {
                    infoPtr->eventMask = events;
                    (*winSock.WSAAsyncSelect)(infoPtr->socket, socketWindow,
                            SOCKET_MESSAGE, events);
                }

	    }
	} else {

            /*
             * We are no longer supposed to be watching this socket. Remove
             * its registration and remember that we are not interested in
             * any events on it.
             */
            
	    if (infoPtr->flags & SOCKET_REGISTERED) {
                infoPtr->flags &= ~(SOCKET_REGISTERED);
                infoPtr->eventMask = 0;
		(*winSock.WSAAsyncSelect)(infoPtr->socket, socketWindow, 0, 0);
	    }
	}
    }
}

/*
 *----------------------------------------------------------------------
 *
 * TclWinSocketReady --
 *
 *	This function is invoked by Tcl_FileReady to check whether
 *	the specified conditions are present on a socket.
 *
 * Results:
 *	The return value is 0 if none of the conditions specified by
 *	mask were true for socket the last time the system checked.
 *	If any of the conditions were true, then the return value is a
 *	mask of those that were true.
 *
 * Side effects:
 *	None.
 *
 *----------------------------------------------------------------------
 */

int
TclWinSocketReady(file, mask)
    Tcl_File file;	/* File handle for a stream. */
    int mask;		/* OR'ed combination of TCL_READABLE,
			 * TCL_WRITABLE, and TCL_EXCEPTION:
			 * indicates conditions caller cares about. */
{
    SocketInfo *infoPtr = (SocketInfo *) Tcl_GetNotifierData(file, NULL);
    int result, status, occurred;
    u_long nBytes;

    /*
     * Check that WinSock is initialized; do not call it if not, to
     * prevent system crashes. This can happen at exit time if the exit
     * handler for WinSock ran before other exit handlers that want to
     * use sockets.
     */

    if (winSock.handle == NULL) {
        return 0;
    }
    
    result = (infoPtr->flags & mask);
    occurred = infoPtr->occurredMask;
    infoPtr->occurredMask = 0;
    infoPtr->flags &= (~(SOCKET_WATCH));

    if (result & TCL_READABLE) {
        
        /*
         * Must check for readability condition still being present on the
         * socket, because someone might have consumed the data in the
         * meantime. If we are accepting on the socket or it got closed,
         * the socket is readable.
         */

        if (occurred & FD_ACCEPT) {
            /* Empty body. */
        } else {
            if (occurred & FD_CLOSE) {
                /* Remember the FD_CLOSE event. */
                infoPtr->flags |= SOCKET_CLOSED;
            }

            /*
             * The socket is readable only if there is data present.
	     * NOTE: We do not really care whether FD_READ happened..
             */

            status = (*winSock.ioctlsocket)(infoPtr->socket, FIONREAD,
                    &nBytes);
            if ((status == SOCKET_ERROR) ||
                    ((nBytes == 0) && (!(infoPtr->flags & SOCKET_CLOSED)))) {
                result &= (~(TCL_READABLE));
                infoPtr->flags &= (~(TCL_READABLE));
            }
        }
    }        
    return result;
}

/*
 *----------------------------------------------------------------------
 *
 * SocketProc --
 *
 *	This function is called when WSAAsyncSelect has been used
 *	to register interest in a socket event, and the event has
 *	occurred.
 *
 * Results:
 *	0 on success.
 *
 * Side effects:
 *	The flags for the given socket are updated to reflect the
 *	event that occured.
 *
 *----------------------------------------------------------------------
 */

static LRESULT CALLBACK
SocketProc(hwnd, message, wParam, lParam)
    HWND hwnd;
    UINT message;
    WPARAM wParam;
    LPARAM lParam;
{
    int event;
    SOCKET socket;
    SocketInfo *infoPtr;

    if ((hwnd != socketWindow) || (message != SOCKET_MESSAGE)) {
	return DefWindowProc(hwnd, message, wParam, lParam);
    }
    
    event = WSAGETSELECTEVENT(lParam);
    socket = (SOCKET) wParam;

    /*
     * Find the specified socket on the socket list and update its
     * check flags.
     */

    for (infoPtr = socketList; infoPtr != NULL; infoPtr = infoPtr->nextPtr) {
	if (infoPtr->socket == socket) {

	    if (event & (FD_READ | FD_ACCEPT | FD_CLOSE)) {
		infoPtr->flags |= TCL_READABLE;
	    }
	    if (event & (FD_WRITE | FD_CONNECT)) {
		infoPtr->flags |= TCL_WRITABLE;
	    }
            infoPtr->occurredMask |= event;
	    break;
	}
    }
    return 0;
}

/*
 *----------------------------------------------------------------------
 *
 * Tcl_GetHostName --
 *
 *	Returns the name of the local host.
 *
 * Results:
 *	Returns a string containing the host name, or NULL on error.
 *	The returned string must be freed by the caller.
 *
 * Side effects:
 *	None.
 *
 *----------------------------------------------------------------------
 */

char *
Tcl_GetHostName()
{
    static int  hostnameInitialized = 0;
    static char hostname[255];	/* This buffer should be big enough for
                                 * hostname plus domain name. */

    if (TclHasSockets(NULL) != TCL_OK) {
	return "";
    }

    if (hostnameInitialized) {
        return hostname;
    }
    if ((*winSock.gethostname)(hostname, 100) == 0) {
        hostnameInitialized = 1;
        return hostname;
    }
    return (char *) NULL;
}
/*
 *----------------------------------------------------------------------
 *
 * TclHasSockets --
 *
 *	This function determines whether sockets are available on the
 *	current system and returns an error in interp if they are not.
 *	Note that interp may be NULL.
 *
 * Results:
 *	Returns TCL_OK if the system supports sockets, or TCL_ERROR with
 *	an error in interp.
 *
 * Side effects:
 *	None.
 *
 *----------------------------------------------------------------------
 */

int
TclHasSockets(interp)
    Tcl_Interp *interp;
{
    static int initialized = 0;	/* 1 if the socket system has been
				 * initialized. */
    static int hasSockets = 0;	/* 1 if the system supports sockets. */

    if (!initialized) {
	OSVERSIONINFO info;

	initialized = 1;

	/*
	 * Find out if we're running on Win32s.
	 */

	info.dwOSVersionInfoSize = sizeof(OSVERSIONINFO);
	GetVersionEx(&info);

	/*
	 * Check to see if Sockets are supported on this system.  Since
	 * win32s panics if we call WSAStartup on a system that doesn't
	 * have winsock.dll, we need to look for it on the system first.
	 * If we find winsock, then load the library and initialize the
	 * stub table.
	 */

	if ((info.dwPlatformId != VER_PLATFORM_WIN32s)
		|| (SearchPath(NULL, "WINSOCK", ".DLL", 0, NULL, NULL) != 0)) {
	    hasSockets = InitSockets();
	}
    }
    
    if (hasSockets) {
	return TCL_OK;
    }
    if (interp != NULL) {
	Tcl_AppendResult(interp, "sockets are not available on this system",
		NULL);
    }
    return TCL_ERROR;
}

/*
 *----------------------------------------------------------------------
 *
 * TclWinGetSockOpt, et al. --
 *
 *	These functions are wrappers that let us bind the WinSock
 *	API dynamically so we can run on systems that don't have
 *	the wsock32.dll.  We need wrappers for these interfaces
 *	because they are called from the generic Tcl code 
 *
 * Results:
 *	As defined for each function.
 *
 * Side effects:
 *	As defined for each function.
 *
 *----------------------------------------------------------------------
 */

int PASCAL FAR
TclWinGetSockOpt(SOCKET s, int level, int optname, char FAR * optval,
	int FAR *optlen)
{
    /*
     * Check that WinSock is initialized; do not call it if not, to
     * prevent system crashes. This can happen at exit time if the exit
     * handler for WinSock ran before other exit handlers that want to
     * use sockets.
     */

    if (winSock.handle == NULL) {
        return SOCKET_ERROR;
    }
    
    return (*winSock.getsockopt)(s, level, optname, optval, optlen);
}

int PASCAL FAR
TclWinSetSockOpt(SOCKET s, int level, int optname, const char FAR * optval,
	int optlen)
{
    /*
     * Check that WinSock is initialized; do not call it if not, to
     * prevent system crashes. This can happen at exit time if the exit
     * handler for WinSock ran before other exit handlers that want to
     * use sockets.
     */

    if (winSock.handle == NULL) {
        return SOCKET_ERROR;
    }

    return (*winSock.setsockopt)(s, level, optname, optval, optlen);
}

u_short PASCAL FAR
TclWinNToHS(u_short netshort)
{
    /*
     * Check that WinSock is initialized; do not call it if not, to
     * prevent system crashes. This can happen at exit time if the exit
     * handler for WinSock ran before other exit handlers that want to
     * use sockets.
     */

    if (winSock.handle == NULL) {
        return (u_short) -1;
    }

    return (*winSock.ntohs)(netshort);
}

struct servent FAR * PASCAL FAR
TclWinGetServByName(const char FAR * name, const char FAR * proto)
{
    /*
     * Check that WinSock is initialized; do not call it if not, to
     * prevent system crashes. This can happen at exit time if the exit
     * handler for WinSock ran before other exit handlers that want to
     * use sockets.
     */

    if (winSock.handle == NULL) {
        return (struct servent FAR *) NULL;
    }

    return (*winSock.getservbyname)(name, proto);
}
