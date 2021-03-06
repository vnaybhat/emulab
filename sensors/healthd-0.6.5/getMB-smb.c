/*-
 * Copyright (c) 1999-2000 James E. Housley <jim@thehousleys.net>
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
 * OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
 * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 *
 *	$Id: getMB-smb.c,v 1.1 2001-12-05 18:45:08 kwebb Exp $
 */

#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#ifdef HAVE_SMBUS
#include <fcntl.h>
#include <sys/types.h>
#include <sys/ioctl.h>
#include <machine/smb.h>
#include <stdio.h>
#include <unistd.h>
#include "methods.h"

static int iosmb;
static u_char smb_addr;

static int
OpenIO(void) {
  static const u_char addrs[] = { 0x5a, 0x2d };	/* SMBus addresses to try */
  char byte;
  struct smbcmd cmd;
  int i;

  if ((iosmb = open("/dev/smb0", 000)) < 0){
    perror("/dev/smb0");
    return -1;
  }
  cmd.cmd = 0x47;
  cmd.data.byte_ptr = &byte;
  for (i = 0; i < sizeof(addrs); i++) {
    cmd.slave = addrs[i];
    if (ioctl(iosmb, SMB_READB, (caddr_t)&cmd) != -1) {
      smb_addr = addrs[i];
      return 0;
    }
  }
  perror("ioctl(SMB_READB)");
  return -1;
}

static int 
CloseIO(void) {
  return close(iosmb);
}

static int
WriteByte(int addr,int value) {
  struct smbcmd cmd;

  cmd.slave = smb_addr;
  cmd.cmd = addr;
  cmd.data.byte = value;
  if (ioctl(iosmb, SMB_WRITEB, &cmd) == -1) {
    perror("ioctl(SMB_WRITEB)");
    exit(-1);
  }
  return 0;
}

static int
ReadByte(int addr) {
  struct smbcmd cmd;
  unsigned char ret;

  cmd.slave = smb_addr;
  cmd.cmd = addr;
  cmd.data.byte_ptr = &ret;
  if (ioctl(iosmb, SMB_READB, &cmd) == -1) {
    perror("ioctl(SMB_READB)");
    exit(-1);
  }
  return (unsigned int)ret;
}

struct lm_methods method_smb = {
  OpenIO, 
  CloseIO, 
  ReadByte, 
  WriteByte
};
#endif /* HAVE_SMBUS */
