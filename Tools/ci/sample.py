#!/usr/bin/env python3
"""CI health check: samples a running app's CPU and memory, taking screenshots along the way.

    sample.py --pid 123 --seconds 150 --label mac-first-launch --out health/mac \
              --phases 0-30,30-90,90-150 --shot-at 25,70,145 --shot 'screencapture -x {path}'

Writes <label>.csv (seconds since start, CPU % over the last interval, resident memory in MB) and
<label>.md (one line per phase), prints the summary and adds it to the GitHub Actions job summary.
CPU comes from the process's accumulated CPU time: 100 % is one core kept busy for the interval.
"""
import argparse
import os
import subprocess
import time


def cpu_seconds(text):
    """ps's accumulated CPU time, "[[dd-]hh:]mm:ss.ss", in seconds."""
    days = 0
    if "-" in text:
        head, text = text.split("-", 1)
        days = int(head)
    seconds = 0.0
    for part in text.split(":"):
        seconds = seconds * 60 + float(part)
    return days * 86400 + seconds


def measure(pid):
    """(CPU seconds so far, resident MB), or None once the process is gone."""
    result = subprocess.run(["ps", "-o", "time=,rss=", "-p", str(pid)], capture_output=True, text=True)
    fields = result.stdout.split()
    if result.returncode != 0 or len(fields) < 2:
        return None
    return cpu_seconds(fields[0]), int(fields[1]) / 1024.0


def footprint(pid):
    """The footprint Activity Monitor shows as Memory ("Footprint: 123 MB"), when the tool can read it."""
    try:
        result = subprocess.run(["footprint", str(pid)], capture_output=True, text=True, timeout=90)
    except (OSError, subprocess.TimeoutExpired):
        return None
    for line in result.stdout.splitlines():
        if "Footprint:" in line:
            return line.split("Footprint:", 1)[1].split("(")[0].strip()
    return None


# Frames where a thread waits rather than works: left out of the busiest frames.
IDLE = ("mach_msg2_trap", "mach_msg_trap", "__psynch_cvwait", "__workq_kernreturn", "kevent_id", "kevent64",
        "__semwait_signal", "__select", "semaphore_wait_trap", "semaphore_timedwait_trap", "__ulock_wait",
        "__ulock_wait2", "poll", "__recvfrom", "__psynch_mutexwait", "__sigsuspend_nocancel", "read")


def stacks(pid, path, binaries):
    """Samples the process's call stacks for 3 s with macOS's `sample` and returns, as text lines, the
    busiest frames (idle waits left out) and the app's own functions most often on the stack."""
    try:
        subprocess.run(["sample", str(pid), "3", "-mayDie", "-file", path], capture_output=True, text=True, timeout=90)
        with open(path) as report:
            text = report.read()
    except (OSError, subprocess.TimeoutExpired):
        return ["(no stack sample)"]
    sections, current = {}, None
    graph = []
    for line in text.splitlines():
        if line.startswith("Call graph:"):
            current = graph
        elif line.startswith("Total number in stack"):
            current = sections.setdefault("inclusive", [])
        elif line.startswith("Sort by top of stack"):
            current = sections.setdefault("top", [])
        elif line.startswith("Binary Images"):
            current = None
        elif not line.strip():
            current = graph if current is graph else None
        elif current is graph:
            graph.append(line)
        elif current is not None:
            current.append(" ".join(line.split()))
    busiest = [l for l in sections.get("top", []) if l.split(" ")[0] not in IDLE][:12]
    ours = [l for l in sections.get("inclusive", []) if any(f"(in {b})" in l for b in binaries)][:15]
    lines = ["Busiest frames (samples at the top of a stack, idle waits left out):", *busiest, "",
             "The app's own functions most often on a stack (samples):", *ours]
    if busiest:
        lines += ["", "Heaviest call path to the busiest frame (outermost first):",
                  *heaviest_path(graph, busiest[0].split(" (in ")[0])]
    return lines


