# Zigix Self-Host Runbook

## GCE Resources

### Build VM (always running)
- **Name**: `zigix-axion`
- **Type**: `c4a-standard-1` (1 vCPU, 4 GB)
- **Zone**: `europe-west4-a`
- **Project**: `YOUR_PROJECT_ID`
- **Purpose**: Build kernel, userspace, disk images. Has Zig 0.16, git, rsync, BusyBox pre-built.
- **Zig path**: `/usr/local/zig-aarch64-linux-0.16.0-dev.2736+3b515fbed/`
- **Repo**: `~/quantum-zig-forge/`

### Test VM (created per-run, delete after)
- **Name**: `zigix-selfhost-2cpu`
- **Type**: `c4a-standard-2` (2 vCPU, 8 GB) — SMP works here, NOT on c4a-standard-8 (no PSCI secondary CPU bringup yet)
- **Image**: `zigix-selfhost-vNN` (latest)
- **Disk**: 10 GB hyperdisk-balanced
- **IMPORTANT**: Only 2 CPUs brought up (MADT shows 8 on standard-8 but kernel only initializes BSP via GICv3 redistributor)

### Other instances (can be deleted)
- `zigix-final2` — old test, can delete to save costs

## Build & Deploy Pipeline

```bash
# 1. SSH to build VM
gcloud compute ssh zigix-axion --zone=europe-west4-a --project=YOUR_PROJECT_ID

# 2. Pull latest code
cd ~/quantum-zig-forge && git pull

# 3. Build kernel
cd zigix && zig build -Darch=aarch64 -Dcpu=neoverse_n2

# 4. Build bootloader (if not already built)
cd bootloader && zig build && cd ..

# 5. Rebuild userspace (if zinit changed)
for prog in zsh zinit zlogin zping zcurl zgrep zhttpd zsshd; do
    (cd userspace/$prog && zig build -Darch=aarch64 2>/dev/null) && cd ~/quantum-zig-forge/zigix
done

# 6. Rebuild ext4 image WITH zig compiler + kernel source
# (Use the existing ext4-aarch64.img if only kernel changed, not userspace)
# Full rebuild uses /tmp/build-selfhost.sh on the VM

# 7. Create GCE disk image
python3 make_gce_disk.py disk.raw bootloader/zig-out/bin/BOOTAA64.efi \
    zig-out/bin/zigix-aarch64 ext4-aarch64.img

# 8. Compress
tar -czf zigix-selfhost.tar.gz disk.raw
```

Then from LOCAL machine:
```bash
# 9. Download
gcloud compute scp zigix-axion:~/quantum-zig-forge/zigix/zigix-selfhost.tar.gz /tmp/zigix-selfhost-vNN.tar.gz \
    --zone=europe-west4-a --project=YOUR_PROJECT_ID

# 10. Upload to GCS
gsutil cp /tmp/zigix-selfhost-vNN.tar.gz gs://YOUR_BUCKET/zigix-selfhost-vNN.tar.gz

# 11. Create GCE image (ignore ConnectionError — it usually succeeds anyway)
gcloud compute images create zigix-selfhost-vNN \
    --project=YOUR_PROJECT_ID \
    --source-uri=gs://YOUR_BUCKET/zigix-selfhost-vNN.tar.gz \
    --guest-os-features=UEFI_COMPATIBLE,GVNIC \
    --architecture=ARM64

# 12. Verify image ready
sleep 20 && gcloud compute images describe zigix-selfhost-vNN --project=YOUR_PROJECT_ID --format='get(status)'

# 13. Boot test instance
gcloud compute instances create zigix-selfhost-2cpu \
    --project=YOUR_PROJECT_ID \
    --zone=europe-west4-a \
    --machine-type=c4a-standard-2 \
    --network-interface=network-tier=PREMIUM,nic-type=GVNIC,stack-type=IPV4_ONLY,subnet=default \
    --no-restart-on-failure \
    --maintenance-policy=TERMINATE \
    --service-account=YOUR_PROJECT_NUMBER-compute@developer.gserviceaccount.com \
    --scopes=https://www.googleapis.com/auth/devstorage.read_only,https://www.googleapis.com/auth/logging.write \
    --create-disk=auto-delete=yes,boot=yes,device-name=zigix-selfhost-2cpu,image=projects/YOUR_PROJECT_ID/global/images/zigix-selfhost-vNN,mode=rw,size=10,type=hyperdisk-balanced \
    --no-shielded-secure-boot \
    --shielded-vtpm \
    --shielded-integrity-monitoring \
    --reservation-affinity=none
```

## Serial Log Capture (CRITICAL)

**ALWAYS save serial output to a local file. The GCE serial buffer is small and gets overwritten by the login respawn loop.**

```bash
# Capture serial to local file — run this IMMEDIATELY after booting
gcloud compute instances get-serial-port-output zigix-selfhost-2cpu \
    --zone=europe-west4-a --project=YOUR_PROJECT_ID > /tmp/zigix-vNN.log

# Copy to repo for permanent storage
cp /tmp/zigix-vNN.log zigix/demo_logs/selfhost-vNN-description.log

# Give the FULL log to Gemini for analysis (free, catches issues human/Claude misses)
```

