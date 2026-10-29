# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is an unofficial CircleCI orb, published as `juburr/corecci`, that replaces CircleCI's built-in `checkout` step with `corecci/checkout`: a checkout over SSH with an ECDSA key that works with FIPS mode on, SSH algorithms from the NSA's CNSA 2.0 suite, pinned host keys, and shallow or empty checkouts and submodules on request. It has no GitHub Actions, unlike the other juburr orbs: the command exists for CircleCI's ED25519 deploy keys and `add_ssh_keys`, and needs none on GitHub.

## Development Commands

```bash
# Pack the orb from source into a single file, and validate it
circleci orb pack src/ > orb.yml
circleci orb validate orb.yml

# Lint
yamllint .
shellcheck src/scripts/*.sh tests/*.sh

# Tests (offline; need git)
for t in tests/*_test.sh; do bash "$t" || break; done
```

## Architecture

### Orb Structure (`src/`)

- `@orb.yml` - Orb metadata (version 2.1)
- `commands/checkout.yml` - The only command: `install_deps.sh` when `install_packages`, `add_ssh_keys` when `fingerprint` is set, then `checkout.sh`
- `scripts/` - Shell implementations, included with `<< include(scripts/...) >>`
- `examples/checkout.yml` - Usage example, pinned to the orb's current version

### `scripts/checkout.sh`

