#!/usr/bin/env python3
"""Turn a macOS arm64 .app into a signed iOS .app that runs the same binaries.

usage: convert_app.py <Mac.app> <out.app> <bundle-id> [--profile P] [--identity I]

1. Copies the Mac app into <out.app>/Mac/Contents (layout kept), puts the main executable
   at the bundle root and rewrites @executable_path/../ to @executable_path/Mac/Contents/.
2. Thins every Mach-O to arm64 and retags it as iOS.
3. For every system library the binaries link: keep the iOS library when it exports
   everything used; otherwise link a generated shim (Frameworks/libShim_<Name>.dylib)
   that re-exports the iOS library and adds logging stubs for what iOS lacks.
   Hand-written code in shim/overrides/<Name>.m and <Name>_*.m is compiled into that
   library's shim and replaces generated stubs (AppKit.m is the UIKit-backed AppKit).
4. Writes Info.plist (Mac keys + iOS keys), signs everything.
"""
import glob, argparse, os, plistlib, re, shutil, subprocess, sys
from collections import defaultdict

MAC_ROOT = "Mac"
# C globals (constants) by Apple naming convention; any other plain symbol is a function.
DATA_NAME = re.compile(r"^_(k[A-Z_]|NS\w*(Notification|ColorSpace|PasteboardType\w*|Key|RunLoopMode)$|NS\w*Hint\w*|NSFontWeight|NSApp$)")
# Data symbols that are NSString/CFStringRef constants; other data stubs are zero-filled.
STRING_CONSTANT = re.compile(r"Notification|Key|Property|Type|Name|ColorSpace|Pasteboard|RunLoopMode|Hint|kSecOID|kCFNetwork|kCGDisplay|kTIS")
HERE = os.path.dirname(os.path.abspath(__file__))
SHIM_DIR = os.path.join(HERE, "..", "shim")
sys.path.insert(0, HERE)
import gap  # noqa: E402
from macho import align_string_pool

