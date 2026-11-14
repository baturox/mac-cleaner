#!/usr/bin/env python3
"""mac-cleaner — find and reclaim disk space on macOS.

  mac-cleaner              scan and show what can be reclaimed (deletes nothing)
  mac-cleaner clean        pick categories interactively, confirm, delete
  mac-cleaner clean --safe -y     delete every "safe" category without prompts
  mac-cleaner clean xcode-derived npm --dry-run
  mac-cleaner projects     find node_modules / build dirs in projects you stopped touching
  mac-cleaner why          explain where the disk went (volumes, snapshots, swap, big dirs)

"safe"    = caches the system or tool rebuilds on its own.
"caution" = real data you may want (Trash, backups, archives, Docker images).
"""
import argparse
import glob
import os
import plistlib
import shutil
import stat
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass

HOME = os.path.realpath(os.path.expanduser("~"))
TMP = os.path.realpath(os.environ.get("TMPDIR", "/tmp")).rstrip("/")
VARF = os.path.dirname(TMP) if TMP.startswith("/private/var/folders/") else None
ROOTS = [r for r in (HOME, VARF) if r]
DATA_VOL = "/System/Volumes/Data" if os.path.isdir("/System/Volumes/Data") else "/"

TTY = sys.stdout.isatty()


def c(code, s):
    return f"\033[{code}m{s}\033[0m" if TTY else str(s)


def bold(s): return c("1", s)
def dim(s): return c("2", s)
def green(s): return c("32", s)
def yellow(s): return c("33", s)
def red(s): return c("31", s)


def human(kb):
    if kb is None:
        return "—"
    n = float(kb) * 1024
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if abs(n) < 1024 or unit == "TB":
            return f"{n:.0f} {unit}" if unit in ("B", "KB", "MB") else f"{n:.1f} {unit}"
        n /= 1024


def free_kb():
    return shutil.disk_usage(DATA_VOL).free // 1024


def run(argv, timeout=120):
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout
    except (OSError, subprocess.TimeoutExpired):
        return 1, ""


# ---------------------------------------------------------------- categories

@dataclass
class Cat:
    id: str
    name: str
    level: str                 # "safe" | "caution"
    globs: tuple = ()          # items matched here are deleted
    exclude: tuple = ()        # basenames never deleted
    min_age_days: int = 0      # only items not modified for this long
    cmds: tuple = ()           # commands run on clean
    needs: str = ""            # binary required for cmds
    measure: tuple = ()        # display-only size when there are no globs
    note: str = ""


AS = "~/Library/Application Support"
ELECTRON_DIRS = ("Cache", "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache",
                 "DawnWebGPUCache", "CachedData", "CachedExtensionVSIXs",
                 "Service Worker/CacheStorage", "Service Worker/ScriptCache", "Crashpad/completed")
CHROMIUM = ("Google/Chrome", "BraveSoftware/Brave-Browser", "Microsoft Edge", "Arc/User Data", "Chromium")

