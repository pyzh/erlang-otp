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
/**
 *  win32sysinfo.c
 *
 *  File:     win32sysinfo.c
 *  Purpose:  Portprogram for supervision of disk and memory usage.
 *
 *  Synopsis: win32sysinfo
 *
 *  PURPOSE OF THIS PROGRAM
 *
 *  This program supervises the reports the memory status or disk status
 *  on request from the Erlang system
 *  
 *
 *  SPAWNING FROM ERLANG
 *
 *  This program is started from Erlang as follows,
 *
 *       Port = open_port({spawn, 'memsup'}, [{packet,1}]) for UNIX
 *
 *  COMMUNICATION
 *
 *    WIN32
 * 
 * get_disk_info 'd' (request info about all drives)
 *      The result is returned as one packet per logical drive with the 
 *      following format:
 *      Drive Type AvailableBytes TotalBytes TotalBytesFree
 *      END
 *
 *      Example: 
 *      A:\ DRIVE_REMOVABLE 0 0 0
 *      C:\ DRIVE_FIXED 10000000 20000000 10000000
 *      END

 * get_disk_info 'd'Driveroot (where Driveroot is a string like this "A:\\"
 *      (request info of specific drive)
 *      The result is returned with the same format as above exept that 
 *      Type will be DRIVE_NOT_EXIST if the drive does not exist.
 *
 * get_mem_info 'm' (request info about memory)
 * 
 *      The result is returned as one packet with the following format
 *      
 *      
 *      
 *      
 *
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <windows.h>
#include "winbase.h"

#define MEM_INFO 'm'
#define DISK_INFO 'd'
#define OK "o"

#define ERLIN_FD      0
#define ERLOUT_FD     1


typedef BOOL (WINAPI *tfpGetDiskFreeSpaceEx)(LPCTSTR, PULARGE_INTEGER,PULARGE_INTEGER,PULARGE_INTEGER);

static  tfpGetDiskFreeSpaceEx fpGetDiskFreeSpaceEx;

static void
return_answer(char* value)
{
    int left, bytes, res;

    bytes = strlen(value); /* Skip trailing zero */

    res = write(1,(char*) &bytes,1);
    if (res != 1) {
	fprintf(stderr,"win32sysinfo:Error writing to pipe");
	exit(1);
    }

    left = bytes;

    while (left > 0)
    {
	res = write(1, value+bytes-left, left);
	if (res <= 0)
	{
	    fprintf(stderr,"win32sysinfo:Error writing to pipe");
	    exit(1);
	}
	left -= res;
    }
}

void output_drive_info(char* drive){
    ULARGE_INTEGER availbytes,totbytesfree,totbytes;
    OSVERSIONINFO osinfo;
    char answer[512];
    osinfo.dwOSVersionInfoSize=sizeof(OSVERSIONINFO);
    GetVersionEx(&osinfo);
    switch (GetDriveType(drive)) {
    case DRIVE_UNKNOWN:
	sprintf(answer,"%s DRIVE_UNKNOWN 0 0 0\n",drive);
	return_answer(answer);
	break;
    case DRIVE_NO_ROOT_DIR:
	sprintf(answer,"%s DRIVE_NO_ROOT_DIR 0 0 0\n",drive);
	return_answer(answer);
	break;
    case DRIVE_REMOVABLE:
	sprintf(answer,"%s DRIVE_REMOVABLE 0 0 0\n",drive);
	return_answer(answer);
	break;
    case DRIVE_FIXED:
	/*		if ((osinfo.dwPlatformId == VER_PLATFORM_WIN32_WINDOWS) &&
			(LOWORD(osinfo.dwBuildNumber) <= 1000)) {
			sprintf(answer,"%s API_NOT_SUPPORTED 0 0 0\n",drive);
			return_answer(answer);
			}
			else
			*/
	    if (fpGetDiskFreeSpaceEx == NULL){
		sprintf(answer,"%s API_NOT_SUPPORTED 0 0 0\n",drive);
		return_answer(answer);
	    }
	    else
		if (fpGetDiskFreeSpaceEx(drive,&availbytes,&totbytes,&totbytesfree)){
		    sprintf(answer,"%s DRIVE_FIXED %I64u %I64u %I64u\n",drive,availbytes,totbytes,totbytesfree);
		    return_answer(answer);
		}
		else {
		    sprintf(answer,"%s API_ERROR 0 0 0\n",drive);
		    return_answer(answer);
		}
	break;
    case DRIVE_REMOTE:
	sprintf(answer,"%s DRIVE_REMOTE 0 0 0\n",drive);
	return_answer(answer);
	break;
    case DRIVE_CDROM:
	sprintf(answer,"%s DRIVE_CDROM 0 0 0\n",drive);
	return_answer(answer);
	break;
    case DRIVE_RAMDISK:
	sprintf(answer,"%s DRIVE_RAMDISK 0 0 0\n",drive);
	return_answer(answer);
	break;
    default:
	sprintf(answer,"%s DRIVE_NOT_EXIST 0 0 0\n",drive);
	return_answer(answer);
    } /* switch */
}
    
