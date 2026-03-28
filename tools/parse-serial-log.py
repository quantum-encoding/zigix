#!/usr/bin/env python3
"""Zigix serial log analyzer.

Parses GCE serial output into categorized, time-sequenced events.

Usage:
    python3 tools/parse-serial-log.py /tmp/zigix-v20.log
    python3 tools/parse-serial-log.py /tmp/zigix-v20.log --section boot
    python3 tools/parse-serial-log.py /tmp/zigix-v20.log --section crash
    python3 tools/parse-serial-log.py /tmp/zigix-v20.log --section nvme
    python3 tools/parse-serial-log.py /tmp/zigix-v20.log --section writes
    python3 tools/parse-serial-log.py /tmp/zigix-v20.log --section syscalls
    python3 tools/parse-serial-log.py /tmp/zigix-v20.log --json
"""

import sys
import re
import json
import argparse
from collections import defaultdict, OrderedDict
from dataclasses import dataclass, field, asdict
from typing import Optional

# --- Event classification ---

@dataclass
class Event:
    line_num: int
    subsystem: str
    category: str  # boot, hw, fs, process, net, error, test, tick
    raw: str
    details: dict = field(default_factory=dict)

@dataclass
class WriteRecord:
    inode: int
    total_bytes: int
    write_count: int
    final_size: int
    disk_writes: int

@dataclass
class CrashInfo:
    type: str           # "INST ABORT", "DATA ABORT", "SYNC EXCEPTION"
    far: str
    elr: str
    esr: str
    pid: int
    lr: str
    sp: str
    registers: dict
    fp_chain: list
    syscall_trace: list  # last N syscalls before crash
    line_num: int

@dataclass
class Report:
    filename: str
    total_lines: int
    boot_events: list
    hw_events: list       # NVMe, GIC, PCI, timer, etc.
    fs_events: list       # ext2/ext3/ext4, VFS
    process_events: list  # execve, exit, fork, init
    net_events: list      # gvnic, dhcp, net
    test_events: list     # vfs-test, init test results
    errors: list          # crashes, aborts, timeouts
    ticks: list           # scheduler ticks
    write_summary: dict   # inode -> WriteRecord
    crash: Optional[CrashInfo]
    subsystem_counts: dict
    syscall_trace: list


# Subsystem → category mapping
CATEGORY_MAP = {
    # Boot
    'boot': 'boot', 'mmu': 'boot', 'pmm': 'boot', 'vmm': 'boot',
    'cpu': 'boot', 'rng': 'boot',
    # Hardware
    'nvme': 'hw', 'pci': 'hw', 'gic': 'hw', 'gicv3': 'hw',
    'gicv3-its': 'hw', 'timer': 'hw', 'wdog': 'hw', 'smp': 'hw',
    'gpt': 'hw', 'acpi': 'hw',
    # Filesystem
    'ext2': 'fs', 'ext2-wr': 'fs', 'ext2-create': 'fs',
    'ext3': 'fs', 'ext4': 'fs', 'vfs-test': 'test',
    'ramfs': 'fs', 'stat-e': 'fs', 'rename-e': 'fs',
    # Process
    'init': 'process', 'execve': 'process', 'exit': 'process',
    'sched': 'process', 'dp': 'process',
    # Network
    'gvnic': 'net', 'net': 'net', 'dhcp': 'net',
    # Exceptions / errors
    'exc': 'error', 'sc-trace': 'error',
    # Tick
    'tick': 'tick',
}


def strip_ansi(text):
    """Remove ANSI escape sequences."""
    return re.sub(r'\x1b\[[0-9;]*[a-zA-Z]|\x1b\[[^a-zA-Z]*[a-zA-Z]', '', text)


def parse_subsystem_tag(line):
    """Extract [subsystem] tag from a log line."""
    m = re.match(r'\[([a-zA-Z0-9_-]+)\]\s*(.*)', line)
    if m:
        return m.group(1), m.group(2)
    return None, line


def parse_ext2_write(rest):
    """Parse: ino=6765 wrote=27 new_sz=27 wdisk=1"""
    d = {}
    for m in re.finditer(r'(\w+)=(\d+)', rest):
        d[m.group(1)] = int(m.group(2))
    return d


