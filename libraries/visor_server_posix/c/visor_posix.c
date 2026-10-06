#define _GNU_SOURCE
#include "visor_posix.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <termios.h>
#include <unistd.h>

int visor_open_terminal(char *slave, size_t capacity) {
    int master = posix_openpt(O_RDWR | O_NOCTTY);
    if (master < 0) return -1;
    if (grantpt(master) != 0 || unlockpt(master) != 0) {
        int error = errno;
        close(master);
        errno = error;
        return -1;
    }
    const char *name = ptsname(master);
    if (!name || strlen(name) + 1 > capacity) {
        close(master);
        errno = ENAMETOOLONG;
        return -1;
    }
    strcpy(slave, name);
    (void)fcntl(master, F_SETFD, FD_CLOEXEC);
    return master;
}

/// Signal handlers and mask back to their defaults, and every descriptor
/// above the standard three closed: what a child should start from. Only
/// async-signal-safe calls, in a forked child of a multithreaded parent.
static void visor_start_clean(int highest) {
    sigset_t none;
    sigemptyset(&none);
    sigprocmask(SIG_SETMASK, &none, 0);
    struct sigaction standard;
    memset(&standard, 0, sizeof standard);
    standard.sa_handler = SIG_DFL;
    sigemptyset(&standard.sa_mask);
    for (int signal = 1; signal < NSIG; signal++) {
        if (signal == SIGKILL || signal == SIGSTOP) continue;
        sigaction(signal, &standard, 0);
    }
    for (int fd = 3; fd < highest; fd++) close(fd);
}

static int visor_highest_descriptor(void) {
    long limit = sysconf(_SC_OPEN_MAX);
    return (limit > 0 && limit < 65536) ? (int)limit : 65536;
}

pid_t visor_spawn_on_terminal(const char *path, char *const argv[], char *const envp[], const char *directory,
                              int terminal) {
    // Everything the child needs is made before the fork.
    int highest = visor_highest_descriptor();
    pid_t pid = fork();
    if (pid != 0) return pid;

    // The child.
    if (setsid() < 0) _exit(126);
    if (ioctl(terminal, TIOCSCTTY, 0) < 0) _exit(126);
    if (dup2(terminal, 0) < 0 || dup2(terminal, 1) < 0 || dup2(terminal, 2) < 0) _exit(126);
    visor_start_clean(highest);
    if (directory) (void)chdir(directory);
    execve(path, argv, envp);
    _exit(127);
}

int visor_set_terminal_size(int terminal, unsigned short cols, unsigned short rows) {
    struct winsize size;
    memset(&size, 0, sizeof size);
    size.ws_col = cols;
    size.ws_row = rows;
    return ioctl(terminal, TIOCSWINSZ, &size);
}

pid_t visor_spawn_detached(const char *path, char *const argv[], char *const envp[], int log) {
    int highest = visor_highest_descriptor();
    int nothing = open("/dev/null", O_RDONLY | O_CLOEXEC);
    if (nothing < 0) return -1;
    pid_t pid = fork();
    if (pid != 0) {
        close(nothing);
        return pid;
    }

    // The child.
    if (setsid() < 0) _exit(126);
    if (dup2(nothing, 0) < 0 || dup2(log, 1) < 0 || dup2(log, 2) < 0) _exit(126);
    visor_start_clean(highest);
    execve(path, argv, envp);
    _exit(127);
}

int visor_listen(unsigned short port, int everywhere) {
    int listener = socket(AF_INET, SOCK_STREAM, 0);
    if (listener < 0) return -1;
    (void)fcntl(listener, F_SETFD, FD_CLOEXEC);
    int yes = 1;
    setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof yes);
    struct sockaddr_in address;
    memset(&address, 0, sizeof address);
    address.sin_family = AF_INET;
    address.sin_port = htons(port);
    address.sin_addr.s_addr = htonl(everywhere ? INADDR_ANY : INADDR_LOOPBACK);
    if (bind(listener, (struct sockaddr *)&address, sizeof address) != 0 || listen(listener, 64) != 0) {
        int error = errno;
        close(listener);
        errno = error;
        return -1;
    }
    return listener;
}

int visor_listen_unix(const char *path) {
    struct sockaddr_un address;
    if (strlen(path) >= sizeof address.sun_path) { errno = ENAMETOOLONG; return -1; }
    int listener = socket(AF_UNIX, SOCK_STREAM, 0);
    if (listener < 0) return -1;
    (void)fcntl(listener, F_SETFD, FD_CLOEXEC);
    unlink(path);
    memset(&address, 0, sizeof address);
    address.sun_family = AF_UNIX;
    strncpy(address.sun_path, path, sizeof address.sun_path - 1);
    if (bind(listener, (struct sockaddr *)&address, sizeof address) != 0 || chmod(path, 0600) != 0 || listen(listener, 64) != 0) {
        int error = errno;
        close(listener);
        errno = error;
        return -1;
    }
    return listener;
}

int visor_accept(int listener) {
    int connection;
    do {
        connection = accept(listener, 0, 0);
    } while (connection < 0 && errno == EINTR);
    if (connection < 0) return -1;
    (void)fcntl(connection, F_SETFD, FD_CLOEXEC);
    struct timeval patience = {30, 0};
    setsockopt(connection, SOL_SOCKET, SO_SNDTIMEO, &patience, sizeof patience);
    return connection;
}

void visor_shutdown(int socket) {
    shutdown(socket, SHUT_RDWR);
}

void visor_ignore_broken_pipes(void) {
    signal(SIGPIPE, SIG_IGN);
}