CATS = [
    Cat("caches", "User caches (~/Library/Caches)", "safe", ("~/Library/Caches/*",),
        note="includes Homebrew, pip, Go build, Playwright, browser caches"),
    Cat("logs", "User logs & crash reports", "safe",
        ("~/Library/Logs/*", f"{AS}/CrashReporter/*")),
    Cat("temp", "Temp files older than 7 days", "safe",
        (TMP + "/*", "/private/tmp/*") + ((VARF + "/C/*",) if VARF else ()), min_age_days=7),
    Cat("app-caches", "App caches (VS Code, Slack, Chrome, Electron…)", "safe",
        tuple(f"{AS}/*/{d}" for d in ELECTRON_DIRS)
        + tuple(f"{AS}/{b}/*/{d}" for b in CHROMIUM for d in ELECTRON_DIRS)
        + tuple(f"{AS}/{b}/{d}" for b in CHROMIUM for d in ("GrShaderCache", "ShaderCache", "component_crx_cache")),
        note="quit the apps first for a clean result"),
    Cat("xcode-derived", "Xcode DerivedData", "safe",
        ("~/Library/Developer/Xcode/DerivedData/*",), note="next build is a full rebuild"),
    Cat("xcode-support", "Xcode device support files", "safe",
        tuple(f"~/Library/Developer/Xcode/{p} DeviceSupport/*" for p in ("iOS", "watchOS", "tvOS", "visionOS")),
        note="re-created when a device is plugged in"),
    Cat("sim-caches", "Simulator caches", "safe", ("~/Library/Developer/CoreSimulator/Caches/*",)),
    Cat("sim-unavailable", "Simulators for runtimes no longer installed", "safe",
        cmds=(("xcrun", "simctl", "delete", "unavailable"),), needs="xcrun"),
    Cat("npm", "npm / npx cache", "safe", ("~/.npm/_cacache", "~/.npm/_npx", "~/.npm/_logs")),
    Cat("bun", "Bun install cache", "safe", ("~/.bun/install/cache",)),
    Cat("yarn", "Yarn cache", "safe", ("~/.yarn/berry/cache", "~/.yarn/cache")),
    Cat("pnpm", "pnpm store (unreferenced packages)", "safe",
        cmds=(("pnpm", "store", "prune"),), needs="pnpm", measure=("~/Library/pnpm/store",),
        note="size is the whole store; only unused packages go"),
    Cat("cargo", "Cargo registry cache", "safe", ("~/.cargo/registry/cache", "~/.cargo/registry/src")),
    Cat("gradle", "Gradle caches", "safe", ("~/.gradle/caches", "~/.gradle/daemon")),
    Cat("xdg-cache", "~/.cache (misc CLI tools)", "safe", ("~/.cache/*",), exclude=("huggingface",)),
    Cat("brew", "Homebrew old versions", "safe",
        cmds=(("brew", "cleanup", "-s", "--prune=all"),), needs="brew"),
    Cat("snapshots", "Time Machine local snapshots", "safe", needs="tmutil",
        note="deleted data stays on disk until these go"),
    Cat("trash", "Trash", "caution", ("~/.Trash/*",), note="permanent"),
    Cat("xcode-archives", "Xcode archives", "caution", ("~/Library/Developer/Xcode/Archives/*",),
        note="needed to symbolicate crashes of shipped builds"),
    Cat("ios-backups", "iPhone/iPad local backups", "caution", (f"{AS}/MobileSync/Backup/*",)),
    Cat("go-mod", "Go module cache", "caution", cmds=(("go", "clean", "-modcache"),), needs="go",
        measure=("~/go/pkg/mod",), note="re-downloaded on next build"),
    Cat("hf-models", "Hugging Face downloaded models", "caution", ("~/.cache/huggingface/hub/*",)),
    Cat("docker", "Docker unused images, containers, build cache", "caution",
        cmds=(("docker", "system", "prune", "-af"), ("docker", "builder", "prune", "-af")), needs="docker",
        measure=("~/Library/Containers/com.docker.docker/Data/vms/*/data/Docker.raw",),
        note="size is the whole Docker disk; volumes are kept"),
]


def expand(pattern):
    """Glob that includes dotfiles for a trailing /*."""
    pattern = os.path.expanduser(pattern)
    if pattern.endswith("/*"):
        out = []
        for parent in glob.glob(pattern[:-2]):
            try:
                out += [os.path.join(parent, n) for n in os.listdir(parent)]
            except OSError:
                pass
        return out
    return glob.glob(pattern)


def items_of(cat):
    cutoff = time.time() - cat.min_age_days * 86400
    out = []
    for g in cat.globs:
        for p in expand(g):
            if os.path.basename(p) in cat.exclude:
                continue
            if cat.min_age_days:
                try:
                    if os.lstat(p).st_mtime > cutoff:
                        continue
                except OSError:
                    continue
            out.append(p)
    return out


def du_kb(paths):
    total = 0
    for i in range(0, len(paths), 200):
        _, out = run(["du", "-skx", "--"] + paths[i:i + 200], timeout=900)
        for line in out.splitlines():
            size = line.split("\t", 1)[0]
            if size.isdigit():
                total += int(size)
    return total


def tm_snapshots():
    _, out = run(["tmutil", "listlocalsnapshotdates", "/"])
    return [l.strip() for l in out.splitlines() if l[:2].isdigit()]


def available(cat):
    if cat.id == "snapshots":
        return bool(tm_snapshots())
    if cat.needs and not shutil.which(cat.needs):
        return False
    if cat.id == "docker":
        return run(["docker", "info"], timeout=8)[0] == 0
    return True


