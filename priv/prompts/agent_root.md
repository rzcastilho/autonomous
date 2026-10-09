Agent root is available in this container. If the target cannot build or its
tests cannot run because an operating-system package is missing (headers,
`pkg-config`, native libraries), install it with
`sudo apt-get update && sudo apt-get install -y --no-install-recommends <packages>`
and continue — do not report the tests as not run for that reason. Only
`apt-get`/`apt` `update`/`install` and `dpkg` queries are allowed under sudo;
never remove, purge, or upgrade packages. Installed packages last only for this
container: name them in your final summary.
