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
 * RAM File operations
 */

#ifdef HAVE_CONFIG_H
#  include "config.h"
#endif

/* Operations */

/* defined "file" functions  */
/* XXX these must be updated if efile_drv.c change (build include file) */
#define FILE_OPEN		 1
#define FILE_READ		 2
#define FILE_LSEEK		 3
#define FILE_WRITE		 4
#define FILE_FSYNC               9
#define FILE_TRUNCATE           14
#define FILE_PREAD              17
#define FILE_PWRITE             18

/* other operations */
#define RAM_FILE_GET           30
#define RAM_FILE_SET           31
#define RAM_FILE_GET_CLOSE     32  /* get_file/close */
#define RAM_FILE_COMPRESS      33  /* compress file */
#define RAM_FILE_UNCOMPRESS    34  /* uncompress file */
#define RAM_FILE_UUENCODE      35  /* uuencode file */
#define RAM_FILE_UUDECODE      36  /* uudecode file */
#define RAM_FILE_SIZE          37  /* get file size */
/* possible new operations include:
   DES_ENCRYPT
   DES_DECRYPT
   CRC-32, CRC-16, CRC-CCITT
   IP-CHECKSUM
*/

/*
 * Open modes for efile_openfile().
 */
#define EFILE_MODE_READ       1
#define EFILE_MODE_WRITE      2  /* Implies truncating file when used alone. */
#define EFILE_MODE_READ_WRITE 3

/*
 * Seek modes for efile_seek().
 */
#define	EFILE_SEEK_SET	0
#define	EFILE_SEEK_CUR	1
#define	EFILE_SEEK_END	2

/* Return codes */

#define FILE_RESP_OK         0
#define FILE_RESP_ERROR      1
#define FILE_RESP_DATA       2
#define FILE_RESP_NUMBER     3
#define FILE_RESP_INFO       4

#include <stdio.h>
#include <ctype.h>

#include "sys.h"
#include "driver.h"

#ifndef NULL
#define NULL ((void*)0)
#endif

#define BFILE_BLOCK  1024

EXTERN_FUNCTION(DriverBinary*, gzinflate_buffer, (char*, int));
EXTERN_FUNCTION(DriverBinary*, gzdeflate_buffer, (char*, int));


#define get_int32(s) ((((unsigned char*) (s))[0] << 24) | \
                      (((unsigned char*) (s))[1] << 16) | \
                      (((unsigned char*) (s))[2] << 8)  | \
                      (((unsigned char*) (s))[3]))

#define put_int32(i, s) {((char*)(s))[0] = (char)((i) >> 24) & 0xff; \
                        ((char*)(s))[1] = (char)((i) >> 16) & 0xff; \
                        ((char*)(s))[2] = (char)((i) >> 8)  & 0xff; \
                        ((char*)(s))[3] = (char)((i)        & 0xff);}

#define get_int16(s) ((((unsigned char*)  (s))[0] << 8) | \
                      (((unsigned char*)  (s))[1]))


#define put_int16(i, s) {((unsigned char*)(s))[0] = ((i) >> 8) & 0xff; \
                        ((unsigned char*)(s))[1] = (i)         & 0xff;}

#define get_int8(s) ((((unsigned char*)  (s))[0] ))


#define put_int8(i, s) { ((unsigned char*)(s))[0] = (i)         & 0xff;}

typedef unsigned char uchar;

static long rfile_start();
static int  rfile_init();
static int  rfile_stop();
static int  rfile_command();

struct driver_entry ram_file_driver_entry = {
    rfile_init,
    rfile_start,
    rfile_stop,
    rfile_command,
    null_func,
    null_func,
    "ram_file_drv"
};

/* A File is represented as a array of bytes, this array is
   reallocated when needed. A possibly better implementation
   whould be to have a vector of blocks. This may be implemented
   when we have the commandv/driver_outputv
*/
typedef struct ram_file {
    int port;           /* the associcated port */
    int flags;          /* flags read/write */
    DriverBinary* bin;  /* binary to hold binary file */
    int bin_sz;         /* size of allocated binary */
    uchar* bin_start;   /* buffer start */
    uchar* bin_end;     /* buffer end (outside) */
    uchar* ptr;         /* current position */
    uchar* ptr_max;     /* maximum position in file */
} RamFile;

