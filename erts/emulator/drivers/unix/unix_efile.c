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
 * Purpose: Provides file and directory operations for Unix.
 */
#ifdef HAVE_CONFIG_H
#  include "config.h"
#endif
#include "sys.h"
#include "erl_efile.h"
#include <utime.h>
#ifdef HAVE_UNISTD_H
#include <unistd.h>
#endif
#ifdef VXWORKS
#include <ioLib.h>
#include <dosFsLib.h>
#include <nfsLib.h>
#include <sys/stat.h>
/*
** Not nice to include usrLib.h as MANY normal variable names get reported
** as shadowing globals, like 'i' for example.
** Instead we declare the only function we use here
*/
/*
 * #include <usrLib.h>
 */
extern STATUS copy(char *, char *);
#include <errno.h>
#else /* UNIX */
#  if defined(HAVE_FCNTL_H) && defined(HAVE_F_DUPFD)
#    include <fcntl.h>
     static int try_dup = -1;
#    if defined(NO_SYSCONF)
#      include <sys/param.h>
#      define MAX_FILES()	NOFILE
#    else
#      define MAX_FILES()	sysconf(_SC_OPEN_MAX)
#    endif
#  endif
#endif /* !VXWORKS */

#ifdef SUNOS4
#  define getcwd(buf, size) getwd(buf)
#endif

/*
 * Macros for testing file types.
 */
  
#define ISDIR(st) (((st).st_mode & S_IFMT) == S_IFDIR)
#define ISREG(st) (((st).st_mode & S_IFMT) == S_IFREG)
#define ISDEV(st) \
  (((st).st_mode&S_IFMT) == S_IFCHR || ((st).st_mode&S_IFMT) == S_IFBLK)
#define ISLNK(st) (((st).st_mode & S_IFLNK) == S_IFLNK)

#ifdef NO_UMASK
#define FILE_MODE 0644
#define DIR_MODE  0755
#else
#define FILE_MODE 0666
#define DIR_MODE  0777
#endif

#define IS_DOT_OR_DOTDOT(s) \
    (s[0] == '.' && (s[1] == '\0' || (s[1] == '.' && s[2] == '\0')))

#ifdef VXWORKS
   /* Use the reentrant version of localtime() */
   static struct tm local_tm;
#  define localtime(a) (localtime_r((a), &local_tm), &local_tm)

static FUNCTION(int, vxworks_to_posix, (int vx_errno));
#endif

/*
** VxWorks (not) strikes again. Too long RESULTING paths
** may give the infamous bus error. Have to check ALL
** filenames and pathnames. No wonder the emulator is slow on
** these cards...
*/
#ifdef VXWORKS
#define CHECK_PATHLEN(Name, ErrInfo)		\
   if (path_size(Name) > PATH_MAX) {		\
       errno = ENAMETOOLONG;			\
       return check_error(-1, ErrInfo);		\
   }
#else
#define CHECK_PATHLEN(X,Y) /* Nothing */
#endif

static FUNCTION(int, check_error, (int result, Efile_error* errInfo));

static int
check_error(int result, Efile_error *errInfo)
{
    if (result < 0) {
#ifdef VXWORKS
	errInfo->posix_errno = errInfo->os_errno = vxworks_to_posix(errno);
#else
	errInfo->posix_errno = errInfo->os_errno = errno;
#endif
	return 0;
    }
    return 1;
}

#ifdef VXWORKS

/*
 * VxWorks has different error codes for different file systems.
 * We map those to POSIX ones.
 */