Monitor loop (run in background):
```bash
for i in $(seq 1 30); do
    sleep 120
    gcloud compute instances get-serial-port-output zigix-selfhost-2cpu \
        --zone=europe-west4-a --project=YOUR_PROJECT_ID 2>/dev/null > /tmp/zigix-vNN.log
    RESULT=$(grep -E "SELF-HOST.*PASSED|ZIGIX CAN|SELF-HOST.*binary not|FATAL|Poll timeout" /tmp/zigix-vNN.log | head -1)
    WRITES=$(grep -c "ext2-wr" /tmp/zigix-vNN.log)
    echo "[$i] ${WRITES} writes | ${RESULT:-compiling...}"
    if [ -n "$RESULT" ]; then break; fi
done
```

## Current Self-Host Status (v20, 2026-03-17)

### What works
- BusyBox 10/10
- `zig version` PASS
- `zig build-exe hello.zig` PASS
- `zig build` (build.zig runner) PASS
- Fork stress 20/20
- 8 GB RAM detected via UEFI memory map (32 GB on standard-8)
- NVMe depth 256, CQ doorbell pre-ring
- execveat (NR 281) for LLD spawn
- waitid (NR 95) for child reaping
- Scheduler orphan detection
- Page cache poison prevention
- inode.ops.close validation

### Current blocker
**NVMe poll timeout at ~8350 commands** during the self-host build's LLVM output phase. The compilation succeeds (13 MB written to inode 7608), but one NVMe timeout during the cleanup/linker phase crashes the kernel.

Crash pattern: `KERNEL INST ABORT FAR=0x0 ELR=0x0 PID=7` — all registers zeroed, corrupted context after NVMe timeout.

### Next fix to try
1. **Increase NVMe poll timeout** from 50M to 500M iterations
2. **Add retry after timeout** — re-ring both SQ and CQ doorbells, then retry the poll
3. **Investigate the ~8350 command threshold** — might be NVMe interrupt coalescing or device-specific behavior
4. **Make timeout truly non-fatal** — ensure the process cleanup path doesn't corrupt kernel state when I/O fails

### Key files
- `nvme.zig` — NVMe driver, `pollCompletion`, `submitIo`
- `exception.zig` — page fault handler, demand paging, EL1 crash diagnostic
- `syscall.zig` — execveat, waitid, closeAllFds, sysExit
- `vfs.zig` — releaseFileDescription with ops.close validation
- `pmm.zig` — page_cache.shrink on OOM
- `scheduler.zig` — orphan detection, idle CPU pickup
- `boot.zig` — UEFI memory map parsing, boot banner
- `zinit/main.zig` — self-host test, waitForPid, spawnSelfHost

### Disk image contents
- `/zig/zig` — 152 MB Zig compiler (aarch64-linux static)
- `/zig/lib/` — Zig stdlib (filtered musl, 6105 files)
- `/zigix/` — Kernel source tree (137 .zig files + build.zig + linker script)
- `/bin/` — 10 binaries (zsh, zinit, busybox, zhttpd, etc.)
- `/tmp/zig-cache/`, `/tmp/zig-global/` — Pre-created cache dirs

### Build script on VM
The script `/tmp/build-selfhost.sh` does the full rebuild including:
- git pull
- kernel build
- userspace build
- ext4 image with zig + kernel source
- GCE disk image

If the script is missing (VM was recreated), upload it:
```bash
gcloud compute scp /tmp/build-selfhost.sh zigix-axion:/tmp/build-selfhost.sh \
    --zone=europe-west4-a --project=YOUR_PROJECT_ID
```

## Commits This Session (2026-03-16/17)

| Hash | Fix | Impact |
|------|-----|--------|
| `f2bea5e3` | ARM64 break-before-make | BusyBox 10/10 |
| `36a2bd7b` | vma_lock/ext2_lock deadlock | SMP stable |
| `44bb4c09` | EC=0 halt + syscall trace | No exception loops |
| `60f9d6a6` | waitid (NR 95) | zig build passes |
| `9b56e0a7` | 64GB identity map | Large instances boot |
| `752a522d` | UEFI memory map parsing | 32 GB RAM detected |
| `c215c792` | NVMe depth 256 + cache invalidation | 0 CID mismatches |
| `3c96ccd0` | Self-host test in zinit | Kernel source on disk |
| `1a3faa03` | readFileHead retry | Login survives NVMe hiccups |
| `c6adec7f` | Skip-to-selfhost | Clean NVMe headroom |
| `33458e14` | Scheduler orphan fix | .running with cpu_id=-1 → .ready |
| `7b5cd3c6` | execveat (NR 281) | LLD spawn works |
| `9fdd001e` | waitForPid specific PID | No grandchild starvation |
| `c4a2c380` | Don't cache partial reads | No page cache poisoning |
| `ca5bfbee` | Validate ops.close | No 0xFFFFFFFF crash |
| `b32283ae` | Boot banner update | "Zigix OS, bare-metal" |
| `9808ba50` | Remove dc ivac from NVMe poll | IO coherent, faster poll |
| `ee61d410` | CQ doorbell before submit | Reduced timeouts to 1 |

## Cost Management
- `c4a-standard-1`: ~$0.04/hr (build VM, keep running)
- `c4a-standard-2`: ~$0.08/hr (test VM, delete after each run)
- `c4a-standard-8`: ~$0.32/hr (only use when SMP secondary CPU bringup works)
- **Always delete test instances after capturing serial logs**
- GCS storage for images: negligible (~67 MB each)