def heaviest_path(graph, symbol):
    """The chain of callers above the call-graph line for `symbol` with the most samples."""
    def depth(line):
        return next((i for i, c in enumerate(line) if c.isdigit()), len(line))

    def count(line):
        digits = line[depth(line):].split(" ", 1)[0]
        return int(digits) if digits.isdigit() else 0

    candidates = [i for i, line in enumerate(graph) if symbol in line]
    if not candidates:
        return ["(not found in the call graph)"]
    target = max(candidates, key=lambda i: count(graph[i]))
    path, level = [graph[target]], depth(graph[target])
    for line in reversed(graph[:target]):
        if depth(line) < level:
            path.append(line)
            level = depth(line)
    path.reverse()
    # The innermost callers say the most: keep the last 28 frames, shortened.
    return [" ".join(line[depth(line):].split())[:160] for line in path[-28:]]


def summary_row(name, rows):
    if not rows:
        return f"| {name} | – | – | – | – |"
    cpu = [r[1] for r in rows]
    memory = [r[2] for r in rows]
    return (f"| {name} | {sum(cpu) / len(cpu):.1f} % | {max(cpu):.0f} % "
            f"| {memory[-1]:.0f} MB | {max(memory):.0f} MB |")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--seconds", type=float, required=True)
    parser.add_argument("--label", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--interval", type=float, default=2.0)
    parser.add_argument("--phases", default="", help="comma-separated start-end windows, in seconds")
    parser.add_argument("--shot", default="", help="screenshot command, {path} is replaced")
    parser.add_argument("--shot-at", default="", help="comma-separated times for the screenshots")
    parser.add_argument("--stacks-at", default="", help="comma-separated times for 3-second stack samples")
    parser.add_argument("--binary", action="append", default=[], help="the app's binary name, for its own frames")
    args = parser.parse_args()
    os.makedirs(args.out, exist_ok=True)

    shots = sorted(float(t) for t in args.shot_at.split(",") if t.strip()) if args.shot else []
    samples = sorted(float(t) for t in args.stacks_at.split(",") if t.strip())
    stack_text = []
    rows = []
    start = time.monotonic()
    previous = None
    tick = start
    while True:
        now = time.monotonic()
        elapsed = now - start
        if elapsed > args.seconds:
            break
        sample = measure(args.pid)
        if sample is None:
            print(f"{args.label}: the process ended after {elapsed:.0f} s")
            break
        cpu, resident = sample
        if previous is not None:
            span = now - previous[0]
            rows.append((elapsed, 100.0 * (cpu - previous[1]) / span if span > 0 else 0.0, resident))
        previous = (now, cpu)
        while shots and elapsed >= shots[0]:
            path = os.path.join(args.out, f"{args.label}-{int(shots.pop(0))}s.png")
            subprocess.run(args.shot.replace("{path}", path), shell=True)
        while samples and elapsed >= samples[0]:
            at = int(samples.pop(0))
            lines = stacks(args.pid, os.path.join(args.out, f"{args.label}-stacks-{at}s.txt"), args.binary)
            stack_text += ["", f"Stacks at {at} s:", "```", *lines, "```"]
            print("\n".join(stack_text[-(len(lines) + 4):]), flush=True)
        tick += args.interval
        time.sleep(max(0.0, tick - time.monotonic()))

    total = footprint(args.pid)
    with open(os.path.join(args.out, f"{args.label}.csv"), "w") as csv:
        csv.write("seconds,cpu_percent,resident_mb\n")
        for t, cpu, resident in rows:
            csv.write(f"{t:.1f},{cpu:.1f},{resident:.1f}\n")

    lines = [f"#### {args.label}", "",
             "| Phase (s) | CPU average | CPU peak | Resident memory at the end | Peak |",
             "|---|---|---|---|---|"]
    for phase in filter(None, (p.strip() for p in args.phases.split(","))):
        low, high = (float(x) for x in phase.split("-"))
        lines.append(summary_row(phase, [r for r in rows if low <= r[0] < high]))
    lines.append(summary_row("whole run", rows))
    if total:
        lines += ["", f"Footprint at the end (Activity Monitor's Memory column): {total}"]
    lines += stack_text
    text = "\n".join(lines) + "\n\n"
    with open(os.path.join(args.out, f"{args.label}.md"), "w") as md:
        md.write(text)
    print(text)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as job:
            job.write(text)


if __name__ == "__main__":
    main()
