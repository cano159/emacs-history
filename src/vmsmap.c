/* VMS mapping of data and alloc arena for GNU Emacs.
   Copyright (C) 1986 Free Software Foundation, Inc.
   
   This file is part of GNU Emacs.
   
   GNU Emacs is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY.  No author or distributor
   accepts responsibility to anyone for the consequences of using it
   or for whether it serves any particular purpose or works at all,
   unless he says so in writing.  Refer to the GNU Emacs General Public
   License for full details.
   
   Everyone is granted permission to copy, modify and redistribute
   GNU Emacs, but only under the conditions described in the
   GNU Emacs General Public License.   A copy of this license is
   supposed to have been given to you along with GNU Emacs so you
   can know your rights and responsibilities.  It should be in a
   file named COPYING.  Among other things, the copyright notice
   and this notice must be preserved on all copies.  */

/* Written by Mukesh Prasad.  */

#ifdef VMS

#include "config.h"
#include "lisp.h"
#include <rab.h>
#include <fab.h>
#include <rmsdef.h>
#include <secdef.h>

/* RMS block size */
#define	BLOCKSIZE	512

/* Maximum number of bytes to be written in one RMS write.
 * Must be a multiple of BLOCKSIZE.
 */
#define	MAXWRITE	(BLOCKSIZE * 30)

extern char * _malloc_base;

/* This funniness is to insure that sdata occurs alphabetically BEFORE the
   $DATA psect and that edata occurs after ALL Emacs psects.  This is
   because the VMS linker sorts all psects in a cluster alphabetically
   during the linking, unless you use the cluster_psect command.  Emacs
   uses the cluster command to group all Emacs psects into one cluster;
   this keeps the dumped data separate from any loaded libraries. */

globaldef {"$D$ATA"} char sdata[512]; /* Start of saved data area */
globaldef {"__DATA"} char edata[512]; /* End of saved data area */

/* Structure to write into first block of map file.
 */

struct map_data
{
  char * sdata;			/* Start of data area */
  char * edata;			/* End of data area */
  char * smalloc;		/* Start of malloc area */
  char * emalloc;		/* End of malloc area */
  int  datablk;			/* Block in file to map data area from/to */
  int  mblk;			/* Block in file to map malloc area from/to */
};

static void fill_fab (), fill_rab ();
static int write_data ();

extern char *start_of_data ();

/* Maps in the data and alloc area from the map file.
 */

int
mapin_data (name)
     char * name;
{
  struct FAB fab;
  struct RAB rab;
  int status, size;
  int inadr[2];
  struct map_data map_data;
  
  /* Open map file.
   */
  fab = cc$rms_fab;
  fab.fab$b_fac = FAB$M_BIO|FAB$M_GET;
  fab.fab$l_fna = name;
  fab.fab$b_fns = strlen (name);
  status = sys$open (&fab);
  if (status != RMS$_NORMAL)
    {
      printf ("Map file not available, running bare Emacs....\n");
      return 0;			/* Map file not available */
    }
  /* Connect the RAB block */
  rab = cc$rms_rab;
  rab.rab$l_fab = &fab;
  rab.rab$b_rac = RAB$C_SEQ;
  rab.rab$l_rop = RAB$M_BIO;
  status = sys$connect (&rab);
  if (status != RMS$_NORMAL)
    lib$stop (status);
  /* Read the header data */
  rab.rab$l_ubf = &map_data;
  rab.rab$w_usz = sizeof (map_data);
  rab.rab$l_bkt = 0;
  status = sys$read (&rab);
  if (status != RMS$_NORMAL)
    lib$stop (status);
  status = sys$close (&fab);
  if (status != RMS$_NORMAL)
    lib$stop (status);
  if (map_data.sdata != start_of_data ())
    {
      printf ("Start of data area has moved: cannot map in data.\n");
      return 0;
    }
  if (map_data.edata != edata)
    {
      printf ("End of data area has moved: cannot map in data.\n");
      return 0;
    }
  /* Extend virtual address space to end of previous malloc area.
   */
  brk (map_data.emalloc);
  /* Open the file for mapping now.
   */
  fab.fab$l_fop |= FAB$M_UFO;
  status = sys$open (&fab);
  if (status != RMS$_NORMAL)
    lib$stop (status);
  /* Map data area.
   */
  inadr[0] = map_data.sdata;
  inadr[1] = map_data.edata;
  status = sys$crmpsc (inadr, 0, 0, SEC$M_CRF | SEC$M_WRT, 0, 0, 0,
		       fab.fab$l_stv, 0, map_data.datablk, 0, 0);
  if (! (status & 1))
    lib$stop (status);
  /* Check mapping.
   */
  if (_malloc_base != map_data.smalloc)
    {
      printf ("Data area mapping invalid.\n");
      exit (1);
    }
  /* Map malloc area.
   */
  inadr[0] = map_data.smalloc;
  inadr[1] = map_data.emalloc;
  status = sys$crmpsc (inadr, 0, 0, SEC$M_CRF | SEC$M_WRT, 0, 0, 0,
		       fab.fab$l_stv, 0, map_data.mblk, 0, 0);
  if (! (status & 1))
    lib$stop (status);
  return 1;
}

