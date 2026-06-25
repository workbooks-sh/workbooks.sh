#include <termios.h>
#include <sys/ioctl.h>
#include <unistd.h>
int main(void) {
    struct termios t;
    if (tcgetattr(0, &t) != 0) return 1;        // get tty attrs (§4 tty_get)
    struct termios raw = t;
    raw.c_lflag &= ~(ECHO | ICANON);            // raw mode: no echo, no canonical
    if (tcsetattr(0, TCSANOW, &raw) != 0) return 2;   // set (§4 tty_set)
    struct winsize ws;
    int got_size = ioctl(1, TIOCGWINSZ, &ws) == 0 && ws.ws_col > 0;  // window size
    tcsetattr(0, TCSANOW, &t);                   // restore
    return (got_size && ws.ws_col > 0 && ws.ws_row > 0) ? 42 : 3;
}
