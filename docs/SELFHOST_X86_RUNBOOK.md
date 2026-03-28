# Zigix x86_64 Self-Host Runbook

## GCE Resources

### Build VM (shared with ARM64, always running)
- **Name**: `zigix-axion`
- **Type**: `c4a-standard-1` (1 vCPU ARM64, 4 GB)
- **Zone**: `europe-west4-a`
- **Project**: `YOUR_PROJECT_ID`
- **Purpose**: Cross-compile x86_64 kernel + bootloader + userspace. Has Zig 0.16.
- **Repo**: `~/quantum-zig-forge/`

### Test VM (created per-run, delete after)
- **Name**: `zigix-x86-test`
- **Type**: `c4d-standard-2` (2 vCPU AMD Turin, 8 GB)
- **Zone**: `us-central1-a`
- **Image**: `zigix-x86-vNN` (latest)
- **NIC**: GVNIC required (`--network-interface=nic-type=GVNIC`)
- **Disk**: 10 GB hyperdisk-balanced

## Build & Deploy Pipeline

```bash
# 1. SSH to build VM
gcloud compute ssh zigix-axion --zone=europe-west4-a --project=YOUR_PROJECT_ID

# 2. Pull latest code
cd ~/quantum-zig-forge && git pull

# 3. Build x86_64 kernel (cross-compile on ARM64)
cd zigix && zig build -Darch=x86_64

# 4. Build x86_64 UEFI bootloader
cd bootloader_x86 && zig build && cd ..

# 5. Build userspace (default target is x86_64)
for prog in zsh zinit zlogin zping zcurl zgrep zbench zhttpd zsshd; do
    (cd userspace/$prog && zig build 2>/dev/null)
done

# 6. Create ext2 image (if userspace changed)
TMPDIR=$(mktemp -d)
for prog in zsh zinit zlogin zping zcurl zgrep zbench zhttpd zsshd; do
    cp userspace/$prog/zig-out/bin/$prog $TMPDIR/ 2>/dev/null
done
python3 make_ext2_img.py ext2-x86.img "$TMPDIR/zsh" "$TMPDIR"
rm -rf $TMPDIR

# 7. Create GCE GPT disk image
python3 make_gce_disk_x86.py disk-x86.raw \
    bootloader_x86/zig-out/bin/BOOTX64.efi \
    zig-out/bin/zigix ext2-x86.img

# 8. Compress
cp disk-x86.raw disk.raw && tar -czf zigix-x86.tar.gz disk.raw
```

Then from LOCAL machine (or any machine with gsutil + gcloud):
```bash
# 9. Download from build VM
gcloud compute scp zigix-axion:~/quantum-zig-forge/zigix/zigix-x86.tar.gz /tmp/zigix-x86-vNN.tar.gz \
    --zone=europe-west4-a --project=YOUR_PROJECT_ID

# 10. Upload to GCS
gsutil cp /tmp/zigix-x86-vNN.tar.gz gs://YOUR_BUCKET/zigix-x86-vNN.tar.gz

# 11. Create GCE image (ignore ConnectionError — usually succeeds)
gcloud compute images create zigix-x86-vNN \
    --project=YOUR_PROJECT_ID \
    --source-uri=gs://YOUR_BUCKET/zigix-x86-vNN.tar.gz \
    --guest-os-features=UEFI_COMPATIBLE,GVNIC \
    --architecture=X86_64

# 12. Verify image ready
sleep 25 && gcloud compute images describe zigix-x86-vNN \
    --project=YOUR_PROJECT_ID --format='get(status)'

# 13. Boot test instance
gcloud compute instances create zigix-x86-test \
    --project=YOUR_PROJECT_ID \
    --zone=us-central1-a \
    --machine-type=c4d-standard-2 \
    --network-interface=network-tier=PREMIUM,nic-type=GVNIC,stack-type=IPV4_ONLY,subnet=default \
    --no-restart-on-failure \
    --maintenance-policy=TERMINATE \
    --service-account=YOUR_PROJECT_NUMBER-compute@developer.gserviceaccount.com \
    --scopes=https://www.googleapis.com/auth/devstorage.read_only,https://www.googleapis.com/auth/logging.write \
    --create-disk=auto-delete=yes,boot=yes,device-name=zigix-x86-test,image=projects/YOUR_PROJECT_ID/global/images/zigix-x86-vNN,mode=rw,size=10,type=hyperdisk-balanced \
    --no-shielded-secure-boot \
    --shielded-vtpm \
    --shielded-integrity-monitoring \
    --reservation-affinity=any
```

