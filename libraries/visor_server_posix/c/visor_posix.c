#define _GNU_SOURCE
#include "visor_posix.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <sys/wait.h>
#ifdef __APPLE__
#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/resource.h>
#include <sys/sysctl.h>
#else
#include <dirent.h>
#endif
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>

/// Signal handlers and mask back to their defaults, and every descriptor
/// above the standard three closed but `keep` (-1 for none): what a child
/// should start from. Only async-signal-safe calls, in a forked child of a
/// multithreaded parent.
static void visor_start_clean(int highest, int keep) {
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
    for (int fd = 3; fd < highest; fd++) if (fd != keep) close(fd);
}

/// In a forked child that could not start its program: why (errno) written
/// to the parent's pipe, then gone.
__attribute__((noreturn)) static void visor_child_failed(int told, int status) {
    int error = errno;
    (void)!write(told, &error, sizeof error);
    _exit(status);
}

static int visor_highest_descriptor(void) {
    long limit = sysconf(_SC_OPEN_MAX);
    return (limit > 0 && limit < 65536) ? (int)limit : 65536;
}

pid_t visor_spawn_piped(const char *path, char *const argv[], char *const envp[], const char *directory, int pipes[3]) {
    int input[2], output[2], errors[2];
    if (pipe(input) != 0) return -1;
    if (pipe(output) != 0) { close(input[0]); close(input[1]); return -1; }
    if (pipe(errors) != 0) { close(input[0]); close(input[1]); close(output[0]); close(output[1]); return -1; }
    int highest = visor_highest_descriptor();
    pid_t pid = fork();
    if (pid == 0) {
        // The child.
        setpgid(0, 0);
        if (dup2(input[0], 0) < 0 || dup2(output[1], 1) < 0 || dup2(errors[1], 2) < 0) _exit(126);
        visor_start_clean(highest, -1);
        if (directory) (void)chdir(directory);
        execve(path, argv, envp);
        _exit(127);
    }
    int error = errno;
    close(input[0]);
    close(output[1]);
    close(errors[1]);
    if (pid < 0) {
        close(input[1]);
        close(output[0]);
        close(errors[0]);
        errno = error;
        return -1;
    }
    // Its group from here as well, so a signal to the group straight
    // after this cannot miss it.
    setpgid(pid, pid);
    pipes[0] = input[1];
    pipes[1] = output[0];
    pipes[2] = errors[0];
    for (int i = 0; i < 3; i++) (void)fcntl(pipes[i], F_SETFD, FD_CLOEXEC);
    return pid;
}

int visor_wait(pid_t pid, int *status, int *signaled) {
    int raw = 0;
    pid_t ended;
    do {
        ended = waitpid(pid, &raw, 0);
    } while (ended < 0 && errno == EINTR);
    if (ended < 0) return -1;
    *signaled = WIFSIGNALED(raw) ? 1 : 0;
    *status = WIFSIGNALED(raw) ? WTERMSIG(raw) : WEXITSTATUS(raw);
    return 0;
}

#ifdef __APPLE__
int visor_processes(struct visor_process *out, int capacity) {
    int room = proc_listallpids(0, 0) + 64;
    if (room <= 64) return -1;
    pid_t *pids = calloc((size_t)room, sizeof(pid_t));
    if (!pids) return -1;
    int found = proc_listallpids(pids, room * (int)sizeof(pid_t));
    int count = 0;
    for (int i = 0; i < found && count < capacity; i++) {
        struct proc_bsdinfo info;
        if (proc_pidinfo(pids[i], PROC_PIDTBSDINFO, 0, &info, sizeof info) != sizeof info) continue;
        struct rusage_info_v2 usage;
        unsigned long long memory = 0;
        if (proc_pid_rusage(pids[i], RUSAGE_INFO_V2, (rusage_info_t *)&usage) == 0) memory = usage.ri_phys_footprint;
        out[count].pid = pids[i];
        out[count].parent = (pid_t)info.pbi_ppid;
        out[count].memory = memory;
        strncpy(out[count].name, info.pbi_name[0] ? info.pbi_name : info.pbi_comm, sizeof out[count].name - 1);
        out[count].name[sizeof out[count].name - 1] = 0;
        count++;
    }
    free(pids);
    return count;
}