def parse_crash_block(lines, start_idx):
    """Parse a kernel crash block starting at start_idx."""
    crash_line = lines[start_idx]
    m = re.search(
        r'(KERNEL \w+ ABORT|SYNC EXCEPTION).*?'
        r'FAR=(0x[0-9a-fA-F]+)\s+'
        r'ELR=(0x[0-9a-fA-F]+)\s+'
        r'ESR=(0x[0-9a-fA-F]+)\s+'
        r'PID=(\d+)',
        crash_line
    )
    if not m:
        return None

    crash = CrashInfo(
        type=m.group(1),
        far=m.group(2),
        elr=m.group(3),
        esr=m.group(4),
        pid=int(m.group(5)),
        lr='', sp='',
        registers={},
        fp_chain=[],
        syscall_trace=[],
        line_num=start_idx + 1,
    )

    # Parse LR, SP from same line
    lr_m = re.search(r'LR=(0x[0-9a-fA-F]+)', crash_line)
    sp_m = re.search(r'SP=(0x[0-9a-fA-F]+)', crash_line)
    if lr_m:
        crash.lr = lr_m.group(1)
    if sp_m:
        crash.sp = sp_m.group(1)

    # Parse continuation lines (registers, FP chain, stack info)
    i = start_idx + 1
    while i < len(lines):
        line = lines[i].strip()
        if not line or (line.startswith('[') and not line.startswith('  ')):
            break
        # Register dump lines
        for rm in re.finditer(r'(X\d+|SPSR|LR|SP)=(0x[0-9a-fA-F]+)', line):
            crash.registers[rm.group(1)] = rm.group(2)
        # Frame/kstack info
        for rm in re.finditer(r'(frame_at|kstack|kstop)=(0x[0-9a-fA-F]+)', line):
            crash.registers[rm.group(1)] = rm.group(2)
        # FP chain
        fp_m = re.search(r'FP chain:\s*(.*)', line)
        if fp_m:
            crash.fp_chain = [x.strip() for x in fp_m.group(1).split('→') if x.strip()]
        i += 1

    return crash


def parse_syscall_trace(lines, start_idx):
    """Parse [sc-trace] Last N syscalls block."""
    trace = []
    i = start_idx + 1
    while i < len(lines):
        line = lines[i].strip()
        m = re.match(r'P(\d+)\s+nr=(\d+)\s+x0=(0x[0-9a-fA-F]+)\s+x1=(0x[0-9a-fA-F]+)\s*->\s*(-?\d+)', line)
        if m:
            trace.append({
                'pid': int(m.group(1)),
                'nr': int(m.group(2)),
                'x0': m.group(3),
                'x1': m.group(4),
                'ret': int(m.group(5)),
            })
            i += 1
        else:
            break
    return trace


# Well-known aarch64 Linux syscall numbers
SYSCALL_NAMES = {
    24: 'sched_yield', 29: 'ioctl', 35: 'nanosleep',
    56: 'openat', 57: 'close', 59: 'pipe2', 61: 'getdents64',
    62: 'lseek', 63: 'read', 64: 'write', 66: 'writev',
    78: 'readlinkat', 79: 'fstatat', 80: 'fstat',
    93: 'exit', 94: 'exit_group', 95: 'waitid', 96: 'set_tid_address',
    98: 'futex', 99: 'set_robust_list', 100: 'nanosleep',
    129: 'kill', 131: 'tgkill', 135: 'sigaction',
    172: 'getpid', 174: 'getuid', 175: 'geteuid',
    176: 'getgid', 177: 'getegid', 178: 'gettid',
    215: 'munmap', 220: 'clone', 221: 'execve',
    222: 'mmap', 226: 'mprotect', 233: 'madvise',
    261: 'prlimit64', 278: 'getrandom', 281: 'execveat',
    291: 'statx', 296: 'pwritev2',
}