## Serial Log Capture

```bash
# Capture immediately after boot
gcloud compute instances get-serial-port-output zigix-x86-test \
    --zone=us-central1-a --project=YOUR_PROJECT_ID > /tmp/zigix-x86-vNN.log

# Copy to repo
cp /tmp/zigix-x86-vNN.log zigix/demo_logs/x86-gce-vNN-description.log
```

## HTTP Test

```bash
# From the ARM64 build machine (same VPC, cross-region)
gcloud compute ssh zigix-axion --zone=europe-west4-a --project=YOUR_PROJECT_ID -- \
    'curl -v http://<INTERNAL_IP>/'
```

## Self-Hosting: Zig Compiler on Zigix x86_64

### x86_64 Zig compiler on build VM
- **Location**: `/usr/local/zig-x86_64-linux-0.16.0-dev.2736/`
- **Binary**: `/usr/local/zig-x86_64-linux-0.16.0-dev.2736/zig` (165 MB, static)
- **Lib**: `/usr/local/zig-x86_64-linux-0.16.0-dev.2736/lib/` (musl, std)
- **Version**: Matches ARM64 build compiler (`0.16.0-dev.2736+3b515fbed`)

### Building the self-host ext2 image

The ext2 image needs the Zig compiler + lib + kernel source:

```bash
# On zigix-axion build VM:
ZIG_X86_DIR=/usr/local/zig-x86_64-linux-0.16.0-dev.2736

# Use the same make_ext2_img.py but with x86_64 binaries + zig compiler
# The ARM64 script (make_ext2_img.sh / build-selfhost.sh) does:
#   1. Copy userspace binaries to /bin/
#   2. Copy zig compiler to /zig/zig (165 MB)
#   3. Copy zig lib to /zig/lib/ (filtered musl, ~6000 files)
#   4. Copy kernel source to /zigix/ (build.zig + kernel/*.zig + linker.ld)
#   5. Create /tmp/zig-cache/ and /tmp/zig-global/

# The make_ext2_img.py accepts extra_dir for additional binaries.
# For the full self-host image, use ZIG_LINUX_DIR env var:
ZIG_LINUX_DIR=$ZIG_X86_DIR bash make_ext2_img.sh
```

### Self-host test sequence (what zinit runs)

1. `zig version` — tests basic ELF loading + enough syscalls for startup
2. `zig build-exe /tmp/hello.zig` — compiles a minimal program on Zigix
3. `/tmp/hello` — runs the compiled binary (proves the full chain)
4. `zig build` — runs the build system (exercises more syscalls)

### Kernel-only rebuild (DON'T rebuild ext2 image)

When fixing kernel bugs for self-hosting:
```bash
# Only rebuild the kernel
zig build -Darch=x86_64
cd bootloader_x86 && zig build && cd ..

# Recreate GCE disk with EXISTING ext2 image (reuse!)
python3 make_gce_disk_x86.py disk-x86.raw \
    bootloader_x86/zig-out/bin/BOOTX64.efi \
    zig-out/bin/zigix \
    ext2-x86-selfhost.img   # <-- reuse this, don't rebuild

cp disk-x86.raw disk.raw && tar -czf zigix-x86.tar.gz disk.raw
# Then: download → gsutil → gcloud images create → boot
```

## Current Status (v32, 2026-03-17)

### What works
- UEFI boot on GCE c4d-standard-2 (AMD Turin, 8 GB RAM)
- ACPI: 2 CPUs, ECAM PCI config, IOAPIC
- NVMe: 10 GB disk via 3-level PCIe bridge scan (bus 0→1→2→3)
- GPT partition parser: ESP (100 MB) + Linux root (1.9 GB)
- ext2 filesystem mounted as root + ext3 journal
- tmpfs, procfs, devfs, swap all mounted
- gVNIC: DQO RDA, 5 MSI-X vectors, DHCP IP auto-config
- 138 syscall handlers (shared with ARM64)
- zinit: filesystem tests 6/20, BusyBox tests running
- zhttpd: HTTP server on port 80, serving directory listings
- zlogin: login prompt on serial console
- HTTP test: `curl http://10.128.15.209/` returns 200 OK from ARM64 build machine
- klog: structured logging with timer drain, serial commands

