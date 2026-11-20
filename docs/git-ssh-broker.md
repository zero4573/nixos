# git-ssh-broker

`git-ssh-broker` (`modules/apps/git-ssh-broker/`, Go source in `src/`, package
`.#git-ssh-broker`) gives the sandboxes git over SSH and commit signing without
an SSH key or the host's ssh-agent inside them. One broker runs on the host per
session and serves two sockets mounted into the container. It is hand-written
on the Go standard library only, so every line between a sandbox and the
1Password SSH keys can be audited. It logs to
`~/.local/state/claude-sandbox.log`.

Options (`programs.gitSshBroker.*`): `signingKeys`, `rewritableBranches`
(default `feature/*`) and `identityEmails` (default the `hostConfig.git`
emails).

## Git socket

The sandbox's `GIT_SSH_COMMAND` is `git-ssh-broker client` (with
`GIT_SSH_VARIANT=ssh`, socket from `GIT_SSH_BROKER_SOCKET`). It forwards git's
transport command only: `git-upload-pack`, `git-receive-pack`,
`git-upload-archive`, and `git-lfs-authenticate <repo> download|upload` (git-lfs
gets an HTTPS token over SSH, then talks to the LFS endpoint itself through the
sandbox's network; `lfs.sshtransfer=never` keeps it off the pure-SSH
`git-lfs-transfer`, which isn't brokered). The broker checks host and repo path, runs the host's own
ssh (`~/.ssh/config`, the 1Password agent) and relays the stream.

- **Hosts.** GitHub and Bitbucket Cloud, plus their port-443 alternatives
  (`ssh.github.com`, `ssh.bitbucket.org`, `altssh.bitbucket.org`), as `git@`
  (`defaultHosts`; `--allow-host` replaces the list).
- **Repo paths** must look like `owner/repo(.git)` with an optional leading `/`;
  `.` and `..` components are refused, so a request can't reach other paths on
  the remote (`repoPathRe`).
- **No ssh options pass through.** Only the checked host, port and command reach
  ssh, which runs with `-x -T -a`, `BatchMode` and `ClearAllForwardings`, so the
  sandbox can't inject `ProxyCommand` or forwarding (`sshArgs`).
- **Bounded input.** Frames and the request line are capped at 1 MiB, agent
  messages at 256 KiB, the held push commands at 16 MiB, so a bad peer can't
  make the broker allocate without limit.

### Push checks

`pushFilter` holds back `git-receive-pack`'s ref-update commands (up to the
first flush), checks each, and only then lets them through. A push is refused
as a whole if any update (`checkUpdate`):

- deletes a branch or tag (including a `:branch` refspec),
- moves a tag,
- is not a fast-forward (`--force`, `--force-with-lease`, `+refspec`),

except a rewrite of a `rewritableBranches` branch whose old commit is in the
client's repo and where every dropped commit (`git rev-list old ^new`) has an
`identityEmails` address as both author and committer (case-insensitive). That
lets an agent rebase its own ticket branch after a conflict; everything else
stays a manual step on the host. With no emails no rewrite is allowed.
Unknown commands and push certificates are refused rather than passed
unchecked. On a refusal the ssh process is killed: nothing reached the remote,
and `receive-pack` stops waiting for input.

- Branch globs are `path.Match` over the name after `refs/heads/`: `*` and `?`
  never cross `/`, so `feature/*` matches `feature/x` but not `feature/x/y`.
- `--force` and `--force-with-lease` are the same push on the wire (the lease is
  compared atomically on the remote), so the broker can't check a lease.
- The client's repository is never used as a git dir: its config, hooks,
  replace refs and grafts could lie or run code on the host. A throwaway bare
  repo reads only its object store (`objectStore`), with
  `GIT_NO_REPLACE_OBJECTS`, `GIT_NO_LAZY_FETCH`, no global or system config and
  `core.commitGraph=false` (commit-graph files hold parents too).
- git doesn't re-hash objects it reads, so a forged object could lie about
  parents and authors. `verify` copies every commit reachable from old and new
  through `pack-objects | index-pack` (naming each by its content hash) into a
  broker-owned repo and answers from it alone; a forged commit is missing there
  and the push is refused.

## Agent socket

The sandbox's `SSH_AUTH_SOCK` is a filtering ssh-agent in front of the host's
(`signingAgent`). It lists only `signingKeys` and signs only SSHSIG blobs in the
`git` namespace (what `ssh-keygen -Y sign -n git` sends). An SSH login's sign
request starts with a session id, never the SSHSIG magic, so logins are refused,
as is every other agent request.

## Residual risk

Anything in a sandbox can push (non-force, or rewriting your own commits on a
rewritable branch) to any repo your keys reach, and sign commits as you.
1Password still asks to approve the broker's use of the keys.

## Tests

The Go tests push through the broker with real git and sign through a real
ssh-agent; `nix build .#git-ssh-broker` runs them. The launcher's socket cases
in `claude-sandbox-test.sh` run against the real binary.
