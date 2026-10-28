/* hello.c — grappa-gen bisect level 0: the most trivial C tool.
 *
 * Purpose (build #27/#28 debugging): grappa-gen died with SIGKILL
 * (exit 137) before main()'s first statement — its write()+fsync diag
 * file never existed. This level separates "our binary" from "the CI
 * execution environment": it is compiled and run by the exact same
 * project.yml build-script path as grappa-gen. If even this dies
 * pre-main, the problem is the environment / execution policy, not
 * anything grappa-gen links or loads.
 *
 * Contract mirrors grappa-gen: argv[1] = diag file; MARK 0 is the
 * first statement of main(), written with raw write()+fsync.
 * stdout: one line. exit 0 on success.
 */

#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static int gDiagFd = -1;

static void mark(const char *line) {
    if (gDiagFd >= 0) {
        (void)!write(gDiagFd, line, strlen(line));
        (void)!write(gDiagFd, "\n", 1);
        fsync(gDiagFd);
    }
    fprintf(stderr, "hello-c: %s\n", line);
    fflush(stderr);
}

int main(int argc, char *argv[]) {
    if (argc > 1 && argv[1] != NULL && argv[1][0] != '\0') {
        gDiagFd = open(argv[1], O_WRONLY | O_CREAT | O_APPEND, 0644);
    }
    mark("MARK 0: hello-c main() entered");
    mark("MARK 1: hello-c about to exit 0");
    printf("hello-c stdout ok\n");
    fflush(stdout);
    if (gDiagFd >= 0) {
        close(gDiagFd);
    }
    return 0;
}
