# Count how often functions run in a live app, without stopping it for long: attach, set
# auto-continue breakpoints, let it run, print hit counts, detach. Same output on Mac and iPad,
# so a working Mac run can be diffed against the iPad port.
# usage: xcrun lldb --batch -o "command script import tools/lldb_count.py" \
#        -o "command script add -f lldb_count.run count" -o "count <udid|mac> <pid> <seconds> <regex> [regex...]"

import lldb, time, sys

def run(debugger, command, result, internal_dict):
    args = command.split()
    where, pid, secs, regexes = args[0], args[1], float(args[2]), args[3:]
    debugger.SetAsync(True)
    ci = debugger.GetCommandInterpreter()
    r = lldb.SBCommandReturnObject()
    cmds = [f"process attach --pid {pid}"] if where == "mac" else [f"device select {where}", f"device process attach --pid {pid}"]
    for c in cmds:
        ci.HandleCommand(c, r); print(c, "->", r.GetError().strip()[:300]); sys.stdout.flush()
    proc = debugger.GetSelectedTarget().GetProcess()
    for _ in range(300):
        proc = debugger.GetSelectedTarget().GetProcess()
        if proc.IsValid() and proc.GetState() == lldb.eStateStopped: break
        time.sleep(0.1)
    target = debugger.GetSelectedTarget()
    bps = []
    for rx in regexes:
        bp = target.BreakpointCreateByRegex(rx)
        bp.SetAutoContinue(True)
        bps.append(bp)
        print(f"breakpoint /{rx}/: {bp.GetNumLocations()} locations")
    proc.Continue()
    print(f"counting for {secs:.0f}s ..."); sys.stdout.flush()
    time.sleep(secs)
    proc.Stop()
    for _ in range(100):
        if proc.GetState() == lldb.eStateStopped: break
        time.sleep(0.1)
    counts = []
    for bp in bps:
        for loc in bp:
            if loc.GetHitCount():
                counts.append((loc.GetHitCount(), loc.GetAddress().GetFunction().GetName() or loc.GetAddress().GetSymbol().GetName()))
    for n, name in sorted(counts, reverse=True):
        print(f"COUNT {n:8d}  {name}")
    for bp in bps:
        target.BreakpointDelete(bp.GetID())
    proc.Detach()
    print("detached")