#ifdef LOADABLE
static int rfile_finish(drv)
DriverEntry* drv;
{
    return 0;
}

DriverEntry* driver_init(handle)
void* handle;
{
    ram_file_driver_entry.handle = handle;
    ram_file_driver_entry.driver_name = "ram_file_drv";
    ram_file_driver_entry.finish = rfile_finish;
    ram_file_driver_entry.init = rfile_init;
    ram_file_driver_entry.start = rfile_start;
    ram_file_driver_entry.stop = rfile_stop;
    ram_file_driver_entry.output = rfile_command;
    ram_file_driver_entry.ready_input = null_func;
    ram_file_driver_entry.ready_output = null_func;
    return &ram_file_driver_entry;
}
#endif

static int rfile_init()
{
    return 0;
}

static long rfile_start(port, buf)
int port; uchar *buf;
{
    RamFile* f;

    if ((f = (RamFile*) sys_alloc(sizeof(RamFile))) == NULL)
	return -1;
    f->port = port;
    f->flags = 0;
    f->bin = NULL;
    f->bin_sz = 0;
    f->bin_start = NULL;
    f->bin_end = NULL;
    f->ptr = NULL;
    f->ptr_max = NULL;
    return (long) f;
}

static int rfile_stop(f)
RamFile* f;
{
    if (f->bin != NULL) 
	driver_free_binary(f->bin);
    sys_free(f);
    return 0;
}

/*
 * Sends back an error reply to Erlang.
 */

static int error_reply(f, err)
RamFile* f; int err;
{
    char response[256];		/* Response buffer. */
    char* s;
    char* t;
    
    /*
     * Contents of buffer sent back:
     *
     * +-----------------------------------------+
     * | FILE_RESP_ERROR | Posix error id string |
     * +-----------------------------------------+
     */
    response[0] = FILE_RESP_ERROR;
    for (s = erl_errno_id(err), t = response+1; *s; s++, t++)
	*t = tolower(*s);
    driver_output2(f->port, response, t-response, NULL, 0);
    return 0;
}

static int reply(f, ok, err)
RamFile* f; int ok; int err;
{
    if (!ok)
	error_reply(f, err);
    else {
	uchar c = FILE_RESP_OK;
        driver_output2(f->port, &c, 1, NULL, 0);
    }
    return 0;
}

static int numeric_reply(f, result)
RamFile* f; int result;
{
    uchar tmp[5];

    /*
     * Contents of buffer sent back:
     *
     * +-----------------------------------------------+
     * | FILE_RESP_NUMBER | 32-bit number (big-endian) |
     * +-----------------------------------------------+
     */

    tmp[0] = FILE_RESP_NUMBER;
    put_int32(result, tmp+1);
    driver_output2(f->port, tmp, sizeof(tmp), NULL, 0);
    return 0;
}

/* install bin as the new binary reset all pointer */

static void ram_file_set(f, bin, bsize, len)
RamFile* f; DriverBinary* bin; int bsize; int len;
{
    char* start;

    start = bin->orig_bytes;
    f->bin_sz = bsize;
    f->ptr = start;
    f->ptr_max = start + len;
    f->bin_start = start;
    f->bin_end   = start + bsize;
    f->bin = bin;
}

static int ram_file_init(f, buf, count, error)
RamFile* f; uchar* buf; int count; int* error;
{
    int bsize = ((count + BFILE_BLOCK - 1) / BFILE_BLOCK) * BFILE_BLOCK;
    DriverBinary* bin;

    if (f->bin == NULL)
	bin = driver_alloc_binary(bsize);
    else 
	bin = driver_realloc_binary(f->bin, bsize);
    if (bin == NULL) {
	*error = ENOMEM;
	return -1;
    }
    sys_memzero(bin->orig_bytes, bsize);
    sys_memcpy(bin->orig_bytes, buf, count);
    ram_file_set(f, bin, bsize, count);
    return count;
}

