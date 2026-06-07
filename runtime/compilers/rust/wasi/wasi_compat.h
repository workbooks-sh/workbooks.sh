#pragma once
#if defined(__wasi__)
#include <errno.h>
#include <sys/types.h>
static inline int pipe(int fds[2]){ (void)fds; errno=ENOSYS; return -1; }
typedef struct { int _u; } posix_spawn_file_actions_t;
typedef struct { int _u; } posix_spawnattr_t;
static inline int posix_spawn_file_actions_init(posix_spawn_file_actions_t*){return 0;}
static inline int posix_spawn_file_actions_destroy(posix_spawn_file_actions_t*){return 0;}
static inline int posix_spawn_file_actions_adddup2(posix_spawn_file_actions_t*,int,int){return 0;}
static inline int posix_spawn_file_actions_addclose(posix_spawn_file_actions_t*,int){return 0;}
static inline int posix_spawn(pid_t* p,const char*,const posix_spawn_file_actions_t*,const posix_spawnattr_t*,char* const[],char* const[]){ if(p)*p=-1; errno=ENOSYS; return ENOSYS; }
static inline pid_t waitpid(pid_t,int*,int){ errno=ENOSYS; return -1; }
static inline int kill(pid_t,int){ errno=ENOSYS; return -1; }
#ifndef WIFEXITED
#define WIFEXITED(s) 0
#define WEXITSTATUS(s) (s)
#define WIFSIGNALED(s) 0
#define WTERMSIG(s) 0
#endif
#endif