static int
vxworks_to_posix(int vx_errno)
{
    DEBUGF(("[vxworks_to_posix] vx_errno: %08x\n", vx_errno));
    switch (vx_errno) {
	/* dosFsLib mapping */
    case S_dosFsLib_VOLUME_NOT_AVAILABLE: return ENXIO;
    case S_dosFsLib_DISK_FULL: return ENOSPC;
    case S_dosFsLib_FILE_NOT_FOUND: return ENOENT;
    case S_dosFsLib_NO_FREE_FILE_DESCRIPTORS: return ENFILE;
    case S_dosFsLib_INVALID_NUMBER_OF_BYTES: return EINVAL;
    case S_dosFsLib_FILE_ALREADY_EXISTS: return EEXIST;
    case S_dosFsLib_ILLEGAL_NAME: return EINVAL;
    case S_dosFsLib_CANT_DEL_ROOT: return EACCES;
    case S_dosFsLib_NOT_FILE: return EISDIR;
    case S_dosFsLib_NOT_DIRECTORY: return ENOTDIR;
    case S_dosFsLib_NOT_SAME_VOLUME: return EXDEV;
    case S_dosFsLib_READ_ONLY: return EACCES;
    case S_dosFsLib_ROOT_DIR_FULL: return ENOSPC;
    case S_dosFsLib_DIR_NOT_EMPTY: return EEXIST;
    case S_dosFsLib_BAD_DISK: return EIO;
    case S_dosFsLib_NO_LABEL: return ENXIO;
    case S_dosFsLib_INVALID_PARAMETER: return EINVAL;
    case S_dosFsLib_NO_CONTIG_SPACE: return ENOSPC;
    case S_dosFsLib_CANT_CHANGE_ROOT: return EINVAL;
    case S_dosFsLib_FD_OBSOLETE: return EBADF;
    case S_dosFsLib_DELETED: return EINVAL;
    case S_dosFsLib_NO_BLOCK_DEVICE: return ENOTBLK;
    case S_dosFsLib_BAD_SEEK: return ESPIPE;
    case S_dosFsLib_INTERNAL_ERROR: return EIO;
    case S_dosFsLib_WRITE_ONLY: return EACCES;
	/* nfsLib mapping - is needed since Windriver has used */
	/* inconsistent error codes (errno.h/nfsLib.h). */
    case S_nfsLib_NFS_OK: return 0;
    case S_nfsLib_NFSERR_PERM: return EPERM;
    case S_nfsLib_NFSERR_NOENT: return ENOENT;
    case S_nfsLib_NFSERR_IO: return EIO;
    case S_nfsLib_NFSERR_NXIO: return ENXIO;
    case S_nfsLib_NFSERR_ACCES: return EACCES;
    case S_nfsLib_NFSERR_EXIST: return EEXIST;
    case S_nfsLib_NFSERR_NODEV: return ENODEV;
    case S_nfsLib_NFSERR_NOTDIR: return ENOTDIR;
    case S_nfsLib_NFSERR_ISDIR: return EISDIR;
    case S_nfsLib_NFSERR_FBIG: return EFBIG;
    case S_nfsLib_NFSERR_NOSPC: return ENOSPC;
    case S_nfsLib_NFSERR_ROFS: return EROFS;
    case S_nfsLib_NFSERR_NAMETOOLONG: return ENAMETOOLONG;
    case S_nfsLib_NFSERR_NOTEMPTY: return EEXIST;
    case S_nfsLib_NFSERR_DQUOT: return ENOSPC;
    case S_nfsLib_NFSERR_STALE: return EINVAL;
    case S_nfsLib_NFSERR_WFLUSH: return ENXIO;
	/* And sometimes (...) the error codes are from ioLib (as in the */
	/* case of the (for nfsLib) unimplemented rename function) */
    case S_ioLib_NO_DRIVER: return ENXIO;
    case S_ioLib_UNKNOWN_REQUEST: return ENOSYS;
    case S_ioLib_DEVICE_ERROR: return ENXIO;
    case  S_ioLib_DEVICE_TIMEOUT: return EIO;
    case S_ioLib_WRITE_PROTECTED: return EACCES;
    case  S_ioLib_DISK_NOT_PRESENT: return EIO;
    case S_ioLib_NO_FILENAME: return EINVAL;
    case S_ioLib_CANCELLED: return EINTR;
    case  S_ioLib_NO_DEVICE_NAME_IN_PATH: return EINVAL;
    case  S_ioLib_NAME_TOO_LONG: return ENAMETOOLONG;
#ifdef S_ioLib_UNFORMATED
	/* Added (VxWorks 5.2 -> 5.3.1) */
    case S_ioLib_UNFORMATED: return EIO;
#endif
    }
    /* If the error code matches none of the above, assume */
    /* it is a POSIX one already. The upper bits (>=16) are */
    /* cleared since VxWorks uses those bits to indicate in */
    /* what module the error occured. */
    return vx_errno & 0xffff;
}

static int 
vxworks_enotsup(Efile_error *errInfo) 
{
    errInfo->posix_errno = errInfo->os_errno = ENOTSUP;
    return 0;
}

static int 
count_path_length(char *pathname, char *pathname2)
{
    static int stack[PATH_MAX / 2 + 1];
    int sp = 0;
    char *tmp;
    char *cpy = NULL;
    int i;
    int sum;
    for(i = 0;i < 2;++i) {
	if (!i) {
	    cpy = malloc(strlen(pathname)+1);
	    strcpy(cpy, pathname);
	} else if (pathname2 != NULL) {
	    free(cpy);
	    cpy = malloc(strlen(pathname2)+1);
	    strcpy(cpy, pathname2);
	} else 
	    break;
	    
	for (tmp = strtok(cpy,"/"); tmp != NULL; tmp = strtok(NULL,"/")) {
	    if (!strcmp(tmp,"..") && sp > 0)
		--sp;
	    else if (strcmp(tmp,".")) 
		stack[sp++] = strlen(tmp);
	}
    }
    if (cpy != NULL)
	free(cpy);
    sum = 0;
    for(i = 0;i < sp; ++i)
	sum += stack[i]+1;
    return (sum) ? sum : 1;
}

