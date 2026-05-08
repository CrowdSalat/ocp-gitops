# HEADING

This guide provides a concise workflow for managing the LVM Operator (LVMS) in OpenShift, ensuring you target the correct disks and handle legacy data safely.

## 1. Pre-Check: Identifying Available Storage

Before installing, you must identify which disks are "clean." The LVM Operator will ignore any disk with existing partitions or metadata.

Run these commands on your node (via oc debug):

``shell
# List all disks and their current filesystems
lsblk -o NAME,SIZE,FSTYPE,TYPE,MOUNTPOINT

# Find the persistent ID for the disk (safer than /dev/sda)
ls -l /dev/disk/by-id/ | grep sda
```

Criteria for Success:

1. TYPE must be disk.
1. FSTYPE must be empty (null).
1. MOUNTPOINT must be empty.

## 2. Choosing Your Strategy

The LVM Operator can manage disks in two primary ways:
A. Automatic Mode (Dynamic)

The operator scans all nodes and claims every empty disk it finds.

- Pros: Hands-off; works well if nodes have different disk names.
- Cons: Less control; might claim a disk you intended for something else.

B. Explicit Path (Recommended)

You provide the specific hardware ID of the disk.

- Pros: Maximum safety; prevents the operator from touching the wrong drive.
- Cons: Requires manual identification of disk IDs for each node.

## 3. Configuration (LVMCluster YAML)

Use this template to apply your configuration. If using Automatic Mode, simply remove the deviceSelector block.

```yaml
apiVersion: lvm.topolvm.io/v1alpha1
kind: LVMCluster
metadata:
  name: my-lvmcluster
  namespace: openshift-lvm-storage
spec:
  storage:
    deviceClasses:
      - name: vg1
        default: true
        fstype: xfs
        deviceSelector:
          # REQUIRED for Explicit Path; Remove for Automatic Mode
          paths:
            - /dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi0-0-0-1
        thinPoolConfig:
          name: thin-pool-1
          sizePercent: 90
          overprovisionRatio: 10
```

## 4. Deleting an Old Volume Group (VG)

If lsblk shows an old vg1 or LVM2_member on a disk you want to use, the operator will fail to initialize. You must manually "zap" the disk.

Warning: This permanently destroys all data on the target disk.

```bash
# 1. Force remove the old Volume Group
vgremove -f vg1

# 2. Remove the Physical Volume label
pvremove /dev/sda

# 3. Wipe all remaining signatures (GPT, MBR, etc.)
wipefs -a /dev/sda

# 4. Final verification (FSTYPE should now be empty)
lsblk /dev/sda
```

## 5. Post-Installation Verification

After applying the LVMCluster YAML, verify the operator has successfully provisioned the storage:

- Check Status: oc get lvmvolumegroup -n openshift-lvm-storage
- Check StorageClass: oc get sc (Ensure an LVM-backed StorageClass exists).
- Check Logs: oc logs -n openshift-lvm-storage -l app.kubernetes.io/name=vg-manager