1. Checks every parameter before anything connects: booleans take `1`/`true` or `0`/`false`, `depth` and `submodules` are matched exactly, and the `ssh_*` values must be algorithm-name lists (`^[A-Za-z0-9@.,+_-]+$`), since they become part of `GIT_SSH_COMMAND`, which git runs with `sh`.
2. Reads the SSH user, host and port from `CIRCLE_REPOSITORY_URL`: `user@host:path`, `ssh://user@host[:port]/path`, or `https://host/path`, which is cloned as `git@host:path`. `known_hosts` names a host on another port `[host]:port`.
3. Finds the key file `add_ssh_keys` wrote: `~/.ssh/id_rsa_<MD5 without colons>` whatever the key type, or for a `SHA256:` fingerprint the `~/.ssh/id_*` file whose `ssh-keygen -l -E sha256` matches.
4. Makes sure `~/.ssh/known_hosts` holds the host's key, the first of: `ssh_known_hosts` lines; GitHub's published keys for `github.com` (`GITHUB_KNOWN_HOSTS`, from GitHub's fingerprints page, with the fingerprints in a comment); a key already in `~/.ssh/known_hosts` or `/etc/ssh/ssh_known_hosts` (`ssh-keygen -F`); with `ssh_accept_new_host_key`, the key the server presents to `ssh -o StrictHostKeyChecking=accept-new` into a `mktemp` file (ssh-keyscan fails to negotiate in FIPS mode on RHEL 9). Otherwise it fails before connecting. Never fall back to trusting a key on first use.
5. Builds `GIT_SSH_COMMAND` as an array quoted with `printf %q` (`StrictHostKeyChecking=yes`, the algorithms, and with a key file `IdentitiesOnly=yes`, `IdentityAgent=none`), and exports it to `BASH_ENV` with `printf 'export %s=%q\n'`, so later steps use the same settings.
6. With `configure_git_ssh`, sets `url.ssh://<user>@<host>[:port]/.insteadOf https://<host>/` before the checkout, so `https://` submodules of the host come over SSH too.
7. Checks out `CIRCLE_SHA1` (or `CIRCLE_TAG`, or `CIRCLE_BRANCH`) into the working directory: `full` clones and checks it out, `shallow` fetches it with `--depth 1`, `empty` clones with `--no-checkout`. Then `git submodule update --init` with `--recursive` and `--depth=1` as `submodules` says.

When GitHub rotates a host key, update `GITHUB_KNOWN_HOSTS` and its fingerprints from https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints, check each key's SHA-256 against the published fingerprint, and update the fingerprint `test-deploy.yml` checks.

### `scripts/install_deps.sh`

Installs `ssh` and `git` when either is missing, with the first of `apt-get`, `apk`, `dnf`, `microdnf` and `yum` on the `PATH`: `openssh-client` for apt-get and apk, `openssh-clients` for the others. It picks the package manager rather than reading `/etc/os-release`, so new releases of those distributions need no change.

### CI Pipeline (`.circleci/`)

- `config.yml` - Setup workflow: `test-env-subst` (`tests/env_subst_test.sh` and `tests/shell_conventions_test.sh`), `test-scripts` (`tests/checkout_test.sh` and `tests/install_deps_test.sh`), orb-tools lint, pack and review (`orb_name: corecci`), shellcheck.
- `test-deploy.yml` - Checks out this repository with the orb: the deploy key (ED25519) and the project's ECDSA key on `cimg/base` at each depth; Rocky Linux 9 and 10 (`quay.io`), UBI 9 minimal and UBI 10, and Debian 12 (`mirror.gcr.io`), which have no ssh or git; and `host-key-test`, which passes `ssh_known_hosts` from a variable, checks `configure_git_ssh` with an `https://` `git ls-remote`, and runs `checkout.sh` against GitHub with a host key GitHub doesn't have, which must fail host key verification. Publishing runs on `v*` tags. The ECDSA key's fingerprint, `SHA256:1wS2Fom3QTXyH5G2DS88+II0U9ajqGKOeq1wBA740Fc`, is in the project's additional SSH keys.

### Tests (`tests/`)

- `checkout_test.sh` runs `checkout.sh` with the real git against local bare repositories (with a submodule), and stand-ins for ssh (it checks the host key as `StrictHostKeyChecking=yes` would, records one for `accept-new`, and serves `git upload-pack`), ssh-keygen and the CircleCI CLI (value on stdin, `$ORB_TEST_VAR` expanded). It runs the script under `env -i`, without the job's `GIT_*` variables, and with a PATH that leaves out any directory holding a real `circleci`.
- `install_deps_test.sh` runs `install_deps.sh` with a PATH of stand-ins only: `id` and the package managers, which "install" stand-in ssh and git.
- `env_subst_test.sh` and `shell_conventions_test.sh` are shared by the juburr orbs; `shell_conventions_test.sh` is identical in every orb, so never edit it here alone.

## Linting

YAML linting uses `.yamllint` config (extends "relaxed", 200-char line limit). Shell scripts are linted with shellcheck via the CI pipeline.

Scripts pass parameter values to `circleci env subst` on stdin, as `subst` in `checkout.sh` does. Passed as an argument, a value starting with `-` is parsed as a CLI flag. `tests/env_subst_test.sh` enforces this. Without the CLI (non-cimg images), values are used as they are, with a warning.

## Shell conventions

Every script in `src/scripts/` follows the conventions all juburr orbs share. `tests/shell_conventions_test.sh` checks the mechanical ones.

- Line 1 is `#!/bin/bash` and the first command is `set -euo pipefail`. No `set +o history`, never xtrace.
- Under `-u`, use `${VAR:-}` for variables that may be unset (`CIRCLE_*`, `BASH_ENV`). `PARAM_*` values the command YAML always sets are read directly, so tests that run a script directly must set every one of them.
- Expand an array that can be empty as `${arr[@]+"${arr[@]}"}`, not `"${arr[@]}"`: under `-u`, bash before 4.4 treats an empty array as unset and aborts with "unbound variable", and the orb supports bash 4.0+. Bash 4.0 also treats an empty `"$@"` (and `$*`) as unbound, so copy `"$@"` into an array only when `$#` is non-zero. The tests pass with bash 4.0, 4.3 and 5 first on the `PATH`.
- `ERROR: ` and `WARN: ` messages go to stderr (`>&2` on every line of the message); everything else goes to stdout. Every non-zero exit prints an `ERROR:` line first, unless the failing tool already explained itself.
- `$BASH_ENV` exports use `printf 'export %s=%q\n'`. Secrets never go on a command line: the private key stays in the file `add_ssh_keys` writes.
- Temporary files come from `mktemp` and are removed by one EXIT trap per script.

## Verification

Before committing changes, verify work locally if tools are available on the system:
- Run `shellcheck src/scripts/*.sh tests/*.sh` and `yamllint .`
- Run every `tests/*_test.sh`, also with bash 4.0 and 4.3 first on the `PATH`
- Run `circleci orb pack src/ > orb.yml && circleci orb validate orb.yml`
