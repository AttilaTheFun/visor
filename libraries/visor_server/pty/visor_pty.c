#include "visor_pty.h"

#include <signal.h>
#include <sys/ioctl.h>
#include <unistd.h>

pid_t visor_spawn_on_terminal(const char *path, char *const argv[], char *const envp[], const char *directory,
                              int terminal) {
    // Everything the child needs is made before the fork: between fork and
    // execve a multithreaded parent's child may only make
    // async-signal-safe calls.
    sigset_t none;
    sigemptyset(&none);
    struct sigaction standard = {0};
    standard.sa_handler = SIG_DFL;
    sigemptyset(&standard.sa_mask);
    long limit = sysconf(_SC_OPEN_MAX);
    int highest = (limit > 0 && limit < 65536) ? (int)limit : 65536;

    pid_t pid = fork();
    if (pid != 0) return pid;

    // The child.
    sigprocmask(SIG_SETMASK, &none, 0);
    for (int signal = 1; signal < NSIG; signal++) {
        if (signal == SIGKILL || signal == SIGSTOP) continue;
        sigaction(signal, &standard, 0);
    }
    if (setsid() < 0) _exit(126);
    if (ioctl(terminal, TIOCSCTTY, 0) < 0) _exit(126);
    if (dup2(terminal, 0) < 0 || dup2(terminal, 1) < 0 || dup2(terminal, 2) < 0) _exit(126);
    for (int fd = 3; fd < highest; fd++) close(fd);
    if (directory) (void)chdir(directory);
    execve(path, argv, envp);
    _exit(127);
}