def analyze_log(filepath):
    """Parse a serial log file into a structured report."""
    with open(filepath, 'r', errors='replace') as f:
        raw_lines = f.readlines()

    lines = [strip_ansi(l.rstrip('\n')) for l in raw_lines]

    report = Report(
        filename=filepath,
        total_lines=len(lines),
        boot_events=[], hw_events=[], fs_events=[],
        process_events=[], net_events=[], test_events=[],
        errors=[], ticks=[],
        write_summary={},
        crash=None,
        subsystem_counts=defaultdict(int),
        syscall_trace=[],
    )

    write_tracker = defaultdict(lambda: {'total_bytes': 0, 'write_count': 0, 'final_size': 0, 'disk_writes': 0})

    for i, line in enumerate(lines):
        subsystem, rest = parse_subsystem_tag(line)
        if not subsystem:
            # Check for UEFI/bootloader lines
            if 'UEFI' in line or 'Bootloader' in line or 'BdsDxe' in line:
                report.boot_events.append(Event(i+1, 'uefi', 'boot', line))
            elif 'Zigix OS' in line or 'QUANTUM ENCODING' in line or 'bare-metal' in line:
                report.boot_events.append(Event(i+1, 'banner', 'boot', line))
            # Check for crash continuation lines (indented register dumps)
            continue

        report.subsystem_counts[subsystem] += 1
        category = CATEGORY_MAP.get(subsystem, 'other')

        # Special parsing for specific event types
        if subsystem == 'ext2-wr':
            d = parse_ext2_write(rest)
            ino = d.get('ino', 0)
            t = write_tracker[ino]
            t['total_bytes'] += d.get('wrote', 0)
            t['write_count'] += 1
            t['final_size'] = d.get('new_sz', t['final_size'])
            t['disk_writes'] += d.get('wdisk', 0)
            # Don't add individual writes to fs_events (too noisy)
            continue

        if subsystem == 'exc' and not ('ABORT' in rest or 'EXCEPTION' in rest):
            # Non-crash exc events (e.g. "Exception vectors installed") → boot
            report.boot_events.append(Event(i+1, subsystem, 'boot', line))
            continue

        if subsystem == 'exc' and ('ABORT' in rest or 'EXCEPTION' in rest):
            crash = parse_crash_block(lines, i)
            if crash:
                report.crash = crash
                report.errors.append(Event(i+1, subsystem, 'error', line, {'crash': True}))
            continue

        if subsystem == 'sc-trace':
            report.syscall_trace = parse_syscall_trace(lines, i)
            continue

        if subsystem == 'nvme' and 'timeout' in rest.lower():
            report.errors.append(Event(i+1, subsystem, 'error', line, {'nvme_timeout': True}))
            continue

        if subsystem == 'tick':
            m = re.search(r't=(\d+)\s+cpu=(\d+)\s+pid=(\d+)\s+elr=(0x[0-9a-fA-F]+)', rest)
            if m:
                report.ticks.append({
                    'line': i+1, 'tick': int(m.group(1)),
                    'cpu': int(m.group(2)), 'pid': int(m.group(3)),
                    'elr': m.group(4),
                })
            continue

        event = Event(i+1, subsystem, category, line)

        # Enrich specific events
        if subsystem == 'execve':
            m = re.search(r'P(\d+).*?(\S+)$', rest)
            if m:
                event.details = {'pid': int(m.group(1)), 'binary': m.group(2)}

        if subsystem == 'init':
            event.details = {'message': rest}

        if subsystem == 'exit':
            m = re.search(r'P(\d+)', rest)
            if m:
                event.details = {'pid': int(m.group(1))}

        # Route to category list
        dest = {
            'boot': report.boot_events,
            'hw': report.hw_events,
            'fs': report.fs_events,
            'process': report.process_events,
            'net': report.net_events,
            'test': report.test_events,
            'error': report.errors,
        }.get(category)
        if dest is not None:
            dest.append(event)

    # Build write summary
    for ino, t in sorted(write_tracker.items(), key=lambda x: -x[1]['total_bytes']):
        report.write_summary[ino] = WriteRecord(
            inode=ino, total_bytes=t['total_bytes'],
            write_count=t['write_count'], final_size=t['final_size'],
            disk_writes=t['disk_writes'],
        )

    return report