@dataclass
class Found:
    cat: Cat
    items: list
    kb: object      # int or None (unknown)
    approx: bool    # size is an upper bound, not what will be freed


def measure(cat):
    if not available(cat):
        return None
    items = items_of(cat)
    if cat.globs:
        if not items and not cat.cmds:
            return None
        return Found(cat, items, du_kb(items), False)
    shown = [p for g in cat.measure for p in expand(g)]
    return Found(cat, [], du_kb(shown) if shown else None, True)


def scan():
    print(dim("Scanning…"), end="\r", flush=True)
    with ThreadPoolExecutor(8) as ex:
        found = [f for f in ex.map(measure, CATS) if f]
    found = [f for f in found if f.kb is None or f.kb >= 1024 or f.cat.cmds or f.cat.id == "snapshots"]
    found.sort(key=lambda f: (f.approx, -(f.kb or 0)))
    return found


def show(found):
    total, used, free = shutil.disk_usage(DATA_VOL)
    print(f"{bold('Disk')}  {human(free // 1024)} free of {human(total // 1024)}"
          f"  ({100 * free / total:.1f}% free)\n")
    print(bold(f"{'#':>3}  {'size':>9}  {'level':<8} {'id':<16} what"))
    for i, f in enumerate(found, 1):
        size = ("≤" if f.approx and f.kb else "") + human(f.kb)
        lvl = green("safe    ") if f.cat.level == "safe" else yellow("caution ")
        note = dim(f"  — {f.cat.note}") if f.cat.note else ""
        print(f"{i:>3}  {size:>9}  {lvl} {f.cat.id:<16} {f.cat.name}{note}")
    safe = sum(f.kb or 0 for f in found if f.cat.level == "safe" and not f.approx)
    caution = sum(f.kb or 0 for f in found if f.cat.level == "caution" and not f.approx)
    print(f"\nReclaimable: {bold(green(human(safe)))} safe, plus {yellow(human(caution))} "
          f"that needs a look. (≤ and — rows not counted.)")


# ------------------------------------------------------------------ deleting

def deletable(path):
    """Only allow paths at least two levels below $HOME or the per-user temp root."""
    path = os.path.abspath(path)
    full = os.path.join(os.path.realpath(os.path.dirname(path)), os.path.basename(path))
    for root in ROOTS:
        if full.startswith(root + "/"):
            return len(os.path.relpath(full, root).split("/")) >= 2
    return full.startswith("/private/tmp/")


def remove(path):
    """Delete a file or tree. Returns number of entries that could not be removed."""
    if not deletable(path):
        print(red(f"  refused (outside allowed area): {path}"))
        return 1
    failed = 0

    def retry(func, p, _exc):
        nonlocal failed
        try:
            os.chmod(os.path.dirname(p), stat.S_IRWXU)
            if not os.path.islink(p):
                os.chmod(p, stat.S_IRWXU)
            func(p)
        except OSError:
            failed += 1

    try:
        if os.path.islink(path) or not os.path.isdir(path):
            os.unlink(path)
        elif sys.version_info >= (3, 12):
            shutil.rmtree(path, onexc=retry)
        else:
            shutil.rmtree(path, onerror=retry)
    except OSError:
        failed += 1
    return failed