static int 
path_size(char *pathname) 
{
    static char currdir[PATH_MAX+2];
    if (*pathname == '/') 
	return count_path_length(pathname,NULL);
    ioDefPathGet(currdir);
    strcat(currdir,"/");
    return count_path_length(currdir,pathname);
}
    
#endif

int
efile_mkdir(Efile_error* errInfo,	/* Where to return error codes. */
	    char* name)			/* Name of directory to create. */
{
    CHECK_PATHLEN(name,errInfo);
#ifdef NO_MKDIR_MODE
#ifdef VXWORKS
	/* This is a VxWorks/nfs workaround for erl_tar to create
	 * non-existant directories. (of some reason (...) VxWorks
	 * returns, the *non-module-prefixed*, 0xd code when
	 * trying to create a directory in a directory that doesn't exist).
	 * (see efile_openfile)
	 */
    if (mkdir(name) < 0) {
	struct stat sb;
	if (stat(name, &sb) == OK) {
	    errno = S_nfsLib_NFSERR_EXIST;
	} else if((strchr(name, '/') != NULL) && (errno == 0xd)) {
	/* Return the correct error code enoent */ 
	    errno = S_nfsLib_NFSERR_NOENT;
	}
	return check_error(-1, errInfo);
    } else return 1;
#else
    return check_error(mkdir(name), errInfo);
#endif
#else
    return check_error(mkdir(name, DIR_MODE), errInfo);
#endif
}

int
efile_rmdir(Efile_error* errInfo,	/* Where to return error codes. */
	    char* name)			/* Name of directory to delete. */
{
    CHECK_PATHLEN(name, errInfo);
    if (rmdir(name) == 0) {
	return 1;
    }
    if (errno == ENOTEMPTY) {
	errno = EEXIST;
    }
    if (errno == EEXIST) {
	int saved_errno = errno;
	struct stat file_stat;
	struct stat cwd_stat;

	/*
	 *  The error code might be wrong if this is the current directory.
	 */

	if (stat(name, &file_stat) == 0 && stat(".", &cwd_stat) == 0 &&
	    file_stat.st_ino == cwd_stat.st_ino &&
	    file_stat.st_dev == cwd_stat.st_dev) {
	    saved_errno = EINVAL;
	}
	errno = saved_errno;
    }
    return check_error(-1, errInfo);
}

int
efile_delete_file(Efile_error* errInfo,	/* Where to return error codes. */
		  char* name)		/* Name of file to delete. */
{
    CHECK_PATHLEN(name,errInfo);
    if (unlink(name) == 0) {
	return 1;
    }
    if (errno == EISDIR) {	/* Linux sets the wrong error code. */
	errno = EPERM;
    }
    return check_error(-1, errInfo);
}

/*
 *---------------------------------------------------------------------------
 *
 *      Changes the name of an existing file or directory, from src to dst.
 *	If src and dst refer to the same file or directory, does nothing
 *	and returns success.  Otherwise if dst already exists, it will be
 *	deleted and replaced by src subject to the following conditions:
 *	    If src is a directory, dst may be an empty directory.
 *	    If src is a file, dst may be a file.
 *	In any other situation where dst already exists, the rename will
 *	fail.  
 *
 * Results:
 *	If the directory was successfully created, returns 1.
 *	Otherwise the return value is 0 and errno is set to
 *	indicate the error.  Some possible values for errno are:
 *
 *	EACCES:     src or dst parent directory can't be read and/or written.
 *	EEXIST:	    dst is a non-empty directory.
 *	EINVAL:	    src is a root directory or dst is a subdirectory of src.
 *	EISDIR:	    dst is a directory, but src is not.
 *	ENOENT:	    src doesn't exist, or src or dst is "".
 *	ENOTDIR:    src is a directory, but dst is not.  
 *	EXDEV:	    src and dst are on different filesystems.
 *	
 * Side effects:
 *	The implementation of rename may allow cross-filesystem renames,
 *	but the caller should be prepared to emulate it with copy and
 *	delete if errno is EXDEV.
 *
 *---------------------------------------------------------------------------
 */

