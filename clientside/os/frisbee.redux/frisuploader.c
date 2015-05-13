/*
 * Copyright (c) 2010-2014 University of Utah and the Flux Group.
 * 
 * {{{EMULAB-LICENSE
 * 
 * This file is part of the Emulab network testbed software.
 * 
 * This file is free software: you can redistribute it and/or modify it
 * under the terms of the GNU Affero General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or (at
 * your option) any later version.
 * 
 * This file is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
 * FITNESS FOR A PARTICULAR PURPOSE.  See the GNU Affero General Public
 * License for more details.
 * 
 * You should have received a copy of the GNU Affero General Public License
 * along with this file.  If not, see <http://www.gnu.org/licenses/>.
 * 
 * }}}
 */

/*
 * Server-side for uploading of frisbee images.
 * Invoked by the frisbee master server.
 */
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <signal.h>
#include <fcntl.h>
#include <sys/time.h>
#include <setjmp.h>
#include "decls.h"
#include "uploadio.h"

static struct in_addr clientip;
static struct in_addr clientif;
static char *path;
static uint64_t maxsize = 0;
static int bufsize = (64 * 1024);;
static int timeout = 0;
static int idletimeout = 0;
static int sock = -1;

/* Globals */
int debug = 0;
int portnum;
int sockbufsize = SOCKBUFSIZE;

static void usage(void);
static void parse_args(int argc, char **argv);
static void net_init(void);
static int recv_file(void);

int
main(int argc, char **argv)
{
	int rv;

	UploadLogInit();
	parse_args(argc, argv);

	net_init();

	FrisLog("%s: listening as %d/%d on port %d for image data from %s (max of %llu bytes)",
		path, geteuid(), getegid(), portnum, inet_ntoa(clientip), maxsize);
	if (idletimeout || timeout)
		FrisLog("%s: using idletimeout=%ds, timeout=%ds\n",
			path, idletimeout, timeout);

	rv = recv_file();
	close(sock);

	exit(rv);
}

static void
parse_args(int argc, char **argv)
{
	int ch;
	while ((ch = getopt(argc, argv, "m:p:i:b:I:T:s:")) != -1) {
		switch (ch) {
		case 'm':
			if (!inet_aton(optarg, &clientip)) {
				fprintf(stderr, "Invalid client IP '%s'\n",
					optarg);
				exit(1);
			}
			break;
		case 'p':
			portnum = atoi(optarg);
			break;
		case 'i':
			if (!inet_aton(optarg, &clientif)) {
				fprintf(stderr, "Invalid client iface IP '%s'\n",
					optarg);
				exit(1);
			}
			break;
		case 'b':
			bufsize = atoi(optarg);
			if (bufsize < 0 || bufsize > MAX_BUFSIZE) {
				fprintf(stderr, "Invalid buffer size %d\n",
					bufsize);
				exit(1);
			}
			break;
		case 'I':
			idletimeout = atoi(optarg);
			if (idletimeout < 0 || idletimeout > (24 * 60 * 60)) {
				fprintf(stderr, "Invalid idle timeout %d\n",
					idletimeout);
				exit(1);
			}
			break;
		case 'T':
			timeout = atoi(optarg);
			if (timeout < 0 || timeout > (24 * 60 * 60)) {
				fprintf(stderr, "Invalid timeout %d\n",
					timeout);
				exit(1);
			}
			break;
		case 's':
			maxsize = strtoull(optarg, NULL, 0);
			break;
		default:
			break;
		}
	}
	argc -= optind;
	argv += optind;

	if (clientip.s_addr == 0 || portnum == 0 || argc < 1)
		usage();
	/*
	 * If both timeouts are set, make sure they play nice
	 */
	if (idletimeout > 0 && timeout > 0) {
		/* idletimeout should be <= timeout */
		if (idletimeout > timeout)
			idletimeout = timeout;
		/* if the are equal, no need for the idletimeout */
		if (idletimeout == timeout)
			idletimeout = 0;
	}

	path = argv[0];
}

static void
usage(void)
{
	char *usagestr =
    	"\nusage: frisuploader [-i iface] [-T timo] [-s maxsize] -m IP -p port outfile\n"
        "Upload a file from client identified by <IP>:<port> and save to <outfile>.\n"
	"Options:\n"
        "<outfile>      File to save the uploaded data into.\n"
	"               Will be created or truncated as necessary.\n"
	"  -m <addr>    Unicast IP address of client to upload from.\n"
	"  -p <port>    TCP port number on which to listen for client.\n"

	"  -i <iface>   Interface on which to listen (specified by local IP).\n"
	"  -I <timo>    Max time (in seconds) to allow connect to be idle (no traffic from client).\n"
	"  -T <timo>    Max time (in seconds) to wait for upload to complete.\n"
    	"  -s <size>    Maximum amount of data (in bytes) to upload.\n"
    	"\n\n";
    	
    	fprintf(stderr, "Frisbee upload/download client%s", usagestr);
	exit(1);
}