def fmt_size(n):
    if n >= 1_048_576:
        return f"{n/1_048_576:.1f} MB"
    if n >= 1024:
        return f"{n/1024:.1f} KB"
    return f"{n} B"


def print_summary(report):
    """Print the top-level summary."""
    print(f"{'='*60}")
    print(f"  Zigix Serial Log Analysis")
    print(f"  {report.filename}")
    print(f"  {report.total_lines} lines")
    print(f"{'='*60}\n")

    # Subsystem event counts
    print("SUBSYSTEM COUNTS:")
    for sub, count in sorted(report.subsystem_counts.items(), key=lambda x: -x[1]):
        bar = '█' * min(count // 50 + 1, 40) if count > 0 else ''
        print(f"  {sub:15s} {count:6d}  {bar}")
    print()

    # Boot sequence
    print(f"BOOT SEQUENCE ({len(report.boot_events)} events):")
    for e in report.boot_events:
        print(f"  L{e.line_num:5d}  {e.raw[:100]}")
    print()

    # Hardware init
    print(f"HARDWARE ({len(report.hw_events)} events):")
    for e in report.hw_events:
        print(f"  L{e.line_num:5d}  {e.raw[:100]}")
    print()

    # Process lifecycle
    print(f"PROCESS LIFECYCLE ({len(report.process_events)} events):")
    for e in report.process_events:
        detail = ''
        if 'binary' in e.details:
            detail = f" → {e.details['binary']}"
        elif 'message' in e.details:
            detail = f" — {e.details['message'][:80]}"
        print(f"  L{e.line_num:5d}  [{e.subsystem}]{detail}")
    print()

    # Tests
    if report.test_events:
        print(f"TESTS ({len(report.test_events)} events):")
        for e in report.test_events:
            status = '✓' if 'PASS' in e.raw else '✗' if 'FAIL' in e.raw else ' '
            print(f"  {status} L{e.line_num:5d}  {e.raw[:100]}")
        print()

    # Network
    if report.net_events:
        print(f"NETWORK ({len(report.net_events)} events):")
        for e in report.net_events[:20]:
            print(f"  L{e.line_num:5d}  {e.raw[:100]}")
        if len(report.net_events) > 20:
            print(f"  ... +{len(report.net_events)-20} more")
        print()


def print_writes(report):
    """Print filesystem write summary."""
    print(f"FILESYSTEM WRITES:")
    total_bytes = sum(w.total_bytes for w in report.write_summary.values())
    total_ops = sum(w.write_count for w in report.write_summary.values())
    print(f"  Total: {fmt_size(total_bytes)} across {total_ops} write ops to {len(report.write_summary)} inodes\n")

    # Top 20 by total bytes
    top = sorted(report.write_summary.values(), key=lambda w: -w.total_bytes)[:20]
    print(f"  {'inode':>7s}  {'writes':>7s}  {'total':>10s}  {'final_sz':>10s}  {'disk_wr':>7s}")
    print(f"  {'─'*7}  {'─'*7}  {'─'*10}  {'─'*10}  {'─'*7}")
    for w in top:
        print(f"  {w.inode:7d}  {w.write_count:7d}  {fmt_size(w.total_bytes):>10s}  {fmt_size(w.final_size):>10s}  {w.disk_writes:7d}")
    if len(report.write_summary) > 20:
        print(f"  ... +{len(report.write_summary)-20} more inodes")
    print()


def print_errors(report):
    """Print errors and crash info."""
    print(f"ERRORS ({len(report.errors)} events):")
    for e in report.errors:
        print(f"  L{e.line_num:5d}  {e.raw[:120]}")
    print()

    if report.crash:
        c = report.crash
        print(f"CRASH ANALYSIS:")
        print(f"  Type:   {c.type}")
        print(f"  FAR:    {c.far}")
        print(f"  ELR:    {c.elr}")
        print(f"  ESR:    {c.esr}")
        print(f"  PID:    {c.pid}")
        print(f"  LR:     {c.lr}")
        print(f"  SP:     {c.sp}")
        print(f"  Line:   {c.line_num}")

        if c.registers:
            print(f"\n  Registers:")
            for k, v in c.registers.items():
                print(f"    {k:10s} = {v}")

        if c.fp_chain:
            print(f"\n  FP Chain: {' → '.join(c.fp_chain)}")

        # Diagnose common crash patterns
        print(f"\n  DIAGNOSIS:")
        if c.far == '0x0' and c.elr == '0x0':
            print(f"    All-zero FAR/ELR: corrupted context — likely cascaded from NVMe timeout")
            print(f"    or use-after-free in process cleanup path (closeAllFds, releaseFileDescription)")
        elif 'FFFFFFFF' in c.far.upper():
            print(f"    Sign-extended null: corrupted function pointer (ops.close or similar)")
            print(f"    Likely inode ops table corruption or cache eviction while FD still open")
        elif c.far.startswith('0x4'):
            print(f"    Kernel address fault: possible stack overflow or page table corruption")
        elif c.far.startswith('0x7'):
            print(f"    User address fault in kernel mode: demand paging or VMA issue")

        # ESR decode for aarch64
        esr_val = int(c.esr, 16)
        ec = (esr_val >> 26) & 0x3f
        ec_names = {
            0x20: 'Inst Abort (lower EL)', 0x21: 'Inst Abort (same EL)',
            0x24: 'Data Abort (lower EL)', 0x25: 'Data Abort (same EL)',
        }
        dfsc = esr_val & 0x3f
        dfsc_names = {
            0x04: 'Translation fault L0', 0x05: 'Translation fault L1',
            0x06: 'Translation fault L2', 0x07: 'Translation fault L3',
            0x09: 'Access flag fault L1', 0x0a: 'Access flag fault L2',
            0x0b: 'Access flag fault L3', 0x0d: 'Permission fault L1',
            0x0e: 'Permission fault L2', 0x0f: 'Permission fault L3',
        }
        print(f"    ESR EC=0x{ec:02x} ({ec_names.get(ec, 'unknown')}) DFSC=0x{dfsc:02x} ({dfsc_names.get(dfsc, 'unknown')})")
        print()


def print_syscalls(report):
    """Print syscall trace with decoded names."""
    if not report.syscall_trace:
        print("SYSCALL TRACE: (none captured)\n")
        return

    print(f"SYSCALL TRACE (last {len(report.syscall_trace)} before crash):")
    for s in report.syscall_trace:
        name = SYSCALL_NAMES.get(s['nr'], f"nr_{s['nr']}")
        ret = s['ret']
        ret_str = str(ret) if ret >= 0 else f"-{abs(ret)} (E{'?'})"
        print(f"  P{s['pid']}  {name:16s} ({s['nr']:3d})  x0={s['x0']}  x1={s['x1']}  → {ret_str}")
    print()

    # Summarize syscall distribution
    nr_counts = defaultdict(int)
    for s in report.syscall_trace:
        nr_counts[s['nr']] += 1
    print("  Syscall distribution:")
    for nr, count in sorted(nr_counts.items(), key=lambda x: -x[1]):
        name = SYSCALL_NAMES.get(nr, f"nr_{nr}")
        print(f"    {name:16s} ({nr:3d}): {count}")
    print()


def print_nvme(report):
    """Print NVMe-specific analysis."""
    print("NVMe ANALYSIS:")
    # Count ext2 writes (each triggers NVMe)
    total_writes = sum(w.disk_writes for w in report.write_summary.values())
    total_bytes = sum(w.total_bytes for w in report.write_summary.values())
    print(f"  Disk writes:     {total_writes}")
    print(f"  Data written:    {fmt_size(total_bytes)}")

    # Timeouts
    timeouts = [e for e in report.errors if e.details.get('nvme_timeout')]
    print(f"  Poll timeouts:   {len(timeouts)}")
    for t in timeouts:
        print(f"    L{t.line_num}: {t.raw[:100]}")

    # Tick analysis — was the system idle after crash?
    if report.ticks:
        first = report.ticks[0]
        last = report.ticks[-1]
        idle_ticks = sum(1 for t in report.ticks if t['pid'] == 0)
        print(f"\n  Tick range:      {first['tick']} → {last['tick']} ({last['tick']-first['tick']} ticks)")
        print(f"  Idle ticks:      {idle_ticks}/{len(report.ticks)} ({100*idle_ticks//max(len(report.ticks),1)}%)")

        # Check if stuck in idle after crash
        if len(report.ticks) > 5:
            last_5 = report.ticks[-5:]
            if all(t['pid'] == 0 for t in last_5):
                print(f"  WARNING: System stuck in idle (PID 0) — likely crashed or all processes dead")
    print()


def print_ticks(report):
    """Print tick timeline showing process scheduling."""
    if not report.ticks:
        print("TICK TIMELINE: (none captured)\n")
        return

    print(f"TICK TIMELINE ({len(report.ticks)} ticks):")
    pid_counts = defaultdict(int)
    for t in report.ticks:
        pid_counts[t['pid']] += 1

    print("  PID distribution:")
    for pid, count in sorted(pid_counts.items(), key=lambda x: -x[1]):
        pct = 100 * count / len(report.ticks)
        bar = '█' * int(pct / 2)
        label = 'idle' if pid == 0 else f'PID {pid}'
        print(f"    {label:10s}  {count:4d} ({pct:5.1f}%)  {bar}")
    print()


def print_json(report):
    """Output full report as JSON."""
    d = {
        'filename': report.filename,
        'total_lines': report.total_lines,
        'subsystem_counts': dict(report.subsystem_counts),
        'boot_events': len(report.boot_events),
        'hw_events': len(report.hw_events),
        'fs_events': len(report.fs_events),
        'process_events': [{'line': e.line_num, 'subsystem': e.subsystem, 'details': e.details} for e in report.process_events],
        'net_events': len(report.net_events),
        'test_events': [{'line': e.line_num, 'raw': e.raw} for e in report.test_events],
        'errors': [{'line': e.line_num, 'subsystem': e.subsystem, 'raw': e.raw} for e in report.errors],
        'write_summary': {
            'total_inodes': len(report.write_summary),
            'total_bytes': sum(w.total_bytes for w in report.write_summary.values()),
            'total_ops': sum(w.write_count for w in report.write_summary.values()),
            'top_inodes': [asdict(w) for w in sorted(report.write_summary.values(), key=lambda w: -w.total_bytes)[:10]],
        },
        'nvme': {
            'disk_writes': sum(w.disk_writes for w in report.write_summary.values()),
            'timeouts': len([e for e in report.errors if e.details.get('nvme_timeout')]),
        },
        'ticks': {
            'count': len(report.ticks),
            'range': [report.ticks[0]['tick'], report.ticks[-1]['tick']] if report.ticks else None,
            'idle_pct': 100 * sum(1 for t in report.ticks if t['pid'] == 0) / max(len(report.ticks), 1),
        },
    }
    if report.crash:
        c = report.crash
        d['crash'] = {
            'type': c.type, 'far': c.far, 'elr': c.elr, 'esr': c.esr,
            'pid': c.pid, 'lr': c.lr, 'sp': c.sp,
            'registers': c.registers, 'fp_chain': c.fp_chain,
        }
    if report.syscall_trace:
        d['syscall_trace'] = [{
            **s, 'name': SYSCALL_NAMES.get(s['nr'], f"nr_{s['nr']}")
        } for s in report.syscall_trace]
    print(json.dumps(d, indent=2))


def print_diff(old_report, new_report):
    """Compare two log reports and highlight differences."""
    print(f"{'='*60}")
    print(f"  Zigix Log Diff")
    print(f"  OLD: {old_report.filename}")
    print(f"  NEW: {new_report.filename}")
    print(f"{'='*60}\n")

    # Lines
    print(f"  Lines:        {old_report.total_lines} → {new_report.total_lines}")

    # Write volume
    old_bytes = sum(w.total_bytes for w in old_report.write_summary.values())
    new_bytes = sum(w.total_bytes for w in new_report.write_summary.values())
    old_ops = sum(w.write_count for w in old_report.write_summary.values())
    new_ops = sum(w.write_count for w in new_report.write_summary.values())
    print(f"  Write ops:    {old_ops} → {new_ops} ({new_ops - old_ops:+d})")
    print(f"  Data written: {fmt_size(old_bytes)} → {fmt_size(new_bytes)}")

    # NVMe timeouts
    old_to = len([e for e in old_report.errors if e.details.get('nvme_timeout')])
    new_to = len([e for e in new_report.errors if e.details.get('nvme_timeout')])
    marker = ' ✓ FIXED' if old_to > 0 and new_to == 0 else (' ✗ NEW' if new_to > old_to else '')
    print(f"  NVMe timeouts: {old_to} → {new_to}{marker}")

    # Crash comparison
    old_crash = 'YES' if old_report.crash else 'NO'
    new_crash = 'YES' if new_report.crash else 'NO'
    marker = ' ✓ FIXED' if old_report.crash and not new_report.crash else ''
    print(f"  Crash:        {old_crash} → {new_crash}{marker}")

    if old_report.crash and new_report.crash:
        oc, nc = old_report.crash, new_report.crash
        if oc.far != nc.far or oc.elr != nc.elr:
            print(f"    FAR: {oc.far} → {nc.far}")
            print(f"    ELR: {oc.elr} → {nc.elr}")
            print(f"    → DIFFERENT crash signature")
        else:
            print(f"    → SAME crash (FAR={nc.far} ELR={nc.elr})")

    # Subsystem count changes
    all_subs = set(old_report.subsystem_counts) | set(new_report.subsystem_counts)
    changes = []
    for sub in all_subs:
        oc = old_report.subsystem_counts.get(sub, 0)
        nc = new_report.subsystem_counts.get(sub, 0)
        if oc != nc:
            changes.append((sub, oc, nc))
    if changes:
        print(f"\n  Subsystem changes:")
        for sub, oc, nc in sorted(changes, key=lambda x: abs(x[2]-x[1]), reverse=True)[:15]:
            print(f"    {sub:15s}  {oc:6d} → {nc:6d} ({nc-oc:+d})")

    # Process events comparison
    old_procs = [e for e in old_report.process_events if e.subsystem == 'init']
    new_procs = [e for e in new_report.process_events if e.subsystem == 'init']
    old_msgs = {e.details.get('message', '') for e in old_procs}
    new_msgs = {e.details.get('message', '') for e in new_procs}
    new_only = new_msgs - old_msgs
    gone = old_msgs - new_msgs
    if new_only:
        print(f"\n  NEW init messages:")
        for m in sorted(new_only):
            if m:
                print(f"    + {m[:80]}")
    if gone:
        print(f"\n  REMOVED init messages:")
        for m in sorted(gone):
            if m:
                print(f"    - {m[:80]}")

    # Tick comparison
    if old_report.ticks and new_report.ticks:
        old_idle = sum(1 for t in old_report.ticks if t['pid'] == 0) / max(len(old_report.ticks), 1)
        new_idle = sum(1 for t in new_report.ticks if t['pid'] == 0) / max(len(new_report.ticks), 1)
        print(f"\n  Idle %:       {100*old_idle:.0f}% → {100*new_idle:.0f}%")

    print()


SECTIONS = {
    'summary': print_summary,
    'boot': lambda r: print_summary(r),
    'writes': print_writes,
    'crash': print_errors,
    'nvme': print_nvme,
    'syscalls': print_syscalls,
    'ticks': print_ticks,
}


def main():
    parser = argparse.ArgumentParser(description='Zigix serial log analyzer')
    parser.add_argument('logfile', help='Path to serial log file')
    parser.add_argument('--diff', metavar='OLD_LOG', help='Compare against an older log')
    parser.add_argument('--section', choices=list(SECTIONS.keys()) + ['all'],
                        default='all', help='Which section to show')
    parser.add_argument('--json', action='store_true', help='Output as JSON')
    args = parser.parse_args()

    report = analyze_log(args.logfile)

    if args.diff:
        old_report = analyze_log(args.diff)
        print_diff(old_report, report)
        return

    if args.json:
        print_json(report)
        return

    if args.section == 'all':
        print_summary(report)
        print_writes(report)
        print_nvme(report)
        print_errors(report)
        print_syscalls(report)
        print_ticks(report)
    else:
        SECTIONS[args.section](report)


if __name__ == '__main__':
    main()
