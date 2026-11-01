// Image entrypoint: confines the whole cage process tree with Landlock so it can't
// connect to abstract unix sockets created outside the cage. `--network host`
// shares the host's abstract socket namespace, which exposes e.g. Xwayland's
// @/tmp/.X11-unix/X0 (DESIGN §2). Abstract sockets created inside the cage still work.
#define _GNU_SOURCE
#include <errno.h>
#include <linux/landlock.h>
#include <stdio.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <unistd.h>

#define MIN_ABI 6 // first ABI with LANDLOCK_SCOPE_ABSTRACT_UNIX_SOCKET (Linux 6.12)

static int die(const char *what) {
  fprintf(stderr,
          "cage-scope: %s: %s\n"
          "cage-scope: refusing to start without abstract-socket isolation "
          "(needs Landlock ABI >= %d, Linux 6.12+, with landlock in the LSM list)\n",
          what, strerror(errno), MIN_ABI);
  return 126;
}

int main(int argc, char **argv) {
  if (argc < 2) {
    fprintf(stderr, "usage: cage-scope <command> [args...]\n");
    return 2;
  }

  long abi = syscall(SYS_landlock_create_ruleset, NULL, 0, LANDLOCK_CREATE_RULESET_VERSION);
  if (abi < 0)
    return die("landlock unavailable");
  if (abi < MIN_ABI) {
    errno = ENOTSUP;
    return die("landlock ABI too old");
  }

  struct landlock_ruleset_attr attr = {.scoped = LANDLOCK_SCOPE_ABSTRACT_UNIX_SOCKET};
  int fd = syscall(SYS_landlock_create_ruleset, &attr, sizeof(attr), 0);
  if (fd < 0)
    return die("landlock_create_ruleset");
  if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0)
    return die("PR_SET_NO_NEW_PRIVS");
  if (syscall(SYS_landlock_restrict_self, fd, 0) != 0)
    return die("landlock_restrict_self");
  close(fd);

  execvp(argv[1], argv + 1);
  fprintf(stderr, "cage-scope: %s: %s\n", argv[1], strerror(errno));
  return errno == ENOENT ? 127 : 126;
}