int
efile_rename(Efile_error* errInfo,	/* Where to return error codes. */
	     char* src,		        /* Original name. */
	     char* dst)			/* New name. */
{
    CHECK_PATHLEN(src,errInfo);
    CHECK_PATHLEN(dst,errInfo);
#ifdef VXWORKS
	
    /* First check if src == dst, if so, just return. */
    /* VxWorks dos file system destroys the file otherwise, */
    /* VxWorks nfs file system rename doesn't work at all. */
    if(strcmp(src, dst) == 0)
	return 1;
#endif
    if (rename(src, dst) == 0) {
	return 1;
    }
#ifdef VXWORKS
    /* nfs for VxWorks doesn't support rename. We try to emulate it */
    /* (by first copying src to dst and then deleting src). */
    if(errno == S_ioLib_UNKNOWN_REQUEST &&     /* error code returned 
						  by ioLib (!) */ 
       copy(src, dst) == OK &&
       unlink(src) == OK)
	return 1;
#endif
    if (errno == ENOTEMPTY) {
	errno = EEXIST;
    }
#if defined (sparc) && !defined(VXWORKS)
    /*
     * SunOS 4.1.4 reports overwriting a non-empty directory with a
     * directory as EINVAL instead of EEXIST (first rule out the correct
     * EINVAL result code for moving a directory into itself).  Must be
     * conditionally compiled because realpath() is only defined on SunOS.
     */

    if (errno == EINVAL) {
	char srcPath[MAXPATHLEN], dstPath[MAXPATHLEN];
	DIR *dirPtr;
	struct dirent *dirEntPtr;

	if ((realpath(src, srcPath) != NULL)
		&& (realpath(dst, dstPath) != NULL)
		&& (strncmp(srcPath, dstPath, strlen(srcPath)) != 0)) {
	    dirPtr = opendir(dst);
	    if (dirPtr != NULL) {
		while ((dirEntPtr = readdir(dirPtr)) != NULL) {
		    if ((strcmp(dirEntPtr->d_name, ".") != 0) &&
			    (strcmp(dirEntPtr->d_name, "..") != 0)) {
			errno = EEXIST;
			closedir(dirPtr);
			return check_error(-1, errInfo);
		    }
		}
		closedir(dirPtr);
	    }
	}
	errno = EINVAL;
    }
#endif	/* sparc */

    if (strcmp(src, "/") == 0) {
	/*
	 * Alpha reports renaming / as EBUSY and Linux reports it as EACCES,
	 * instead of EINVAL.
	 */
	 
	errno = EINVAL;
    }

    /*
     * DEC Alpha OSF1 V3.0 returns EACCES when attempting to move a
     * file across filesystems and the parent directory of that file is
     * not writable.  Most other systems return EXDEV.  Does nothing to
     * correct this behavior.
     */

    return check_error(-1, errInfo);
}

int
efile_chdir(Efile_error* errInfo,   /* Where to return error codes. */
	    char* name)		    /* Name of directory to make current. */
{
    CHECK_PATHLEN(name, errInfo);
    return check_error(chdir(name), errInfo);
}


int
efile_getdcwd(Efile_error* errInfo,	/* Where to return error codes. */
	      int drive,		/* 0 - current, 1 - A, 2 - B etc. */
	      char* buffer,		/* Where to return the current 
					   directory. */
	      unsigned size)		/* Size of buffer. */
{
    if (drive == 0) {
	if (getcwd(buffer, size) == NULL)
	    return check_error(-1, errInfo);
	return 1;
    }

    /*
     * Drives other than 0 is not supported on Unix.
     */

    errno = ENOTSUP;
    return check_error(-1, errInfo);
}

int
efile_opendir(Efile_error* errInfo,	/* Where to return error codes. */
	      char* name,		/* Name of directory to open. */
	      EFILE_DIR_HANDLE* p_dir_handle)	/* Where to return 
						   directory handle. */
{
    DIR *dp;

    CHECK_PATHLEN(name, errInfo);

    dp = opendir(name);
    if (dp == NULL)
	return check_error(-1, errInfo);
    *p_dir_handle = (EFILE_DIR_HANDLE) dp;
    return 1;
}

int
efile_readdir(Efile_error* errInfo,	/* Where to return error codes. */
	      char* name,		/* Name of directory to open. */
	      EFILE_DIR_HANDLE* p_dir_handle,	/* Pointer to directory 
						   handle of
						   open directory.*/
	      char* buffer,		/* Pointer to buffer for 
					   one filename. */
	      unsigned int size)	/* Size of buffer. */
{
    DIR *dp;			/* Pointer to directory structure. */
    struct dirent* dirp;	/* Pointer to directory entry. */

    /*
     * If this is the first call, we must open the directory.
     */

    CHECK_PATHLEN(name, errInfo);

    if (*p_dir_handle == NULL) {
	dp = opendir(name);
	if (dp == NULL)
	    return check_error(-1, errInfo);
	*p_dir_handle = (EFILE_DIR_HANDLE) dp;
    }

    /*
     * Retrieve the name of the next file using the directory handle.
     */

    dp = *((DIR **)((void *)p_dir_handle));
    for (;;) {
	dirp = readdir(dp);
	if (dirp == NULL) {
	    closedir(dp);
	    return 0;
	}
	if (IS_DOT_OR_DOTDOT(dirp->d_name))
	    continue;
	buffer[0] = '\0';
	strncat(buffer, dirp->d_name, size);
	return 1;
    }
}

