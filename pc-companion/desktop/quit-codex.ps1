$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$p = Get-Process -Id ([int]$env:CM_DESKTOP_PID)
if ($p.Path -ne $env:CM_DESKTOP_EXE -or $p.StartTime.ToUniversalTime().Ticks.ToString() -ne $env:CM_DESKTOP_CREATED) { 'changed'; exit }

# CloseMainWindow can minimize Electron to the tray. Restart Manager requests an
# application shutdown and lets the app veto it. Do not use RmForceShutdown.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class ClawMateQuit {
  [StructLayout(LayoutKind.Sequential)]
  struct UniqueProcess {
    public uint pid;
    public System.Runtime.InteropServices.ComTypes.FILETIME started;
  }
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  struct ProcessInfo {
    public UniqueProcess process;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=256)] public string name;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=64)] public string service;
    public int type;
    public uint status, session;
    [MarshalAs(UnmanagedType.Bool)] public bool restartable;
  }
  [DllImport("rstrtmgr.dll", CharSet=CharSet.Unicode)]
  static extern int RmStartSession(out uint handle, uint flags, StringBuilder key);
  [DllImport("rstrtmgr.dll", CharSet=CharSet.Unicode)]
  static extern int RmRegisterResources(uint handle, uint nFiles, IntPtr files, uint nApps,
    [In] UniqueProcess[] apps, uint nServices, IntPtr services);
  [DllImport("rstrtmgr.dll")]
  static extern int RmGetList(uint handle, out uint needed, ref uint count,
    [In, Out] ProcessInfo[] apps, ref uint rebootReasons);
  [DllImport("rstrtmgr.dll")]
  static extern int RmShutdown(uint handle, uint flags, IntPtr progress);
  [DllImport("rstrtmgr.dll")]
  static extern int RmEndSession(uint handle);

  public static bool Request(uint pid, long startTime) {
    uint handle;
    if (RmStartSession(out handle, 0, new StringBuilder(33)) != 0) return false;
    try {
      var target = new UniqueProcess { pid=pid };
      target.started.dwLowDateTime = unchecked((int)startTime);
      target.started.dwHighDateTime = unchecked((int)(startTime >> 32));
      if (RmRegisterResources(handle, 0, IntPtr.Zero, 1, new[]{target}, 0, IntPtr.Zero) != 0) return false;
      uint needed, count=1, reasons=0;
      var affected = new ProcessInfo[1];
      if (RmGetList(handle, out needed, ref count, affected, ref reasons) != 0 || reasons != 0 || count != 1) return false;
      var actual = affected[0].process;
      if (actual.pid != pid || actual.started.dwLowDateTime != target.started.dwLowDateTime ||
          actual.started.dwHighDateTime != target.started.dwHighDateTime) return false;
      return RmShutdown(handle, 0, IntPtr.Zero) == 0;
    } finally { RmEndSession(handle); }
  }
}
'@
if ([ClawMateQuit]::Request($p.Id,$p.StartTime.ToFileTimeUtc()) -and $p.WaitForExit(5000)) { 'closed' } else { 'refused' }
