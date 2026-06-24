# jellyfin-db-sync
Shell scripts to sync the Jellyfin database (jellyfin.db) between a Jellyfin LXC container and a TrueNAS VM on a Proxmox host, using an NFS share as the transfer bridge.

## Why this approach
In this setup, **TrueNAS only talks directly to the Proxmox host**. Everything else on the network reaches storage through SMB, which is intentionally heavily restricted. This keeps NFS traffic point-to-point and limits TrueNAS's exposure to a single trusted peer.
That's why these scripts run on the Proxmox host rather than inside the Jellyfin container. The host is the only thing allowed to mount the NFS export, so it acts as the bridge: it pulls `jellyfin.db` out of the Jellyfin LXC with `pct`, mounts the share locally, copies the file across, and unmounts. The Jellyfin container never touches NFS, and TrueNAS never opens a session into a container — each service only speaks to the one peer it's supposed to.

## Scripts
| Script | Direction | What it does |
|---|---|---|
| `pull-from-jelly-push-to-truenas.sh` | Jellyfin → TrueNAS | Pulls `jellyfin.db` from the Jellyfin LXC, mounts the TrueNAS NFS share, copies the DB to the clone directory, verifies, unmounts. **Backup.** |
| `pull-from-truenas-push-to-jelly.sh` | TrueNAS → Jellyfin | Mounts the TrueNAS NFS share, copies the cloned DB to the Proxmox host, unmounts, then pushes it to the Jellyfin container's home dir for manual verification. **Restore.** |

## Requirements
- Proxmox VE host, run as **root**
- Jellyfin running in an LXC container (`pct`)
- TrueNAS running as a VM (`qm`) with an NFS export configured
- `nfs-common` installed on the Proxmox host (`apt install nfs-common`)
- The TrueNAS NFS export must allow the Proxmox host to read/writ

## Notes
- Only `jellyfin.db` is synced — not the full data directory.
- If the push-to-TrueNAS step fails with a permission error on an existing `jellyfin.db`, your NFS export likely has `root_squash` enabled. Either set the export to `no_root_squash` (or map root) on TrueNAS, or remove the stale file manually.
- The restore script deliberately does **not** auto-replace the live database — it drops the file in the container's home dir so you can verify before swapping it in.
