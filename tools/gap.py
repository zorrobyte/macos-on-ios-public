#!/usr/bin/env python3
"""List a macOS Mach-O's imported symbols that the iOS SDK doesn't export.

usage: gap.py <mach-o> [more mach-os...]
Prints, per macOS library, the imported symbols missing from every iOS SDK .tbd,
plus libraries that have no iOS counterpart at all. Weak imports are marked (weak).
"""
import os, re, subprocess, sys
from collections import defaultdict

SDK = subprocess.check_output(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"], text=True).strip()
SECTIONS = {"symbols": "", "weak-symbols": "", "thread-local-symbols": "",
            "objc-classes": "_OBJC_CLASS_$_", "objc-eh-types": "_OBJC_EHTYPE_$_",
            "objc-ivars": "_OBJC_IVAR_$_"}


def list_items(text, i):
    """Items of a YAML flow list starting at text[i] (just past '['); quotes may hold ']' or ','."""
    items, cur, quote = [], [], False
    while i < len(text):
        c = text[i]
        if c == "'":
            quote = not quote
        elif not quote and c in ",]":
            if "".join(cur).strip():
                items.append("".join(cur).strip())
            cur = []
            if c == "]":
                break
        else:
            cur.append(c)
        i += 1
    return items


class IOSIndex:
    """Exports of every iOS SDK library, per install name, following re-exports."""

    def __init__(self):
        self.direct = defaultdict(set)      # install name -> symbols it defines
        self.reexports = defaultdict(list)  # install name -> re-exported install names
        self.owners = defaultdict(set)      # symbol -> install names defining it
        for root in ("System/Library/Frameworks", "System/Library/SubFrameworks", "usr/lib"):
            for d, _, files in os.walk(os.path.join(SDK, root), followlinks=True):
                for f in files:
                    if f.endswith(".tbd"):
                        # one .tbd may hold several libraries, one YAML document each
                        for doc in re.split(r"^--- ", open(os.path.join(d, f), errors="ignore").read(), flags=re.M):
                            self._add(doc)
        self.names = set(self.direct) | set(self.reexports)
        self._tree = {}

    def _add(self, doc):
        m = re.search(r"install-name:\s*'?([^'\n]+)'?", doc)
        if not m:
            return
        name = m.group(1).strip()
        self.direct[name]
        rx = re.search(r"reexported-libraries:(.*?)(?:^\S|\Z)", doc, re.S | re.M)
        if rx:
            for lm in re.finditer(r"libraries:\s*\[", rx.group(1)):
                self.reexports[name] += list_items(rx.group(1), lm.end())
        for m in re.finditer(r"\b([a-z-]+):\s*\[", doc):
            prefix = SECTIONS.get(m.group(1))
            if prefix is None:
                continue
            for item in list_items(doc, m.end()):
                for sym in [prefix + item] + (["_OBJC_METACLASS_$_" + item] if m.group(1) == "objc-classes" else []):
                    self.direct[name].add(sym)
                    self.owners[sym].add(name)

    def tree(self, name):
        """name plus everything it re-exports, transitively."""
        if name not in self._tree:
            self._tree[name] = {name}
            for r in self.reexports.get(name, []):
                self._tree[name] |= self.tree(r)
        return self._tree[name]

    def provides(self, name, sym):
        return any(sym in self.direct.get(n, ()) for n in self.tree(name))


def ios_exports():
    """All symbols exported by any iOS SDK library, and the set of install names."""
    idx = IOSIndex()
    return set(idx.owners), idx.names


def imports(binary):
    """(library basename, symbol, weak) for every import in the arm64 slice."""
    out = subprocess.run(["xcrun", "dyld_info", "-arch", "arm64", "-imports", binary],
                         capture_output=True, text=True).stdout
    return [(m.group(2), m.group(1), "weak" in m.group(3))
            for m in re.finditer(r"^[ \t]+(?:0x[0-9A-F]+\s+)?(\S+)\s+\(from (.+?)\)(.*)$", out, re.M)]


def main():
    syms, names = ios_exports()
    for binary in sys.argv[1:]:
        missing = defaultdict(list)
        for lib, sym, weak in imports(binary):
            if sym not in syms and not lib.startswith("<"):  # <weak-def-coalesce> = own C++ weak defs
                missing[lib].append(sym + (" (weak)" if weak else ""))
        deps = subprocess.check_output(["xcrun", "dyld_info", "-arch", "arm64", "-dependents", binary], text=True)
        print(f"== {binary}")
        for dep in re.findall(r"^[ \t]+(?:\S+[ \t]+)?(/\S+)$", deps, re.M):
            ios_path = re.sub(r"(\w+)\.framework/Versions/\w+/\1$", r"\1.framework/\1", dep)
            if dep.startswith("/") and ios_path not in names:
                print(f"  no iOS library: {dep}")
        total = sum(len(v) for v in missing.values())
        print(f"  {total} imported symbols missing on iOS")
        for lib, items in sorted(missing.items(), key=lambda kv: -len(kv[1])):
            print(f"  [{lib}] {len(items)}")
            for s in sorted(items):
                print(f"      {s}")


if __name__ == "__main__":
    main()