int
efile_openfile(Efile_error* errInfo,	/* Where to return error codes. */
	       char* name,		/* Name of directory to open. */
	       int flags,		/* Flags to user for opening. */
	       int* pfd,		/* Where to store the file 
					   descriptor. */
	       unsigned int *pSize)	/* Where to store the size of the 
					   file. */
{
    struct stat statbuf;
    int fd;
    int mode;			/* Open mode. */
#ifdef VXWORKS
    char pathbuff[PATH_MAX+2];
    char sbuff[PATH_MAX*2];
    char *totbuff = sbuff;
    int nameneed;
#endif


    CHECK_PATHLEN(name, errInfo);

#ifdef VXWORKS
    /* Have to check that it's not a directory. */
    if (stat(name,&statbuf) != ERROR && ISDIR(statbuf)) {
	errno = EISDIR;
	return check_error(-1, errInfo);
    }	
#endif	

    switch (flags & (EFILE_MODE_READ|EFILE_MODE_WRITE)) {
    case EFILE_MODE_READ:
	mode = O_RDONLY;
	break;
    case EFILE_MODE_WRITE:
	if (flags & EFILE_NO_TRUNCATE)
	    mode = O_WRONLY | O_CREAT;
	else
	    mode = O_WRONLY | O_CREAT | O_TRUNC;
	break;
    case EFILE_MODE_READ_WRITE:
	mode = O_RDWR | O_CREAT;
	break;
    default:
	errno = EINVAL;
	return check_error(-1, errInfo);
    }


    if (flags & EFILE_MODE_APPEND) {
	mode &= ~O_TRUNC;
#ifndef VXWORKS
	mode |= O_APPEND; /* Dont make VxWorks think things it shouldn't */
#endif
    }


#ifdef VXWORKS
    if (*name != '/') {
	/* Make sure it is an absolute pathname, because ftruncate needs it */
	ioDefPathGet(pathbuff);
	strcat(pathbuff,"/");
	nameneed = strlen(pathbuff) + strlen(name) + 1;
	if (nameneed > PATH_MAX*2)
	    totbuff = malloc(nameneed);
	strcpy(totbuff,pathbuff);
	strcat(totbuff,name);
	fd = open(totbuff, mode, FILE_MODE);
	if (totbuff != sbuff)
	    free(totbuff);
    } else {
	fd = open(name, mode, FILE_MODE);
    }
#else
    fd = open(name, mode, FILE_MODE);
#endif

#ifdef VXWORKS

	/* This is a VxWorks/nfs workaround for erl_tar to create 
	 * non-existant directories. (of some reason (...) VxWorks
	 * returns, the *non-module-prefixed*, 0xd code when
	 * trying to write a file in a directory that doesn't exist).
	 * (see efile_mkdir)
	 */
    if ((fd < 0) && (strchr(name, '/') != NULL) && (errno == 0xd)) {
	/* Return the correct error code enoent */ 
	errno = S_nfsLib_NFSERR_NOENT;
	return check_error(-1, errInfo);
    }
#endif

    if (!check_error(fd, errInfo))
	return 0;
    if (fstat(fd, &statbuf) < 0) {
	close(fd);
	return check_error(-1, errInfo);
    }
    if (!ISREG(statbuf)) {
	close(fd);
	errno = EISDIR;
	return check_error(-1, errInfo);
    }

#if !defined(VXWORKS) && defined(HAVE_FCNTL_H) && defined(HAVE_F_DUPFD)
    if (try_dup < 0) {
	try_dup = MAX_FILES() > 1024;
    }
    if (try_dup) {
	if ((*pfd = fcntl(fd,F_DUPFD,1024)) < 0) {
	    *pfd = fd;
	} else {
	    close(fd);
	}
    } else {
	*pfd = fd;
    }
#else
    *pfd = fd;
#endif
    *pSize = statbuf.st_size;
    return 1;
}

void
efile_closefile(int fd)
{
    close(fd);
}

int
efile_fsync(Efile_error *errInfo, /* Where to return error codes. */
	    int fd)               /* File descriptor for file to sync. */
{
#ifdef NO_FSYNC
#ifdef VXWORKS
    return check_error(ioctl(fd, FIOSYNC, 0), errInfo); 
#else
  undefined fsync
#endif /* VXWORKS */
#else
    return check_error(fsync(fd), errInfo);
#endif /* NO_FSYNC */
}