def clean(found, dry):
    before = free_kb()
    failed = 0
    for f in found:
        size = "" if f.kb is None or f.approx else f" ({human(f.kb)})"
        print(f"{bold('→')} {f.cat.name}{size}")
        if dry:
            for p in f.items[:5]:
                print(dim(f"    would delete {p}"))
            if len(f.items) > 5:
                print(dim(f"    … and {len(f.items) - 5} more"))
            for cmd in f.cat.cmds:
                print(dim(f"    would run    {' '.join(cmd)}"))
            continue
        for p in f.items:
            failed += remove(p)
        if f.cat.id == "snapshots":
            for date in tm_snapshots():
                code, _ = run(["tmutil", "deletelocalsnapshots", date])
                if code:
                    print(yellow(f"    could not delete snapshot {date} — try: sudo tmutil deletelocalsnapshots {date}"))
        for cmd in f.cat.cmds:
            try:
                p = subprocess.run(cmd, capture_output=True, text=True, timeout=1800)
                tail = (p.stdout + p.stderr).strip().splitlines()[-1:] or [""]
                print(dim(f"    {' '.join(cmd)}: {tail[0][:100]}"))
            except (OSError, subprocess.TimeoutExpired) as e:
                print(yellow(f"    {' '.join(cmd)} failed: {e}"))
    if dry:
        print(dim("\nDry run — nothing was deleted."))
        return
    time.sleep(1)
    after = free_kb()
    print(f"\n{bold(green('Freed ' + human(max(after - before, 0))))} — {human(after)} free now.")
    if failed:
        print(dim(f"{failed} entries were skipped (in use or protected by macOS; that is normal)."))
    if after - before < sum(f.kb or 0 for f in found if not f.approx) * 0.5:
        print(dim("Less than expected? macOS releases space lazily, and snapshots keep deleted "
                  "data alive. Run `mac-cleaner why`."))


def pick(found, prompt_extra=""):
    """Parse '1,3-5' / 'safe' / 'all' into a selection."""
    try:
        ans = input(f"\nDelete which? numbers like 1,3-5{prompt_extra}, 'all', or Enter to cancel: ").strip().lower()
    except (EOFError, KeyboardInterrupt):
        print()
        return []
    if not ans or ans in ("q", "n", "no"):
        return []
    if ans == "all":
        return list(found)
    if ans == "safe":
        return [f for f in found if getattr(getattr(f, "cat", None), "level", "") == "safe"]
    chosen = []
    for part in ans.replace(" ", "").split(","):
        lo, _, hi = part.partition("-")
        if not lo.isdigit() or (hi and not hi.isdigit()):
            print(red(f"Didn't understand '{part}'."))
            return []
        for i in range(int(lo), int(hi or lo) + 1):
            if 1 <= i <= len(found) and found[i - 1] not in chosen:
                chosen.append(found[i - 1])
    return chosen


def confirm(question):
    try:
        return input(f"{question} [y/N] ").strip().lower() in ("y", "yes")
    except (EOFError, KeyboardInterrupt):
        print()
        return False


def cmd_clean(args):
    known = {cat.id for cat in CATS}
    bad = [i for i in args.ids if i not in known]
    if bad:
        sys.exit(f"Unknown category: {', '.join(bad)}\nKnown: {', '.join(sorted(known))}")
    found = scan()
    if args.ids:
        chosen = [f for f in found if f.cat.id in args.ids]
    elif args.all:
        chosen = found
    elif args.safe:
        chosen = [f for f in found if f.cat.level == "safe"]
    else:
        show(found)
        chosen = pick(found, ", 'safe'")
    if not chosen:
        print("Nothing selected.")
        return
    if not args.dry_run and not args.yes:
        total = sum(f.kb or 0 for f in chosen if not f.approx)
        print(f"\nAbout to delete {bold(human(total))} from: {', '.join(f.cat.id for f in chosen)}")
        risky = [f.cat.id for f in chosen if f.cat.level == "caution"]
        if risky:
            print(yellow(f"Includes data that is not rebuilt automatically: {', '.join(risky)}"))
        if not confirm("Proceed?"):
            print("Cancelled.")
            return
    clean(chosen, args.dry_run)


# ------------------------------------------------------------------ projects

ALWAYS = {"node_modules"}
WITH_SIBLING = {
    ".next": ("package.json",), ".nuxt": ("package.json",), ".turbo": ("package.json",),
    ".svelte-kit": ("package.json",), ".parcel-cache": ("package.json",), ".expo": ("package.json",),
    "target": ("Cargo.toml",), "Pods": ("Podfile",),
    "build": ("build.gradle", "build.gradle.kts", "pubspec.yaml"),
    ".gradle": ("build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"),
    ".dart_tool": ("pubspec.yaml",),
}
VENVS = {".venv", "venv", "env"}
SKIP_TOP = {"Library", "Applications", "Pictures", "Music", "Movies", "Public"}


def is_artifact(parent, name, siblings):
    if name in ALWAYS:
        return True
    if name in WITH_SIBLING:
        return any(s in siblings for s in WITH_SIBLING[name])
    if name in VENVS:
        return os.path.isfile(os.path.join(parent, name, "pyvenv.cfg"))
    return False