static int ram_file_expand(f, size, error)
RamFile* f; int size; int* error;
{
    int bsize = ((size + BFILE_BLOCK - 1) / BFILE_BLOCK) * BFILE_BLOCK;
    DriverBinary* bin;
    uchar* start;

    if (bsize <= f->bin_sz)
	return f->bin_sz;
    else {
	if ((bin = driver_realloc_binary(f->bin, bsize)) == NULL) {
	    *error = ENOMEM;
	    return -1;
	}
	sys_memzero(bin->orig_bytes+f->bin_sz, bsize - f->bin_sz);
	start = bin->orig_bytes;
	f->bin_sz = bsize;
	f->ptr = start + (f->ptr - f->bin_start);
	f->ptr_max = start + (f->ptr_max - f->bin_start);
	f->bin_start = start;
	f->bin_end   = start + bsize;
	f->bin = bin;
	return bsize;
    }
}


static int ram_file_write(f, buf, length, location, error)
RamFile* f; uchar* buf; int length; int* location; int* error;
{
    uchar* ptr;

    if (!(f->flags & EFILE_MODE_WRITE)) {
	*error = EBADF;
	return -1;
    }
    ptr = (location == NULL) ? f->ptr : (f->bin_start + *location);

    if (ptr + length > f->bin_end) {
	int extra =  ((ptr + length) - f->bin_end);
	if (ram_file_expand(f, f->bin_sz + extra, error) < 0)
	    return -1;
	/* reload ptr file may have been moved ! */
	ptr = (location == NULL) ? f->ptr : f->bin_start + *location;
    }
    sys_memcpy(ptr, buf, length);
    ptr += length;
    if (ptr > f->ptr_max)
	f->ptr_max = ptr;
    if (location == NULL)
	f->ptr = ptr;
    return length;
}

static int ram_file_read(f, length, bp, location, error)
RamFile* f; int length; DriverBinary** bp; int *location; int* error;
{
    DriverBinary* bin;
    uchar* ptr;

    if (!(f->flags & EFILE_MODE_READ)) {
	*error = EBADF;
	return -1;
    }
    ptr = (location == NULL) ? f->ptr : (f->bin_start + *location);

    if (ptr + length > f->ptr_max) {
	if ((length = f->ptr_max - ptr) < 0)
	    length = 0;
    }
    if ((bin = driver_alloc_binary(length)) == NULL) {
	*error = ENOMEM;
	return -1;
    }
    sys_memcpy(bin->orig_bytes, ptr, length);
    *bp = bin;
    if (location == NULL)
	f->ptr = ptr + length;
    return length;
}

static int ram_file_seek(f, offset, whence, error)
RamFile* f; int offset; int whence; int* error;
{
    int pos;

    if (f->flags == 0) {
	*error = EBADF;
	return -1;
    }	
    switch(whence) {
    case EFILE_SEEK_SET: pos = offset; break;
    case EFILE_SEEK_CUR: pos = (f->ptr - f->bin_start) + offset; break;
    case EFILE_SEEK_END: pos = (f->ptr_max - f->bin_start) + offset; break;
    default: *error = EINVAL; return -1;
    }
    if (pos < 0) {
	*error = EINVAL;
	return -1;
    }
    if (f->bin_start + pos > f->bin_end) {
	int extra = ((f->bin_start + pos) - f->bin_end);
	if (ram_file_expand(f, f->bin_sz + extra, error) < 0)
	    return -1;
    }
    f->ptr = f->bin_start + pos;
/* DO SEEK OPERATION CHANGE FILE SIZE? */
/*    if (f->ptr > f->ptr_max)	f->ptr_max = f->ptr; */
    return pos;
}

#define UUMASK(x)     ((x)&0x3F)
#define uu_encode(x)  (UUMASK(x)+32)

/* calculate max number of quadrauple bytes given max line length */
#define UULINE(n) ( (((n)-1) / 4) * 3)

#define UNIX_LINE 61  /* 61 character lines =>  45 uncoded => 60 coded */

#define uu_pack(p, c1, c2, c3) \
        (p)[0] = uu_encode((c1) >> 2), \
        (p)[1] = uu_encode(((c1) << 4) | ((c2) >> 4)), \
        (p)[2] = uu_encode(((c2) << 2) | ((c3) >> 6)), \
        (p)[3] = uu_encode(c3)

