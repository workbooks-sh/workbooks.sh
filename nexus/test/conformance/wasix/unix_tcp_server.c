#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <pthread.h>
#include <string.h>
#include <unistd.h>
static int port_fd_listen;
static unsigned short bound_port;
static void *server(void *_) {
    int c = accept(port_fd_listen, 0, 0);
    char buf[5] = {0};
    read(c, buf, 4);
    write(c, buf, 4);           // echo back
    close(c);
    return 0;
}
int main(void) {
    int ls = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in a; memset(&a, 0, sizeof a);
    a.sin_family = AF_INET; a.sin_addr.s_addr = htonl(0x7f000001); a.sin_port = 0;
    if (bind(ls, (struct sockaddr*)&a, sizeof a) != 0) return 1;
    socklen_t al = sizeof a; getsockname(ls, (struct sockaddr*)&a, &al);
    bound_port = a.sin_port;
    if (listen(ls, 1) != 0) return 2;
    port_fd_listen = ls;
    pthread_t t; pthread_create(&t, 0, server, 0);
    int cs = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in sa; memset(&sa, 0, sizeof sa);
    sa.sin_family = AF_INET; sa.sin_addr.s_addr = htonl(0x7f000001); sa.sin_port = bound_port;
    if (connect(cs, (struct sockaddr*)&sa, sizeof sa) != 0) return 3;
    write(cs, "ping", 4);
    char buf[5] = {0}; read(cs, buf, 4);
    pthread_join(t, 0);
    return strcmp(buf, "ping") == 0 ? 42 : 4;
}
