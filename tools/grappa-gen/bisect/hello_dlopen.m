/* hello_dlopen.m — grappa-gen bisect level 2: level 1 + one dlopen.
 *
 * Adds exactly one action to hello_foundation.m: dlopen of
 * AirTrafficHost (the private framework that EXISTS on the macOS CI
 * runner; AirTrafficDevice does not ship on macOS). The dlopen result
 * is recorded between MARK 2/MARK 3 but does not change the exit
 * code — this level tests process survival, not framework usability.
 * If levels 0–1 live and this dies (especially between MARK 2 and
 * MARK 3), loading the private framework itself is the kill point.
 * Level 3 in the bisect is the full grappa-gen (tools/grappa-gen/
 * main.m), run by the same script right after this one.
 */

#import <Foundation/Foundation.h>
#import <dlfcn.h>
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
    fprintf(stderr, "hello-dlopen: %s\n", line);
    fflush(stderr);
}

static void markf2(const char *a, const char *b) {
    char buf[1200];
    snprintf(buf, sizeof(buf), "%s%s", a, b ?: "");
    mark(buf);
}

int main(int argc, char *argv[]) {
    if (argc > 1 && argv[1] != NULL && argv[1][0] != '\0') {
        gDiagFd = open(argv[1], O_WRONLY | O_CREAT | O_APPEND, 0644);
    }
    mark("MARK 0: hello-dlopen main() entered");
    @autoreleasepool {
        mark("MARK 1: autoreleasepool entered");
        static const char *path =
            "/System/Library/PrivateFrameworks/AirTrafficHost.framework/AirTrafficHost";
        mark("MARK 2: before dlopen AirTrafficHost");
        dlerror(); /* clear */
        void *handle = dlopen(path, RTLD_NOW);
        if (handle != NULL) {
            mark("MARK 3: after dlopen AirTrafficHost -> handle OK");
        } else {
            const char *err = dlerror();
            markf2("MARK 3: after dlopen AirTrafficHost -> NULL, dlerror: ",
                   err ?: "unknown error");
        }
        mark("MARK 4: hello-dlopen about to exit 0");
        fprintf(stdout, "hello-dlopen stdout ok (dlopen %s)\n",
                handle != NULL ? "OK" : "NULL");
        fflush(stdout);
    }
    if (gDiagFd >= 0) {
        close(gDiagFd);
    }
    return 0;
}
