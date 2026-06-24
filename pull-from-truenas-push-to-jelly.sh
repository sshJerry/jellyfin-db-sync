#!/bin/bash
# ============================================================
# Pull jellyfin.db from TrueNAS VM via NFS -> Push to Jellyfin (CTID XXX) home dir
# ============================================================
# Run this on the Proxmox host as root.
# Mounts the TrueNAS NFS share, copies jellyfin.db locally, then pushes
# to the Jellyfin container's home directory.
# You will manually move it to /var/lib/jellyfin/data/ after verifying.
# ============================================================
# pct enter XXX
# pkill -f jellyfin
# cd /var/lib/jellyfin/data
# mv jellyfin.db jellyfin.db.old
# mv ~/jellyfin.db jellyfin.db
# chown jellyfin:jellyfin /var/lib/jellyfin/data/jellyfin.db
# systemctl restart jellyfin

set -e

TRUENAS_VMID=TRUENAS_VMID                   # TrueNAS VM ID (qm, not pct)
NFS_SERVER="TRUENAS_IP"
NFS_EXPORT="/mnt/Media/content/JellyfinDBClone"
NFS_MOUNT="/mnt/nfs_JellyfinDBClone"
JELLY_CTID=JELLYFIN_CTID
TMP_LOCAL="/tmp/jellyfin.db"
JELLY_HOME="/root"  # Home directory in the Jellyfin container

echo "============================================================"
echo "Pull jellyfin.db: TrueNAS VM ${TRUENAS_VMID} via NFS -> CTID ${JELLY_CTID}"
echo "============================================================"

# --- Step 1: Verify TrueNAS VM is running ---
echo ""
echo "[1/9] Verifying TrueNAS VM ${TRUENAS_VMID} is running..."
if qm status ${TRUENAS_VMID} | grep -q "running"; then
    echo "  PASS: VM ${TRUENAS_VMID} is running"
else
    echo "  FAIL: VM ${TRUENAS_VMID} is not running"
    exit 1
fi

# --- Step 2: Mount NFS share from TrueNAS ---
echo ""
echo "[2/9] Mounting NFS share: ${NFS_SERVER}:${NFS_EXPORT} -> ${NFS_MOUNT}..."
mkdir -p ${NFS_MOUNT}
mount -t nfs -o vers=3,rw,hard,intr ${NFS_SERVER}:${NFS_EXPORT} ${NFS_MOUNT}
if mountpoint -q ${NFS_MOUNT}; then
    echo "  PASS: NFS share mounted at ${NFS_MOUNT}"
else
    echo "  FAIL: NFS mount failed"
    exit 1
fi

# --- Step 3: Verify read/write access on NFS mount ---
echo ""
echo "[3/9] Verifying read/write access on ${NFS_MOUNT}..."
TEST_FILE="${NFS_MOUNT}/.rw_test_$$"
if touch "${TEST_FILE}" 2>/dev/null; then
    echo "  PASS: Write access OK"
    rm -f "${TEST_FILE}"
else
    echo "  FAIL: No write access to ${NFS_MOUNT}"
    umount ${NFS_MOUNT}
    exit 1
fi

if ls ${NFS_MOUNT} >/dev/null 2>&1; then
    echo "  PASS: Read access OK"
else
    echo "  FAIL: No read access to ${NFS_MOUNT}"
    umount ${NFS_MOUNT}
    exit 1
fi

# --- Step 4: Copy jellyfin.db from NFS mount to Proxmox host ---
echo ""
echo "[4/9] Copying jellyfin.db from NFS mount to Proxmox host..."
if [ -f "${NFS_MOUNT}/jellyfin.db" ]; then
    SRC_SIZE=$(stat -c '%s' "${NFS_MOUNT}/jellyfin.db")
    echo "  Found ${NFS_MOUNT}/jellyfin.db (${SRC_SIZE} bytes)"
else
    echo "  FAIL: jellyfin.db not found on NFS share"
    umount ${NFS_MOUNT}
    exit 1
fi