int load_if_possible() {
    HINSTANCE lh;
    if((lh = LoadLibrary("KERNEL32")) ==NULL)
	return 0;		/* error */
    if ((fpGetDiskFreeSpaceEx = 
	 (tfpGetDiskFreeSpaceEx) GetProcAddress(lh,"GetDiskFreeSpaceExA")) ==NULL)
	return GetLastError(); /* error */
    return 1;
}

void get_disk_info_all(){
    DWORD dwNumBytesForDriveStrings;
    char DriveStrings[255];
    char* dp = DriveStrings;
    
    dwNumBytesForDriveStrings = GetLogicalDriveStrings(254,dp);
    if (dwNumBytesForDriveStrings != 0) {
	/* GetLogicalDriveStringsIs supported on this platform */
	while (*dp != 0) {
	    output_drive_info(dp);
	    dp = strchr(dp,0) +1;
	}
    }
    else {
	/* GetLogicalDriveStrings is not supported (some old W95) */
	DWORD dwDriveMask = GetLogicalDrives();
	int nDriveNum;
	char drivename[]="A:\\";
	/*printf("DriveName95 DriveType BytesAvail BytesTotal BytesTotalFree\n");*/
	for (nDriveNum = 0; dwDriveMask != 0;nDriveNum++) {
	    if (dwDriveMask & 1) {
		drivename[0]='A'+ nDriveNum;
		output_drive_info(drivename);
	    }
	    dwDriveMask = dwDriveMask >> 1;
	}
    }
}

void get_avail_mem() {
    char answer[512];
    MEMORYSTATUS ms;
    ms.dwLength=sizeof(MEMORYSTATUS);
    GlobalMemoryStatus(&ms);
    sprintf(answer,"%d %d %d %d %d %d %d\n",
	    ms.dwMemoryLoad,
	    ms.dwTotalPhys,
	    ms.dwAvailPhys,
	    ms.dwTotalPageFile,
	    ms.dwAvailPageFile,
	    ms.dwTotalVirtual,
	    ms.dwAvailVirtual
	    );
    return_answer(answer);
    /*    
       MemoryLoad;    percent of memory in use 
       TotalPhys;     // bytes of physical memory
       AvailPhys;     // free physical memory bytes
       TotalPageFile; // bytes of paging file
       AvailPageFile; // free bytes of paging file
       TotalVirtual;  // user bytes of address space
       AvailVirtual;  // free user bytes
       
       */
}

static void
message_loop()
{
    char cmdLen;
    char cmd[512];
    int res;
    
    fprintf(stderr,"in message_loop\n");
    /* Startup ACK. */
    return_answer(OK);
    while (1)
    {
	/*
	 *  Wait for command from Erlang
	 */
	if ((res = read(0, &cmdLen, 1)) < 0) {
	    fprintf(stderr,"win32sysinfo:Error reading from Erlang.");
	    return;
	}
	
	if (res != 1){	/* Exactly one byte read ? */ 
	    fprintf(stderr,"win32sysinfo:Erlang has closed.");
	    return;
	}
	if ((res = read(0, &cmd, cmdLen)) == cmdLen){
	    if (cmdLen == 1) {
		switch (cmd[0]) {
		case MEM_INFO:
		    get_avail_mem();
		    return_answer(OK);
		    break;
		case DISK_INFO:
		    get_disk_info_all();
		    return_answer(OK);
		    break;
		default:	/* ignore all other messages */
		    break;
		} /* switch */
	    }
	    else 
		if ((res > 0) && (cmd[0]==DISK_INFO)) {
		    cmd[cmdLen] = 0;
		    output_drive_info(&cmd[1]);
		    return_answer("OK");
		    return;
		}
		else
		    return_answer("xEND");
	}    
	else if (res == 0) {
	    fprintf(stderr,"win32sysinfo:Erlang has closed.");
	    return;
	}
	else {
	    fprintf(stderr,"win32sysinfo:Error reading from Erlang.");
	    return;
	} 
    }
}

int main(int argc, char ** argv){

    _setmode(0, _O_BINARY);
    _setmode(1, _O_BINARY);
    load_if_possible();
    message_loop();
    return 0;    
}







