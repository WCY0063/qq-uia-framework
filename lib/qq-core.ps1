# =============================================================================
# qq-core.ps1 - UIA enumeration, locating, DPI conversion, focus, waiting,
#               keyboard injection, screenshots, and message parsing.
# Authority: G:\work\FRAMEWORK-DESIGN.md section 3 (core layer)
# Origin: hardened from qq-uia\scripts\qq-lib.ps1
#
# Hard rules encoded here (each one was a real defect in the pre-framework
# scripts, see FRAMEWORK-DESIGN section 3 problem table):
#   * never launch, restart, or stop a QQ process; only ever attach
#   * DPI awareness is enabled at load time (QQUiaNative.EnableDpiAwareness,
#     recorded in $script:QQ_DPI_AWARE). An aware process reads UIA rectangles,
#     GetWindowRect and GDI capture all in the same physical pixel space, so no
#     conversion is applied; the logical conversions exist only for a host where
#     awareness could not be enabled. Both branches live in
#     Convert-QQPointToPhysical / Convert-QQWindowRectToPhysical so no caller
#     scales a coordinate by hand
#   * the message editor is contenteditable (TextPattern only), so text is
#     injected with physical keyboard events and verified by read-back
#   * every wait is bounded and reports a timeout instead of hanging
#
# ASCII-ONLY SOURCE. PowerShell 5.1 decodes a BOM-less file as ANSI, so CJK in a
# comment or string literal corrupts parsing. CJK text is built at runtime from
# [char]0x.... escapes. run-tests.ps1 enforces this rule.
# =============================================================================

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

# ---- module root and selector registry (single load per process) ----
# $PSScriptRoot resolves only while a dot-sourced file is executing, so the
# directory is captured once and reused by the functions below and by guard
# code. A module that cannot locate itself must fail loudly: silently reading
# the wrong root is how a framework ends up probing a non-existent config.
if (-not (Get-Variable -Name QQ_LIB_DIR -Scope Script -ErrorAction SilentlyContinue)) {
  $selfDir = $PSScriptRoot
  if ([string]::IsNullOrEmpty($selfDir) -and $null -ne $MyInvocation -and $null -ne $MyInvocation.MyCommand) {
    $selfPath = [string]$MyInvocation.MyCommand.Path
    if (-not [string]::IsNullOrEmpty($selfPath)) { $selfDir = Split-Path -Parent $selfPath }
  }
  if ([string]::IsNullOrEmpty($selfDir)) {
    throw 'qq-core.ps1 could not resolve its own directory; dot-source it from the dispatcher (qq-uia.ps1)'
  }
  $script:QQ_LIB_DIR = $selfDir
  $script:QQ_ROOT_DIR = Split-Path -Parent $selfDir
}

if (-not (Get-Variable -Name QQ_SEL -Scope Script -ErrorAction SilentlyContinue)) {
  $script:QQ_SEL = $null
  $selPath = Join-Path $script:QQ_LIB_DIR 'selectors.psd1'
  if (-not (Test-Path -LiteralPath $selPath)) {
    throw ("selectors.psd1 not found at {0}" -f $selPath)
  }
  $loaded = $null
  try {
    # Import-PowerShellDataFile, not dot-sourcing: Windows PowerShell returns
    # nothing when a .psd1 is dot-sourced from a function's enclosing scope here,
    # while the data-file cmdlet reliably yields the hashtable.
    $loaded = Import-PowerShellDataFile -Path $selPath -ErrorAction Stop
  } catch {
    throw ("selectors.psd1 could not be loaded: {0}" -f $_.Exception.Message)
  }
  if ($null -eq $loaded) {
    throw ("selectors.psd1 produced no selector table: {0}" -f $selPath)
  }
  $script:QQ_SEL = $loaded
}

# UIA exposes no image content; QQ renders a bracketed placeholder instead.
# Built here from character codes so the shipped source stays pure ASCII.
$script:QQ_IMAGE_PLACEHOLDER = [string]([char]0x56FE + [char]0x7247)

# ---- native layer: window enumeration, DPI, input, capture ----
$script:QQCoreSrc = @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text;

public class QQUiaNative {
  public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);

  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr hWnd, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr hWnd, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int cmd);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
  [DllImport("user32.dll")] public static extern IntPtr GetFocus();
  [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr hWnd, uint flags);

  [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr ctx);

  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

  [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT {
    public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public UIntPtr dwExtraInfo;
  }
  [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT {
    public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public UIntPtr dwExtraInfo;
  }
  [StructLayout(LayoutKind.Sequential)] public struct HARDWAREINPUT { public uint uMsg; public ushort wParamL; public ushort wParamH; }
  [StructLayout(LayoutKind.Explicit)] public struct INPUTUNION {
    [FieldOffset(0)] public MOUSEINPUT mi;
    [FieldOffset(0)] public KEYBDINPUT ki;
    [FieldOffset(0)] public HARDWAREINPUT hi;
  }
  [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public INPUTUNION u; }

  [DllImport("user32.dll", SetLastError = true)] public static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);
  [DllImport("user32.dll")] public static extern ushort VkKeyScan(char ch);
  [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
  [DllImport("user32.dll")] public static extern bool keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);

  [DllImport("gdi32.dll")] public static extern IntPtr CreateCompatibleDC(IntPtr hdc);
  [DllImport("gdi32.dll")] public static extern IntPtr CreateCompatibleBitmap(IntPtr hdc, int w, int h);
  [DllImport("gdi32.dll")] public static extern IntPtr SelectObject(IntPtr hdc, IntPtr obj);
  [DllImport("gdi32.dll")] public static extern bool BitBlt(IntPtr dst, int x, int y, int w, int h, IntPtr src, int sx, int sy, int rop);
  [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr obj);
  [DllImport("gdi32.dll")] public static extern bool DeleteDC(IntPtr hdc);

  private const int INPUT_KEYBOARD = 1;
  private const uint KEYEVENTF_UNICODE = 0x0004;
  private const uint KEYEVENTF_KEYUP = 0x0002;
  private const uint KEYEVENTF_SCANCODE = 0x0008;
  private const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
  private const uint MOUSEEVENTF_LEFTUP = 0x0004;
  private const int SRCCOPY = 0x00CC0020;
  private const int CAPTUREBLT = 0x40000000;

  [DllImport("user32.dll")] public static extern IntPtr GetThreadDpiAwarenessContext();
  [DllImport("user32.dll")] public static extern bool AreDpiAwarenessContextsEqual(IntPtr a, IntPtr b);

  private static bool IsAwareLevelName(string level) {
    return level == "per-monitor-v2" || level == "per-monitor" || level == "system";
  }

  // Names a DPI_AWARENESS_CONTEXT value. The comparison goes through
  // AreDpiAwarenessContextsEqual rather than == because the constants are
  // pseudo-handles, not guaranteed distinct pointer values.
  public static string ContextName(IntPtr ctx) {
    try {
      if (ctx == IntPtr.Zero) { return "unknown"; }
      if (AreDpiAwarenessContextsEqual(ctx, new IntPtr(-4))) { return "per-monitor-v2"; }
      if (AreDpiAwarenessContextsEqual(ctx, new IntPtr(-3))) { return "per-monitor"; }
      if (AreDpiAwarenessContextsEqual(ctx, new IntPtr(-2))) { return "system"; }
      if (AreDpiAwarenessContextsEqual(ctx, new IntPtr(-1))) { return "unaware"; }
    } catch { }
    return "unknown";
  }

  // The level actually in effect for this thread, read back from the host. The
  // older API pairs are absent before Windows 10 1607, where this returns
  // "unknown".
  public static string CurrentDpiAwareness() {
    try { return ContextName(GetThreadDpiAwarenessContext()); } catch { return "unknown"; }
  }

  // Enables the strongest awareness the host supports and reports the level that
  // is in effect afterwards.
  //
  // Two rules, both learned from the defect this replaced: stop at the first
  // level that takes effect (calling a weaker setter afterwards downgraded
  // per-monitor-v2 to the process level on every run), and report the read-back
  // level rather than a setter's return value (SetProcessDPIAware reports failure
  // when a manifest already set the level, and a wrong answer here inverts every
  // coordinate conversion downstream).
  public static string EnableDpiAwareness() {
    try { SetThreadDpiAwarenessContext(new IntPtr(-4)); } catch { }
    string level = CurrentDpiAwareness();
    if (IsAwareLevelName(level)) { return level; }

    try { SetThreadDpiAwarenessContext(new IntPtr(-3)); } catch { }
    level = CurrentDpiAwareness();
    if (IsAwareLevelName(level)) { return level; }

    try { if (SetProcessDPIAware()) { return "system"; } } catch { }
    level = CurrentDpiAwareness();
    if (IsAwareLevelName(level)) { return level; }
    return level;
  }

  // Returns the window's DPI, or 0 when the host cannot report it.
  public static int GetWindowDpi(IntPtr hWnd) {
    try { return (int)GetDpiForWindow(hWnd); } catch { return 0; }
  }

  public static string Text(IntPtr hWnd) { StringBuilder sb = new StringBuilder(512); GetWindowTextW(hWnd, sb, 512); return sb.ToString(); }
  public static string Cls(IntPtr hWnd) { StringBuilder sb = new StringBuilder(512); GetClassNameW(hWnd, sb, 512); return sb.ToString(); }
  public static uint WinPid(IntPtr hWnd) { uint p; GetWindowThreadProcessId(hWnd, out p); return p; }
  public static bool IsForeground(IntPtr hWnd) { return GetForegroundWindow() == hWnd; }

  public static INPUT Key(ushort vk, ushort scan, bool up) {
    INPUT input = new INPUT();
    input.type = INPUT_KEYBOARD;
    input.u.ki.wVk = vk;
    input.u.ki.wScan = scan;
    input.u.ki.dwFlags = (up ? KEYEVENTF_KEYUP : 0) | (vk == 0 ? KEYEVENTF_UNICODE : 0);
    input.u.ki.time = 0;
    input.u.ki.dwExtraInfo = UIntPtr.Zero;
    return input;
  }

  // Injects text as physical keyboard events. Unicode code units travel through
  // KEYEVENTF_UNICODE, which is layout independent, so CJK needs no IME and no
  // clipboard and reaches the same input queue a human keyboard would.
  public static int SendText(string text, int delayMs) {
    int sent = 0;
    for (int i = 0; i < text.Length; i++) {
      char c = text[i];
      if (c == '\r' || c == '\n') { continue; }
      INPUT[] pair = new INPUT[2];
      pair[0] = Key(0, (ushort)c, false);
      pair[1] = Key(0, (ushort)c, true);
      sent += (int)SendInput((uint)pair.Length, pair, Marshal.SizeOf(typeof(INPUT)));
      if (delayMs > 0) { System.Threading.Thread.Sleep(delayMs); }
    }
    return sent;
  }

  public static int PressKey(ushort vk, bool shift) {
    INPUT[] seq;
    if (shift) {
      seq = new INPUT[4];
      seq[0] = Key(0x10, 0, false);
      seq[1] = Key(vk, 0, false);
      seq[2] = Key(vk, 0, true);
      seq[3] = Key(0x10, 0, true);
    } else {
      seq = new INPUT[2];
      seq[0] = Key(vk, 0, false);
      seq[1] = Key(vk, 0, true);
    }
    return (int)SendInput((uint)seq.Length, seq, Marshal.SizeOf(typeof(INPUT)));
  }

  public static void Click(int x, int y) {
    SetCursorPos(x, y);
    System.Threading.Thread.Sleep(60);
    mouse_event(MOUSEEVENTF_LEFTDOWN, 0, 0, 0, UIntPtr.Zero);
    System.Threading.Thread.Sleep(40);
    mouse_event(MOUSEEVENTF_LEFTUP, 0, 0, 0, UIntPtr.Zero);
  }

  private static Bitmap Capture(IntPtr hWnd, int x, int y, int w, int h) {
    if (w <= 0 || h <= 0) { return null; }
    IntPtr screenDc = IntPtr.Zero;
    IntPtr memDc = IntPtr.Zero;
    IntPtr hBmp = IntPtr.Zero;
    IntPtr oldBmp = IntPtr.Zero;
    try {
      screenDc = GetWindowDC(hWnd);
      memDc = CreateCompatibleDC(screenDc);
      hBmp = CreateCompatibleBitmap(screenDc, w, h);
      oldBmp = SelectObject(memDc, hBmp);
      BitBlt(memDc, 0, 0, w, h, screenDc, x, y, SRCCOPY | CAPTUREBLT);
      Bitmap bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb);
      using (Graphics g = Graphics.FromImage(bmp)) {
        IntPtr dstDc = g.GetHdc();
        BitBlt(dstDc, 0, 0, w, h, memDc, 0, 0, SRCCOPY);
        g.ReleaseHdc(dstDc);
      }
      return bmp;
    } finally {
      if (oldBmp != IntPtr.Zero) { SelectObject(memDc, oldBmp); }
      if (hBmp != IntPtr.Zero) { DeleteObject(hBmp); }
      if (memDc != IntPtr.Zero) { DeleteDC(memDc); }
      if (screenDc != IntPtr.Zero) { ReleaseDC(hWnd, screenDc); }
    }
  }

  [DllImport("user32.dll")] public static extern IntPtr GetWindowDC(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr hWnd, IntPtr hDc);

  // Captures the visible window rectangle. The result is saved immediately, so
  // the caller gets a path rather than a bitmap handle.
  public static string CaptureWindowToFile(IntPtr hWnd, string path, out int width, out int height) {
    width = 0; height = 0;
    RECT r;
    if (!GetWindowRect(hWnd, out r)) { return "GetWindowRect failed"; }
    int w = r.Right - r.Left;
    int h = r.Bottom - r.Top;
    if (w <= 0 || h <= 0) { return "window has no visible area"; }
    Bitmap bmp = Capture(hWnd, 0, 0, w, h);
    if (bmp == null) { return "bitmap allocation failed"; }
    try {
      bmp.Save(path, ImageFormat.Png);
      width = w; height = h;
      return "";
    } catch (Exception ex) {
      return ex.Message;
    } finally {
      bmp.Dispose();
    }
  }

  // Captures the whole virtual screen. Coordinates are physical pixels when the
  // process is DPI aware (see EnableDpiAwareness).
  public static string CaptureScreenToFile(string path, out int width, out int height) {
    width = 0; height = 0;
    IntPtr hWnd = GetDesktopWindow();
    RECT r;
    if (!GetWindowRect(hWnd, out r)) { return "GetWindowRect(desktop) failed"; }
    int w = r.Right - r.Left;
    int h = r.Bottom - r.Top;
    if (w <= 0 || h <= 0) { return "desktop has no area"; }
    Bitmap bmp = Capture(hWnd, 0, 0, w, h);
    if (bmp == null) { return "bitmap allocation failed"; }
    try {
      bmp.Save(path, ImageFormat.Png);
      width = w; height = h;
      return "";
    } catch (Exception ex) {
      return ex.Message;
    } finally {
      bmp.Dispose();
    }
  }

  [DllImport("user32.dll")] public static extern IntPtr GetDesktopWindow();
  [DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }

  // Captures a rectangle of the virtual screen. A QQ window is GPU composited, so
  // its own window DC returns a black image; the desktop DC does include it. This
  // is the same mechanism the pre-framework verification scripts used, which is
  // why it is the primary capture path and CaptureWindowToFile is the fallback.
  public static string CaptureScreenRegionToFile(int x, int y, int w, int h, string path, out int width, out int height) {
    width = 0; height = 0;
    int vx = GetSystemMetrics(76);   // SM_XVIRTUALSCREEN
    int vy = GetSystemMetrics(77);   // SM_YVIRTUALSCREEN
    int vw = GetSystemMetrics(78);   // SM_CXVIRTUALSCREEN
    int vh = GetSystemMetrics(79);   // SM_CYVIRTUALSCREEN
    if (vw <= 0 || vh <= 0) { vw = GetSystemMetrics(0); vh = GetSystemMetrics(1); vx = 0; vy = 0; }
    int sx = x - vx;
    int sy = y - vy;
    if (sx < 0) { w += sx; sx = 0; }
    if (sy < 0) { h += sy; sy = 0; }
    if (sx + w > vw) { w = vw - sx; }
    if (sy + h > vh) { h = vh - sy; }
    if (w <= 0 || h <= 0) { return "the window rectangle lies outside the virtual screen"; }

    IntPtr screenDc = IntPtr.Zero;
    IntPtr memDc = IntPtr.Zero;
    IntPtr hBmp = IntPtr.Zero;
    IntPtr oldBmp = IntPtr.Zero;
    try {
      screenDc = GetDC(IntPtr.Zero);
      if (screenDc == IntPtr.Zero) { return "GetDC(desktop) failed"; }
      memDc = CreateCompatibleDC(screenDc);
      hBmp = CreateCompatibleBitmap(screenDc, w, h);
      oldBmp = SelectObject(memDc, hBmp);
      bool ok = BitBlt(memDc, 0, 0, w, h, screenDc, sx, sy, SRCCOPY | CAPTUREBLT);
      if (!ok) { return "BitBlt from the desktop failed"; }
      using (Bitmap bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb)) {
        using (Graphics g = Graphics.FromImage(bmp)) {
          IntPtr dstDc = g.GetHdc();
          BitBlt(dstDc, 0, 0, w, h, memDc, 0, 0, SRCCOPY);
          g.ReleaseHdc(dstDc);
        }
        bmp.Save(path, ImageFormat.Png);
      }
      width = w; height = h;
      return "";
    } catch (Exception ex) {
      return ex.Message;
    } finally {
      if (oldBmp != IntPtr.Zero) { SelectObject(memDc, oldBmp); }
      if (hBmp != IntPtr.Zero) { DeleteObject(hBmp); }
      if (memDc != IntPtr.Zero) { DeleteDC(memDc); }
      if (screenDc != IntPtr.Zero) { ReleaseDC(IntPtr.Zero, screenDc); }
    }
  }

  [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool IsChild(IntPtr parent, IntPtr child);

  public static IntPtr WindowAtPoint(int x, int y) {
    POINT p; p.X = x; p.Y = y;
    return WindowFromPoint(p);
  }

  // True when 'candidate' is the target window or one of its child windows.
  public static bool IsAncestorOf(IntPtr candidate, IntPtr target) {
    if (candidate == target) { return true; }
    if (IsChild(target, candidate)) { return true; }
    IntPtr root = GetAncestor(candidate, 2);   // GA_ROOT
    return root == target;
  }

  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint attach, uint attachTo, bool fAttach);
  [DllImport("user32.dll")] public static extern IntPtr SetFocus(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern void SwitchToThisWindow(IntPtr hWnd, bool altTab);

  private static uint CurrentThread() { return GetCurrentThreadId(); }
  private static uint FgThread(IntPtr hWnd) { uint pid; return GetWindowThreadProcessId(hWnd, out pid); }

  // Activates a window owned by another process. Attaching this thread's input
  // queue to the foreground window's queue is what makes SetForegroundWindow
  // succeed: Windows refuses a bare SetForegroundWindow from a process that does
  // not own the current foreground window, which would leave a screenshot
  // capturing whatever happened to be in front (a different application).
  public static bool ActivateWindow(IntPtr hWnd) {
    if (IsIconic(hWnd)) { ShowWindow(hWnd, 9); }   // SW_RESTORE
    ShowWindow(hWnd, 5);                            // SW_SHOW
    IntPtr fg = GetForegroundWindow();
    if (fg == hWnd) { return true; }
    uint target = FgThread(hWnd);
    uint current = CurrentThread();
    bool attached = false;
    if (fg != IntPtr.Zero) { attached = AttachThreadInput(current, FgThread(fg), true); }
    try { BringWindowToTop(hWnd); } catch { }
    try { SetForegroundWindow(hWnd); } catch { }
    try { SetFocus(hWnd); } catch { }
    if (attached) { AttachThreadInput(current, FgThread(fg), false); }
    SwitchToThisWindow(hWnd, true);
    return IsForeground(hWnd);
  }
}
'@
if (-not ('QQUiaNative' -as [type])) {
  Add-Type -TypeDefinition $script:QQCoreSrc -Language CSharp -ReferencedAssemblies 'System.Drawing'
}