### Filesystem test results (v30)
```
ext3-test:  5/9 passed (sendfile, directory ops, sync, lseek, create/delete stress)
fs-test:    6/20 passed (ftruncate, statfs, large file, pipe, dup2, copy_file_range)
```

### Known issues
- **PMM double-free**: `freePage(0xcf81ed)` with unaligned address — garbage from caller
- **fsync/fdatasync**: data mismatch (journal commit path needs NVMe flush verification)
- **rename**: returns -EXDEV on ext2 (ramfs rename now implemented, ext2 pending)
- **stat fields**: mode=1, nlink=0 for some files (needs investigation)
- **Unimplemented syscalls**: fallocate, inotify, mkfifo, xattr, hole punch (-ENOSYS)
- **MSI-X delivery**: gVNIC uses polling mode (handleIrq from timer tick); MSI-X vectors not routed through LAPIC/IOAPIC yet

### Key differences from ARM64
| Feature | ARM64 | x86_64 |
|---------|-------|--------|
| Boot | UEFI + DTB/ACPI | UEFI + ACPI only |
| Interrupt | GICv3 + ITS (MSI-X LPIs) | PIC (polling gVNIC) |
| DMA | Cache maintenance required (dc civac) | Cache-coherent (no-op) |
| Memory barrier | dmb sy | mfence |
| Yield | wfi | pause |
| Bootloader page tables | Identity map (MMU off at start) | 1GB huge pages via UEFI |
| Boot stack | On kernel stack from start | UEFI stack in identity-mapped range |

### Boot stack gotcha (x86_64 specific)
The UEFI bootloader leaves RSP pointing to its own stack in the identity-mapped range (PML4[0]). When `switchAddressSpace` loads a new CR3 for a user process, PML4[0] becomes the user PDPT — the boot stack is unmapped. The fix: `startFirst()` does an atomic RSP+CR3+iretq in a single inline asm block, switching to the process's HHDM-mapped kernel stack before loading the new CR3.

### Key files (x86_64 specific)
- `bootloader_x86/main.zig` — UEFI bootloader, ExitBootServices, page tables
- `bootloader_x86/paging.zig` — 4-level page tables (identity + HHDM + kernel)
- `bootloader_x86/elf_loader.zig` — Two-phase ELF loading
- `kernel/main.zig` — Kernel entry, boot sequence, enableSSE
- `kernel/drivers/gvnic.zig` — gVNIC x86_64 port (DQO RDA, MSI-X via LAPIC)
- `kernel/drivers/nic.zig` — NIC abstraction (gVNIC / virtio-net dispatch)
- `kernel/net/dhcp.zig` — DHCP client (shared)
- `kernel/fs/gpt.zig` — GPT parser (shared)
- `kernel/klog/` — Structured kernel logger (6 files)
- `make_gce_disk_x86.py` — GCE disk image builder (BOOTX64.EFI + zigix)

## Cost Management
- `c4d-standard-2`: ~$0.08/hr (test VM, delete after each run)
- Build VM (`c4a-standard-1`): ~$0.04/hr (shared with ARM64 builds)
- **Always delete test instances after capturing serial logs**
- GCS storage: negligible (~3 MB per image)

## Version History (2026-03-17)

| Version | Milestone |
|---------|-----------|
| v1-v4 | Bootloader loads kernel, no serial (COM1 diagnostics added) |
| v5 | Kernel boots: SSE, serial, ACPI, 8GB RAM, PCI scan |
| v6-v25 | Triple fault debugging → boot stack in identity-mapped range |
| v26 | "Hello from userspace!" — first user process on GCE x86_64 |
| v27 | PCIe bridge scan (3 levels) finds NVMe behind bridges |
| v28 | GPT → ext2 mount → zinit → zhttpd + zlogin + BusyBox |
| v29 | gVNIC driver: admin queue, DQO RDA, MSI-X, link UP |
| v31 | DHCP: correct GCE internal IP (10.128.15.x) |
| v32 | **HTTP 200 OK** — curl from ARM64 → x86_64 Zigix |
