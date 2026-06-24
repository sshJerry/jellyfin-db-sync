#!/bin/bash
# ============================================================
# Pull jellyfin.db from Jellyfin (CTID XXX) -> Push to TrueNAS VM via NFS
# ============================================================
# Run this on the Proxmox host as root.
# Pulls ONLY jellyfin.db (not the whole data directory).
# TrueNAS is a VM (not a container), so we use NFS mount instead of pct push.
# ============================================================

set -e

JELLY_CTID=JELLY_CTID
TRUENAS_VMID=TRUENAS_VMID                    # TrueNAS VM ID (qm, not pct)
NFS_SERVER="TRUENAS_IP"
NFS_EXPORT="/mnt/Media/content/JellyfinDBClone"
NFS_MOUNT="/mnt/nfs_JellyfinDBClone"
JELLY_DB_PATH="/var/lib/jellyfin/data/jellyfin.db"
TMP_LOCAL="/tmp/jellyfin.db"

echo "============================================================"
echo "Pull jellyfin.db: CTID ${JELLY_CTID} -> TrueNAS VM ${TRUENAS_VMID} via NFS"
echo "============================================================"

# --- Step 1: Verify Jellyfin container is running ---
echo ""
echo "[1/8] Verifying CTID ${JELLY_CTID} is running..."
if pct status ${JELLY_CTID} | grep -q "running"; then
    echo "  PASS: CTID ${JELLY_CTID} is running"
else
    echo "  FAIL: CTID ${JELLY_CTID} is not running"
    exit 1
fi

# --- Step 2: Verify jellyfin.db exists in container ---
echo ""
echo "[2/8] Verifying jellyfin.db exists in CTID ${JELLY_CTID}..."
if pct exec ${JELLY_CTID} -- test -f ${JELLY_DB_PATH}; then
    SIZE=$(pct exec ${JELLY_CTID} -- stat -c '%s' ${JELLY_DB_PATH})
    echo "  PASS: ${JELLY_DB_PATH} exists (${SIZE} bytes)"
else
    echo "  FAIL: ${JELLY_DB_PATH} not found in CTID ${JELLY_CTID}"
    exit 1
fi

# --- Step 3: Pull jellyfin.db to Proxmox host ---
echo ""
echo "[3/8] Pulling jellyfin.db to Proxmox host..."
pct pull ${JELLY_CTID} ${JELLY_DB_PATH} ${TMP_LOCAL}
if [ -f "${TMP_LOCAL}" ]; then
    LOCAL_SIZE=$(stat -c '%s' ${TMP_LOCAL})
    echo "  PASS: Pulled to ${TMP_LOCAL} (${LOCAL_SIZE} bytes)"
else
    echo "  FAIL: Pull failed"
    exit 1
fi

# --- Step 4: Verify TrueNAS VM is running ---
echo ""
echo "[4/8] Verifying TrueNAS VM ${TRUENAS_VMID} is running..."
if qm status ${TRUENAS_VMID} | grep -q "running"; then
    echo "  PASS: VM ${TRUENAS_VMID} is running"
else
    echo "  FAIL: VM ${TRUENAS_VMID} is not running"
    exit 1
fi

# --- Step 5: Mount NFS share from TrueNAS ---
echo ""
echo "[5/8] Mounting NFS share: ${NFS_SERVER}:${NFS_EXPORT} -> ${NFS_MOUNT}..."
mkdir -p ${NFS_MOUNT}
mount -t nfs -o vers=3,rw,hard,intr ${NFS_SERVER}:${NFS_EXPORT} ${NFS_MOUNT}
if mountpoint -q ${NFS_MOUNT}; then
    echo "  PASS: NFS share mounted at ${NFS_MOUNT}"
else
    echo "  FAIL: NFS mount failed"
    exit 1
fi

# --- Step 6: Verify read/write access on NFS mount ---
echo ""
echo "[6/8] Verifying read/write access on ${NFS_MOUNT}..."
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

# --- Step 7: Copy jellyfin.db to TrueNAS NFS share ---
echo ""
echo "[7/8] Copying jellyfin.db to ${NFS_MOUNT}..."
cp ${TMP_LOCAL} ${NFS_MOUNT}/jellyfin.db
REMOTE_SIZE=$(stat -c '%s' ${NFS_MOUNT}/jellyfin.db)
echo "  PASS: Copied to ${NFS_MOUNT}/jellyfin.db (${REMOTE_SIZE} bytes)"

# --- Step 8: Verify, cleanup, and unmount ---
echo ""
echo "[8/8] Verifying, cleaning up, and unmounting..."
VERIFY_OK=true

if [ "${LOCAL_SIZE}" = "${REMOTE_SIZE}" ]; then
    echo "  PASS: Size match (${LOCAL_SIZE} == ${REMOTE_SIZE})"
else
    echo "  WARNING: Size mismatch (${LOCAL_SIZE} vs ${REMOTE_SIZE})"
    VERIFY_OK=false
fi

rm -f ${TMP_LOCAL}
echo "  Cleaned up ${TMP_LOCAL}"

umount ${NFS_MOUNT}
if ! mountpoint -q ${NFS_MOUNT}; then
    echo "  PASS: Unmounted ${NFS_MOUNT}"
else
    echo "  WARNING: Failed to unmount ${NFS_MOUNT}"
fi

rmdir ${NFS_MOUNT} 2>/dev/null || true

echo ""
echo "============================================================"
if [ "${VERIFY_OK}" = true ]; then
    echo "DONE: jellyfin.db copied to TrueNAS at ${NFS_EXPORT}/jellyfin.db"
else
    echo "DONE with warnings: jellyfin.db copied but size mismatch detected"
fi
echo "============================================================"