# DPI awareness is decided once, here, and every coordinate conversion reads the
# answer back from this variable. "unknown" (a host too old to report it) is kept
# distinct from "unaware" so the log says which one happened; both take the
# converting branch because neither proves the process is aware.
$script:QQ_DPI_AWARE = 'unknown'
try { $script:QQ_DPI_AWARE = [string][QQUiaNative]::EnableDpiAwareness() } catch { $script:QQ_DPI_AWARE = 'unknown' }
if (Get-Command -Name 'Write-QQLog' -CommandType Function -ErrorAction SilentlyContinue) {
  Write-QQLog -Text ("process dpi awareness: {0}" -f $script:QQ_DPI_AWARE)
  if ($script:QQ_DPI_AWARE -eq 'unknown') {
    Write-QQLog -Text 'the host cannot report its dpi awareness; coordinates are treated as logical, which is wrong above 100% scaling'
  }
}

# =============================================================================
# Configuration
# =============================================================================

function Get-QQConfig {
  <#
  .SYNOPSIS
    Loads config.json from the framework root and exposes typed values.
  .DESCRIPTION
    Missing keys fall back to the documented defaults so a partial config file
    still runs. Which pid belongs to which account is still discovered at run time
    by `identify`: accounts[] only names the accounts an operator wants to address
    by alias, and the live binding is resolved from the instance's own avatar. An
    invalid config file is reported through Valid=$false instead of silently
    defaulting.
  .PARAMETER Root
    Framework root directory.
  .OUTPUTS
    [hashtable] Valid, Raw plus flat typed keys (Timeouts, DpiMode, DpiScale,
    A11yMinNodes, EvidenceDir, TypingDelayMs, RequireAccountMatch, ...), plus
    Accounts (normalized list), DefaultAccount and AccountsWarning.
  #>
  param([Parameter(Mandatory)][string]$Root)

  $path = Join-Path $Root 'config.json'
  $cfg = @{
    Valid               = $false
    Path                = $path
    Raw                 = $null
    ParseError          = ''
    Timeouts            = @{}
    EvidenceDir         = 'evidence'
    DpiMode             = 'auto'
    DpiScale            = 1.5
    A11yMinNodes        = 100
    NodeCountTimeoutMs  = 8000
    MinWindowWidth      = 400
    TypingEngine        = 'sendinput'
    TypingDelayMs       = 12
    RequireAccountMatch = $false
    MinSendIntervalMs   = 0
    WriteAudit          = $true
    AuditIncludeText    = $true
    KeepLatestAliases   = $true
    IgnorePids          = @()
    Accounts            = @()
    DefaultAccount      = ''
    AccountsWarning     = ''
    # Which flat keys came from the FILE rather than from this default table.
    # Callers that resolve "config beats selectors.psd1 beats the built-in
    # default" need the distinction, because this table always answers every key:
    # a ContainsKey test cannot tell an operator's value from the built-in one.
    FileKeys            = @()
  }

  if (Test-Path -LiteralPath $path) {
    try {
      $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
      $cfg.Raw = $raw
      $cfg.Valid = $true
    } catch {
      $cfg.ParseError = $_.Exception.Message
      return $cfg
    }
  } else {
    $cfg.ParseError = 'config.json not found'
    return $cfg
  }

  $script:QQ_CFG_MAP = [ordered]@{
    'evidence.dir'                = 'EvidenceDir'
    'evidence.writeAudit'         = 'WriteAudit'
    'evidence.auditIncludeMessageText' = 'AuditIncludeText'
    'evidence.keepLatestAliases'  = 'KeepLatestAliases'
    'timeouts.defaultSec'         = 'DefaultTimeoutSec'
    'timeouts.searchResultsMs'    = 'SearchResultsMs'
    'timeouts.switchHeaderMs'     = 'SwitchHeaderMs'
    'timeouts.afterFocusMs'       = 'AfterFocusMs'
    'timeouts.afterTypeMs'        = 'AfterTypeMs'
    'timeouts.afterSendMs'        = 'AfterSendMs'
    'timeouts.settleMs'           = 'SettleMs'
    'dpi.mode'                    = 'DpiMode'
    'dpi.scale'                   = 'DpiScale'
    'a11y.minNodes'               = 'A11yMinNodes'
    'a11y.nodeCountTimeoutMs'     = 'NodeCountTimeoutMs'
    'instances.minWindowWidth'    = 'MinWindowWidth'
    'instances.ignorePids'        = 'IgnorePids'
    'typing.engine'               = 'TypingEngine'
    'typing.delayMs'              = 'TypingDelayMs'
    'guards.requireAccountMatch'  = 'RequireAccountMatch'
    'guards.minSendIntervalMs'    = 'MinSendIntervalMs'
  }

  # Which flat keys this file actually carries, in map order. Recorded while the
  # values are read so a key that is present but null cannot count as explicit.
  $fileKeys = New-Object System.Collections.ArrayList
  foreach ($dotPath in $script:QQ_CFG_MAP.Keys) {
    $node = $raw
    $found = $true
    foreach ($seg in ($dotPath -split '\.')) {
      if ($null -eq $node) { $found = $false; break }
      $names = @($node.PSObject.Properties.Name)
      if ($names -notcontains $seg) { $found = $false; break }
      $node = $node.$seg
    }
    if (-not $found -or $null -eq $node) { continue }
    $target = $script:QQ_CFG_MAP[$dotPath]
    if ($target -eq 'IgnorePids') {
      $cfg[$target] = @($node | ForEach-Object { [int]$_ })
    } elseif ($node -is [bool]) {
      $cfg[$target] = [bool]$node
    } elseif ($node -is [int] -or $node -is [long] -or $node -is [double]) {
      $cfg[$target] = $node
    } else {
      $cfg[$target] = [string]$node
    }
    [void]$fileKeys.Add([string]$target)
  }
  $cfg['FileKeys'] = @($fileKeys)

  # accounts[] is a LIST, which the scalar dot-path map above cannot express, so it
  # is normalized here. A malformed entry is skipped instead of fatal, because one
  # mistyped alias must not make every command unusable. Identity is still read at
  # run time (identify/accounts): an entry only says which nickname the operator
  # calls an account, never which pid is signed in as it.
  $topLevel = @($raw.PSObject.Properties.Name)
  if ($topLevel -contains 'defaultAccount' -and $null -ne $raw.defaultAccount) {
    $cfg['DefaultAccount'] = [string]$raw.defaultAccount
  }
  if ($topLevel -contains 'accounts' -and $null -ne $raw.accounts) {
    $accounts = New-Object System.Collections.ArrayList
    $warnings = New-Object System.Collections.ArrayList
    $seenAliases = @{}
    foreach ($entry in @($raw.accounts)) {
      if ($null -eq $entry) { continue }
      $entryProps = @()
      try { $entryProps = @($entry.PSObject.Properties.Name) } catch { $entryProps = @() }

      $fields = @{ alias = ''; nick = ''; qqId = ''; note = '' }
      foreach ($field in @('alias', 'nick', 'qqId', 'note')) {
        if ($entryProps -notcontains $field) { continue }
        $value = $entry.$field
        if ($null -ne $value) { $fields[$field] = [string]$value }
      }
      $alias = ([string]$fields['alias']).Trim()
      if ([string]::IsNullOrEmpty($alias)) { continue }

      $aliasKey = $alias.ToLowerInvariant()
      if ($seenAliases.ContainsKey($aliasKey)) {
        [void]$warnings.Add(("alias '{0}' is defined more than once; the first definition wins" -f $alias))
        continue
      }
      $seenAliases[$aliasKey] = $true

      # enabled defaults to true: an entry that does not say otherwise is usable.
      $enabled = $true
      if ($entryProps -contains 'enabled' -and $null -ne $entry.enabled) {
        if ($entry.enabled -is [bool]) { $enabled = [bool]$entry.enabled }
        else { $enabled = (([string]$entry.enabled).Trim().ToLowerInvariant() -ne 'false') }
      }

      [void]$accounts.Add([ordered]@{
        Alias   = [string]$alias
        Nick    = [string]$fields['nick']
        QqId    = [string]$fields['qqId']
        Enabled = [bool]$enabled
        Note    = [string]$fields['note']
      })
    }
    $cfg['Accounts'] = @($accounts)
    if ($warnings.Count -gt 0) { $cfg['AccountsWarning'] = ($warnings -join '; ') }
  }

  # Evidence directory may be absolute or framework-relative.
  if (-not [string]::IsNullOrEmpty([string]$cfg.EvidenceDir)) {
    if (-not [System.IO.Path]::IsPathRooted([string]$cfg.EvidenceDir)) {
      $cfg.EvidenceDir = Join-Path $Root ([string]$cfg.EvidenceDir)
    }
  } else {
    $cfg.EvidenceDir = Join-Path $Root 'evidence'
  }

  # Timeout defaults fill any key the file omitted.
  $timeoutDefaults = @{
    DefaultTimeoutSec = 30
    SearchResultsMs   = 12000
    SwitchHeaderMs    = 10000
    AfterFocusMs      = 600
    AfterTypeMs       = 1000
    AfterSendMs       = 5000
    SettleMs          = 700
  }
  foreach ($k in $timeoutDefaults.Keys) {
    if (-not $cfg.ContainsKey($k) -or $null -eq $cfg[$k]) { $cfg[$k] = $timeoutDefaults[$k] }
  }
  return $cfg
}