SDK = gap.SDK
MACHO_MAGICS = {b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"}
# Mac libraries with no iOS counterpart that should re-export a different iOS library.
REEXPORT_INSTEAD = {"AudioUnit": "/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox",
                    "Cocoa": "@rpath/libShim_AppKit.dylib"}


def run(*cmd, **kw):
    r = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if r.returncode:
        sys.exit(f"FAILED: {' '.join(cmd[:6])}...\n{r.stderr[-3000:]}")
    return r.stdout


def is_macho(path):
    try:
        with open(path, "rb") as f:
            return f.read(4) in MACHO_MAGICS
    except OSError:
        return False


def ios_path(mac_path, names=None):
    """iOS install name for a macOS library path (some, like IOKit, keep Versions/A on iOS)."""
    if names is not None and mac_path in names:
        return mac_path
    return re.sub(r"(\w+)\.framework/Versions/\w+/\1$", r"\1.framework/\1", mac_path)


def flatten_framework(fw):
    """Mac framework (Versions/A/{binary,Resources/Info.plist} + symlinks) -> iOS flat layout
    (binary and Info.plist at the root); codesign rejects the half-converted mix as ambiguous."""
    cur = os.path.join(fw, "Versions", "Current")
    if not os.path.isdir(cur):
        return
    real = os.path.realpath(cur)
    for n in os.listdir(fw):
        if os.path.islink(os.path.join(fw, n)):
            os.remove(os.path.join(fw, n))
    for n in os.listdir(real):
        shutil.move(os.path.join(real, n), os.path.join(fw, n))
    shutil.rmtree(os.path.join(fw, "Versions"))
    plist = os.path.join(fw, "Resources", "Info.plist")
    if os.path.exists(plist):
        shutil.move(plist, os.path.join(fw, "Info.plist"))
    shutil.rmtree(os.path.join(fw, "_CodeSignature"), ignore_errors=True)


def lib_name(path):
    return os.path.basename(path).split(".")[0]


def dependents(binary):
    out = subprocess.run(["xcrun", "dyld_info", "-arch", "arm64", "-dependents", binary],
                         capture_output=True, text=True).stdout  # fails on dependency-free bundles
    paths = re.findall(r"^[ \t]+(?:\S+[ \t]+)?([/@]\S+)$", out, re.M)
    return [p for p in paths if p.startswith(("/System/", "/usr/lib/", "@"))]  # skip rpath lines


def classify(symbols_by_lib):
    """{(macpath, sym): kind} using the real macOS libraries."""
    tool = os.path.join(TMP, "macinfo")
    if not os.path.exists(tool):
        run("xcrun", "-sdk", "macosx", "clang", "-fobjc-arc", "-framework", "Foundation",
            os.path.join(HERE, "macinfo.m"), "-o", tool)
    lines = [f"{lib} {sym}" for lib, syms in symbols_by_lib.items() for sym in sorted(syms)]
    out = subprocess.run([tool], input="\n".join(lines) + "\n", capture_output=True, text=True).stdout
    kinds, result = {}, out.splitlines()
    i = 0
    for lib, syms in symbols_by_lib.items():
        for sym in sorted(syms):
            kind = result[i].split(" ", 1)[1]
            i += 1
            # macinfo's executable-page test can't see into the shared cache (reports
            # everything as data), so functions vs data comes from Apple's naming rules.
            if not kind.startswith("class"):
                kind = "data" if DATA_NAME.search(sym) else "func"
            kinds[(lib, sym)] = kind
    return kinds


def linkable_owner(idx, sym):
    """A public iOS library (framework or /usr/lib/*.dylib) that provides sym, or None."""
    cands = [n for n in idx.names if (".framework/" in n and "/PrivateFrameworks/" not in n and "/SubFrameworks/" not in n)
             or re.fullmatch(r"/usr/lib/[^/]+\.dylib", n)]
    hits = [n for n in cands if sym in idx.owners and idx.owners[sym] & idx.tree(n)]
    return min(hits, key=len) if hits else None


def overrides(name):
    d = os.path.join(SHIM_DIR, "overrides")
    return sorted(os.path.join(d, f) for f in os.listdir(d)
                  if f == f"{name}.m" or (f.startswith(f"{name}_") and f.endswith(".m")))


def handwritten(name):
    """(classes, symbols) defined by the hand-written override sources for a library."""
    classes, syms = {}, set()
    for src in overrides(name):
        classes.update(re.findall(r"@interface (\w+) : (\w+)", open(src).read()))
        obj = os.path.join(TMP, os.path.basename(src) + ".o")
        run("xcrun", "-sdk", "iphoneos", "clang", "-fobjc-arc", "-target", "arm64-apple-ios17.0", "-c", src, "-o", obj)
        syms |= set(run("nm", "-gUj", obj).split())
    return classes, syms


def gen_stub_source(name, items, kinds, skip_classes):
    """Objective-C source with one stub per missing symbol."""
    out = ['#import <Foundation/Foundation.h>', '#import <objc/runtime.h>',
           'static id ShimStubIMP(id self, SEL _cmd, ...) { return nil; }',
           'static id ShimStubInit(id self, SEL _cmd, ...) { return self; }',
           'static BOOL ShimStubResolve(Class c, SEL s, BOOL meta) {',
           '    NSLog(@"SHIM MISSING %c[%@ %@]", meta ? \'+\' : \'-\', NSStringFromClass(c), NSStringFromSelector(s));',
           '    BOOL init = !meta && [NSStringFromSelector(s) hasPrefix:@"init"];',
           '    class_addMethod(meta ? object_getClass(c) : c, s, (IMP)(init ? ShimStubInit : ShimStubIMP), "@@:"); return YES; }']
    classes = {}
    for i, sym in enumerate(sorted(items)):
        kind = kinds.get(sym, "func")
        if sym.startswith("_OBJC_METACLASS_$_") or sym.startswith("_OBJC_EHTYPE_$_"):
            continue  # emitted with the class
        if sym.startswith("_OBJC_CLASS_$_"):
            cls = sym[len("_OBJC_CLASS_$_"):]
            if cls not in skip_classes:
                classes[cls] = kind.split()[1] if kind.startswith("class ") else "NSObject"
            continue
        if kind == "data" and STRING_CONSTANT.search(sym):
            out.append(f'__attribute__((visibility("default"))) NSString *shim_d{i} __asm__("{sym}") = @"{sym[1:]}";')
        elif kind == "data":  # numbers/ports/structs: zero (e.g. kIOMasterPortDefault = MACH_PORT_NULL = default)
            out.append(f'__attribute__((visibility("default"))) char shim_d{i}[64] __asm__("{sym}") = {{0}};')
        else:
            out.append(f'__attribute__((visibility("default"))) void *shim_f{i}(void) __asm__("{sym}");')
            out.append(f'void *shim_f{i}(void) {{ static int n; if (!n++) NSLog(@"SHIM STUB {name} {sym[1:]}"); return 0; }}')
    # Classes, superclasses first (only when the superclass is also generated here).
    # Re-declare hand-written classes (superclasses first) so generated subclasses compile.
    declared = {"NSObject", "NSProxy"}
    def declare(cls):
        if cls in declared or cls not in skip_classes or not cls.startswith("NS"):  # AppKit classes only
            return
        declare(skip_classes[cls])
        declared.add(cls)
        out.append(f"@interface {cls} : {skip_classes[cls]} @end")
    for cls in skip_classes:
        declare(cls)
    done = set(skip_classes)
    def emit(cls):
        if cls in done:
            return
        sup = classes[cls]
        if sup in classes:
            emit(sup)
        elif sup not in done and not hasattr_foundation(sup):
            sup = "NSObject"
        done.add(cls)
        out.append(f'__attribute__((visibility("default"))) @interface {cls} : {sup} @end')
        out.append(f'@implementation {cls}\n+ (BOOL)resolveInstanceMethod:(SEL)s {{ return [super resolveInstanceMethod:s] || ShimStubResolve(self, s, NO); }}'
                   f'\n+ (BOOL)resolveClassMethod:(SEL)s {{ return [super resolveClassMethod:s] || ShimStubResolve(self, s, YES); }}\n@end')
    for cls in list(classes):
        emit(cls)
    return "\n".join(out) + "\n"


def hasattr_foundation(cls):
    return cls in ("NSObject", "NSProxy")


def main():
    global TMP
    ap = argparse.ArgumentParser()
    ap.add_argument("mac_app"); ap.add_argument("out_app"); ap.add_argument("bundle_id")
    ap.add_argument("--profile", required=True)
    ap.add_argument("--identity", default=os.environ.get("IDENTITY"), required="IDENTITY" not in os.environ,
                    help='signing identity, e.g. "Apple Development: Name (ABCDE12345)" (or env IDENTITY)')
    ap.add_argument("--team", default=os.environ.get("TEAM"), required="TEAM" not in os.environ,
                    help="Apple developer Team ID (or env TEAM)")
    ap.add_argument("--exclude", action="append", default=[], help="path under Contents/ to leave out")
    ap.add_argument("--allow-network", action="store_true", help="don't block URL loading (blocked by default)")
    ap.add_argument("--no-controller-replay", action="store_true",
                    help="don't re-announce connected controllers after launch (it double-binds some games)")
    ap.add_argument("--no-metal-hud", action="store_true", help="don't show Apple's Metal performance HUD")
    ap.add_argument("--trace", action="append", default=[], metavar="CLASS.SELECTOR",
                    help="log calls to a game method (void, <= 4 args), e.g. GameView.mouseDown:")
    ap.add_argument("--redirect-app-parent", metavar="HOME_REL",
                    help="paths next to the .app (games that keep data beside it) go to <home>/HOME_REL")
    ap.add_argument("--report-memory-gb", type=float, help="RAM size reported to the app (hw.memsize, physicalMemory)")
    ap.add_argument("--bounded-reservations", "--shrink-reservations", action="store_true",
                    help="quarter large reservations only in recognized arm64 reserve helpers, updating their returned bounds")
    ap.add_argument("--keep-original", action="append", default=[], metavar="LIB",
                    help="don't swap in shim/replace/<LIB>.m for this app (keep the app's own copy)")
    ap.add_argument("--entitlement", action="append", default=[], metavar="KEY",
                    help="extra boolean entitlement (needs a matching explicit-App-ID profile), e.g. "
                         "com.apple.developer.kernel.increased-memory-limit")
    ap.add_argument("--redirect", action="append", default=[], metavar="PATH_PART=HOME_REL",
                    help="rewrite file paths containing PATH_PART to <home>/HOME_REL (e.g. /Resources/Packages=Documents/packages)")
    a = ap.parse_args()
    out = os.path.abspath(a.out_app)
    TMP = os.path.dirname(out)

    # 1. Copy + layout
    shutil.rmtree(out, ignore_errors=True)
    os.makedirs(out)
    # Mac tree lives in <app>/Mac/Contents (iOS signing rejects a root Contents/); the shim
    # reports <app>/Mac as the bundle path so the game finds Contents/Resources/Data as on macOS.
    contents = os.path.join(out, MAC_ROOT, "Contents")
    src = os.path.join(a.mac_app, "Contents")
    skip = {os.path.normpath(os.path.join(src, e)) for e in a.exclude}  # e.g. huge data dirs pushed separately
    shutil.copytree(src, contents, symlinks=True,
                    ignore=lambda d, names: [n for n in names if os.path.join(d, n) in skip])
    for d, dirs, _ in os.walk(contents):
        for f in dirs:
            if f.endswith(".framework"):
                flatten_framework(os.path.join(d, f))
    mac_plist = plistlib.load(open(os.path.join(contents, "Info.plist"), "rb"))
    # codesign treats a root-level Contents/ with its own Info.plist/signature as an unsealed nested bundle
    os.remove(os.path.join(contents, "Info.plist"))
    shutil.rmtree(os.path.join(contents, "_CodeSignature"), ignore_errors=True)
    exe = mac_plist["CFBundleExecutable"]
    shutil.move(os.path.join(contents, "MacOS", exe), os.path.join(out, exe))
    os.makedirs(os.path.join(out, "Frameworks"), exist_ok=True)

    machos = [os.path.join(d, f) for d, _, fs in os.walk(out) for f in fs if is_macho(os.path.join(d, f))]
    print(f"{len(machos)} Mach-O files")

    # 2. Thin + retag
    for m in machos:
        if "arm64" not in run("lipo", "-archs", m).split():
            sys.exit(f"no arm64 slice: {m}")
        if len(run("lipo", "-archs", m).split()) > 1:
            run("lipo", "-thin", "arm64", m, "-output", m)
        run("vtool", "-set-build-version", "ios", "17.0", "27.1", "-replace", "-output", m, m)
        if align_string_pool(m):  # before dependency analysis, which can't read misaligned files
            print(f"aligned LINKEDIT string pool: {os.path.relpath(m, out)}")

    # App libraries with a stand-in in shim/replace/<name>.m are rebuilt for iOS (none ship with this repo).
    for m in machos:
        src = os.path.join(SHIM_DIR, "replace", lib_name(m) + ".m")
        if os.path.exists(src) and lib_name(m) not in a.keep_original:
            install = run("otool", "-D", m).splitlines()[-1].strip()
            extra = sorted(glob.glob(os.path.join(SHIM_DIR, "replace", lib_name(m) + "_*.m")))
            run("xcrun", "-sdk", "iphoneos", "clang", "-fobjc-arc", "-target", "arm64-apple-ios17.0", "-dynamiclib",
                "-install_name", install, "-framework", "Foundation", "-framework", "GameController", src, *extra, "-o", m)
            print(f"replaced {os.path.relpath(m, out)} with {os.path.basename(src)}")

    # 3. Gap analysis across all binaries
    idx = gap.IOSIndex()
    ios_names = idx.names
    missing = defaultdict(set)          # mac lib path -> symbols iOS lacks entirely (stubbed)
    foreign = defaultdict(set)          # mac lib path -> iOS libs to re-export for symbols that moved
    def target_of(p):
        t = REEXPORT_INSTEAD.get(lib_name(p)) or ios_path(p, ios_names)
        return t if t in ios_names or t.startswith("@rpath/") else None
    deps = {m: dependents(m) for m in machos}
    by_name = {}
    for m in machos:
        for dep in deps[m]:
            if dep.startswith("/"):
                by_name[lib_name(dep)] = dep
        for lib, sym, weak in gap.imports(m):
            if lib.startswith("<") or lib not in by_name:
                continue
            p = by_name[lib]
            t = target_of(p)
            if t and not t.startswith("@rpath/") and idx.provides(t, sym):
                continue
            home = linkable_owner(idx, sym)
            if home:
                foreign[p].add(home)
            else:
                missing[p].add(sym)
    system_libs = {d for ds in deps.values() for d in ds if d.startswith("/")}
    needs_shim = {p for p in system_libs if missing[p] or foreign[p] or not target_of(p) or lib_name(p) in REEXPORT_INSTEAD
                  or lib_name(p) in ("AppKit", "Cocoa")}
    kinds = classify({p: missing[p] for p in needs_shim if missing[p]})

    # Build shims
    needs_shim |= {p for p in system_libs if overrides(lib_name(p))}
    hand = {p: handwritten(lib_name(p)) for p in needs_shim}
    for p in needs_shim:
        missing[p] -= hand[p][1]
    shim_dir = os.path.join(TMP, "shims"); os.makedirs(shim_dir, exist_ok=True)
    order = sorted(needs_shim, key=lambda p: lib_name(p) == "Cocoa")  # AppKit before Cocoa
    for p in order:
        name = lib_name(p)
        dylib = os.path.join(out, "Frameworks", f"libShim_{name}.dylib")
        src = os.path.join(shim_dir, f"Shim_{name}.m")
        open(src, "w").write(gen_stub_source(name, missing[p], {s: kinds[(p, s)] for s in missing[p]},
                                             hand[p][0]))
        srcs = [src] + overrides(name)
        cmd = ["xcrun", "-sdk", "iphoneos", "clang", "-fobjc-arc", "-target", "arm64-apple-ios17.0",
               "-dynamiclib", "-install_name", f"@rpath/libShim_{name}.dylib", "-Wno-incompatible-library-redeclaration",
               "-framework", "Foundation", "-framework", "UIKit", "-framework", "QuartzCore", "-framework", "CoreGraphics", "-framework", "Metal", "-framework", "GameController"]
        target = target_of(p)
        for t in [target] + sorted(foreign[p] - {target}):
            if not t:
                continue
            if t.startswith("@rpath/"):
                cmd += ["-Wl,-reexport_library," + os.path.join(out, "Frameworks", os.path.basename(t))]
            elif ".framework/" in t:
                cmd += ["-F" + SDK + os.path.dirname(t.split(".framework/")[0]), "-Wl,-reexport_framework," + lib_name(t)]
            else:
                cmd += ["-Wl,-reexport_library," + SDK + re.sub(r"\.dylib$", ".tbd", t)]
        run(*cmd, *srcs, "-o", dylib)
        print(f"shim {name}: {len(missing[p])} stubs, re-exports {[target] + sorted(foreign[p] - {target})}")

    # Rewrite load commands
    main_exe = os.path.join(out, exe)
    for m in machos:
        changes = []
        for dep in deps[m]:
            if dep in needs_shim:
                changes += ["-change", dep, f"@rpath/libShim_{lib_name(dep)}.dylib"]
            elif dep.startswith("/System/") and ios_path(dep, ios_names) != dep:
                changes += ["-change", dep, ios_path(dep, ios_names)]
            elif not dep.startswith("/") and ios_path(dep) != dep:  # app frameworks, flattened above
                changes += ["-change", dep, ios_path(dep)]
            elif dep.startswith("@executable_path/../"):
                changes += ["-change", dep, dep.replace("@executable_path/../", f"@executable_path/{MAC_ROOT}/Contents/")]
            elif m == main_exe and dep.startswith("@loader_path/"):  # main exe moved out of Contents/MacOS
                changes += ["-change", dep, dep.replace("@loader_path/", f"@executable_path/{MAC_ROOT}/Contents/MacOS/")]
        rpaths = re.findall(r"cmd LC_RPATH\n\s+cmdsize \d+\n\s+path (\S+)", run("otool", "-l", m))
        for rp in rpaths:
            new = rp.replace("@executable_path/../", f"@executable_path/{MAC_ROOT}/Contents/")
            if m == main_exe:
                new = new.replace("@loader_path/", f"@executable_path/{MAC_ROOT}/Contents/MacOS/")
            if new != rp:
                changes += ["-rpath", rp, new]
        own = run("otool", "-D", m).splitlines()[1:]  # dylib id, if any
        if own and not own[0].startswith("/") and ios_path(own[0]) != own[0]:
            changes += ["-id", ios_path(own[0])]
        if changes:
            run("install_name_tool", *changes, m)
        subprocess.run(["install_name_tool", "-add_rpath", "@executable_path/Frameworks", m], capture_output=True)

    # 4. Info.plist, profile, signing
    ios = plistlib.load(open(os.path.join(SHIM_DIR, "Info-ios.plist"), "rb"))
    plist = {k: v for k, v in mac_plist.items()
             if (not k.startswith("LS") or k == "LSApplicationCategoryType") and k != "CFBundleIconFile"}
    if plist.get("LSApplicationCategoryType", "").startswith("public.app-category.") and "games" in plist["LSApplicationCategoryType"]:
        plist["GCSupportsGameMode"] = True  # iPadOS Game Mode
        # iPadOS only hands game controllers to apps that declare them (macOS doesn't care; Cyberpunk doesn't)
        plist.setdefault("GCSupportedGameControllers", [{"ProfileName": "ExtendedGamepad"}])
        plist.setdefault("GCSupportsControllerUserInteraction", True)
    plist.update(ios)
    plist.update(CFBundleDisplayName=mac_plist.get("CFBundleDisplayName") or mac_plist.get("CFBundleName") or exe)
    plist.pop("SHIMShrinkReservations", None)
    plist.update(CFBundleExecutable=exe, CFBundleIdentifier=a.bundle_id, SHIMMacRoot=MAC_ROOT, SHIMBlockNetwork=not a.allow_network, SHIMBoundedReservations=a.bounded_reservations, MetalHudEnabled=not a.no_metal_hud, SHIMControllerReplay=not a.no_controller_replay,
                 SHIMPathRedirects=dict(r.split("=", 1) for r in a.redirect))
    if os.environ.get("SHIM_NO_EARLY_METAL"):  # experiment: skip the shim's startup Metal device
        plist["SHIMNoEarlyMetal"] = True
    if a.trace:
        plist["SHIMTrace"] = a.trace
    if a.redirect_app_parent:
        plist["SHIMAppParentRedirect"] = a.redirect_app_parent
    if a.report_memory_gb:
        plist["SHIMReportedMemoryGB"] = a.report_memory_gb
    plistlib.dump(plist, open(os.path.join(out, "Info.plist"), "wb"))
    shutil.copy(a.profile, os.path.join(out, "embedded.mobileprovision"))
    ent = os.path.join(TMP, "entitlements.plist")
    ents = plistlib.loads(open(os.path.join(SHIM_DIR, "entitlements.plist")).read()
                          .replace("TEAM", a.team).replace("BID", a.bundle_id).encode())
    ents.update({k: True for k in a.entitlement})
    plistlib.dump(ents, open(ent, "wb"))
    signed = [os.path.join(out, "Frameworks", f) for f in os.listdir(os.path.join(out, "Frameworks"))]
    for m in machos + signed:
        if os.path.abspath(m) != os.path.join(out, exe):
            run("codesign", "-f", "-s", a.identity, m)
    run("codesign", "-f", "-s", a.identity, "--entitlements", ent, out)
    print(f"signed {out}")


if __name__ == "__main__":
    main()
