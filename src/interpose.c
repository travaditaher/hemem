#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <libsyscall_intercept_hook_point.h>
#include <syscall.h>
#include <errno.h>
#define __USE_GNU
#include <dlfcn.h>
#include <pthread.h>
#include <sys/mman.h>
#include <assert.h>
#include <malloc.h>

#include "hemem.h"
#include "interpose.h"

void* (*libc_mmap)(void *addr, size_t length, int prot, int flags, int fd, off_t offset) = NULL;
int (*libc_munmap)(void *addr, size_t length) = NULL;
void* (*libc_malloc)(size_t size) = NULL;
void (*libc_free)(void* ptr) = NULL;
int user_hint_tier = -1;  
int user_hint_persistence = 0;  
int user_hint_priority = 0;  

static int mmap_filter(void *addr, size_t length, int prot, int flags, int fd, off_t offset, int tier_code, int persistence, int priority, uint64_t *result)
{

  if (fd == -420) {
    user_hint_tier = tier_code;  // User-specified tier
    user_hint_persistence = persistence; // Persistence flag(forcibly)
    user_hint_priority = priority;  // Store priority flag (0 = Cold, 1 = Hot)

    return 0;  // Not an actual mmap call
  }

  //ensure_init();
  if (!is_init) {
    //LOG("hemem interpose: calling libc mmap due to hemem init in progress\n");
    return 1;
  }

  if (internal_call) {
    LOG("hemem interpose: calling libc mmap due to internal memory call: mmap(0x%lx, %ld, %x, %x, %d, %ld)\n", (uint64_t)addr, length, prot, flags, fd, offset);
    return 1;
  }

  //TODO: figure out which mmap calls should go to libc vs hemem
  // non-anonymous mappings should probably go to libc (e.g., file mappings)
  if (((flags & MAP_ANONYMOUS) != MAP_ANONYMOUS) && !((fd == dramfd) || (fd == nvmfd))) {
    LOG("hemem interpose: calling libc mmap due to non-anonymous, non-devdax mapping: mmap(0x%lx, %ld, %x, %x, %d, %ld)\n", (uint64_t)addr, length, prot, flags, fd, offset);
    return 1;
  }
  
  if ((prot & PROT_EXEC) == PROT_EXEC) {
    // filter out code mappings
    return 1;
  }

  if ((flags & MAP_STACK) == MAP_STACK) {
    // pthread mmaps are called with MAP_STACK
    LOG("hemem interpose: calling libc mmap due to stack mapping: mmap(0x%lx, %ld, %x, %x, %d, %ld)\n", (uint64_t)addr, length, prot, flags, fd, offset);
    return 1;
  }

  //if (((flags & MAP_NORESERVE) == MAP_NORESERVE)) {
    // thread stack is called without swap space reserved, so we can probably ignore these
    //fprintf(stderr, "hemem interpose: calling libc mmap due to non-swap space reserved mapping: mmap(0x%lx, %ld, %x, %x, %d, %ld)\n", (uint64_t)addr, length, prot, flags, fd, offset);
    //return 1;
  //}
  
  if ((fd == dramfd) || (fd == nvmfd)) {
    //LOG("hemem interpose: calling libc mmap due to hemem devdax mapping\n");
    return 1;
  }

#ifndef LLAMA
  if (length < 1UL * 1024UL * 1024UL * 1024UL) {
    LOG("hemem interpose calling libc mmap due to small allocation size: mmap(0x%lx, %ld, %x, %x, %d, %ld)\n", (uint64_t)addr, length, prot, flags, fd, offset);
    return 1;
  }
#endif

  LOG("hemem interpose: calling hemem mmap(0x%lx, %ld, %x, %x, %d, %ld)\n", (uint64_t)addr, length, prot, flags, fd, offset);
  if ((*result = (uint64_t)hemem_mmap(addr, length, prot, flags, fd, offset)) == (uint64_t)MAP_FAILED) {
    // hemem failed for some reason, try libc
    LOG("hemem mmap failed\n\tmmap(0x%lx, %ld, %x, %x, %d, %ld)\n", (uint64_t)addr, length, prot, flags, fd, offset);
  }
  return 0;
}


static int munmap_filter(void *addr, size_t length, uint64_t* result)
{
  //ensure_init();
  
  //TODO: figure out which munmap calls should go to libc vs hemem
  
  if (internal_call) {
    return 1;
  }

  if ((*result = hemem_munmap(addr, length)) == -1) {
    LOG("hemem munmap failed\n\tmunmap(0x%lx, %ld)\n", (uint64_t)addr, length);
  }
  return 0;
}


static void* bind_symbol(const char *sym)
{
  void *ptr;
  if ((ptr = dlsym(RTLD_NEXT, sym)) == NULL) {
    fprintf(stderr, "hemem memory manager interpose: dlsym failed (%s)\n", sym);
    abort();
  }
  return ptr;
}

static int hook(long syscall_number, long arg0, long arg1, long arg2, long arg3,	long arg4, long arg5, long arg6, long arg7, long arg8, long *result)
{
	if (syscall_number == SYS_mmap) {
    int tier_code = (arg6 != 0) ? (int)arg6 : -1;  // Default: -1 (Let Hemem decide)
    int persistence = (arg7 != 0) ? (int)arg7 : 0;  // Default: 0 (Flexible)
    int priority = (arg8 != 0) ? (int)arg8 : 0;  // Default: 0 (Cold)

	  return mmap_filter((void*)arg0, (size_t)arg1, (int)arg2, (int)arg3, (int)arg4, (off_t)arg5, tier_code, persistence, priority, (uint64_t*)result);
	} else if (syscall_number == SYS_munmap){
    return munmap_filter((void*)arg0, (size_t)arg1, (uint64_t*)result);
  } else {
    // ignore non-mmap system calls
		return 1;
	}
}

static __attribute__((constructor)) void init(void)
{
  libc_mmap = bind_symbol("mmap");
  libc_munmap = bind_symbol("munmap");
  libc_malloc = bind_symbol("malloc");
  libc_free = bind_symbol("free");
  intercept_hook_point = hook;

#ifdef LLAMA
  int ret = mallopt(M_MMAP_THRESHOLD, 0);
  if (ret != 1) {
    perror("mallopt");
  }
  assert(ret == 1);
#endif
  hemem_init();
}

static __attribute__((destructor)) void hemem_shutdown(void)
{
  hemem_stop();
}

/* 
void* malloc(size_t size)
{
  void* ret;
  if(libc_malloc == NULL) {
    libc_malloc = bind_symbol("malloc");
  }
  assert(libc_malloc != NULL);
  ret = libc_malloc(size);
  return ret;
}

void free(void* ptr)
{
  if(libc_free == NULL) {
    libc_free = bind_symbol("free");
  }
  assert(libc_free != NULL);
  libc_free(ptr);
}
*/
