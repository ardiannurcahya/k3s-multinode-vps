# Backup And Restore

Single control-plane is a single point of failure. Back up before important workloads.

## What To Protect

```text
/var/lib/rancher/k3s/server/db/
/var/lib/rancher/k3s/server/token
/etc/rancher/k3s/
application persistent volumes
Git-managed manifests and Helm values
```

K3s datastore backup does not back up application volume contents.

## SQLite Backup

Single-server K3s commonly uses SQLite. Stop K3s briefly for consistent file-level backup:

```bash
systemctl stop k3s
tar -C / -czf /root/k3s-control-plane-backup.tgz \
  var/lib/rancher/k3s/server/db \
  var/lib/rancher/k3s/server/token \
  etc/rancher/k3s
systemctl start k3s
```

Copy archive to encrypted off-host storage. Restrict permissions:

```bash
chmod 600 /root/k3s-control-plane-backup.tgz
```

## Restore Principles

1. Provision compatible control-plane OS.
2. Install same K3s version, but do not start workload changes.
3. Stop K3s.
4. Restore database, token, and configuration with original ownership and permissions.
5. Start K3s.
6. Verify nodes and workloads.
7. Rejoin workers if certificates/state require it.

Test restore on isolated infrastructure. Untested backup is not reliable recovery.

Never publish server token or backup archive. Both grant sensitive cluster access.
