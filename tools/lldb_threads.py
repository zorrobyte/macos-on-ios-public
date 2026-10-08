# Live thread dump without killing the app: attach, stop, print every thread stack, detach.
# usage: xcrun lldb --batch -o "command script import tools/lldb_threads.py" \
#        -o "command script add -f lldb_threads.run btall" -o "btall <udid> <pid>"

import lldb, time, sys

def run(debugger, command, result, internal_dict):
    udid, pid = command.split()
    debugger.SetAsync(True)
    ci = debugger.GetCommandInterpreter()
    r = lldb.SBCommandReturnObject()
    for c in (f"device select {udid}", f"device process attach --pid {pid}"):
        ci.HandleCommand(c, r); print(c, "->", r.GetOutput().strip()[:200], r.GetError().strip()[:300]); sys.stdout.flush()
    target = debugger.GetSelectedTarget(); proc = target.GetProcess()
    for _ in range(300):  # wait for the attach to settle
        if proc.IsValid() and proc.GetState() in (lldb.eStateStopped, lldb.eStateRunning): break
        time.sleep(0.1); proc = debugger.GetSelectedTarget().GetProcess()
    print("state after attach:", lldb.SBDebugger.StateAsCString(proc.GetState()))
    if proc.GetState() == lldb.eStateRunning:
        proc.Stop()
        for _ in range(100):
            if proc.GetState() == lldb.eStateStopped: break
            time.sleep(0.1)
    print("state:", lldb.SBDebugger.StateAsCString(proc.GetState()), "threads:", proc.GetNumThreads())
    if proc.GetState() == lldb.eStateStopped:
        for t in proc:
            print(f"--- thread {t.GetIndexID()} {t.GetName() or ''} {t.GetQueueName() or ''}")
            for f in list(t)[:14]:
                mod = f.GetModule().GetFileSpec().GetFilename() or "?"
                off = f.GetPCAddress().GetFileAddress()
                print(f"   {mod:28} {f.GetFunctionName() or ''}  {hex(off)}")
        proc.Detach()
        print("detached; state:", lldb.SBDebugger.StateAsCString(proc.GetState()))