def last_touched(project, artifacts):
    newest = 0
    try:
        names = [n for n in os.listdir(project) if n not in artifacts]
    except OSError:
        return 0
    paths = [os.path.join(project, n) for n in names]
    paths += [os.path.join(project, ".git", n) for n in ("index", "HEAD", "logs/HEAD")]
    paths += glob.glob(os.path.join(project, "src", "*"))[:200]
    for p in paths:
        try:
            newest = max(newest, os.lstat(p).st_mtime)
        except OSError:
            pass
    return newest


@dataclass
class Artifact:
    path: str
    kb: int
    age_days: int
    items: list
    approx: bool = False


def cmd_projects(args):
    root = os.path.realpath(os.path.expanduser(args.root))
    print(dim(f"Looking for build artifacts under {root} …"))
    hits = []
    for parent, dirs, files in os.walk(root):
        siblings = set(files) | set(dirs)
        matched = {d for d in dirs if is_artifact(parent, d, siblings)}
        if matched:
            hits.append((parent, matched))
        dirs[:] = [d for d in dirs if d not in matched and not d.startswith(".")
                   and not (parent == HOME and d in SKIP_TOP)
                   and not os.path.islink(os.path.join(parent, d))]
    now = time.time()
    stale = []
    for project, matched in hits:
        age = int((now - last_touched(project, matched)) / 86400)
        if age >= args.days:
            stale += [(os.path.join(project, m), age) for m in matched]
    with ThreadPoolExecutor(8) as ex:
        sizes = list(ex.map(lambda s: du_kb([s[0]]), stale))
    arts = [Artifact(p, kb, age, [p]) for (p, age), kb in zip(stale, sizes) if kb >= args.min_mb * 1024]
    arts.sort(key=lambda a: -a.kb)
    if not arts:
        print(f"No build artifacts ≥ {args.min_mb} MB in projects untouched for {args.days}+ days.")
        return
    print(bold(f"\n{'#':>3}  {'size':>9}  {'idle':>6}  path"))
    for i, a in enumerate(arts, 1):
        print(f"{i:>3}  {human(a.kb):>9}  {a.age_days:>4} d  {a.path.replace(HOME, '~', 1)}")
    print(f"\nTotal: {bold(green(human(sum(a.kb for a in arts))))} in {len(arts)} folders "
          f"from projects untouched for {args.days}+ days. All are rebuilt by install/build.")
    if args.dry_run:
        return
    chosen = arts if args.yes else pick(arts)
    if not chosen:
        print("Nothing selected.")
        return
    if not args.yes and not confirm(f"Delete {len(chosen)} folders ({human(sum(a.kb for a in chosen))})?"):
        print("Cancelled.")
        return
    before = free_kb()
    failed = sum(remove(a.path) for a in chosen)
    time.sleep(1)
    print(f"{bold(green('Freed ' + human(max(free_kb() - before, 0))))} — {human(free_kb())} free now."
          + (dim(f" ({failed} entries skipped)") if failed else ""))


# ----------------------------------------------------------------------- why