function Get-QQTimeouts {
  <#
  .SYNOPSIS
    Converts the flat config timeout keys into a millisecond table.
  .PARAMETER Config
    Hashtable from Get-QQConfig, or null for pure defaults.
  .OUTPUTS
    [hashtable] millisecond values keyed by purpose.
  #>
  param($Config)
  $values = @{
    switchHeaderMs  = 10000
    searchResultsMs = 12000
    afterFocusMs    = 600
    afterTypeMs     = 1000
    afterSendMs     = 5000
    settleMs        = 700
  }
  if ($null -ne $Config) {
    foreach ($k in @('SwitchHeaderMs', 'SearchResultsMs', 'AfterFocusMs', 'AfterTypeMs', 'AfterSendMs', 'SettleMs')) {
      if ($Config.ContainsKey($k) -and $null -ne $Config[$k]) {
        $short = $k.Substring(0, 1).ToLower() + $k.Substring(1)
        $values[$short] = [int]$Config[$k]
      }
    }
  }
  return $values
}

function Get-QQEffectiveTimeouts {
  <#
  .SYNOPSIS
    Applies the -TimeoutSec budget to a millisecond timeout table.
  .DESCRIPTION
    FRAMEWORK-DESIGN 4.3 gives the window commands -TimeoutSec (timeouts.defaultSec
    in config.json, 30 s). The per-stage waits stay the primary control; the
    override is a ceiling, so a stage wait that would outlast the caller's budget
    is shortened to it and no wait can outlast the budget by more than one stage.
    At the shipped defaults nothing changes: every stage wait is already under 30 s.
  .PARAMETER Timeouts
    Millisecond table from Get-QQTimeouts.
  .PARAMETER TimeoutSec
    Ceiling in seconds, or 0 for "no ceiling" (the dispatcher resolves the
    configured default before calling, so 0 here means the operator disabled it).
  .OUTPUTS
    [hashtable] the same keys, each capped. A copy is returned; the input is not
    modified, because the same table is shared through the dispatcher context.
  #>
  param(
    [Parameter(Mandatory)]$Timeouts,
    [int]$TimeoutSec = 0
  )
  $capped = @{}
  foreach ($key in @($Timeouts.Keys)) { $capped[$key] = [int]$Timeouts[$key] }
  if ($TimeoutSec -le 0) { return $capped }
  $capMs = $TimeoutSec * 1000
  foreach ($key in @($capped.Keys)) {
    if ([int]$capped[$key] -gt $capMs) { $capped[$key] = [int]$capMs }
  }
  return $capped
}

function Get-QQA11yMinNodes {
  <#
  .SYNOPSIS
    Resolves the accessibility activation threshold from a config hashtable.
  .DESCRIPTION
    a11y.minNodes is the single definition of "the tree is activated", shared by
    doctor's readiness verdict and by every command that refuses to act on a
    9-node skeleton window. It used to be hardcoded per call site (10 in one
    place, 100 in another), which let doctor call an instance ready while a
    command refused it.
  .PARAMETER Config
    Config hashtable from Get-QQConfig, or null for the built-in default.
  .OUTPUTS
    [int] minimum node count.
  #>
  param($Config = $null)
  if ($null -ne $Config -and $Config.ContainsKey('A11yMinNodes') -and [int]$Config['A11yMinNodes'] -gt 0) {
    return [int]$Config['A11yMinNodes']
  }
  return 100
}

function Test-QQA11yActive {
  <#
  .SYNOPSIS
    Reports whether a node count means the accessibility tree is activated.
  .PARAMETER NodeCount
    Nodes read from the window.
  .PARAMETER MinNodes
    Threshold from Get-QQA11yMinNodes.
  .OUTPUTS
    [bool].
  #>
  param(
    [int]$NodeCount = 0,
    [int]$MinNodes = 100
  )
  if ($MinNodes -le 0) { $MinNodes = 100 }
  return ($NodeCount -gt $MinNodes)
}

function Test-QQIsDpiAware {
  <#
  .SYNOPSIS
    Reports whether this process ended up DPI aware.
  .DESCRIPTION
    Decided once at load by QQUiaNative.EnableDpiAwareness. An aware process reads
    UIA bounding rectangles, GetWindowRect and GDI capture in one physical pixel
    space, so coordinates must NOT be scaled; 'unknown' (a host too old to report
    its awareness) and 'unaware' both take the converting branch.
  .OUTPUTS
    [bool] true when the process is DPI aware.
  #>
  if ([string]::IsNullOrEmpty([string]$script:QQ_DPI_AWARE)) { return $false }
  return (@('per-monitor-v2', 'per-monitor', 'system') -contains [string]$script:QQ_DPI_AWARE)
}

function Get-QQDpiAwareness {
  <#
  .SYNOPSIS
    Returns the DPI awareness level that is actually in effect.
  .OUTPUTS
    [string] per-monitor-v2, per-monitor, system, unaware or unknown.
  #>
  return [string]$script:QQ_DPI_AWARE
}

function Get-QQSelector {
  <#
  .SYNOPSIS
    Returns the parsed selectors.psd1 registry.
  .OUTPUTS
    [hashtable] the registry, or $null when it failed to load.
  #>
  return $script:QQ_SEL
}

function Get-QQSelectorEntry {
  <#
  .SYNOPSIS
    Returns one selector entry as Class/Type/Stable/Required/Note.
  .PARAMETER Section
    Top-level section name, for example 'Chat'.
  .PARAMETER Name
    Entry name inside the section, for example 'Header'.
  .OUTPUTS
    [hashtable] normalized entry (Class and Type default to '').
  #>
  param(
    [Parameter(Mandatory)][string]$Section,
    [Parameter(Mandatory)][string]$Name
  )
  if ($null -eq $script:QQ_SEL) {
    throw (New-QQErrorRecord -Code 'ERROR' -Message 'selectors.psd1 is not loaded' -Details @{ section = $Section; name = $Name })
  }
  if (-not $script:QQ_SEL.ContainsKey($Section)) {
    throw (New-QQErrorRecord -Code 'ERROR' -Message ("unknown selector section: {0}" -f $Section) -Details @{ section = $Section })
  }
  $sectionObj = $script:QQ_SEL[$Section]
  if (-not $sectionObj.ContainsKey($Name)) {
    throw (New-QQErrorRecord -Code 'ERROR' -Message ("unknown selector: {0}.{1}" -f $Section, $Name) -Details @{ section = $Section; name = $Name })
  }
  $entry = $sectionObj[$Name]
  $class = ''
  if ($entry.ContainsKey('Class')) { $class = [string]$entry['Class'] }
  $type = ''
  if ($entry.ContainsKey('Type')) { $type = [string]$entry['Type'] }
  $stable = $true
  if ($entry.ContainsKey('Stable')) { $stable = [bool]$entry['Stable'] }
  $required = $false
  if ($entry.ContainsKey('Required')) { $required = [bool]$entry['Required'] }
  $note = ''
  if ($entry.ContainsKey('Note')) { $note = [string]$entry['Note'] }
  return @{ Class = $class; Type = $type; Stable = $stable; Required = $required; Note = $note }
}

function New-QQErrorRecord {
  <#
  .SYNOPSIS
    Builds an exception carrying a framework error code and details. Throw it.
  .DESCRIPTION
    The dispatcher unwraps Data['QQCode'] / Data['QQDetails'] to build the JSON
    envelope's error object, which keeps error classification in one place.
  .PARAMETER Code
    One of the FRAMEWORK-DESIGN 5.3 names, or a GUARD_* name mapped to
    GUARD_ABORT by Resolve-QQExitCodeName.
  .PARAMETER Message
    Human-readable failure text for the agent.
  .PARAMETER Details
    Structured context (the mismatching header, the expected nick, ...).
  .OUTPUTS
    [Exception] ready to throw.
  #>
  param(
    [Parameter(Mandatory)][string]$Code,
    [Parameter(Mandatory)][string]$Message,
    $Details = $null
  )
  $ex = New-Object System.Exception($Message)
  $ex.Data['QQCode'] = $Code
  if ($null -ne $Details) { $ex.Data['QQDetails'] = $Details }
  return $ex
}

function Resolve-QQExitCodeName {
  <#
  .SYNOPSIS
    Maps a detailed error code onto a FRAMEWORK-DESIGN 5.3 exit-code name.
  .DESCRIPTION
    Guard failures keep their specific code (GUARD_HEADER_MISMATCH, ...) for the
    agent log while still exiting with GUARD_ABORT (4), which is what the manual
    tells the agent to treat as "stop, do not retry".
  .PARAMETER Code
    Raw code from an exception, possibly a GUARD_* name.
  .OUTPUTS
    [string] one of OK, ERROR, BAD_ARGS, NOT_FOUND, GUARD_ABORT, ENV_NOT_READY,
    TIMEOUT.
  #>
  param([string]$Code)
  if ([string]::IsNullOrEmpty($Code)) { return 'ERROR' }
  if (Test-QQIsExitCodeName -Name $Code) { return $Code }
  if ($Code -like 'GUARD_*') { return 'GUARD_ABORT' }
  return 'ERROR'
}

# =============================================================================
# Window and instance enumeration
# =============================================================================