cp ${NFS_MOUNT}/jellyfin.db ${TMP_LOCAL}
if [ -f "${TMP_LOCAL}" ]; then
    LOCAL_SIZE=$(stat -c '%s' ${TMP_LOCAL})
    echo "  PASS: Copied to ${TMP_LOCAL} (${LOCAL_SIZE} bytes)"
else
    echo "  FAIL: Copy failed"
    umount ${NFS_MOUNT}
    exit 1
fi

# --- Step 5: Verify local copy and unmount ---
echo ""
echo "[5/9] Verifying local copy and unmounting NFS share..."
if [ "${SRC_SIZE}" = "${LOCAL_SIZE}" ]; then
    echo "  PASS: Copy size match (${SRC_SIZE} == ${LOCAL_SIZE})"
else
    echo "  WARNING: Copy size mismatch (${SRC_SIZE} vs ${LOCAL_SIZE})"
fi

umount ${NFS_MOUNT}
if ! mountpoint -q ${NFS_MOUNT}; then
    echo "  PASS: Unmounted ${NFS_MOUNT}"
else
    echo "  WARNING: Failed to unmount ${NFS_MOUNT}"
fi

rmdir ${NFS_MOUNT} 2>/dev/null || true

# --- Step 6: Verify Jellyfin container is running ---
echo ""
echo "[6/9] Verifying CTID ${JELLY_CTID} is running..."
if pct status ${JELLY_CTID} | grep -q "running"; then
    echo "  PASS: CTID ${JELLY_CTID} is running"
else
    echo "  FAIL: CTID ${JELLY_CTID} is not running"
    exit 1
fi

# --- Step 7: Verify home directory exists in Jellyfin container ---
echo ""
echo "[7/9] Verifying home directory in CTID ${JELLY_CTID}..."
if pct exec ${JELLY_CTID} -- test -d ${JELLY_HOME}; then
    echo "  PASS: ${JELLY_HOME} exists"
else
    echo "  WARNING: ${JELLY_HOME} not found, using /tmp instead"
    JELLY_HOME="/tmp"
fi

# --- Step 8: Push jellyfin.db to Jellyfin home directory ---
echo ""
echo "[8/9] Pushing jellyfin.db to CTID ${JELLY_CTID}:${JELLY_HOME}/..."
pct push ${JELLY_CTID} ${TMP_LOCAL} ${JELLY_HOME}/jellyfin.db
REMOTE_SIZE=$(pct exec ${JELLY_CTID} -- stat -c '%s' ${JELLY_HOME}/jellyfin.db)
echo "  PASS: Pushed to ${JELLY_HOME}/jellyfin.db (${REMOTE_SIZE} bytes)"

# --- Step 9: Verify and cleanup ---
echo ""
echo "[9/9] Verifying and cleaning up..."
VERIFY_OK=true

if [ "${LOCAL_SIZE}" = "${REMOTE_SIZE}" ]; then
    echo "  PASS: Size match (${LOCAL_SIZE} == ${REMOTE_SIZE})"
else
    echo "  WARNING: Size mismatch (${LOCAL_SIZE} vs ${REMOTE_SIZE})"
    VERIFY_OK=false
fi
rm -f ${TMP_LOCAL}
echo "  Cleaned up ${TMP_LOCAL}"

echo ""
echo "============================================================"
if [ "${VERIFY_OK}" = true ]; then
    echo "DONE: jellyfin.db is now at ${JELLY_HOME}/jellyfin.db on CTID ${JELLY_CTID}"
else
    echo "DONE with warnings: jellyfin.db pushed but size mismatch detected"
fi
echo ""
echo "NEXT STEPS (manual):"
echo "  1. Stop Jellyfin service in CTID ${JELLY_CTID}"
echo "  2. Backup current DB: cp /var/lib/jellyfin/data/jellyfin.db /var/lib/jellyfin/data/jellyfin.db.bak"
echo "  3. Replace: cp ${JELLY_HOME}/jellyfin.db /var/lib/jellyfin/data/jellyfin.db"
echo "  4. Fix ownership: chown jellyfin:jellyfin /var/lib/jellyfin/data/jellyfin.db"
echo "  5. Start Jellyfin service"
echo "============================================================"