int
efile_fileinfo(Efile_error* errInfo, Efile_info* pInfo, 
	       char* name, int info_for_link)
{
    struct stat statbuf;	/* Information about the file */
    struct tm *timep;		/* Broken-apart filetime. */
    int result;

    CHECK_PATHLEN(name, errInfo);

    if (info_for_link) {
#ifdef VXWORKS
	result = stat(name, &statbuf);
#else
	result = lstat(name, &statbuf);
#endif
    } else {
	result = stat(name, &statbuf);
    }	
    if (!check_error(result, errInfo)) {
	return 0;
    }

    pInfo->size_high = 0;
    pInfo->size_low = statbuf.st_size;

#ifdef NO_ACCESS
    /* Just look at read/write access for owner. */
#ifdef VXWORKS

    pInfo->access = FA_NONE;
    if(statbuf.st_mode & S_IRUSR)
        pInfo->access |= FA_READ;
    if(statbuf.st_mode & S_IWUSR)
        pInfo->access |= FA_WRITE;
    
#else

    pInfo->access = ((statbuf.st_mode >> 6) & 07) >> 1;

#endif /* VXWORKS */
#else
    pInfo->access = FA_NONE;
    if (access(name, R_OK) == 0)
	pInfo->access |= FA_READ;
    if (access(name, W_OK) == 0)
	pInfo->access |= FA_WRITE;

#endif	

    if (ISDEV(statbuf))
	pInfo->type = FT_DEVICE;
    else if (ISDIR(statbuf))
	pInfo->type = FT_DIRECTORY;
    else if (ISREG(statbuf))
	pInfo->type = FT_REGULAR;
    else if (ISLNK(statbuf))
	pInfo->type = FT_SYMLINK;
    else
	pInfo->type = FT_OTHER;

#define GET_TIME(dst, src) \
    timep = localtime(&statbuf.src); \
    (dst).year = timep->tm_year+1900; \
    (dst).month = timep->tm_mon+1; \
    (dst).day = timep->tm_mday; \
    (dst).hour = timep->tm_hour; \
    (dst).minute = timep->tm_min; \
    (dst).second = timep->tm_sec

    GET_TIME(pInfo->accessTime, st_atime);
    GET_TIME(pInfo->modifyTime, st_mtime);
    GET_TIME(pInfo->cTime, st_ctime);

#undef GET_TIME

    pInfo->mode = statbuf.st_mode;
    pInfo->links = statbuf.st_nlink;
    pInfo->major_device = statbuf.st_dev;
    pInfo->minor_device = statbuf.st_rdev;
    pInfo->inode = statbuf.st_ino;
    pInfo->uid = statbuf.st_uid;
    pInfo->gid = statbuf.st_gid;

    return 1;
}

int
efile_write_info(Efile_error *errInfo, Efile_info *pInfo, char *name)
{
    CHECK_PATHLEN(name, errInfo);

#ifdef VXWORKS

    if (pInfo->mode != -1) {
	int fd;
	struct stat statbuf;

	fd = open(name, O_RDONLY, 0);
	if (!check_error(fd, errInfo))
	    return 0;
	if (fstat(fd, &statbuf) < 0) {
	    close(fd);
	    return check_error(-1, errInfo);
	}
	if (pInfo->mode & S_IWUSR) {
	    /* clear read only bit */
	    statbuf.st_attrib &= ~DOS_ATTR_RDONLY;
	} else {
	    /* set read only bit */
	    statbuf.st_attrib |= DOS_ATTR_RDONLY;
	}
	/* This should work for dos files but not for nfs ditos, so don't 
	 * report errors (to avoid problems when running e.g. erl_tar)
	 */
	ioctl(fd, FIOATTRIBSET, statbuf.st_attrib);
	close(fd);
    }
#else
    /*
     * On some systems chown will always fail for a non-root user unless
     * POSIX_CHOWN_RESTRICTED is not set.  Others will succeed as long as 
     * you don't try to chown a file to someone besides youself.
     */
    
    if (chown(name, pInfo->uid, pInfo->gid) && errno != EPERM) {
	return check_error(-1, errInfo);
    }

    if (pInfo->mode != -1) {
	mode_t newMode = pInfo->mode & (S_ISUID | S_ISGID |
					S_IRWXU | S_IRWXG | S_IRWXO);
	if (chmod(name, newMode)) {
	    newMode &= ~(S_ISUID | S_ISGID);
	    if (chmod(name, newMode)) {
		return check_error(-1, errInfo);
	    }
	}
    }

#endif /* !VXWORKS */

    if (pInfo->accessTime.year != -1 && pInfo->modifyTime.year != -1) {
	struct utimbuf tval;
	struct tm timebuf;

#define MKTIME(tb, ts) \
    timebuf.tm_year = ts.year-1900; \
    timebuf.tm_mon = ts.month-1; \
    timebuf.tm_mday = ts.day; \
    timebuf.tm_hour = ts.hour; \
    timebuf.tm_min = ts.minute; \
    timebuf.tm_sec = ts.second; \
    timebuf.tm_isdst = -1; \
    if ((tb = mktime(&timebuf)) == (time_t) -1) { \
       errno = EINVAL; \
       return check_error(-1, errInfo); \
    }

        MKTIME(tval.actime, pInfo->accessTime);
	MKTIME(tval.modtime, pInfo->modifyTime);
#undef MKTIME
	
#ifdef VXWORKS
	/* VxWorks' utime doesn't work when the file is a nfs mounted
	 * one, don't report error if utime fails.
	 */
	utime(name, &tval);
	return 1;
#else
	return check_error(utime(name, &tval), errInfo);
#endif
    }
    return 1;
}


