#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(int argc, char **argv) {
     int rv;

     if (argc != 2) {
         printf("usage: %s exp-to-swap\n", *argv);
         exit(1);
     }

     rv = setuid(geteuid());
     if ( rv < 0) {
         perror("setuid");
         exit(1);
     }

     rv = execl("/usr/testbed/sbin/withadminprivs",
                "/usr/testbed/sbin/withadminprivs",
                "/usr/testbed/sbin/idleswap",
                "-i",
                argv[1],
				(char *)0);
     perror("execl");
     exit(1);
}