static int ram_file_uuencode(f)
RamFile* f;
{
    int code_len = UULINE(UNIX_LINE);
    int len = (f->ptr_max - f->bin_start);
    int usize = (len*4+2)/3 + 2*(len/code_len+1) + 2 + 1;
    DriverBinary* bin;
    uchar* inp;
    uchar* outp;
    int count = 0;

    if ((bin = driver_alloc_binary(usize)) == NULL)
	return error_reply(f, ENOMEM);
    outp = bin->orig_bytes;
    inp = f->bin_start;

    while(len > 0) {
        int c1, c2, c3;
        int n = (len >= code_len) ? code_len : len;

        len -= n;
        *outp++ = uu_encode(UUMASK(n));
        count++;
        while (n >= 3) {
            c1 = inp[0];
            c2 = inp[1];
            c3 = inp[2];
	    uu_pack(outp, c1, c2, c3);
            inp += 3; n -= 3;
            outp += 4; count += 4;
        }
        if (n == 2) {
            c1 = inp[0];
            c2 = inp[1];
	    uu_pack(outp, c1, c2, 0);
	    inp += 2;
            outp += 4; count += 4;
        }
        else if (n == 1) {
            c1 = inp[0];
	    uu_pack(outp, c1, 0, 0);
	    inp += 1;
            outp += 4; count += 4;
        }
        *outp++ = '\n';
        count++;
    }
    *outp++ = ' ';   /* this end of file 0 length !!! */
    *outp++ = '\n';
    count += 2;

    driver_free_binary(f->bin);
    ram_file_set(f, bin, usize, count);
    return numeric_reply(f, count);
}


#define uu_decode(x)  ((x)-32)

static int ram_file_uudecode(f)
RamFile* f;
{
    int len = (f->ptr_max - f->bin_start);
    int usize = ( (len+3) / 4 ) * 3;
    DriverBinary* bin;
    uchar* inp;
    uchar* outp;
    int count = 0;
    int n;

    if ((bin = driver_alloc_binary(usize)) == NULL)
	return error_reply(f, ENOMEM);
    outp = bin->orig_bytes;
    inp  = f->bin_start;

    while(len > 0) {
	if ((n = uu_decode(*inp++)) < 0)
	    goto error;
        len--;
	if ((n == 0) && (*inp == '\n'))
	    break;
        count += n;     /* count characters */
        while((n > 0) && (len >= 4)) {
            int c1, c2, c3, c4;
            c1 = uu_decode(inp[0]);
            c2 = uu_decode(inp[1]);
            c3 = uu_decode(inp[2]);
            c4 = uu_decode(inp[3]);
	    inp += 4;
            len -= 4;

            switch(n) {
            case 1:
                *outp++ = (c1 << 2) | (c2 >> 4);
		n = 0;
                break;
            case 2:
                *outp++ = (c1 << 2) | (c2 >> 4);
                *outp++ = (c2 << 4) | (c3 >> 2);
		n = 0;
                break;
            default:
                *outp++ = (c1 << 2) | (c2 >> 4);
                *outp++ = (c2 << 4) | (c3 >> 2);
                *outp++ = (c3 << 6) | c4;
                n -= 3;
                break;
            }
        }
	if ((n != 0) || (*inp++ != '\n'))
	    goto error;
        len--;
    }
    driver_free_binary(f->bin);
    ram_file_set(f, bin, usize, count);
    return numeric_reply(f, count);

 error:
    driver_free_binary(bin);
    return error_reply(f, EINVAL);
}


static int ram_file_compress(f)
RamFile* f;
{
    int size = f->ptr_max - f->bin_start;
    DriverBinary* bin;

    if ((bin = gzdeflate_buffer(f->bin_start, size)) == NULL)
	return error_reply(f, EINVAL);
    driver_free_binary(f->bin);
    size = bin->orig_size;
    ram_file_set(f, bin, size, size);
    return numeric_reply(f, size);
}

/* Tricky since we dont know the expanded size !!! */
/* First attempt is to double the size of input */
/* loop until we don't get Z_BUF_ERROR */

static int ram_file_uncompress(f)
RamFile* f;
{
    int size = f->ptr_max - f->bin_start;
    DriverBinary* bin;

    if ((bin = gzinflate_buffer(f->bin_start, size)) == NULL)
	return error_reply(f, EINVAL);

    driver_free_binary(f->bin);
    size = bin->orig_size;
    ram_file_set(f, bin, size, size);
    return numeric_reply(f, size);
}