unsigned long long visor_physical_memory(void) {
    unsigned long long memory = 0;
    size_t size = sizeof memory;
    if (sysctlbyname("hw.memsize", &memory, &size, 0, 0) != 0) return 0;
    return memory;
}
#else
int visor_processes(struct visor_process *out, int capacity) {
    DIR *proc = opendir("/proc");
    if (!proc) return -1;
    long page = sysconf(_SC_PAGESIZE);
    int count = 0;
    struct dirent *entry;
    while ((entry = readdir(proc)) && count < capacity) {
        char *end;
        long pid = strtol(entry->d_name, &end, 10);
        if (*end || pid <= 0) continue;
        char path[64], line[512];
        snprintf(path, sizeof path, "/proc/%ld/stat", pid);
        FILE *file = fopen(path, "r");
        if (!file) continue;
        size_t length = fread(line, 1, sizeof line - 1, file);
        fclose(file);
        line[length] = 0;
        // "pid (name) state ppid …": the name may hold spaces and parens.
        char *open = strchr(line, '('), *close = strrchr(line, ')');
        if (!open || !close || close < open) continue;
        char state;
        int parent;
        if (sscanf(close + 1, " %c %d", &state, &parent) != 2) continue;
        unsigned long long memory = 0;
        snprintf(path, sizeof path, "/proc/%ld/statm", pid);
        file = fopen(path, "r");
        if (file) {
            unsigned long size = 0, resident = 0;
            if (fscanf(file, "%lu %lu", &size, &resident) == 2) memory = (unsigned long long)resident * (unsigned long long)page;
            fclose(file);
        }
        out[count].pid = (pid_t)pid;
        out[count].parent = (pid_t)parent;
        out[count].memory = memory;
        size_t name = (size_t)(close - open - 1);
        if (name >= sizeof out[count].name) name = sizeof out[count].name - 1;
        memcpy(out[count].name, open + 1, name);
        out[count].name[name] = 0;
        count++;
    }
    closedir(proc);
    return count;
}

unsigned long long visor_physical_memory(void) {
    long pages = sysconf(_SC_PHYS_PAGES), size = sysconf(_SC_PAGESIZE);
    return pages > 0 && size > 0 ? (unsigned long long)pages * (unsigned long long)size : 0;
}
#endif

pid_t visor_spawn_detached(const char *path, char *const argv[], char *const envp[], int log) {
    int highest = visor_highest_descriptor();
    int nothing = open("/dev/null", O_RDONLY | O_CLOEXEC);
    if (nothing < 0) return -1;
    // Whether the program started: the child writes errno here if it could
    // not, and the pipe closes without a word once the program runs
    // (close-on-exec). Nobody else waits for a daemon, so a program that
    // is not there would otherwise go unnoticed.
    int told[2];
    if (pipe(told) != 0) {
        int error = errno;
        close(nothing);
        errno = error;
        return -1;
    }
    (void)fcntl(told[0], F_SETFD, FD_CLOEXEC);
    (void)fcntl(told[1], F_SETFD, FD_CLOEXEC);
    pid_t pid = fork();
    if (pid != 0) {
        int error = errno;
        close(nothing);
        close(told[1]);
        if (pid < 0) {
            close(told[0]);
            errno = error;
            return -1;
        }
        int failed = 0;
        ssize_t got;
        do got = read(told[0], &failed, sizeof failed); while (got < 0 && errno == EINTR);
        close(told[0]);
        if (got == (ssize_t)sizeof failed) {
            (void)waitpid(pid, 0, 0);
            errno = failed;
            return -1;
        }
        return pid;
    }

    // The child.
    if (setsid() < 0) visor_child_failed(told[1], 126);
    if (dup2(nothing, 0) < 0 || dup2(log, 1) < 0 || dup2(log, 2) < 0) visor_child_failed(told[1], 126);
    visor_start_clean(highest, told[1]);
    execve(path, argv, envp);
    visor_child_failed(told[1], 127);
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

int visor_connect_unix(const char *path) {
    struct sockaddr_un address;
    if (strlen(path) >= sizeof address.sun_path) { errno = ENAMETOOLONG; return -1; }
    int connection = socket(AF_UNIX, SOCK_STREAM, 0);
    if (connection < 0) return -1;
    (void)fcntl(connection, F_SETFD, FD_CLOEXEC);
    memset(&address, 0, sizeof address);
    address.sun_family = AF_UNIX;
    strncpy(address.sun_path, path, sizeof address.sun_path - 1);
    if (connect(connection, (struct sockaddr *)&address, sizeof address) != 0) {
        int error = errno;
        close(connection);
        errno = error;
        return -1;
    }
    struct timeval patience = {30, 0};
    setsockopt(connection, SOL_SOCKET, SO_SNDTIMEO, &patience, sizeof patience);
    return connection;
}

int visor_unix_answers(const char *path) {
    struct sockaddr_un address;
    if (strlen(path) >= sizeof address.sun_path) return 0;
    int probe = socket(AF_UNIX, SOCK_STREAM, 0);
    if (probe < 0) return 0;
    memset(&address, 0, sizeof address);
    address.sun_family = AF_UNIX;
    strncpy(address.sun_path, path, sizeof address.sun_path - 1);
    int answers = connect(probe, (struct sockaddr *)&address, sizeof address) == 0;
    close(probe);
    return answers;
}

void visor_local_address(int socket, char *out, size_t size) {
    if (size == 0) return;
    out[0] = 0;
    struct sockaddr_storage address;
    socklen_t length = sizeof address;
    if (getsockname(socket, (struct sockaddr *)&address, &length) != 0) return;
    if (address.ss_family == AF_INET) {
        inet_ntop(AF_INET, &((struct sockaddr_in *)&address)->sin_addr, out, (socklen_t)size);
    } else if (address.ss_family == AF_INET6) {
        inet_ntop(AF_INET6, &((struct sockaddr_in6 *)&address)->sin6_addr, out, (socklen_t)size);
    }
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
