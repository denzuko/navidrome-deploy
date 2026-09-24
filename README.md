# navidrome-deploy

Consfigurator-driven deployment of [Navidrome](https://www.navidrome.org/) on a
single host: natively encrypted ZFS dataset for state, rootless Podman quadlet
under a dedicated service account, HAProxy as the only reverse proxy.

Licensed BSD-3-Clause.

## Layout

| Path | Purpose |
|------|---------|
| `navidrome.asd` | Umbrella `:navidrome` system (empty on purpose) plus `:navidrome/deploy` |
| `src/deploy.lisp` | Properties, rendered artifacts, CLI entry point |
| `navidrome-deploy.ros` | Thin Roswell wrapper around `navidrome/deploy:main` |
| `Makefile` | `build`, `render`, `install`, `clean` |

## What gets provisioned

In order; provisioning aborts at the first failure and never reports success
with skipped properties.

1. `podman` present.
2. `navidrome` account with lingering enabled.
3. Raw 32-byte key at `/etc/zfs-keys/navidrome-data.key` (mode 0600, dir 0700).
4. `<pool>/navidrome/data` created with `encryption=aes-256-gcm`,
   `keyformat=raw`, mounted at `/srv/navidrome/data`. On an existing but
   locked dataset (post-reboot, post-restore) the key is loaded and the
   dataset mounted.
5. `/srv/navidrome/data` owned by `navidrome`, mode 750.
6. The music library is readable by `navidrome`. This property does not fix
   permissions; it fails with a message telling you to grant read+execute via
   group or ACL. The library is mounted read-only and never written to.
7. Podman secrets `navidrome-admin-password` and `navidrome-encryption-key`,
   random, created once, never rotated by the deploy.
8. Pinned image pulled into the service account's store.
9. Quadlet at `~navidrome/.config/containers/systemd/navidrome.container`. A
   content change triggers `daemon-reload` and a restart.
10. `navidrome.service` active.
11. HAProxy backend at `/etc/haproxy/conf.d/navidrome.cfg` plus a line in
    `/etc/haproxy/hosts.map`. A change triggers `haproxy -c` validation, then
    `systemctl reload haproxy`. A failed validation leaves the running config
    untouched.

HAProxy is wired last on purpose. Navidrome makes the first visitor the admin
unless an admin already exists; the admin is created at first start from the
`navidrome-admin-password` secret (user `admin`), before the vhost exists.

## Prerequisites

- Native build deps for Consfigurator's CFFI grovel step: `libacl1-dev`,
  `libcap-dev`.
- HAProxy started with the conf dir as a second `-f`, and a shared HTTPS
  frontend that routes by host map:

  ```
  # systemctl edit haproxy
  [Service]
  Environment="CONFIG=/etc/haproxy/haproxy.cfg -f /etc/haproxy/conf.d"
  ```

  ```
  frontend fe_https
      bind :443 ssl crt /etc/haproxy/certs/
      use_backend %[req.hdr(host),lower,word(1,:),map(/etc/haproxy/hosts.map)]
  ```

## Build and run

```sh
ros init
ros install qlot
qlot add consfigurator
make build
./navidrome-deploy --render --fqdn on.dapla.net --music /tank/media/music
sudo ./navidrome-deploy --fqdn on.dapla.net --music /tank/media/music
```

`--render` prints the quadlet, HAProxy backend, and map line without touching
the host. Overridable settings: `--fqdn`, `--music`, `--pool`, `--image`,
`--base-url`, `--scan-schedule`. Everything else is a special in
`src/deploy.lisp`.

Redeploys are idempotent: properties that already hold are skipped, and
Navidrome only restarts when the rendered quadlet changes.

## Runbook

All user-unit commands run as the service account:

```sh
as_nd() { runuser -u navidrome -- env XDG_RUNTIME_DIR=/run/user/$(id -u navidrome) "$@"; }
```

**Status.** `as_nd systemctl --user status navidrome` and
`as_nd podman healthcheck run navidrome`.

**Logs.** `journalctl _SYSTEMD_USER_UNIT=navidrome.service -f` as root.

**Initial admin password.** `as_nd podman secret inspect --showsecret
--format '{{.SecretData}}' navidrome-admin-password`. Log in as `admin` and
change it in the UI. The secret only matters on first start; once an admin
exists Navidrome ignores it.

**Restart.** `as_nd systemctl --user restart navidrome`.

**Upgrade.** Snapshot first, since Navidrome migrates its database on start
and migrations are one-way:

```sh
zfs snapshot tank/navidrome/data@pre-0.61.0
sudo ./navidrome-deploy --image docker.io/deluan/navidrome:0.61.0 ...
```

Roll back by redeploying the old tag and `zfs rollback` to the snapshot.

**Password encryption key.** Never rotate `navidrome-encryption-key` on a live
install. Navidrome encrypts stored user passwords with it; replacing it makes
existing passwords undecryptable.

**Common failures.**

- *Deploy stops at "not readable by navidrome".* Grant access, for example
  `setfacl -R -m u:navidrome:rX /tank/media/music` plus a default ACL, then
  redeploy.
- *Service fails after reboot, data dir empty.* The dataset is locked.
  Redeploy (loads key and mounts) or `zfs load-key tank/navidrome/data && zfs
  mount tank/navidrome/data`.
- *502 from HAProxy.* Check `navidrome.service` and the healthcheck; the
  backend's `httpchk` marks the server down until `/ping` answers.
- *Container restart loop with `ReadOnly=true`.* Drop `ReadOnly=true` from
  `quadlet-unit` to confirm, then find the path it is writing to.

## Playbook: replication and recovery

State lives in one dataset; the music library is out of scope (replicate it
with whatever already covers it).

Replicate raw (`-w`) so the stream stays encrypted in flight and at rest on
the receiver. Plain `send` would decrypt an unlocked dataset into the stream.

```sh
zfs snapshot tank/navidrome/data@$(date +%Y%m%dT%H%M)
zfs send -w -I @<previous> tank/navidrome/data@<latest> \
  | ssh <rsync.net-host> zfs receive -u data1/navidrome/data
```

Drive this from a systemd timer on your existing replication cadence.

**Back up the key separately.** `/etc/zfs-keys/navidrome-data.key` is the most
critical file in this stack. Without it every snapshot, local or remote, is
unreadable. It must not live only on the pool it unlocks.

**Recovery.**

```sh
install -d -m 0700 /etc/zfs-keys
install -m 0600 <backup>/navidrome-data.key /etc/zfs-keys/
ssh <rsync.net-host> zfs send -w data1/navidrome/data@<snap> \
  | zfs receive tank/navidrome/data
zfs set keylocation=file:///etc/zfs-keys/navidrome-data.key tank/navidrome/data
sudo ./navidrome-deploy ...
```

The deploy loads the key, mounts, fixes ownership, and brings the service up.
Podman secrets are not in the dataset; the encryption-key secret must be
restored from backup with the same value
(`printf %s "$VALUE" | as_nd podman secret create navidrome-encryption-key -`)
before the deploy runs, or existing user passwords will not decrypt.

## Decommission

Least destructive first. Stop after any step if you only need to take the
service offline.

1. Unpublish: delete the `be_navidrome` line from `/etc/haproxy/hosts.map`,
   remove `/etc/haproxy/conf.d/navidrome.cfg`, `haproxy -c ...` and reload.
2. Stop: `as_nd systemctl --user stop navidrome`, remove the quadlet,
   `as_nd systemctl --user daemon-reload`.
3. Clean Podman state: `as_nd podman secret rm navidrome-admin-password
   navidrome-encryption-key`, `as_nd podman image rm <image>`.
4. Remove the account: `loginctl disable-linger navidrome`,
   `userdel -r navidrome`.
5. Final raw send to rsync.net if you want an archive, then
   `zfs destroy -r tank/navidrome/data`.
6. Last, and only if no archive is being kept: `shred -u
   /etc/zfs-keys/navidrome-data.key`.
