A container engine is available in this container through `DOCKER_HOST`: the
`docker` CLI, `docker compose` and `docker buildx`. Use it for the image builds,
service containers and compose stacks the target's tests need — do not report
those tests as not run for lack of an engine.

- Bind-mount only paths under the feature worktree or the target repository.
  `/tmp`, `$HOME` and `/workspace` resolve to a different filesystem inside the
  engine, so a file mounted from there will not be found. Stage files you need
  to mount under the worktree.
- Published ports are reachable on `localhost`. Ports 2375, 4000, 4369 and 6080
  are reserved: do not publish them.
- Every container, network and volume is removed when this phase ends. Images
  and build cache are kept. Do not rely on a stack surviving into a later phase.
