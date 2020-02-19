/*
 * =====================================================================================
 *
 *       Filename:  gups.c
 *
 *    Description:  
 *
 *        Version:  1.0
 *        Created:  02/21/2018 02:36:27 PM
 *       Revision:  none
 *       Compiler:  gcc
 *
 *         Author:  YOUR NAME (), 
 *   Organization:  
 *
 * =====================================================================================
 */

#define _GNU_SOURCE

#include <stdlib.h>
#include <stdio.h>
#include <assert.h>
#include <unistd.h>
#include <sys/time.h>
#include <fcntl.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <math.h>
#include <string.h>
#include <pthread.h>
#include <sys/mman.h>
#include <errno.h>

#include "timer.h"
#include "hemem.h"


#include "gups.h"

#define MAX_THREADS	64

#ifdef HOTSPOT
extern uint64_t hotset_start;
extern double hotset_fraction;
#endif

struct gups_args {
  int tid;                      // thread id
  unsigned long *indices;       // array of indices to access
  void* field;                  // pointer to start of thread's region
  unsigned long iters;          // iterations to perform
  unsigned long size;           // size of region
  unsigned long elt_size;       // size of elements
};

static unsigned long updates, nelems;

static void *do_gups(void *arguments)
{
  //printf("do_gups entered\n");
  struct gups_args *args = (struct gups_args*)arguments;
  char *field = (char*)(args->field);
  unsigned long i;
  unsigned long long index;
  unsigned long elt_size = args->elt_size;
  char data[elt_size];

  //printf("Thread [%d] starting: field: [%llx]\n", args->tid, field);
  for (i = 0; i < args->iters; i++) {
    index = args->indices[i];
    memcpy(data, &field[index * elt_size], elt_size);
    memset(data, data[0] + i, elt_size);
    memcpy(&field[index * elt_size], data, elt_size);
  }

  return 0;
}

static void *calc_indices_thread(void *arg)
{
  struct gups_args *gai = arg;
  calc_indices(gai->indices, updates, nelems);
  return NULL;
}

int main(int argc, char **argv)
{
  int threads;
  unsigned long expt;
  unsigned long size, elt_size;
  struct timeval starttime, stoptime;
  double secs, gups;
  int i;
  void *p;
  struct gups_args** ga;
  pthread_t t[MAX_THREADS];

  if (argc != 5) {
    printf("Usage: %s [threads] [updates per thread] [exponent] [data size (bytes)] [noremap/remap]\n", argv[0]);
    printf("  threads\t\t\tnumber of threads to launch\n");
    printf("  updates per thread\t\tnumber of updates per thread\n");
    printf("  exponent\t\t\tlog size of region\n");
    printf("  data size\t\t\tsize of data in array (in bytes)\n");
    return 0;
  }

  gettimeofday(&starttime, NULL);
  
  threads = atoi(argv[1]);
  assert(threads <= MAX_THREADS);
  ga = (struct gups_args**)malloc(threads * sizeof(struct gups_args*));
  
  updates = atol(argv[2]);
  updates -= updates % 256;
  expt = atoi(argv[3]);
  assert(expt > 8);
  assert(updates > 0 && (updates % 256 == 0));
  size = (unsigned long)(1) << expt;
  size -= (size % 256);
  assert(size > 0 && (size % 256 == 0));
  elt_size = atoi(argv[4]);

  printf("%lu updates per thread (%d threads)\n", updates, threads);
  printf("field of 2^%lu (%lu) bytes\n", expt, size);
  printf("%ld byte element size (%ld elements total)\n", elt_size, size / elt_size);

  p = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANONYMOUS, -1, 0);

  gettimeofday(&stoptime, NULL);
  printf("Init took %.4f seconds\n", elapsed(&starttime, &stoptime));
  printf("Region address: %p\t size: %ld\n", p, size);
  //printf("Field addr: 0x%x\n", p);

  nelems = (size / threads) / elt_size; // number of elements per thread
  printf("Elements per thread: %lu\n", nelems);

  printf("initializing thread data\n");
  for (i = 0; i < threads; ++i) {
    ga[i] = (struct gups_args*)malloc(sizeof(struct gups_args));
    ga[i]->field = p + (i * nelems * elt_size);
    //printf("Thread [%d] starting address: %llx\n", i, ga[i]->field);
    //printf("thread %d start address: %llu\n", i, (unsigned long)td[i].field);
    ga[i]->indices = (unsigned long*)malloc(updates * sizeof(unsigned long));
    if (ga[i]->indices == NULL) {
      perror("malloc");
      exit(1);
    }
    int r = pthread_create(&t[i], NULL, calc_indices_thread, (void*)ga[i]);
    assert(r == 0);
  }
  
  // wait for worker threads
  for (i = 0; i < threads; i++) {
    int r = pthread_join(t[i], NULL);
    assert(r == 0);
  }

  gettimeofday(&stoptime, NULL);
  secs = elapsed(&starttime, &stoptime);
  printf("Initialization time: %.4f seconds.\n", secs);

  printf("Timing.\n");
  gettimeofday(&starttime, NULL);
  
  // spawn gups worker threads
  for (i = 0; i < threads; i++) {
    //printf("starting thread [%d]\n", i);
    ga[i]->tid = i; 
    ga[i]->iters = updates;
    ga[i]->size = nelems;
    ga[i]->elt_size = elt_size;
    //printf("  tid: [%d]  iters: [%llu]  size: [%llu]  elt size: [%llu]\n", ga[i]->tid, ga[i]->iters, ga[i]->size, ga[i]->elt_size);
    int r = pthread_create(&t[i], NULL, do_gups, (void*)ga[i]);
    assert(r == 0);
  }

  // wait for worker threads
  for (i = 0; i < threads; i++) {
    int r = pthread_join(t[i], NULL);
    assert(r == 0);
  }

  gettimeofday(&stoptime, NULL);

  secs = elapsed(&starttime, &stoptime);
  printf("Elapsed time: %.4f seconds.\n", secs);
  gups = threads * ((double)updates) / (secs * 1.0e9);
  printf("GUPS = %.10f\n", gups);

#ifdef HOTSPOT
  hotset_start = nelems - (uint64_t)(nelems * hotset_fraction) - 1;

  for (i = 0; i < threads; ++i) {
    int r = pthread_create(&t[i], NULL, calc_indices_thread, (void*)ga[i]);
    assert(r == 0);
  }
  // wait for worker threads
  for (i = 0; i < threads; i++) {
    int r = pthread_join(t[i], NULL);
    assert(r == 0);
  }
  
  printf("Re-timing.\n");
  gettimeofday(&starttime, NULL);
  
  // spawn gups worker threads
  for (i = 0; i < threads; i++) {
    ga[i]->tid = i; 
    ga[i]->iters = updates;
    ga[i]->size = nelems;
    ga[i]->elt_size = elt_size;
    int r = pthread_create(&t[i], NULL, do_gups, (void*)ga[i]);
    assert(r == 0);
  }

  // wait for worker threads
  for (i = 0; i < threads; i++) {
    int r = pthread_join(t[i], NULL);
    assert(r == 0);
  }

  gettimeofday(&stoptime, NULL);

  secs = elapsed(&starttime, &stoptime);
  printf("Elapsed time: %.4f seconds.\n", secs);
  gups = threads * ((double)updates) / (secs * 1.0e9);
  printf("GUPS = %.10f\n", gups);
#endif
  
  for (i = 0; i < threads; i++) {
    free(ga[i]->indices);
    free(ga[i]);
  }
  free(ga);
  
  munmap(p, size);

  return 0;
}
