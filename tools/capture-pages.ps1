# 逐页启动应用并用 PrintWindow 抓图（绕过 RenderTargetBitmap 的文本丢失问题）
param([string[]]$Pages = @('NavOverview','NavApps','NavUpdates','NavBuckets','NavTools','NavPath'))

Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class CapW {
  [DllImport("shcore.dll")] public static extern int SetProcessDpiAwareness(int v);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint f);
  public struct RECT { public int L,T,R,B; }
}
'@
[void][CapW]::SetProcessDpiAwareness(2)

$exe = 'D:\harness\envman\envman.ps1'
foreach ($pg in $Pages) {
    $out = "D:\harness\envman\page-$pg.png"
    $p = Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',$exe,'-Page',$pg -PassThru
    # 等窗口就绪
    $ok = $false
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Milliseconds 500
        $p.Refresh()
        if ($p.HasExited) { break }
        if ($p.MainWindowHandle -ne 0) { $ok = $true; break }
    }
    if (-not $ok) { Write-Host "  [$pg] 窗口未就绪"; try { $p.Kill() } catch {}; continue }
    Start-Sleep 3   # 等数据渲染完

    $r = New-Object CapW+RECT
    [void][CapW]::GetWindowRect($p.MainWindowHandle, [ref]$r)
    $w = $r.R - $r.L; $h = $r.B - $r.T
    if ($w -le 0 -or $h -le 0) { Write-Host "  [$pg] 尺寸异常"; try { $p.Kill() } catch {}; continue }

    $bmp = New-Object Drawing.Bitmap $w, $h
    $g = [Drawing.Graphics]::FromImage($bmp)
    $hdc = $g.GetHdc()
    $done = [CapW]::PrintWindow($p.MainWindowHandle, $hdc, 2)
    $g.ReleaseHdc($hdc); $g.Dispose()
    $bmp.Save($out, [Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()

    Write-Host "  [$pg] ${w}x${h} -> $out"
    try { $p.CloseMainWindow() | Out-Null } catch {}
    Start-Sleep 1
    try { if (-not $p.HasExited) { $p.Kill() } } catch {}
    Start-Sleep 1
}
Write-Host 'DONE'