static sigjmp_buf toenv;

static void
recv_timeout(int sig)
{
	siglongjmp(toenv, 1);
}

/*
 * XXX multithread (socket read, file write)
 */
static int
recv_file()
{
	/* volatiles are for setjmp/longjmp */
	conn * volatile conn = NULL;
	char * volatile wbuf = NULL;
	volatile int fd = -1;
	volatile uint64_t remaining = maxsize;
	struct timeval st, et;
	int rv = 1;
	char *stat;

	gettimeofday(&st, NULL);	/* XXX for early errors */

	/*
	 * If we have an overall timeout (timeout > 0) then just set the
	 * alarm to that and we will longjmp if we hit it.
	 *
	 * Idletimeout are handled by the connection.
	 */
	if (timeout > 0) {
		struct itimerval it;

		if (sigsetjmp(toenv, 1)) {
			rv = 2;
			goto done;
		}
		it.it_value.tv_sec = timeout;
		it.it_value.tv_usec = 0;
		it.it_interval.tv_sec = it.it_interval.tv_usec = 0;
		signal(SIGALRM, recv_timeout);
		setitimer(ITIMER_REAL, &it, NULL);
	}

	wbuf = malloc(bufsize);
	if (wbuf == NULL) {
		FrisError("Could not allocate %d byte buffer, try using -b",
			  bufsize);
		goto done;
	}

	if (strcmp(path, "-") == 0)
		fd = STDOUT_FILENO;
	else
		fd = open(path, O_WRONLY|O_CREAT|O_TRUNC, 0644);
	if (fd < 0) {
		FrisPwarning(path);
		goto done;
	}

	conn = conn_accept_tcp(sock, &clientip, idletimeout, idletimeout);
	if (conn == NULL) {
		FrisError("Error accepting from %s", inet_ntoa(clientip));
		goto done;
	}
	FrisLog("%s: upload from %s started", path, inet_ntoa(clientip));

	gettimeofday(&st, NULL);
	while (maxsize == 0 || remaining > 0) {
		ssize_t cc, ncc;

		if (maxsize == 0 || remaining > bufsize)
			cc = bufsize;
		else
			cc = remaining;
		ncc = conn_read(conn, wbuf, cc);
		if (ncc < 0) {
			if (conn_timeout(conn))
				rv = 2;
			else
				FrisPwarning("socket read");
			goto done;
		}
		if (ncc == 0)
			break;

		cc = write(fd, wbuf, ncc);
		if (cc < 0) {
			FrisPwarning("file write");
			goto done;
		}
		remaining -= cc;
		if (cc != ncc) {
			FrisError("short write on file (%d != %d)", cc, ncc);
			goto done;
		}
	}
	/* Note that coming up short (remaining > 0) is not an error */
	rv = 0;

 done:
	gettimeofday(&et, NULL);

	if (timeout) {
		struct itimerval it;

		it.it_value.tv_sec = it.it_value.tv_usec = 0;
		setitimer(ITIMER_REAL, &it, NULL);

	}
	if (conn != NULL)
		conn_close(conn);
	if (fd >= 0) {
		if (rv == 0 && fsync(fd) != 0) {
			perror(path);
			rv = 1;
		}
		close(fd);
	}
	if (wbuf != NULL)
		free(wbuf);

	timersub(&et, &st, &et);

	stat = rv == 0 ? "completed" : (rv == 1 ? "terminated" : "timed-out");
	if (maxsize && remaining)
		FrisLog("%s: upload %s after %llu (of max %llu) bytes "
			"in %d.%03d seconds",
			path, stat, maxsize-remaining, maxsize,
			et.tv_sec, et.tv_usec/1000);
	else
		FrisLog("%s: upload %s after %llu bytes in %d.%03d seconds",
			path, stat, maxsize-remaining,
			et.tv_sec, et.tv_usec/1000);

	/* XXX unlink file on error? */
	return rv;
}

/*
 * It would be nice to use some of the infrastructure in network.c,
 * but ServerNetInit only sets up UDP sockets. Maybe when we revisit
 * and refactor...
 */
static void
net_init(void)
{
	struct sockaddr_in name;
	
	if ((sock = socket(PF_INET, SOCK_STREAM, IPPROTO_TCP)) < 0)
		FrisPfatal("Could not allocate socket");

	name.sin_family = AF_INET;
	name.sin_addr.s_addr = clientif.s_addr;
	name.sin_port = htons(portnum);
	if (bind(sock, (struct sockaddr *)&name, sizeof(name)) < 0) {
		/*
		 * We reproduce ServerNetInit behavior here: if we cannot
		 * bind to the indicated port we exit with a special status
		 * so that the master server which invoked us can pick
		 * another.
		 */
		perror("Binding to socket");
		close(sock);
		exit(EADDRINUSE);
	}
	if (listen(sock, 128) < 0) {
		close(sock);
		FrisPfatal("Could not listen on socket");
	}
}