function Get-QQWindowList {
  <#
  .SYNOPSIS
    Enumerates visible QQ top-level windows as Hwnd/Pid/Width/Height/X/Y/Title.
  .DESCRIPTION
    Attaches only: no process is launched, restarted, or stopped. The window
    class filter (Chrome_WidgetWin_1) and the process-name filter together keep
    renderer and helper windows out of the result.
  .PARAMETER Config
    Config hashtable from Get-QQConfig, or null for defaults.
  .OUTPUTS
    [object[]] window records, unsorted. Scale is the window's DPI factor, or 0
    when the host could not report it.
  #>
  param($Config = $null)
  $procName = 'QQ'
  $winClass = 'Chrome_WidgetWin_1'
  # Width floor, most specific source first: instances.minWindowWidth from
  # config.json, then selectors.psd1 Window.MinWidth, then the built-in 400. The
  # provenance test is not optional: Get-QQConfig always answers MinWindowWidth
  # with its own default, so a ContainsKey check would let that default shadow an
  # edited selectors.psd1 with a value nobody configured.
  $minWidth = 400
  if ($null -ne $script:QQ_SEL -and $script:QQ_SEL.ContainsKey('Window')) {
    $w = $script:QQ_SEL['Window']
    if ($w.ContainsKey('ProcessName')) { $procName = [string]$w['ProcessName'] }
    if ($w.ContainsKey('Class')) { $winClass = [string]$w['Class'] }
    if ($w.ContainsKey('MinWidth') -and [int]$w['MinWidth'] -gt 0) { $minWidth = [int]$w['MinWidth'] }
  }
  if ($null -ne $Config) {
    $explicitMinWidth = ($Config.ContainsKey('FileKeys') -and @($Config['FileKeys']) -contains 'MinWindowWidth')
    if ($explicitMinWidth -and [int]$Config['MinWindowWidth'] -gt 0) { $minWidth = [int]$Config['MinWindowWidth'] }
    if ($Config.ContainsKey('IgnorePids')) { $ignore = @($Config['IgnorePids']) } else { $ignore = @() }
  } else {
    $ignore = @()
  }

  $pids = @()
  foreach ($p in @(Get-Process -Name $procName -ErrorAction SilentlyContinue)) {
    if ($ignore -contains [int]$p.Id) { continue }
    $pids += [int]$p.Id
  }
  if ($pids.Count -eq 0) { return @() }

  $list = New-Object System.Collections.ArrayList
  $cb = [QQUiaNative+EnumProc]{
    param($h, $p)
    $wpid = [int][QQUiaNative]::WinPid($h)
    if ($pids -notcontains $wpid) { return $true }
    if (-not [QQUiaNative]::IsWindowVisible($h)) { return $true }
    if ([QQUiaNative]::Cls($h) -ne $winClass) { return $true }
    $r = New-Object QQUiaNative+RECT
    if (-not [QQUiaNative]::GetWindowRect($h, [ref]$r)) { return $true }
    $width = $r.Right - $r.Left
    if ($width -lt $minWidth) { return $true }
    # The DPI is read once and reused. It used to be read twice in this one
    # record, which is two native round trips for one value and lets the second
    # read disagree with the first if the window moves to another monitor mid-enum.
    $scale = Get-QQWindowDpiScale -Hwnd $h
    [void]$list.Add([pscustomobject]@{
      Hwnd   = [System.IntPtr]$h
      Pid    = $wpid
      Title  = [QQUiaNative]::Text($h)
      Width  = [int]$width
      Height = [int]($r.Bottom - $r.Top)
      X      = [int]$r.Left
      Y      = [int]$r.Top
      Scale  = [double]$scale
    })
    return $true
  }
  [void][QQUiaNative]::EnumWindows($cb, [IntPtr]::Zero)
  return @($list)
}

function Get-QQWindowDpiScale {
  <#
  .SYNOPSIS
    Returns a window's DPI scale factor (1.5 at 150%), or 0 when unknown.
  .DESCRIPTION
    The raw DPI comes from GetDpiForWindow. A value outside 72..800 (75%..833%)
    is treated as unusable AND reported: the old 480 upper bound returned 0 for a
    legitimate high-DPI display, and a scale of 0 reads downstream as "unscaled",
    which is the wrong answer to give quietly.
  .PARAMETER Hwnd
    Window handle.
  .OUTPUTS
    [double] DPI divided by 96, or 0 when the host could not report a usable DPI.
  #>
  param([Parameter(Mandatory)][System.IntPtr]$Hwnd)
  $dpi = 0
  try { $dpi = [int][QQUiaNative]::GetWindowDpi($Hwnd) } catch { $dpi = 0 }
  if ($dpi -le 0) {
    Write-QQLog -Text ("window {0} did not report a dpi: treating it as unscaled" -f $Hwnd)
    return 0.0
  }
  if ($dpi -lt 72 -or $dpi -gt 800) {
    Write-QQLog -Text ("window {0} reports dpi {1}, outside the accepted 72..800 range: treating it as unscaled" -f $Hwnd, $dpi)
    return 0.0
  }
  return [double]$dpi / 96.0
}

function Get-QQWindowInfo {
  <#
  .SYNOPSIS
    Returns the target instance's window record, or throws NOT_FOUND.
  .PARAMETER TargetPid
    QQ process id, as returned by `identify`. There is no default: a guessed pid
    is how a message reaches the wrong account.
  .PARAMETER Config
    Config hashtable, or null.
  .OUTPUTS
    Window record with Hwnd/Pid/Width/Height/X/Y/Title/Scale.
  #>
  param(
    [Parameter(Mandatory)][int]$TargetPid,
    $Config = $null
  )
  $candidates = @(Get-QQWindowList -Config $Config | Where-Object { $_.Pid -eq $TargetPid } | Sort-Object Width -Descending)
  if ($candidates.Count -eq 0) {
    throw (New-QQErrorRecord -Code 'NOT_FOUND' -Message ("no visible QQ window for pid {0}" -f $TargetPid) -Details @{ pid = $TargetPid })
  }
  return $candidates[0]
}

function Get-QQRectOf {
  <#
  .SYNOPSIS
    Reads an element's bounding rectangle in UIA (physical) pixels.
  .PARAMETER Element
    UIA element.
  .OUTPUTS
    [hashtable] X, Y, W, H, CX, CY in physical pixels.
  #>
  param([Parameter(Mandatory)]$Element)
  $r = $Element.Current.BoundingRectangle
  $w = [double]$r.Width
  $h = [double]$r.Height
  if ([double]::IsInfinity($w) -or [double]::IsNaN($w)) { $w = -1 }
  if ([double]::IsInfinity($h) -or [double]::IsNaN($h)) { $h = -1 }
  return @{
    X  = [int]$r.X
    Y  = [int]$r.Y
    W  = [int]$w
    H  = [int]$h
    CX = [int]($r.X + $w / 2)
    CY = [int]($r.Y + $h / 2)
  }
}

function Get-QQLogicalPoint {
  <#
  .SYNOPSIS
    Converts a UIA (physical) point to the virtualized coordinates a DPI-unaware
    process must hand to SetCursorPos.
  .DESCRIPTION
    This is the DPI-unaware branch on its own. Such a process receives UIA
    bounding rectangles in physical pixels while its own cursor API works in
    logical space: at 150% scaling a physical coordinate is 1.5x its logical
    value, so a click placed without this conversion misses its target. An aware
    process must NOT divide (see Convert-QQPointToPhysical), which is the double
    conversion the split exists to prevent.
  .PARAMETER X
    Physical X.
  .PARAMETER Y
    Physical Y.
  .PARAMETER Scale
    DPI scale factor (1.5 at 150%); values below 1 are treated as 1.
  .OUTPUTS
    [hashtable] X and Y in logical pixels.
  #>
  param(
    [Parameter(Mandatory)][int]$X,
    [Parameter(Mandatory)][int]$Y,
    [double]$Scale = 1.0
  )
  if ($Scale -lt 1.0) { $Scale = 1.0 }
  return @{ X = [int][Math]::Round($X / $Scale); Y = [int][Math]::Round($Y / $Scale) }
}

function Convert-QQPointToPhysical {
  <#
  .SYNOPSIS
    Converts a UIA point into the coordinate space SetCursorPos expects here.
  .DESCRIPTION
    UIA always reports physical pixels. What SetCursorPos expects depends on this
    process: physical when it is DPI aware, virtualized when it is not. Every
    cursor placement goes through this function, so the decision lives in one
    place instead of as a division at each call site.
  .PARAMETER X
    UIA X in physical pixels.
  .PARAMETER Y
    UIA Y in physical pixels.
  .PARAMETER Scale
    DPI scale factor, used on the unaware branch only.
  .OUTPUTS
    [hashtable] X and Y ready for SetCursorPos.
  #>
  param(
    [Parameter(Mandatory)][int]$X,
    [Parameter(Mandatory)][int]$Y,
    [double]$Scale = 1.0
  )
  if (Test-QQIsDpiAware) { return @{ X = [int]$X; Y = [int]$Y } }
  return Get-QQLogicalPoint -X $X -Y $Y -Scale $Scale
}

function Convert-QQWindowRectToPhysical {
  <#
  .SYNOPSIS
    Converts a GetWindowRect rectangle into the physical pixels GDI captures in.
  .DESCRIPTION
    GetWindowRect answers in physical pixels once this process is DPI aware and in
    logical pixels otherwise, while BitBlt and the desktop DC are always physical.
    So an unaware process scales the rectangle by the window's DPI and an aware one
    must not: multiplying an already physical rectangle is what cropped the
    evidence screenshot to the wrong region at 150% scaling.
  .PARAMETER Left
    RECT.Left as returned by GetWindowRect.
  .PARAMETER Top
    RECT.Top.
  .PARAMETER Right
    RECT.Right.
  .PARAMETER Bottom
    RECT.Bottom.
  .PARAMETER Scale
    DPI scale factor, used on the unaware branch only.
  .OUTPUTS
    [hashtable] X, Y, W, H in physical pixels.
  #>
  param(
    [Parameter(Mandatory)][int]$Left,
    [Parameter(Mandatory)][int]$Top,
    [Parameter(Mandatory)][int]$Right,
    [Parameter(Mandatory)][int]$Bottom,
    [double]$Scale = 1.0
  )
  $w = [int]($Right - $Left)
  $h = [int]($Bottom - $Top)
  if (Test-QQIsDpiAware) { return @{ X = [int]$Left; Y = [int]$Top; W = [int]$w; H = [int]$h } }
  if ($Scale -lt 1.0) { $Scale = 1.0 }
  return @{
    X = [int][Math]::Round([double]$Left * $Scale)
    Y = [int][Math]::Round([double]$Top * $Scale)
    W = [int][Math]::Round([double]$w * $Scale)
    H = [int][Math]::Round([double]$h * $Scale)
  }
}

function Get-QQScaleForPid {
  <#
  .SYNOPSIS
    Resolves the DPI scale to use for a target instance.
  .DESCRIPTION
    mode=auto uses the window's own DPI (per-monitor aware); any other mode uses
    the configured dpi.scale so an operator can pin the value on a host where DPI
    detection is wrong.

    The value is reported in payloads and is what the unaware conversion branch
    needs. It is not consulted at all while the process is DPI aware, where UIA and
    the cursor API already share one coordinate space, so tuning it cannot fix a
    mis-placed click on an aware host (look at the reported dpi awareness instead).
  .PARAMETER TargetPid
    QQ process id.
  .PARAMETER Config
    Config hashtable, or null.
  .OUTPUTS
    [double] scale factor, never below 1.0.
  #>
  param(
    [Parameter(Mandatory)][int]$TargetPid,
    $Config = $null
  )
  $mode = 'auto'
  $fallback = 1.5
  if ($null -ne $Config) {
    if ($Config.ContainsKey('DpiMode') -and -not [string]::IsNullOrEmpty([string]$Config['DpiMode'])) { $mode = [string]$Config['DpiMode'] }
    if ($Config.ContainsKey('DpiScale') -and [double]$Config['DpiScale'] -gt 0) { $fallback = [double]$Config['DpiScale'] }
  }
  if ($mode -ne 'auto') { return [Math]::Max(1.0, $fallback) }
  try {
    $win = Get-QQWindowInfo -TargetPid $TargetPid -Config $Config
    if ($win.Scale -ge 1.0) { return [double]$win.Scale }
  } catch {
    # A missing window is reported by the caller's own NOT_FOUND path; falling
    # back here only keeps the scale query total.
  }
  return [Math]::Max(1.0, $fallback)
}

# =============================================================================
# UIA access
# =============================================================================

function Get-QQRootElement {
  <#
  .SYNOPSIS
    Returns the UIA root element of the target instance's window.
  .PARAMETER TargetPid
    QQ process id.
  .PARAMETER Config
    Config hashtable, or null.
  .OUTPUTS
    AutomationElement root of the QQ window.
  #>
  param(
    [Parameter(Mandatory)][int]$TargetPid,
    $Config = $null
  )
  $win = Get-QQWindowInfo -TargetPid $TargetPid -Config $Config
  try {
    $el = [System.Windows.Automation.AutomationElement]::FromHandle($win.Hwnd)
  } catch {
    throw (New-QQErrorRecord -Code 'NOT_FOUND' -Message ("AutomationElement.FromHandle failed for hwnd {0}" -f $win.Hwnd) -Details @{ pid = $TargetPid; hwnd = [int64]$win.Hwnd })
  }
  if ($null -eq $el) {
    throw (New-QQErrorRecord -Code 'NOT_FOUND' -Message ("no UIA element for hwnd {0}" -f $win.Hwnd) -Details @{ pid = $TargetPid; hwnd = [int64]$win.Hwnd })
  }
  return $el
}

function Get-QQAllNodes {
  <#
  .SYNOPSIS
    Reads every descendant node of a root element.
  .PARAMETER Root
    UIA element to descend from.
  .OUTPUTS
    UIA elements in document order.
  #>
  param([Parameter(Mandatory)]$Root)
  try {
    return @($Root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition))
  } catch {
    throw (New-QQErrorRecord -Code 'ERROR' -Message ("UIA tree walk failed: {0}" -f $_.Exception.Message))
  }
}

function Get-QQNodeCount {
  <#
  .SYNOPSIS
    Counts an instance's UIA nodes, reporting 0 for an unreadable window.
  .PARAMETER Root
    UIA root element.
  .OUTPUTS
    [int] descendant count.
  #>
  param([Parameter(Mandatory)]$Root)
  try {
    return $Root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition).Count
  } catch {
    return 0
  }
}