int
efile_write(Efile_error* errInfo,	/* Where to return error codes. */
	    int flags,			/* Flags given when file was 
					   opened. */
	    int fd,			/* File descriptor to write to. */
	    char* buf,			/* Buffer to write. */
	    unsigned int count)		/* Number of bytes to write. */
{
    int written;		/* Bytes written in last operation. */

#ifdef VXWORKS
    if (flags & EFILE_MODE_APPEND) {
	lseek(fd, 0, SEEK_END); /* Naive append emulation on VXWORKS */
    }
#endif
    while (count > 0) {
	if ((written = write(fd, buf, count)) < 0) {
	    if (errno != EINTR)
		return check_error(-1, errInfo);
	    else
		written = 0;
	}
	buf += written;
	count -= written;
    }
    return 1;
}

int
efile_read(Efile_error* errInfo,     /* Where to return error codes. */
	   int flags,		     /* Flags given when file was opened. */
	   int fd,		     /* File descriptor to read from. */
	   char* buf,		     /* Buffer to read into. */
	   unsigned int count,	     /* Number of bytes to read. */
	   unsigned int *pBytesRead) /* Where to return number of 
					bytes read. */
{
    int n;

    for (;;) {
	if ((n = read(fd, buf, count)) >= 0)
	    break;
	else if (errno != EINTR)
	    return check_error(-1, errInfo);
    }
    *pBytesRead = (unsigned) n;
    return 1;
}


/* pread() and pwrite()                                                   */
/* Some unix systems, notably Solaris has these syscalls                  */
/* It is especially nice for i.e. the dets module to have support         */
/* for this, even if the underlying OS dosn't support it, it is           */
/* reasonably easy to work around by first calling seek, and then         */
/* calling read().                                                        */
/* This later strategy however changes the file pointer, which pread()    */
/* does not do. We choose to ignore this and say that the location        */
/* of the file pointer is undefined after a call to any of the p functions*/


int
efile_pread(Efile_error* errInfo,     /* Where to return error codes. */
	    int fd,		      /* File descriptor to read from. */
	    int offset,               /* Offset in bytes from BOF. */
	    char* buf,		      /* Buffer to read into. */
	    unsigned int count,	      /* Number of bytes to read. */
	    unsigned int *pBytesRead) /* Where to return 
					 number of bytes read. */
{

#if defined(HAVE_PREAD) && defined(HAVE_PWRITE)
    int n;
    for (;;) {
	if ((n = pread(fd, buf, count, offset)) >= 0)
	    break;
	else if (errno != EINTR)
	    return check_error(-1, errInfo);
    }
    *pBytesRead = (unsigned) n;
    return 1;
#else
    {
	int res, location;
	if ((res = efile_seek(errInfo, fd, offset, EFILE_SEEK_SET, 
			      &location)))
	    return efile_read(errInfo, 0, fd, buf, count, pBytesRead);
	else
	    return res;
    }
#endif
}



int
efile_pwrite(Efile_error* errInfo,  /* Where to return error codes. */
	     int fd,		    /* File descriptor to write to. */
	     char* buf,		    /* Buffer to write. */
	     unsigned count,	    /* Number of bytes to write. */
	     int offset)            /* where to write it */
{ 

#if defined(HAVE_PREAD) && defined(HAVE_PWRITE)
    int written;		/* Bytes written in last operation. */

    while (count > 0) {
	if ((written = pwrite(fd, buf, count, offset)) < 0) {
	    if (errno != EINTR)
		return check_error(-1, errInfo);
	    else
		written = 0;
	}
	buf += written;
	count -= written;
	offset += written;
    }
    return 1;
#else  /* For unix systems that don't support pread() and pwrite() */    
    {
	int location, res;
	if ((res = efile_seek(errInfo, fd, offset, 
			      EFILE_SEEK_SET, &location)))
	    return efile_write(errInfo, 0, fd, buf, count);
	else
	    return res;
    }
#endif
}


int
efile_seek(Efile_error* errInfo,      /* Where to return error codes. */
	   int fd,                    /* File descriptor to do the seek on. */
	   int offset,                /* Offset in bytes from the given 
					 origin. */ 
	   int origin,                /* Origin of seek (SEEK_SET, SEEK_CUR,
				         SEEK_END). */ 
	   unsigned int *new_location)/* Resulting new location in file. */
{
    int result;

    switch (origin) {
    case EFILE_SEEK_SET: origin = SEEK_SET; break;
    case EFILE_SEEK_CUR: origin = SEEK_CUR; break;
    case EFILE_SEEK_END: origin = SEEK_END; break;
    default:
	errno = EINVAL;
	check_error(-1, errInfo);
	break;
    }

    errno = 0;
    result = lseek(fd, offset, origin);

    /*
     * Note that the man page for lseek (on SunOs 5) says:
     * 
     * "if fildes is a remote file  descriptor  and  offset  is
     * negative,  lseek()  returns  the  file pointer even if it is
     * negative."
     */

    if (result < 0 && errno == 0)
	errno = EINVAL;
    if (result < 0)
	return check_error(-1, errInfo);
    *new_location = (unsigned) result;
    return 1;
}


