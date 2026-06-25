// §8 fork — the return-twice proc_fork oracle (bd wb-nsrp).
// A real wasix-libc C program using fork()+waitpid() UNCHANGED. wasix-libc's fork()
// wrapper emits the wasix_32v1.{stack_checkpoint,proc_fork,stack_restore} import trio —
// so this single binary drives all three Washy host clauses through the genuine asyncify
// setjmp dance. Proves return-twice semantics: parent sees child pid, child sees 0, child
// has its OWN copy of linear memory (mutation isolation), parent reaps the exit status.
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/wait.h>

int main(void) {
    // a heap sentinel the child will mutate; the parent must NOT observe the mutation
    int *shared = malloc(sizeof(int));
    *shared = 100;

    pid_t pid = fork();
    if (pid < 0) {
        // fork failed (ENOSYS today) — distinct exit so the oracle can tell apart
        return 9;
    }
    if (pid == 0) {
        // CHILD: mutate our copy, prove isolation, exit with a known status
        *shared = 200;
        if (*shared != 200) _exit(11);
        _exit(7);
    }
    // PARENT: wait for the child, assert its status, assert our copy is untouched
    int status = 0;
    pid_t got = waitpid(pid, &status, 0);
    if (got != pid) return 8;
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 7) return 6;
    if (*shared != 100) return 5;  // memory-isolation proof: parent's copy unchanged
    return 42;
}