function Test-QQNodeMatch {
  <#
  .SYNOPSIS
    Tests one UIA node against a Class/Type selector pair.
  .PARAMETER Element
    UIA element.
  .PARAMETER Class
    Class-name regex; '' matches any class.
  .PARAMETER Type
    ControlType regex without the 'ControlType.' prefix; '' matches any type.
  .OUTPUTS
    [bool].
  #>
  param(
    [Parameter(Mandatory)]$Element,
    [string]$Class = '',
    [string]$Type = ''
  )
  try {
    if ($Type -ne '') {
      $ct = $Element.Current.ControlType.ProgrammaticName
      if ($ct -notmatch ('^ControlType\.' + $Type + '$')) { return $false }
    } elseif ($Element.Current.ControlType.ProgrammaticName -notmatch '^ControlType\.') {
      return $false
    }
    if ($Class -ne '') { return ($Element.Current.ClassName -match $Class) }
    return $true
  } catch {
    return $false
  }
}

function Get-QQNodes {
  <#
  .SYNOPSIS
    Returns every node matching a selector from lib\selectors.psd1.
  .PARAMETER Root
    UIA root element.
  .PARAMETER Section
    Selector section, for example 'Sessions'.
  .PARAMETER Name
    Selector name, for example 'Item'.
  .PARAMETER Nodes
    Precomputed node list to filter instead of walking the tree again.
  .OUTPUTS
    [object[]] matching elements, possibly empty.
  #>
  param(
    [Parameter(Mandatory)]$Root,
    [Parameter(Mandatory)][string]$Section,
    [Parameter(Mandatory)][string]$Name,
    $Nodes = $null
  )
  $entry = Get-QQSelectorEntry -Section $Section -Name $Name
  $all = $(if ($null -ne $Nodes) { $Nodes } else { Get-QQAllNodes -Root $Root })
  return @($all | Where-Object { Test-QQNodeMatch -Element $_ -Class $entry.Class -Type $entry.Type })
}

function Get-QQNode {
  <#
  .SYNOPSIS
    Returns the first node matching a selector, or $null.
  .PARAMETER Root
    UIA root element.
  .PARAMETER Section
    Selector section.
  .PARAMETER Name
    Selector name.
  .PARAMETER Index
    Zero-based index among the matches.
  .PARAMETER Nodes
    Precomputed node list.
  .OUTPUTS
    AutomationElement or $null.
  #>
  param(
    [Parameter(Mandatory)]$Root,
    [Parameter(Mandatory)][string]$Section,
    [Parameter(Mandatory)][string]$Name,
    [int]$Index = 0,
    $Nodes = $null
  )
  $hits = @(Get-QQNodes -Root $Root -Section $Section -Name $Name -Nodes $Nodes)
  if ($hits.Count -eq 0) { return $null }
  return $hits[[Math]::Min($Index, $hits.Count - 1)]
}

function Get-QQChildNodes {
  <#
  .SYNOPSIS
    Returns the direct control-view children of a node.
  .PARAMETER Element
    UIA element.
  .PARAMETER Max
    Safety cap on the number of children returned.
  .OUTPUTS
    [object[]] child elements.
  #>
  param(
    [Parameter(Mandatory)]$Element,
    [int]$Max = 200
  )
  $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
  $cache = [System.Windows.Automation.CacheRequest]::Current
  $kids = New-Object System.Collections.ArrayList
  $c = $null
  try { $c = $walker.GetFirstChild($Element, $cache) } catch { return @() }
  while ($null -ne $c -and $kids.Count -lt $Max) {
    [void]$kids.Add($c)
    try { $c = $walker.GetNextSibling($c, $cache) } catch { break }
  }
  return @($kids)
}

function Get-QQDescendants {
  <#
  .SYNOPSIS
    Walks a node's control-view subtree in document order.
  .PARAMETER Element
    UIA element to descend from.
  .PARAMETER Max
    Safety cap on the number of nodes returned.
  .OUTPUTS
    [object[]] descendant elements, deepest-last.
  #>
  param(
    [Parameter(Mandatory)]$Element,
    [int]$Max = 4000
  )
  $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
  $cache = [System.Windows.Automation.CacheRequest]::Current
  $out = New-Object System.Collections.ArrayList
  $stack = New-Object System.Collections.Stack
  $stack.Push($Element)
  while ($stack.Count -gt 0 -and $out.Count -lt $Max) {
    $cur = $stack.Pop()
    [void]$out.Add($cur)
    $kids = New-Object System.Collections.ArrayList
    $c = $null
    try { $c = $walker.GetFirstChild($cur, $cache) } catch { $c = $null }
    while ($null -ne $c) {
      [void]$kids.Add($c)
      try { $c = $walker.GetNextSibling($c, $cache) } catch { break }
    }
    for ($i = $kids.Count - 1; $i -ge 0; $i--) { $stack.Push($kids[$i]) }
  }
  return @($out)
}

function Get-QQParentWhere {
  <#
  .SYNOPSIS
    Climbs from a node until an ancestor's class name matches a regex.
  .DESCRIPTION
    TreeWalker.GetParent requires an explicit CacheRequest here; calling it with
    one argument raises "cannot find an overload" on PowerShell 5.1.
  .PARAMETER Element
    Start element.
  .PARAMETER ClassRegex
    Class-name regex the ancestor must satisfy.
  .PARAMETER MaxUp
    Maximum number of levels to climb.
  .OUTPUTS
    AutomationElement or $null.
  #>
  param(
    [Parameter(Mandatory)]$Element,
    [Parameter(Mandatory)][string]$ClassRegex,
    [int]$MaxUp = 8
  )
  $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
  $cache = [System.Windows.Automation.CacheRequest]::Current
  $cur = $Element
  for ($i = 0; $i -lt $MaxUp; $i++) {
    try { $cur = $walker.GetParent($cur, $cache) } catch { return $null }
    if ($null -eq $cur) { return $null }
    try { if ($cur.Current.ClassName -match $ClassRegex) { return $cur } } catch { return $null }
  }
  return $null
}

function Get-QQTextPatternText {
  <#
  .SYNOPSIS
    Reads an element's text through TextPattern.
  .DESCRIPTION
    The message editor is contenteditable and exposes no ValuePattern, so
    TextPattern is the only way to read back what was typed.
  .PARAMETER Element
    UIA element, or null.
  .PARAMETER MaxChars
    Maximum characters to read.
  .OUTPUTS
    [string] the text, or '' when the pattern is unavailable.
  #>
  param(
    $Element,
    [int]$MaxChars = 400
  )
  if ($null -eq $Element) { return '' }
  try {
    $tp = $Element.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern)
    return [string]$tp.DocumentRange.GetText($MaxChars)
  } catch {
    return ''
  }
}

function Get-QQValuePatternValue {
  <#
  .SYNOPSIS
    Reads an element's ValuePattern value, or $null when unsupported.
  .PARAMETER Element
    UIA element, or null.
  .OUTPUTS
    [string] value or $null.
  #>
  param($Element)
  if ($null -eq $Element) { return $null }
  try {
    $vp = $Element.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
    return [string]$vp.Current.Value
  } catch {
    return $null
  }
}

function Get-QQFocusedElement {
  <#
  .SYNOPSIS
    Returns the process-wide UIA focused element, or $null.
  .OUTPUTS
    AutomationElement or $null.
  #>
  try { return [System.Windows.Automation.AutomationElement]::FocusedElement } catch { return $null }
}

# =============================================================================
# Focus, waiting, clicking
# =============================================================================

function Invoke-QQWindowFocus {
  <#
  .SYNOPSIS
    Activates a window so keyboard injection and screen capture both target it.
  .DESCRIPTION
    Confirms activation instead of assuming it: this process does not own the
    foreground window, so the plain SetForegroundWindow call can be refused and
    the caller would then type into, or capture, whatever window was in front.
    The returned flag is what callers act on.
  .PARAMETER Hwnd
    Target window handle.
  .PARAMETER TimeoutMs
    How long to wait for the window to actually become foreground.
  .OUTPUTS
    [bool] true when the window is foreground at return.
  #>
  param(
    [Parameter(Mandatory)][System.IntPtr]$Hwnd,
    [int]$TimeoutMs = 2500
  )
  $activated = $false
  try { $activated = [QQUiaNative]::ActivateWindow($Hwnd) } catch { $activated = $false }
  $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
  while ((Get-Date) -lt $deadline) {
    if ([QQUiaNative]::IsForeground($Hwnd)) { return $true }
    Start-Sleep -Milliseconds 120
    if (-not $activated) {
      try { $activated = [QQUiaNative]::ActivateWindow($Hwnd) } catch { $activated = $false }
    }
  }
  return [bool][QQUiaNative]::IsForeground($Hwnd)
}

function Invoke-QQElementClick {
  <#
  .SYNOPSIS
    Activates an element, preferring InvokePattern and falling back to a click.
  .DESCRIPTION
    SelectionItemPattern is unavailable on conversation rows, so InvokePattern is
    the primary path; a physical click at the element centre covers rows that
    expose neither pattern. The centre comes from the UIA bounding rectangle and
    goes through Convert-QQPointToPhysical, which is the single place that decides
    whether the cursor API wants physical or logical coordinates.
  .PARAMETER Element
    Target UIA element.
  .PARAMETER Scale
    DPI scale factor, used by the fallback only when this process is not DPI aware.
  .OUTPUTS
    [hashtable] Via: 'invoke' | 'click' | 'none'.
  #>
  param(
    [Parameter(Mandatory)]$Element,
    [double]$Scale = 1.0
  )
  $obj = $null
  try {
    if ($Element.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$obj)) {
      $obj.Invoke()
      return @{ Via = 'invoke' }
    }
  } catch {
    Write-QQLog -Text ("InvokePattern failed, falling back to a physical click: {0}" -f $_.Exception.Message)
  }
  $r = Get-QQRectOf -Element $Element
  if ($r.W -le 0 -or $r.H -le 0) { return @{ Via = 'none' } }
  $pt = Convert-QQPointToPhysical -X $r.CX -Y $r.CY -Scale $Scale
  [QQUiaNative]::Click($pt.X, $pt.Y)
  return @{ Via = 'click' }
}

function Set-QQElementFocus {
  <#
  .SYNOPSIS
    Focuses an element and confirms it through UIA.
  .PARAMETER Element
    Target element.
  .PARAMETER VerifyMs
    How long to wait for the element to report focus.
  .OUTPUTS
    [bool] true when the element is the focused element afterwards.
  #>
  param(
    [Parameter(Mandatory)]$Element,
    [int]$VerifyMs = 1200
  )
  try { $Element.SetFocus() } catch {
    Write-QQLog -Text ("SetFocus failed: {0}" -f $_.Exception.Message)
    return $false
  }
  $deadline = (Get-Date).AddMilliseconds($VerifyMs)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 120
    $focused = Get-QQFocusedElement
    if ($null -eq $focused) { continue }
    try {
      if ($focused.Current.NativeWindowHandle -eq $Element.Current.NativeWindowHandle -and
          $focused.Current.ClassName -eq $Element.Current.ClassName -and
          $focused.Current.Name -eq $Element.Current.Name) {
        return $true
      }
    } catch { }
    try { if ([System.Windows.Automation.AutomationElement]::Equals($focused, $Element)) { return $true } } catch { }
  }
  return $false
}

function Wait-QQCondition {
  <#
  .SYNOPSIS
    Polls a condition until it is true or the timeout expires.
  .PARAMETER Condition
    Script block returning a truthy value.
  .PARAMETER TimeoutMs
    Maximum wait.
  .PARAMETER IntervalMs
    Poll interval.
  .OUTPUTS
    [bool] whether the condition became true.
  #>
  param(
    [Parameter(Mandatory)][scriptblock]$Condition,
    [int]$TimeoutMs = 10000,
    [int]$IntervalMs = 500
  )
  $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
  while ($true) {
    $ok = $false
    try { $ok = [bool](& $Condition) } catch { $ok = $false }
    if ($ok) { return $true }
    if ((Get-Date) -ge $deadline) { return $false }
    Start-Sleep -Milliseconds $IntervalMs
  }
}

function Wait-QQNodeCount {
  <#
  .SYNOPSIS
    Waits for a window's accessibility tree to reach the activation threshold.
  .DESCRIPTION
    QQ activates its accessibility tree lazily, so the first UIA client to attach
    can still see the 9-node skeleton and report an inactive tree; a wait finds the
    activated tree without restarting QQ. a11y.nodeCountTimeoutMs bounds the wait
    (0 skips it), and the largest node list seen is returned either way, so a
    timeout reports the best evidence rather than an empty result.
  .PARAMETER Root
    UIA root element of the window.
  .PARAMETER MinNodes
    Activation threshold from Get-QQA11yMinNodes.
  .PARAMETER TimeoutMs
    Maximum wait in milliseconds, from a11y.nodeCountTimeoutMs.
  .PARAMETER Nodes
    Node list already read for this window, reused when it already passes.
  .OUTPUTS
    [object[]] the node list with the highest count observed.
  #>
  param(
    [Parameter(Mandatory)]$Root,
    [int]$MinNodes = 100,
    [int]$TimeoutMs = 0,
    $Nodes = $null
  )
  $best = @($Nodes)
  if (Test-QQA11yActive -NodeCount $best.Count -MinNodes $MinNodes) { return $best }
  if ($null -eq $Root -or $TimeoutMs -le 0) { return $best }

  $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
    $fresh = @()
    try { $fresh = @(Get-QQAllNodes -Root $Root) } catch { continue }
    if ($fresh.Count -gt $best.Count) { $best = $fresh }
    if (Test-QQA11yActive -NodeCount $best.Count -MinNodes $MinNodes) { break }
  }
  return $best
}

