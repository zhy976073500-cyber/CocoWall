/* hello_foundation.m — grappa-gen bisect level 1: ObjC + Foundation.
 *
 * Same structure as hello.c (argv[1] diag file, MARK 0 first via raw
 * write()+fsync), but compiled with grappa-gen's exact flags
 * (-fobjc-arc -fblocks -framework Foundation) and it actually enters
 * an @autoreleasepool and uses Foundation classes. If level 0 lives
 * and this dies pre-main, the ObjC/Foundation layer (or its link /
 * deployment-target shape) is implicated; if both live, suspicion
 * moves to what grappa-gen does next (dlopen of private frameworks).
 */

#import <Foundation/Foundation.h>
#import <fcntl.h>
#import <string.h>
#import <unistd.h>

static int gDiagFd = -1;

static void mark(const char *line) {
    if (gDiagFd >= 0) {
        (void)!write(gDiagFd, line, strlen(line));
        (void)!write(gDiagFd, "\n", 1);
        fsync(gDiagFd);
    }
    fprintf(stderr, "hello-foundation: %s\n", line);
    fflush(stderr);
}

int main(int argc, char *argv[]) {
    if (argc > 1 && argv[1] != NULL && argv[1][0] != '\0') {
        gDiagFd = open(argv[1], O_WRONLY | O_CREAT | O_APPEND, 0644);
    }
    mark("MARK 0: hello-foundation main() entered");
    @autoreleasepool {
        mark("MARK 1: autoreleasepool entered");
        NSString *s = [NSString stringWithFormat:@"foundation ok (%d)", 42];
        mark(s.UTF8String ?: "MARK 2: (string unavailable)");
        fprintf(stdout, "hello-foundation stdout: %s\n", s.UTF8String ?: "?");
        fflush(stdout);
        mark("MARK 3: hello-foundation about to exit 0");
    }
    if (gDiagFd >= 0) {
        close(gDiagFd);
    }
    return 0;
}