def cmd_why(args):
    total, _, free = shutil.disk_usage(DATA_VOL)
    print(f"{bold('Disk')}  {human(free // 1024)} free of {human(total // 1024)}\n")

    print(bold("APFS volumes sharing this disk"))
    try:
        raw = subprocess.run(["diskutil", "apfs", "list", "-plist"], capture_output=True, timeout=60).stdout
        for cont in plistlib.loads(raw)["Containers"]:
            vols = cont.get("Volumes", [])
            if not any("System" in v.get("Roles", []) for v in vols):
                continue
            for v in sorted(vols, key=lambda v: -v.get("CapacityInUse", 0)):
                role = "/".join(v.get("Roles", [])) or "-"
                print(f"  {human(v.get('CapacityInUse', 0) // 1024):>9}  {v.get('Name', '?')} {dim('(' + role + ')')}")
            print(f"  {human(cont.get('CapacityFree', 0) // 1024):>9}  {green('unallocated')}")
    except Exception as e:
        print(dim(f"  (could not read APFS layout: {e})"))

    print(bold("\nSnapshots") + dim("  (pin deleted data on disk until they are removed)"))
    _, out = run(["tmutil", "listlocalsnapshots", "/"])
    snaps = [l.strip() for l in out.splitlines() if l.startswith("com.")]
    for s in snaps:
        kind = "macOS update — goes away once the pending update is installed" if "os.update" in s \
            else "Time Machine — `mac-cleaner clean snapshots`"
        print(f"  {s[:60]}  {dim(kind)}")
    if not snaps:
        print(dim("  none"))

    try:
        swap = sum(os.path.getsize(os.path.join("/private/var/vm", n)) for n in os.listdir("/private/var/vm"))
        print(bold("\nSwap / sleep image") + f"  {human(swap // 1024)}"
              + dim("  (shrinks after a reboot; grows when RAM is exhausted)"))
    except OSError:
        pass

    print(dim(f"\nMeasuring folders and looking for big recent files (last {args.days} days) — takes a few minutes…"))
    tops = [HOME, os.path.join(HOME, "Library"), os.path.join(HOME, "Library/Application Support"),
            os.path.join(HOME, "Library/Containers"), os.path.join(HOME, "Library/Developer")]

    def children(d):
        _, out = run(["du", "-kxd1", d], timeout=1800)
        rows = []
        for line in out.splitlines():
            size, _, path = line.partition("\t")
            if size.isdigit() and path != d:
                rows.append((int(size), path))
        return sorted(rows, reverse=True)[:args.top]

    def recent():
        _, out = run(["find", HOME, "/private/var/vm", "/private/tmp", "-xdev", "-type", "f",
                      "-size", "+300M", "-mtime", f"-{args.days}"], timeout=1800)
        rows = []
        for p in out.splitlines():
            try:
                st = os.lstat(p)
                rows.append((st.st_blocks * 512 // 1024, st.st_mtime, p))
            except OSError:
                pass
        return sorted(rows, reverse=True)[:args.top]

    with ThreadPoolExecutor(6) as ex:
        recent_f = ex.submit(recent)
        results = list(ex.map(children, tops))
    for d, rows in zip(tops, results):
        print(bold(f"\nLargest in {d.replace(HOME, '~', 1)}"))
        for kb, path in rows:
            if kb >= 512 * 1024:
                print(f"  {human(kb):>9}  {path.replace(HOME, '~', 1)}")
    print(bold(f"\nFiles over 300 MB written in the last {args.days} days") + dim("  (what just ate the space)"))
    for kb, mtime, path in recent_f.result():
        print(f"  {human(kb):>9}  {time.strftime('%b %d %H:%M', time.localtime(mtime))}  {path.replace(HOME, '~', 1)}")


# ---------------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(prog="mac-cleaner", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd")
    sub.add_parser("scan", help="show what can be reclaimed (default)")
    p = sub.add_parser("clean", help="delete selected categories")
    p.add_argument("ids", nargs="*", help="category ids (see scan)")
    p.add_argument("--safe", action="store_true", help="all safe categories")
    p.add_argument("--all", action="store_true", help="everything, including caution")
    p.add_argument("-y", "--yes", action="store_true", help="do not ask for confirmation")
    p.add_argument("-n", "--dry-run", action="store_true", help="show what would happen")
    p = sub.add_parser("projects", help="stale node_modules / build folders")
    p.add_argument("root", nargs="?", default="~")
    p.add_argument("--days", type=int, default=30, help="project untouched for this long (default 30)")
    p.add_argument("--min-mb", type=int, default=50)
    p.add_argument("-y", "--yes", action="store_true")
    p.add_argument("-n", "--dry-run", action="store_true", help="list only")
    p = sub.add_parser("why", help="explain where the disk space went")
    p.add_argument("--days", type=int, default=7)
    p.add_argument("--top", type=int, default=12)
    args = ap.parse_args()
    if sys.platform != "darwin":
        sys.exit("mac-cleaner only runs on macOS.")
    try:
        if args.cmd == "clean":
            cmd_clean(args)
        elif args.cmd == "projects":
            cmd_projects(args)
        elif args.cmd == "why":
            cmd_why(args)
        else:
            show(scan())
            print(dim("Run `mac-cleaner clean` to choose what to delete."))
    except KeyboardInterrupt:
        print("\nInterrupted.")


if __name__ == "__main__":
    main()