int
efile_truncate_file(Efile_error* errInfo, int *fd, int flags)
{
#ifdef VXWORKS
    off_t offset;
    char namebuf[PATH_MAX+1];
    char namebuf2[PATH_MAX+10];
    int new;
    int dummy;
    int i;
    int left;
    static char buff[1024];
    struct stat st;
    Efile_error tmperr;

    if ((offset = lseek(*fd, 0, 1)) < 0) {
	return check_error((int) offset,errInfo);
    }
    if (ftruncate(*fd, offset) < 0) {
	if (vxworks_to_posix(errno) != EINVAL) {
	    return check_error(-1, errInfo);
	}
	/*
	** Kludge
	*/
	if(ioctl(*fd,FIOGETNAME,(int) namebuf) < 0) {
	    return check_error(-1, errInfo);
	}
	for(i=0;i<1000;++i) {
	    sprintf(namebuf2,"%s%d",namebuf,i);
	    CHECK_PATHLEN(namebuf2,errInfo);
	    if (stat(namebuf2,&st) < 0) {
		break;
	    }
	}
	if (i > 1000) {
	    errno = EINVAL;
	    return check_error(-1, errInfo);
	}
	if (close(*fd) < 0) {
	    return check_error(-1, errInfo);
	}
	if (efile_rename(&tmperr,namebuf,namebuf2) < 0) {
	    i = check_error(-1,&tmperr);
	    if (!efile_openfile(errInfo,namebuf,flags | EFILE_NO_TRUNCATE,
				fd,&dummy)) {
		*fd = -1;
	    } else {
		*errInfo = tmperr;
	    }
	    return i;
	}
	if ((*fd = open(namebuf2, O_RDONLY, 0)) < 0) {
	    i = check_error(-1,errInfo);
	    efile_rename(&tmperr,namebuf2,namebuf); /* at least try */
	    if (!efile_openfile(errInfo,namebuf,flags | EFILE_NO_TRUNCATE,
				fd,&dummy)) {
		*fd = -1;
	    } else {
		lseek(*fd,offset,SEEK_SET);
	    }
	    return i;
	}
	/* Point of no return... */

	if ((new = open(namebuf,O_RDWR | O_CREAT, FILE_MODE)) < 0) {
	    close(*fd);
	    *fd = -1;
	    return 0;
	}
	left = offset;
	
	while (left) {
	    if ((i = read(*fd,buff,(left > 1024) ? 1024 : left)) < 0) {
		i = check_error(-1,errInfo);
		close(new);
		close(*fd);
		unlink(namebuf);
		efile_rename(&tmperr,namebuf2,namebuf); /* at least try */
		if (!efile_openfile(errInfo,namebuf,flags | EFILE_NO_TRUNCATE,
				    fd,&dummy)) {
		    *fd = -1;
		} else {
		    lseek(*fd,offset,SEEK_SET);
		}
		return i;
	    }
	    left -= i;
	    if (write(new,buff,i) < 0) {
		i = check_error(-1,errInfo);
		close(new);
		close(*fd);
		unlink(namebuf);
		rename(namebuf2,namebuf); /* at least try */
		if (!efile_openfile(errInfo,namebuf,flags | EFILE_NO_TRUNCATE,
				    fd,&dummy)) {
		    *fd = -1;
		} else {
		    lseek(*fd,offset,SEEK_SET);
		}
		return i;
	    }
	}
	close(*fd);
	unlink(namebuf2);
	close(new);
	i = efile_openfile(errInfo,namebuf,flags | EFILE_NO_TRUNCATE,fd,
			   &dummy);
	if (i) {
	    lseek(*fd,offset,SEEK_SET);
	}
	return i;
    }
    return 1;
#else
#ifndef NO_FTRUNCATE
    off_t offset;

    return check_error((offset = lseek(*fd, 0, 1)) >= 0 &&
		       ftruncate(*fd, offset) == 0 ? 1 : -1,
		       errInfo);
#else
    return 1;
#endif
#endif
}

int
efile_readlink(Efile_error* errInfo, char* name, char* buffer, unsigned size)
{
#ifdef VXWORKS
    return vxworks_enotsup(errInfo);
#else
    int len = readlink(name, buffer, size-1);
    if (len == -1) {
	return check_error(-1, errInfo);
    }
    buffer[len] = '\0';
    return 1;
#endif
}

int
efile_link(Efile_error* errInfo, char* old, char* new)
{
#ifdef VXWORKS
    return vxworks_enotsup(errInfo);
#else
    return check_error(link(old, new), errInfo);
#endif
}

int
efile_symlink(Efile_error* errInfo, char* old, char* new)
{
#ifdef VXWORKS
    return vxworks_enotsup(errInfo);
#else
    return check_error(symlink(old, new), errInfo);
#endif
}