/* Writes the data and alloc area to the map file.
 */

mapout_data (into)
     char * into;
{
  struct FAB fab;
  struct RAB rab;
  int status;
  struct map_data map_data;
  int datasize, msize;
  char * sbrk ();
  
  map_data.sdata = start_of_data ();
  map_data.edata = edata;
  map_data.smalloc = _malloc_base;
  map_data.emalloc = sbrk (0) - 1;
  datasize = map_data.edata - map_data.sdata + 1;
  msize = map_data.emalloc - map_data.smalloc + 1;
  map_data.datablk = 2 + (sizeof (map_data) + BLOCKSIZE - 1) / BLOCKSIZE;
  map_data.mblk = 1 + map_data.datablk +
    ((datasize + BLOCKSIZE - 1) / BLOCKSIZE);
  /* Create map file.
   */
  fab = cc$rms_fab;
  fab.fab$b_fac = FAB$M_BIO|FAB$M_PUT;
  fab.fab$l_fna = into;
  fab.fab$b_fns = strlen (into);
  fab.fab$l_fop = FAB$M_CBT;
  fab.fab$b_org = FAB$C_SEQ;
  fab.fab$b_rat = 0;
  fab.fab$b_rfm = FAB$C_VAR;
  fab.fab$l_alq = 1 + map_data.mblk +
    ((msize + BLOCKSIZE - 1) / BLOCKSIZE);
  status = sys$create (&fab);
  if (status != RMS$_NORMAL)
    {
      error ("Could not create map file");
      return 0;
    }
  /* Connect the RAB block */
  rab = cc$rms_rab;
  rab.rab$l_fab = &fab;
  rab.rab$b_rac = RAB$C_SEQ;
  rab.rab$l_rop = RAB$M_BIO;
  status = sys$connect (&rab);
  if (status != RMS$_NORMAL)
    {
      error ("RMS connect to map file failed");
      return 0;
    }
  /* Write the header */
  rab.rab$l_rbf = &map_data;
  rab.rab$w_rsz = sizeof (map_data);
  status = sys$write (&rab);
  if (status != RMS$_NORMAL)
    {
      error ("RMS write (header) to map file failed");
      return 0;
    }
  if (! write_data (&rab, map_data.datablk, map_data.sdata, datasize))
    return 0;
  if (! write_data (&rab, map_data.mblk, map_data.smalloc, msize))
    return 0;
  status = sys$close (&fab);
  if (status != RMS$_NORMAL)
    {
      error ("RMS close on map file failed");
      return 0;
    }
  return 1;
}

static int
write_data (rab, firstblock, data, length)
     struct RAB * rab;
     char * data;
{
  int status;
  
  rab->rab$l_bkt = firstblock;
  while (length > 0)
    {
      rab->rab$l_rbf = data;
      rab->rab$w_rsz = length > MAXWRITE ? MAXWRITE : length;
      status = sys$write (rab, 0, 0);
      if (status != RMS$_NORMAL)
	{
	  error ("RMS write to map file failed");
	  return 0;
	}
      data = &data[MAXWRITE];
      length -= MAXWRITE;
      rab->rab$l_bkt = 0;
    }
  return 1;
}				/* write_data */

#endif /* VMS */

