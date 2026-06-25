#include <pthread.h>
static int counter = 0;
static void *worker(void *arg) {
  for (int i = 0; i < 1000; i++) __atomic_fetch_add(&counter, 1, __ATOMIC_SEQ_CST);
  return 0;
}
int main(void) {
  pthread_t t1, t2;
  pthread_create(&t1, 0, worker, 0);
  pthread_create(&t2, 0, worker, 0);
  pthread_join(t1, 0);
  pthread_join(t2, 0);
  return counter == 2000 ? 42 : counter;
}