function Get-QQCurrentChatName {
  <#
  .SYNOPSIS
    Reads the open conversation title, or '' when no chat is open.
  .PARAMETER Root
    UIA root element.
  .PARAMETER Nodes
    Precomputed node list.
  .OUTPUTS
    [string] header name.
  #>
  param(
    [Parameter(Mandatory)]$Root,
    $Nodes = $null
  )
  $el = Get-QQNode -Root $Root -Section 'Chat' -Name 'Header' -Nodes $Nodes
  if ($null -eq $el) { return '' }
  try { return [string]$el.Current.Name } catch { return '' }
}

function Test-QQIsGroupChat {
  <#
  .SYNOPSIS
    Reports whether the open conversation is a group chat.
  .DESCRIPTION
    The group member panel is present only in group chats, which is the reliable
    discriminator the send guard depends on.
  .PARAMETER Root
    UIA root element.
  .PARAMETER Nodes
    Precomputed node list.
  .OUTPUTS
    [bool].
  #>
  param(
    [Parameter(Mandatory)]$Root,
    $Nodes = $null
  )
  $el = Get-QQNode -Root $Root -Section 'Chat' -Name 'GroupMembers' -Nodes $Nodes
  return ($null -ne $el)
}

function Wait-QQHeaderChange {
  <#
  .SYNOPSIS
    Waits for the conversation header to change away from a previous value.
  .DESCRIPTION
    Waiting for "header equals target" is not enough: a stale or search-result
    value can satisfy it while the pane still shows the previous conversation,
    which is how the pre-framework scripts sent to the wrong chat. Requiring an
    actual change is the guard FRAMEWORK-DESIGN 6.4 mandates.
  .PARAMETER Root
    UIA root element.
  .PARAMETER Before
    Header value observed before the switch.
  .PARAMETER TimeoutMs
    Maximum wait.
  .OUTPUTS
    [hashtable] Changed (bool) and Header (current value).
  #>
  param(
    [Parameter(Mandatory)]$Root,
    [string]$Before = '',
    [int]$TimeoutMs = 10000
  )
  $changed = Wait-QQCondition -TimeoutMs $TimeoutMs -IntervalMs 400 -Condition {
    $h = Get-QQCurrentChatName -Root $Root
    return (-not [string]::IsNullOrEmpty($h)) -and ($h -ne $Before)
  }
  return @{ Changed = $changed; Header = (Get-QQCurrentChatName -Root $Root) }
}

# =============================================================================
# Account identity
# =============================================================================

function Get-QQAccountIdentity {
  <#
  .SYNOPSIS
    Reads which account a QQ instance is logged in as.
  .DESCRIPTION
    The avatar element's Name is the authoritative source ('<nick>' followed by a
    localized avatar suffix). The topbar nickname is only a fallback, because it
    is absent on some builds. Window size and process age are never used as
    identity evidence (AGENT-MANUAL 4.3).
  .PARAMETER Root
    UIA root element.
  .PARAMETER Nodes
    Precomputed node list.
  .OUTPUTS
    [hashtable] Nick, ImageSuffix, Signature, Online, AbnormalOnline.
  #>
  param(
    [Parameter(Mandatory)]$Root,
    $Nodes = $null
  )
  $all = $(if ($null -ne $Nodes) { $Nodes } else { Get-QQAllNodes -Root $Root })
  $suffix = Get-QQUiText -Key 'avatarSuffix'
  $sigPrefix = Get-QQUiText -Key 'signaturePrefix'

  $nick = ''
  $avatar = Get-QQNode -Root $Root -Section 'Identity' -Name 'Avatar' -Nodes $all
  if ($null -ne $avatar) {
    try {
      $nick = [string]$avatar.Current.Name
      if (-not [string]::IsNullOrEmpty($suffix) -and $nick.EndsWith($suffix)) {
        $nick = $nick.Substring(0, $nick.Length - $suffix.Length)
      }
    } catch { $nick = '' }
  }
  if ([string]::IsNullOrEmpty($nick)) {
    $fallback = Get-QQNode -Root $Root -Section 'Identity' -Name 'Nickname' -Nodes $all
    if ($null -ne $fallback) {
      try { $nick = [string]$fallback.Current.Name } catch { $nick = '' }
    }
  }

  $signature = ''
  $sig = Get-QQNode -Root $Root -Section 'Identity' -Name 'Signature' -Nodes $all
  if ($null -ne $sig) {
    try {
      $signature = [string]$sig.Current.Name
      if (-not [string]::IsNullOrEmpty($sigPrefix) -and $signature.StartsWith($sigPrefix)) {
        $signature = $signature.Substring($sigPrefix.Length)
      }
    } catch { $signature = '' }
  }

  $online = $false
  $status = Get-QQNode -Root $Root -Section 'Identity' -Name 'OnlineStatus' -Nodes $all
  if ($null -ne $status) {
    try { $online = ($status.Current.ClassName -match 'icon-online') } catch { $online = $false }
  }
  $abnormal = $null -ne (Get-QQNode -Root $Root -Section 'Identity' -Name 'AbnormalOnline' -Nodes $all)

  return @{
    Nick           = [string]$nick
    Signature      = [string]$signature
    Online         = [bool]$online
    AbnormalOnline = [bool]$abnormal
  }
}

function Get-QQUiText {
  <#
  .SYNOPSIS
    Returns a localized UI string built from character-code escapes.
  .DESCRIPTION
    QQ's UI exposes localized labels (the avatar suffix, the update suffix, the
    signature prefix). The shipped source stays pure ASCII, so these strings are
    assembled here from [char] codes rather than stored as literals.
  .PARAMETER Key
    Key name: avatarSuffix, signaturePrefix, unreadSuffix, updateSuffix,
    sendLabel, imageKind, groupMarker, comprehensiveSearch, historyUnit.
  .OUTPUTS
    [string] the localized label, or '' for an unknown key.
  #>
  param([Parameter(Mandatory)][string]$Key)
  switch ($Key) {
    # <nick> + this suffix = the avatar element's Name
    'avatarSuffix'    { return [string]([char]0x7684 + [char]0x5934 + [char]0x50CF) }
    # signature Name prefix
    'signaturePrefix' { return [string]([char]0x4E2A + [char]0x6027 + [char]0x7B7E + [char]0x540D + [char]0xFF1A) }
    # unread badge Name suffix, as in "3" + this
    'unreadSuffix'    { return [string]([char]0x6761 + [char]0x672A + [char]0x8BFB) }
    # "[" + number + "]" + this, the list preview time marker
    'updateSuffix'    { return [string]([char]0x6761 + [char]0x65B0 + [char]0x6D88 + [char]0x606F) }
    # send button Name
    'sendLabel'       { return [string]([char]0x53D1 + [char]0x9001) }
    # image placeholder text; UIA exposes no image content
    'imageKind'       { return [string]([char]0x56FE + [char]0x7247) }
    # search-result group-row marker
    'groupMarker'     { return [string]([char]0x7FA4 + [char]0x804A) }
    # prefix of the "search everything" umbrella row
    'comprehensiveSearch' { return [string]([char]0x8FDB + [char]0x5165 + [char]0x7EFC + [char]0x5408 + [char]0x641C + [char]0x7D22) }
    # unit word of a chat-history search result, as in "<nick> 5" + this. The
    # search parser requires it: "<name> <number>" alone is not a history row.
    'historyUnit'     { return [string]([char]0x6761 + [char]0x76F8 + [char]0x5173 + [char]0x804A + [char]0x5929 + [char]0x8BB0 + [char]0x5F55) }
    default           { return '' }
  }
}

# =============================================================================
# Keyboard injection
# =============================================================================

