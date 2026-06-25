#include <sys/socket.h>
#include <netinet/in.h>
#include <poll.h>
#include <unistd.h>
int main(void) {
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  struct pollfd p; p.fd = fd; p.events = POLLIN;
  int r = poll(&p, 1, 0);
  return (fd >= 0 && r >= 0) ? 42 : 1;
}