static int rfile_command(f, buf, count)
RamFile* f; uchar *buf; int count;
{
    int error = 0;
    DriverBinary* bin;
    char header[5];     /* result code + count */
    int offset;
    int origin;		/* Origin of seek. */
    int n;

    count--;
    switch(*buf++) {
    case FILE_OPEN:  /* args is initial data */
	f->flags = get_int32(buf);
	if (ram_file_init(f, buf+4, count-4, &error) < 0)
	    return error_reply(f, error);
	return numeric_reply(f, 0); /* 0 is not used */

    case FILE_FSYNC:
	if (f->flags == 0)
	    return error_reply(f, EBADF);
	return reply(f, 1, 0);

    case FILE_WRITE:
	if (ram_file_write(f, buf, count, NULL, &error) < 0)
	    return error_reply(f, error);
	return numeric_reply(f, count);

    case FILE_PWRITE:
        if ((offset = get_int32(buf)) < 0)
	    return error_reply(f, EINVAL);
	if (ram_file_write(f, buf+4, count-4, &offset, &error) < 0)
	    return error_reply(f, error);
	return numeric_reply(f, count-4);

    case FILE_LSEEK:
	offset = get_int32(buf);
	origin = get_int32(buf+4);
	if ((offset = ram_file_seek(f, offset, origin, &error)) < 0)
	    return error_reply(f, error);
	return numeric_reply(f, offset);

    case FILE_PREAD:
	if ((offset = get_int32(buf)) < 0)
	    return error_reply(f, EINVAL);
	count = get_int32(buf+4);
	if ((n = ram_file_read(f, count, &bin, &offset, &error)) < 0)
	    return error_reply(f, error);
	else {
	    header[0] = FILE_RESP_DATA;
	    put_int32(n, header+1);
	    driver_output_binary(f->port, header, sizeof(header),
				 bin, 0, n);
	}
	driver_free_binary(bin);
	return 0;

    case FILE_READ:
	count = get_int32(buf);
	if ((n = ram_file_read(f, count, &bin, NULL, &error)) < 0)
	    return error_reply(f, error);
	else {
	    header[0] = FILE_RESP_DATA;
	    put_int32(n, header+1);
	    driver_output_binary(f->port, header, sizeof(header),
				 bin, 0, n);
	}
	driver_free_binary(bin);
	return 0;

    case FILE_TRUNCATE:
	if (f->flags == 0)
	    return error_reply(f, EBADF);
	if (f->ptr_max > f->ptr)
	    sys_memzero(f->ptr, (f->ptr_max - f->ptr));
	f->ptr_max = f->ptr;
	return reply(f, 1, 0);

    case RAM_FILE_GET:        /* return a copy of the file */
	n = (f->ptr_max - f->bin_start);  /* length */
	if ((bin = driver_alloc_binary(n)) == NULL)
	    return error_reply(f, ENOMEM);
	sys_memcpy(bin->orig_bytes, f->bin_start, n);
	
	header[0] = FILE_RESP_DATA;
	put_int32(n, header+1);
	driver_output_binary(f->port, header, sizeof(header),
			     bin, 0, n);
	driver_free_binary(bin);
	return 0;

    case RAM_FILE_GET_CLOSE:  /* return the file and close driver */
	n = (f->ptr_max - f->bin_start);  /* length */
	bin = f->bin;
	f->bin = NULL;  /* NUKE IT */
	header[0] = FILE_RESP_DATA;
	put_int32(n, header+1);
	driver_output_binary(f->port, header, sizeof(header),
			     bin, 0, n);
	driver_free_binary(bin);
	driver_failure(f->port, 0);
	return 0;

    case RAM_FILE_SIZE:
	return numeric_reply(f, (f->ptr_max - f->bin_start));

    case RAM_FILE_SET:        /* re-init file with new data */
	if ((n = ram_file_init(f, buf, count, &error)) < 0)
	    return error_reply(f, error);
	return numeric_reply(f, n); /* 0 is not used */
	
    case RAM_FILE_COMPRESS:   /* inline compress the file */
	return ram_file_compress(f);

    case RAM_FILE_UNCOMPRESS: /* inline uncompress file */
	return ram_file_uncompress(f);

    case RAM_FILE_UUENCODE:   /* uuencode file */
	return ram_file_uuencode(f);
	
    case RAM_FILE_UUDECODE:   /* uudecode file */
	return ram_file_uudecode(f);

    }
    /*
     * Ignore anything else -- let the caller hang.
     */
     
    return 0;
}