function Send-QQText {
  <#
  .SYNOPSIS
    Types text into the focused control with physical keyboard events.
  .DESCRIPTION
    SendInput with KEYEVENTF_UNICODE is layout independent, so CJK text reaches
    the contenteditable editor without an IME, a clipboard, or SendKeys brace
    escaping. Line breaks are skipped: the caller decides when to press Enter,
    because in QQ a bare Enter sends the message.
  .PARAMETER Text
    Text to type.
  .PARAMETER DelayMs
    Per-character delay, which also paces the app's render loop.
  .OUTPUTS
    [int] number of characters submitted.
  #>
  param(
    [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
    [int]$DelayMs = 12
  )
  if ([string]::IsNullOrEmpty($Text)) { return 0 }
  return [int][QQUiaNative]::SendText($Text, [Math]::Max(0, $DelayMs))
}

function Send-QQEnter {
  <#
  .SYNOPSIS
    Presses Enter in the focused control.
  .PARAMETER Shift
    Press Shift+Enter instead, which inserts a line break rather than sending.
  .OUTPUTS
    [int] number of injected events.
  #>
  param([switch]$Shift)
  return [int][QQUiaNative]::PressKey(0x0D, [bool]$Shift)   # VK_RETURN
}

function Send-QQEscape {
  <#
  .SYNOPSIS
    Presses Escape, used to dismiss the search dropdown without leaving text.
  .OUTPUTS
    [int] number of injected events.
  #>
  return [int][QQUiaNative]::PressKey(0x1B, $false)          # VK_ESCAPE
}

# =============================================================================
# Evidence: screenshots, audit log
# =============================================================================

function Get-QQEvidenceDir {
  <#
  .SYNOPSIS
    Resolves the evidence directory and creates it when missing.
  .PARAMETER Config
    Config hashtable, or null.
  .PARAMETER Root
    Framework root, used when Config is null.
  .OUTPUTS
    [string] absolute evidence directory path.
  #>
  param(
    $Config = $null,
    [string]$Root = ''
  )
  $dir = ''
  if ($null -ne $Config -and $Config.ContainsKey('EvidenceDir')) { $dir = [string]$Config['EvidenceDir'] }
  if ([string]::IsNullOrEmpty($dir)) {
    if ([string]::IsNullOrEmpty($Root)) { $Root = $script:QQ_ROOT_DIR }
    $dir = Join-Path $Root 'evidence'
  }
  if (-not (Test-Path -LiteralPath $dir)) {
    [void](New-Item -ItemType Directory -Force -Path $dir)
  }
  return $dir
}

function New-QQEvidencePath {
  <#
  .SYNOPSIS
    Builds a timestamped evidence file name inside the evidence directory.
  .PARAMETER Dir
    Evidence directory.
  .PARAMETER Kind
    Short label, for example 'window' or 'screen'.
  .PARAMETER TargetPid
    QQ process id the evidence belongs to, or 0.
  .PARAMETER Extension
    File extension without a dot.
  .OUTPUTS
    [string] absolute path.
  #>
  param(
    [Parameter(Mandatory)][string]$Dir,
    [Parameter(Mandatory)][string]$Kind,
    [int]$TargetPid = 0,
    [string]$Extension = 'png'
  )
  $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss-fff')
  $safeKind = ($Kind -replace '[^A-Za-z0-9\-_]', '')
  $name = ('{0}-{1}-{2}.{3}' -f $stamp, $safeKind, $TargetPid, $Extension)
  return (Join-Path $Dir $name)
}

function Save-QQWindowScreenshot {
  <#
  .SYNOPSIS
    Captures the QQ window to a PNG in the evidence directory.
  .DESCRIPTION
    This is the artifact behind the manual's "read the screenshot and confirm the
    target" step. The window must be foreground first; the capture reads the
    window's visible rectangle through BitBlt.
  .PARAMETER Hwnd
    Window handle.
  .PARAMETER Dir
    Evidence directory.
  .PARAMETER Kind
    Label embedded in the file name.
  .PARAMETER TargetPid
    QQ process id. Named TargetPid, not Pid: $PID is a read-only automatic
    variable in PowerShell and a parameter of that name aborts the call.
  .PARAMETER Alias
    Optional fixed alias file (for example 'last-open-chat') kept alongside the
    timestamped copy so an agent can always read the newest evidence.
  .PARAMETER KeepAlias
    evidence.keepLatestAliases, passed in by the caller. False skips the alias copy
    entirely, which is what an operator who wants timestamped evidence only sets.
  .OUTPUTS
    [hashtable] Path, AliasPath, Width, Height, Error, Note.
  #>
  param(
    [Parameter(Mandatory)][System.IntPtr]$Hwnd,
    [Parameter(Mandatory)][string]$Dir,
    [Parameter(Mandatory)][string]$Kind,
    [int]$TargetPid = 0,
    [string]$Alias = '',
    [bool]$KeepAlias = $true
  )
  $path = New-QQEvidencePath -Dir $Dir -Kind $Kind -TargetPid $TargetPid
  $w = 0
  $h = 0
  $err = ''
  $note = ''

  # The rectangle is converted once, by Convert-QQWindowRectToPhysical, and the
  # window DPI is read only for the branch that needs it. An aware process gets
  # physical pixels from GetWindowRect and captures in physical pixels, so scaling
  # there is the double conversion that used to crop this image to the wrong
  # region at 150%.
  $scale = 1.0
  if (-not (Test-QQIsDpiAware)) {
    $scale = Get-QQWindowDpiScale -Hwnd $Hwnd
    if ($scale -lt 1.0) { $scale = 1.0 }
  }

  $rect = New-Object QQUiaNative+RECT
  $gotRect = [QQUiaNative]::GetWindowRect($Hwnd, [ref]$rect)
  if ($gotRect) {
    $box = Convert-QQWindowRectToPhysical -Left $rect.Left -Top $rect.Top -Right $rect.Right -Bottom $rect.Bottom -Scale $scale
    $lx = [int]$box.X
    $ly = [int]$box.Y
    $rw = [int]$box.W
    $rh = [int]$box.H

    # If another application's window sits where the QQ window should be, the
    # capture would silently produce that application: check first and report it
    # rather than handing the agent a misleading image.
    $probe = [QQUiaNative]::WindowAtPoint($lx + 40, $ly + 40)
    if ($probe -ne [IntPtr]::Zero -and $probe -ne $Hwnd -and -not [QQUiaNative]::IsAncestorOf($probe, $Hwnd)) {
      $foreground = [QQUiaNative]::IsForeground($Hwnd)
      $err = ('the screen area of hwnd {0} shows a different window (hwnd {1}); QQ foreground={2}' -f $Hwnd, $probe, $foreground)
    } elseif ($rw -le 0 -or $rh -le 0) {
      $err = 'window has no visible area'
    } else {
      $err = [QQUiaNative]::CaptureScreenRegionToFile($lx, $ly, $rw, $rh, $path, [ref]$w, [ref]$h)
      if ([string]::IsNullOrEmpty($err)) { $note = ('captured {0}x{1} at ({2},{3}); dpi awareness {4}, scale {5}' -f $w, $h, $lx, $ly, (Get-QQDpiAwareness), $scale) }
    }
  } else {
    $err = 'GetWindowRect failed'
  }

  if (-not [string]::IsNullOrEmpty($err)) {
    Write-QQLog -Text ("desktop-region capture failed ({0}); retrying through the window DC" -f $err)
    $w = 0
    $h = 0
    $err = [QQUiaNative]::CaptureWindowToFile($Hwnd, $path, [ref]$w, [ref]$h)
    if ([string]::IsNullOrEmpty($err)) { $note = ('captured through the window DC; dpi awareness {0}' -f (Get-QQDpiAwareness)) }
  }
  $aliasPath = ''
  if ($KeepAlias -and [string]::IsNullOrEmpty($err) -and -not [string]::IsNullOrEmpty($Alias)) {
    $safeAlias = ($Alias -replace '[^A-Za-z0-9\-_]', '')
    if (-not [string]::IsNullOrEmpty($safeAlias)) {
      $aliasPath = Join-Path $Dir ('{0}.png' -f $safeAlias)
      try { Copy-Item -LiteralPath $path -Destination $aliasPath -Force } catch { $aliasPath = '' }
    }
  }
  return @{
    Path      = $path
    AliasPath = $aliasPath
    Width     = [int]$w
    Height    = [int]$h
    Error     = [string]$err
    Note      = [string]$note
  }
}

function Write-QQAuditRecord {
  <#
  .SYNOPSIS
    Appends one JSON line to evidence\audit.jsonl for an L2 operation.
  .DESCRIPTION
    FRAMEWORK-DESIGN 6.8 requires every outward-writing operation to leave a
    trace: time, pid, account, target, message hash, result and screenshot path.
    A hash is always written; the plain text is included only when
    evidence.auditIncludeMessageText is true.

    Writes are unsequenced (a plain append), which is safe only because
    FRAMEWORK-DESIGN forbids concurrent framework calls: a second writer would
    interleave lines and break the one-record-per-line contract that
    Assert-QQRateLimit reads. Known limit, not an oversight.
  .PARAMETER Dir
    Evidence directory.
  .PARAMETER Record
    Hashtable of audit fields.
  .OUTPUTS
    [string] audit file path, or '' when auditing is disabled or failed.
  #>
  param(
    [Parameter(Mandatory)][string]$Dir,
    [Parameter(Mandatory)]$Record
  )
  try {
    $file = Join-Path $Dir 'audit.jsonl'
    $json = ($Record | ConvertTo-Json -Depth 6 -Compress)
    # One record per line, UTF-8 without a BOM: the JSONL reader must be able to
    # concatenate files, and PowerShell 5.1 reads BOM-less UTF-8 JSON correctly
    # only through an explicit encoding, which is what readers here always use.
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::AppendAllText($file, $json + [Environment]::NewLine, $utf8)
    return $file
  } catch {
    Write-QQLog -Text ("audit write failed: {0}" -f $_.Exception.Message)
    return ''
  }
}

function Get-QQStringHash {
  <#
  .SYNOPSIS
    Returns the SHA-256 hash of a string as lowercase hex.
  .PARAMETER Text
    Input text.
  .OUTPUTS
    [string] 64-character hex digest.
  #>
  param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $hash = $sha.ComputeHash($bytes)
    return (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
  } finally {
    $sha.Dispose()
  }
}

# =============================================================================
# Message parsing
# =============================================================================
function Get-QQSubtreeInfo {
  <#
  .SYNOPSIS
    Collects a node's subtree classes and names in a single walk.
  .DESCRIPTION
    Message and conversation rows both need the same traversal data. Reading it
    once per row instead of once per question keeps a 25-row pass to a handful of
    UIA round trips. Names keep document order, which is the order the app renders
    them (topmost first in the DOM), and for the message list that is oldest-first
    even when the pane is scrolled.
  .PARAMETER Element
    Root of the subtree.
  .PARAMETER Max
    Safety cap on visited nodes.
  .OUTPUTS
    [hashtable] Classes, Names (document order), Timestamp, Sender, Self.
  #>
  param(
    [Parameter(Mandatory)]$Element,
    [int]$Max = 400
  )
  $nodes = Get-QQDescendants -Element $Element -Max $Max
  $classes = New-Object System.Collections.ArrayList
  $names = New-Object System.Collections.ArrayList
  $timestamp = ''
  $sender = ''
  $self = $false
  foreach ($n in $nodes) {
    try {
      $cls = [string]$n.Current.ClassName
      if (-not [string]::IsNullOrEmpty($cls)) { [void]$classes.Add($cls) }
      $nm = [string]$n.Current.Name
      if (-not [string]::IsNullOrEmpty($nm)) { [void]$names.Add($nm) }
      if ($cls -match 'message__timestamp' -and [string]::IsNullOrEmpty($timestamp)) { $timestamp = $nm }
      if ($cls -match 'avatar-span' -and [string]::IsNullOrEmpty($sender)) { $sender = $nm }
      if ($cls -match '(^|\s)(container--self|message-container--self)($|\s)') { $self = $true }
    } catch { }
  }
  return @{
    Classes   = @($classes)
    Names     = @($names)
    Timestamp = [string]$timestamp
    Sender    = [string]$sender
    Self      = [bool]$self
  }
}

function Get-QQMessageKind {
  <#
  .SYNOPSIS
    Classifies a message by the classes inside its content box.
  .DESCRIPTION
    MessageKinds in lib\selectors.psd1 is ordered, and the first fingerprint that
    matches wins, so a specific kind (image, file, card) is decided before the
    generic text fallback. Image content itself is never readable through UIA, so
    an image message reports kind=image and only its placeholder text.
  .PARAMETER Classes
    Class names collected from the message (usually its content box).
  .OUTPUTS
    [string] text, image, file, face, market-face, card, video, voice, reply,
    system, or unknown.
  #>
  param($Classes = @())
  if ($null -eq $script:QQ_SEL -or -not $script:QQ_SEL.ContainsKey('MessageKinds')) { return 'unknown' }
  foreach ($fingerprint in @($script:QQ_SEL['MessageKinds'])) {
    $pattern = [string]$fingerprint['Match']
    foreach ($cls in @($Classes)) {
      if ([string]$cls -match $pattern) { return [string]$fingerprint['Kind'] }
    }
  }
  return 'unknown'
}

function Get-QQDescendantByClass {
  <#
  .SYNOPSIS
    Returns the first descendant whose class name matches a regex.
  .PARAMETER Element
    Root of the subtree.
  .PARAMETER ClassRegex
    Regex tested against each descendant's class name.
  .PARAMETER Max
    Safety cap on visited nodes.
  .OUTPUTS
    AutomationElement or $null.
  #>
  param(
    [Parameter(Mandatory)]$Element,
    [Parameter(Mandatory)][string]$ClassRegex,
    [int]$Max = 400
  )
  foreach ($n in (Get-QQDescendants -Element $Element -Max $Max)) {
    try { if ([string]$n.Current.ClassName -match $ClassRegex) { return $n } } catch { }
  }
  return $null
}

function Get-QQDescendantsByName {
  <#
  .SYNOPSIS
    Returns every descendant whose automation Name equals a string exactly.
  .DESCRIPTION
    Message content reaches UIA as an element's Name, never as its ClassName, so
    this is the lookup that can actually find a rendered message text inside the
    message area. Comparison is -ceq (case sensitive, exact): a send confirmation
    must not accept a string that merely looks like the message.
  .PARAMETER Element
    Root of the subtree.
  .PARAMETER Name
    Exact automation Name to match.
  .PARAMETER Max
    Safety cap on visited nodes.
  .OUTPUTS
    [object[]] matching elements, document order.
  #>
  param(
    [Parameter(Mandatory)]$Element,
    [Parameter(Mandatory)][AllowEmptyString()][string]$Name,
    [int]$Max = 400
  )
  $hits = New-Object System.Collections.ArrayList
  if ([string]::IsNullOrEmpty($Name)) { return @() }
  foreach ($n in (Get-QQDescendants -Element $Element -Max $Max)) {
    try { if ([string]$n.Current.Name -ceq $Name) { [void]$hits.Add($n) } } catch { }
  }
  return @($hits)
}

function Get-QQMessageParts {
  <#
  .SYNOPSIS
    Splits a message row into its metadata fields and its content fragments.
  .DESCRIPTION
    A group or direct message renders a metadata strip 12-14 physical pixels below
    the row top: the avatar, the "LV" label, the level number, the sender nick and
    (for the first message of a time group) the timestamp. That strip carries no
    class of its own to filter on, so it is identified by its position relative to
    the avatar element rather than by an absolute row offset.

    Content is then collected from the row's content box when one exists, and in
    document order otherwise, which keeps a peer message's text from being dropped
    when the content box is missing. A message row can hold several content boxes
    (a reply quotes one and answers with another), so all of them are read.
  .PARAMETER Element
    Message row element.
  .PARAMETER SenderLabelClass
    Class regex identifying the sender nick element (Chat.SenderLabel).
  .PARAMETER TimestampClass
    Class regex identifying the timestamp element (Chat.MsgTimestamp).
  .PARAMETER ContentClass
    Class regex identifying a content box (Chat.MsgContent).
  .PARAMETER PlaceholderText
    The localized image placeholder that a picture message renders as its Name.
  .OUTPUTS
    [hashtable] Sender, Time, MetaY, ContentY, Parts.
  #>
  param(
    [Parameter(Mandatory)]$Element,
    [Parameter(Mandatory)][string]$SenderLabelClass,
    [Parameter(Mandatory)][string]$TimestampClass,
    [Parameter(Mandatory)][string]$ContentClass,
    [string]$PlaceholderText = ''
  )
  $rows = New-Object System.Collections.ArrayList
  foreach ($n in (Get-QQDescendants -Element $Element -Max 250)) {
    $cls = ''
    $nm = ''
    try { $cls = [string]$n.Current.ClassName; $nm = [string]$n.Current.Name } catch { continue }
    $rect = Get-QQRectOf -Element $n
    [void]$rows.Add([pscustomobject]@{
      Class   = $cls
      Name    = $nm
      X       = [int]$rect.X
      Y       = [int]$rect.Y
      W       = [int]$rect.W
      Content = ($cls -ne '' -and $cls -match $ContentClass)
    })
  }

  $avatarY = $null
  $time = ''
  $contentBottoms = New-Object System.Collections.ArrayList
  foreach ($r in $rows) {
    if ($null -eq $avatarY -and $r.Class -match $SenderLabelClass) { $avatarY = [int]$r.Y }
    if ([string]::IsNullOrEmpty($time) -and $r.Class -match $TimestampClass -and -not [string]::IsNullOrWhiteSpace($r.Name)) {
      $time = [string]$r.Name
    }
    if ($r.Content) { [void]$contentBottoms.Add([int]$r.Y) }
  }

  # Sender: the rightmost non-badge text on the metadata strip. A QQ group message
  # renders the nick twice (before the level badge and at the author column).
  $sender = ''
  if ($null -ne $avatarY) {
    $strip = @($rows | Where-Object { [Math]::Abs([int]$_.Y - [int]$avatarY) -le 4 -and -not [string]::IsNullOrWhiteSpace($_.Name) } | Sort-Object { $_.X })
    foreach ($r in $strip) {
      if ($r.Name -match '^(LV|VIP)\d*$') { continue }
      $sender = [string]$r.Name
    }
  }

  # Metadata is a band above the first content box. Without a content box (a
  # system tip has none) there is no metadata to strip.
  $contentY = $null
  if ($contentBottoms.Count -gt 0) {
    $contentY = [int](($contentBottoms | Measure-Object -Minimum).Minimum)
  }

  $parts = New-Object System.Collections.ArrayList
  foreach ($r in $rows) {
    if ([string]::IsNullOrWhiteSpace($r.Name)) { continue }
    if ($r.Class -match $TimestampClass) { continue }
    if ($r.Class -match 'gray-tip-img|q-badge|no-disturb-icon|avatar-span') { continue }
    if ($null -ne $contentY -and [int]$r.Y -lt [int]$contentY -and -not $r.Content) { continue }
    if ($r.Name -match '^\d{1,2}:\d{2}(:\d{2})?$') { continue }
    if ($r.Name -match '^(LV|VIP)\d*$') { continue }
    if ($r.Name -match '^\d{1,4}$' -and $r.Class -eq '') { continue }
    if (-not [string]::IsNullOrEmpty($PlaceholderText) -and $r.Name -eq $PlaceholderText) { continue }
    if ($parts -notcontains $r.Name) { [void]$parts.Add([string]$r.Name) }
  }

  return @{
    Sender        = [string]$sender
    Time          = [string]$time
    MetaY         = $(if ($null -ne $avatarY) { [int]$avatarY } else { -1 })
    ContentY      = $(if ($null -ne $contentY) { [int]$contentY } else { -1 })
    HasContentBox = [bool]($contentBottoms.Count -gt 0)
    Parts         = @($parts)
  }
}

function Get-QQMessageRecord {
  <#
  .SYNOPSIS
    Reads one message row into a record.
  .DESCRIPTION
    Direction comes from container--self / container--others on the content box
    (the 9.9.35 spelling). The timestamp is rendered only on the first message of
    a time group, so `time` is legitimately empty for most messages. `unreadable`
    marks a message whose content UIA cannot expose at all, which for this app
    means non-text payloads: only their kind and placeholder text are available.
  .PARAMETER Element
    Message row element.
  .PARAMETER SelfNick
    Nickname of the account signed in to this instance, used only when the row
    carries no direction marker. Pass '' to skip the fallback.
  .OUTPUTS
    [ordered] hashtable: kind, sender, self, time, text, unreadable.
  #>
  param(
    [Parameter(Mandatory)]$Element,
    [string]$SelfNick = ''
  )
  $contentEntry = Get-QQSelectorEntry -Section 'Chat' -Name 'MsgContent'
  $metaEntry = Get-QQSelectorEntry -Section 'Chat' -Name 'MsgMeta'
  $selfEntry = Get-QQSelectorEntry -Section 'Chat' -Name 'MsgSelf'
  $tsEntry = Get-QQSelectorEntry -Section 'Chat' -Name 'MsgTimestamp'

  $contentBox = Get-QQDescendantByClass -Element $Element -ClassRegex $contentEntry.Class
  $probe = $(if ($null -ne $contentBox) { $contentBox } else { $Element })
  $info = Get-QQSubtreeInfo -Element $probe -Max 200
  $kind = Get-QQMessageKind -Classes $info.Classes

  $parts = Get-QQMessageParts -Element $Element -SenderLabelClass $metaEntry.Class -TimestampClass $tsEntry.Class `
    -ContentClass $contentEntry.Class -PlaceholderText $script:QQ_IMAGE_PLACEHOLDER

  # Direction is carried by container--self / container--others. When neither
  # marker is present (an unusual message type) the sender label is compared
  # against the account's own nick. Falling back to `false` rather than guessing
  # keeps an unreadable message from being reported as outgoing.
  $self = $false
  $hasMarker = $false
  foreach ($c in $info.Classes) {
    $text2 = [string]$c
    if ($text2 -match '(^|\s)(container--self|message-container--self)($|\s)') { $self = $true; $hasMarker = $true; break }
    if ($text2 -match '(^|\s)(container--others|message-container--others)($|\s)') { $hasMarker = $true; break }
  }
  $sender = [string]$parts.Sender
  if (-not $self -and -not $hasMarker -and -not [string]::IsNullOrEmpty($SelfNick) -and $sender -eq $SelfNick) {
    $self = $true
  }
  if ($self -and [string]::IsNullOrEmpty($sender)) { $sender = 'self' }

  # A kind is only trustworthy when its distinctive marker was actually found. A
  # row with a content box but no marker of its own is plain text; without a
  # content box it is a system tip.
  if ($kind -eq 'unknown') {
    if ($parts.HasContentBox) { $kind = 'text' } else { $kind = 'system' }
  }

  $text = [string](@($parts.Parts) -join ' ')
  # image and face carry their label as their only readable content, so an empty
  # text there is expected rather than a read failure.
  $unreadable = ([string]::IsNullOrWhiteSpace($text) -and $kind -ne 'image' -and $kind -ne 'face' -and $kind -ne 'market-face')
  return [ordered]@{
    kind       = [string]$kind
    sender     = [string]$sender
    self       = [bool]$self
    time       = [string]$parts.Time
    text       = [string]$text
    unreadable = [bool]$unreadable
  }
}

function Get-QQMessages {
  <#
  .SYNOPSIS
    Reads the open conversation's message rows.
  .DESCRIPTION
    Rows are returned in document order, which is oldest-first, so `Limit` keeps
    the most recent N by slicing the tail. The pane is virtualized: rows scrolled
    far out of view are not in the UIA tree, so Total is "messages currently
    rendered", not the conversation length.
  .PARAMETER Root
    UIA root element.
  .PARAMETER Limit
    Maximum number of most recent messages to return (0 = all rendered).
  .PARAMETER Nodes
    Precomputed node list.
  .PARAMETER SelfNick
    Nickname of the account signed in to this instance, used as the direction
    fallback for rows that carry no direction marker.
  .OUTPUTS
    [hashtable] Total, Rendered and Messages.
  #>
  param(
    [Parameter(Mandatory)]$Root,
    [int]$Limit = 50,
    $Nodes = $null,
    [string]$SelfNick = ''
  )
  $rows = @(Get-QQNodes -Root $Root -Section 'Chat' -Name 'Message' -Nodes $Nodes)
  $all = New-Object System.Collections.ArrayList
  foreach ($row in $rows) {
    [void]$all.Add((Get-QQMessageRecord -Element $row -SelfNick $SelfNick))
  }
  $total = $all.Count
  $result = $all
  if ($Limit -gt 0 -and $total -gt $Limit) {
    $result = New-Object System.Collections.ArrayList
    for ($i = $total - $Limit; $i -lt $total; $i++) { [void]$result.Add($all[$i]) }
  }
  return @{ Total = [int]$total; Rendered = [int]$total; Messages = @($result) }
}

function Test-QQLooksLikeTime {
  <#
  .SYNOPSIS
    Reports whether a row fragment is a conversation-list time label.
  .DESCRIPTION
    QQ renders the row time in several localized forms (clock, yesterday+clock,
    weekday, month/day, year/month/day), all of which contain a digit and sit in
    the same aligned column. Anything without a digit is content, not a time.
  .PARAMETER Text
    Candidate fragment.
  .OUTPUTS
    [bool].
  #>
  param([string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
  if ($Text -notmatch '\d') { return $false }
  return ($Text -match '^\d{1,2}:\d{2}$' -or
          $Text -match '^\d{4}/\d{1,2}/\d{1,2}$' -or
          $Text -match '^\d{1,2}/\d{1,2}$' -or
          $Text -match '^(yesterday|Yesterday)\s*\d{1,2}:\d{2}$')
}

function Get-QQSessionRowRecord {
  <#
  .SYNOPSIS
    Reads one conversation-list row into a record.
  .DESCRIPTION
    A row holds two text lines: the large title with the right-aligned time, then
    the small preview (sender prefix plus last message). Y position inside the row
    separates them reliably, which the earlier text-order approach did not: it
    pushed preview-only rows (whose time sits on the title line) into `preview`.
  .PARAMETER Row
    Conversation row element.
  .PARAMETER UnreadSuffix
    Localized unread suffix, stripped from badge names.
  .PARAMETER UpdateSuffix
    Localized "new messages" suffix, stripped from preview text.
  .OUTPUTS
    [ordered] hashtable: title, preview, time, unread, muted, selected.
  #>
  param(
    [Parameter(Mandatory)]$Row,
    [string]$UnreadSuffix = '',
    [string]$UpdateSuffix = ''
  )
  $rowClass = ''
  try { $rowClass = [string]$Row.Current.ClassName } catch { $rowClass = '' }
  $selected = ($rowClass -match 'selected')

  $fragments = New-Object System.Collections.ArrayList
  $unread = 0
  $muted = $false
  foreach ($n in (Get-QQDescendants -Element $Row -Max 80)) {
    $c = ''
    $nm = ''
    try { $c = [string]$n.Current.ClassName; $nm = [string]$n.Current.Name } catch { continue }
    if ($c -match 'no-disturb-icon') { $muted = $true; continue }
    if ($c -match 'q-badge') {
      $digits = [regex]::Match($nm, '\d+')
      if ($digits.Success) { $unread = [int]$digits.Value }
      continue
    }
    if ([string]::IsNullOrWhiteSpace($nm)) { continue }
    $rect = Get-QQRectOf -Element $n
    [void]$fragments.Add(@{ X = [int]$rect.X; Y = [int]$rect.Y; Name = [string]$nm })
  }

  # Group fragments into visual lines (same Y within the 8px row line height).
  $lines = New-Object System.Collections.ArrayList
  foreach ($f in @($fragments | Sort-Object { $_.Y })) {
    $placed = $false
    foreach ($line in $lines) {
      if ([Math]::Abs([int]$line.Y - [int]$f.Y) -le 8) {
        [void]$line.Items.Add($f)
        $placed = $true
        break
      }
    }
    if (-not $placed) {
      $line = @{ Y = [int]$f.Y; Items = (New-Object System.Collections.ArrayList) }
      [void]$line.Items.Add($f)
      [void]$lines.Add($line)
    }
  }
  foreach ($line in $lines) { $line.Items = @($line.Items | Sort-Object { $_.X }) }

  # Line 0 = title plus its right-aligned time; line 1 = preview fragments.
  $title = ''
  $time = ''
  $preview = ''
  if ($lines.Count -ge 1) {
    foreach ($item in $lines[0].Items) {
      if (Test-QQLooksLikeTime -Text ([string]$item.Name)) { $time = [string]$item.Name; continue }
      if ([string]::IsNullOrEmpty($title)) { $title = [string]$item.Name; continue }
      if ([string]::IsNullOrEmpty($preview)) { $preview = [string]$item.Name }
    }
  }
  if ($lines.Count -ge 2) {
    $parts = New-Object System.Collections.ArrayList
    if (-not [string]::IsNullOrWhiteSpace($preview)) { [void]$parts.Add($preview.Trim()) }
    foreach ($item in $lines[1].Items) {
      $piece = [string]$item.Name
      if (-not [string]::IsNullOrEmpty($UnreadSuffix)) { $piece = $piece -replace [regex]::Escape($UnreadSuffix), '' }
      if (-not [string]::IsNullOrEmpty($UpdateSuffix)) { $piece = $piece -replace [regex]::Escape($UpdateSuffix), '' }
      $piece = ($piece -replace '^\[\d+\]', '').Trim()
      if ([string]::IsNullOrWhiteSpace($piece)) { continue }
      [void]$parts.Add($piece)
    }
    $preview = ($parts -join ' ')
  }

  return [ordered]@{
    title    = [string]$title
    preview  = [string]$preview
    time     = [string]$time
    unread   = [int]$unread
    muted    = [bool]$muted
    selected = [bool]$selected
  }
}

function Get-QQSessionRows {
  <#
  .SYNOPSIS
    Reads every conversation-list row of an instance.
  .PARAMETER Root
    UIA root element.
  .PARAMETER Nodes
    Precomputed node list.
  .OUTPUTS
    [object[]] session records as returned by Get-QQSessionRowRecord.
  #>
  param(
    [Parameter(Mandatory)]$Root,
    $Nodes = $null
  )
  $rows = @(Get-QQNodes -Root $Root -Section 'Sessions' -Name 'Item' -Nodes $Nodes)
  $unreadSuffix = Get-QQUiText -Key 'unreadSuffix'
  $updateSuffix = Get-QQUiText -Key 'updateSuffix'
  $out = New-Object System.Collections.ArrayList
  foreach ($row in $rows) {
    [void]$out.Add((Get-QQSessionRowRecord -Row $row -UnreadSuffix $unreadSuffix -UpdateSuffix $updateSuffix))
  }
  return @($out)
}

function Find-QQSessionRow {
  <#
  .SYNOPSIS
    Finds the conversation-list row whose title equals a given name.
  .PARAMETER Root
    UIA root element.
  .PARAMETER Title
    Exact conversation title.
  .PARAMETER Nodes
    Precomputed node list.
  .OUTPUTS
    [hashtable] Found (bool), Element, Title.
  #>
  param(
    [Parameter(Mandatory)]$Root,
    [Parameter(Mandatory)][string]$Title,
    $Nodes = $null
  )
  $rows = @(Get-QQNodes -Root $Root -Section 'Sessions' -Name 'Item' -Nodes $Nodes)
  foreach ($row in $rows) {
    foreach ($n in (Get-QQDescendants -Element $row -Max 80)) {
      $nm = ''
      try { $nm = [string]$n.Current.Name } catch { continue }
      if ($nm -eq $Title) { return @{ Found = $true; Element = $row; Title = [string]$nm } }
    }
  }
  return @{ Found = $false; Element = $null; Title = '' }
}
