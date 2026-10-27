#Requires -Version 5.1
<#
    环境管理 · Environment Manager
    ------------------------------------------------
    Scoop GUI + 环境变量管理
    设计系统：Fluent dark 基础 + 粉色强调
    - 间距：4 / 8 / 12 / 16 / 20 / 24 / 32（8px 网格）
    - 圆角：卡片 10 / 控件 6 / 胶囊 999
    - 字号：26 页标题 / 13 正文 / 12 元信息 / 11 说明
    - 标签定宽，保证各列数值垂直对齐
#>

param(
    [string]$Shot = '',
    [string]$Page = 'NavOverview',
    # Scoop 安装根目录；留空则自动探测
    [string]$ScoopRoot = ''
)

$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

# ═══════════════════════════════════════════════════════════
#  路径探测
#  Scoop 可能装在任意盘符，这里按优先级自动发现，
#  避免把 D:\Scoop 写死在十几处调用里。
# ═══════════════════════════════════════════════════════════

function Resolve-ScoopRoot {
    $cands = @()
    if ($ScoopRoot) { $cands += $ScoopRoot }
    if ($env:SCOOP) { $cands += $env:SCOOP }
    $cands += (Join-Path $env:USERPROFILE 'scoop')
    foreach ($d in @('D:', 'C:', 'E:')) { $cands += "${d}\Scoop" }
    foreach ($c in $cands) {
        if ($c -and (Test-Path (Join-Path $c 'shims\scoop.cmd'))) { return (Resolve-Path $c).Path }
    }
    return ''
}

$script:ScoopRoot = Resolve-ScoopRoot
$script:ScoopShims = if ($script:ScoopRoot) { Join-Path $script:ScoopRoot 'shims' } else { '' }
$script:ScoopCmd = if ($script:ScoopShims) { Join-Path $script:ScoopShims 'scoop.cmd' } else { '' }

# ── 从注册表取最新 PATH，并确保 Scoop shims 可见 ──
try {
    $uP = [Environment]::GetEnvironmentVariable('PATH', 'User')
    $mP = [Environment]::GetEnvironmentVariable('PATH', 'Machine')
    if ($mP -or $uP) { $env:Path = (@($mP, $uP) | Where-Object { $_ }) -join ';' }
} catch { }
if ($script:ScoopShims -and $env:Path -notlike "*$($script:ScoopShims)*") {
    $env:Path = "$($script:ScoopShims);$env:Path"
}
$script:ScoopOk = [bool](Get-Command scoop -ErrorAction SilentlyContinue)

# ── Win11 深色标题栏 ──
try {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class DwmDark {
    [DllImport("dwmapi.dll")]
    public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int val, int size);

    // 浅色标题栏：关闭 immersive dark，底色跟随窗口，文字用深色
    public static void ApplyLight(IntPtr h, int captionColorRef, int textColorRef) {
        int off = 0;
        DwmSetWindowAttribute(h, 20, ref off, sizeof(int));       // DWMWA_USE_IMMERSIVE_DARK_MODE
        int cap = captionColorRef;
        DwmSetWindowAttribute(h, 35, ref cap, sizeof(int));       // DWMWA_CAPTION_COLOR
        int txt = textColorRef;
        DwmSetWindowAttribute(h, 36, ref txt, sizeof(int));       // DWMWA_TEXT_COLOR
    }
}
'@ -ErrorAction Stop
} catch { }

# ═══════════════════════════════════════════════════════════
#  数据层
# ═══════════════════════════════════════════════════════════

function Get-PathEntries {
    # 优先使用后台采集的缓存
    if ($script:cache -and $script:cache.Paths) { return $script:cache.Paths }
    $uP = [Environment]::GetEnvironmentVariable('PATH', 'User')
    $mP = [Environment]::GetEnvironmentVariable('PATH', 'Machine')
    $uItems = @($uP -split ';' | Where-Object { $_ })
    $mItems = @($mP -split ';' | Where-Object { $_ })
    $uKeys = @($uItems | ForEach-Object { $_.TrimEnd('\').ToLower() })
    $mKeys = @($mItems | ForEach-Object { $_.TrimEnd('\').ToLower() })

    $count = @{}
    foreach ($k in @($uKeys + $mKeys)) { $count[$k] = 1 + $count[$k] }

    $out = New-Object System.Collections.ArrayList
    foreach ($set in @(@{ Items = $uItems; Scope = '用户' }, @{ Items = $mItems; Scope = '系统' })) {
        foreach ($p in $set.Items) {
            $k = $p.TrimEnd('\').ToLower()
            $exists = Test-Path -LiteralPath $p
            $dup = $count[$k] -gt 1
            $state = if (-not $exists) { 'broken' } elseif ($dup) { 'dup' } else { 'ok' }
            [void]$out.Add([pscustomobject]@{
                Path  = $p
                Scope = $set.Scope
                State = $state
                Note  = switch ($state) { 'broken' { '不存在' } 'dup' { '重复' } default { '' } }
            })
        }
    }
    return $out.ToArray()
}

function Get-ScoopApps {
    if ($script:cache -and $script:cache.Apps) { return $script:cache.Apps }
    if (-not $script:ScoopOk) { return @() }
    $r = & scoop list 2>$null
    return @($r | Where-Object { $_.Name } | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; Version = $_.Version; Bucket = $_.Source }
    })
}

function Get-Buckets {
    if ($script:cache -and $script:cache.Buckets) { return $script:cache.Buckets }
    if (-not $script:ScoopOk) { return @() }
    $r = & scoop bucket list 2>$null
    return @($r | Where-Object { $_.Name } | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; Source = $_.Source; Count = $_.Manifests }
    })
}

function Get-ToolVersions {
    if ($script:cache -and $script:cache.Tools) { return $script:cache.Tools }
    $defs = @(
        @{ N = 'Node.js';    C = 'node';   A = '--version'; P = '^v' },
        @{ N = 'npm';        C = 'npm';    A = '--version'; P = '' },
        @{ N = 'Python';     C = 'python'; A = '--version'; P = '^Python\s+' },
        @{ N = 'Java';       C = 'java';   A = '--version'; P = '^java\s+' },
        @{ N = 'Maven';      C = 'mvn';    A = '--version'; P = '^Apache Maven\s+' },
        @{ N = 'Git';        C = 'git';    A = '--version'; P = '^git version\s+' },
        @{ N = 'GitHub CLI'; C = 'gh';     A = '--version'; P = '^gh version\s+' },
        @{ N = 'aria2';      C = 'aria2c'; A = '--version'; P = '^aria2 version\s+' }
    )
    $out = New-Object System.Collections.ArrayList
    foreach ($d in $defs) {
        $c = Get-Command $d.C -ErrorAction SilentlyContinue
        if (-not $c) {
            [void]$out.Add([pscustomobject]@{ Name = $d.N; Version = '未安装'; Where = ''; Ok = $false })
            continue
        }
        $v = '已安装'
        try {
            $raw = & $d.C $d.A.Split(' ') 2>&1
            $first = @($raw | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ }) | Select-Object -First 1
            if ($first) {
                $v = $first
                if ($d.P) { $v = $v -replace $d.P, '' }
                # 只保留版本号本身，避免长哈希串撑破列宽
                $v = ($v -split '\s+')[0]
                if ($v.Length -gt 24) { $v = $v.Substring(0, 24) + '…' }
            }
        } catch { $v = '读取失败' }
        [void]$out.Add([pscustomobject]@{ Name = $d.N; Version = $v; Where = $c.Source; Ok = $true })
    }

    # Scoop 单独处理：
    # 直接调 scoop.ps1 时文本会被 PS 的输出处理吞掉，只剩 git log 对象；
    # 改调 scoop.cmd 才能拿到完整的 --version 文本。
    $scCmd = $script:ScoopCmd
    if (-not (Test-Path $scCmd)) { $scCmd = (Get-Command scoop -ErrorAction SilentlyContinue).Source }
    if ($scCmd) {
        $sv = '已安装'
        try {
            $sr = @(& $scCmd --version 2>$null | ForEach-Object { $_.ToString() })
            $hit = $sr | Where-Object { $_ -match '\d+\.\d+\.\d+' } | Select-Object -First 1
            if ($hit -and $hit -match '(\d+\.\d+\.\d+)') { $sv = 'v' + $Matches[1] }
        } catch { }
        [void]$out.Add([pscustomobject]@{ Name = 'Scoop'; Version = $sv; Where = $scCmd; Ok = $true })
    }
    return $out.ToArray()
}

function Get-EnvVarList {
    if ($script:cache -and $script:cache.Vars) { return $script:cache.Vars }
    $names = @('JAVA_HOME', 'MAVEN_HOME', 'NVM_HOME', 'NVM_SYMLINK', 'PNPM_HOME', 'SCOOP', 'SCOOP_GLOBAL')
    $out = New-Object System.Collections.ArrayList
    foreach ($n in $names) {
        $v = [Environment]::GetEnvironmentVariable($n, 'User')
        $scope = '用户'
        if (-not $v) { $v = [Environment]::GetEnvironmentVariable($n, 'Machine'); $scope = '系统' }
        if ($v) {
            [void]$out.Add([pscustomobject]@{ Name = $n; Value = $v; Scope = $scope; Ok = (Test-Path -LiteralPath $v) })
        } else {
            [void]$out.Add([pscustomobject]@{ Name = $n; Value = '未设置'; Scope = ''; Ok = $null })
        }
    }
    return $out.ToArray()
}

function Get-SysInfo {
    $os = '未知'
    try {
        $o = Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 3
        if ($o -and $o.Caption) { $os = $o.Caption -replace 'Microsoft\s*', '' }
    } catch {
        try { $os = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').ProductName } catch { }
    }
    return @(
        @{ K = '计算机名';   V = $env:COMPUTERNAME },
        @{ K = '当前用户';   V = $env:USERNAME },
        @{ K = '操作系统';   V = $os },
        @{ K = 'PowerShell'; V = $PSVersionTable.PSVersion.ToString() },
        @{ K = '.NET';       V = [Environment]::Version.ToString() },
        @{ K = 'Scoop 目录'; V = (if ($script:ScoopRoot) { $script:ScoopRoot } else { '未找到' }) }
    )
}

# ═══════════════════════════════════════════════════════════
#  主题
#  固定浅色樱粉主题。不做运行时切换，避免资源替换引发的重排开销。
# ═══════════════════════════════════════════════════════════

# WPF 的 #AARRGGBB 转 Win32 COLORREF (0x00BBGGRR)
function Get-CaptionColorRef([string]$argb) {
    if ($argb -match '^#([0-9A-F]{2})([0-9A-F]{2})([0-9A-F]{2})([0-9A-F]{2})$') {
        $r = [Convert]::ToInt32($Matches[2], 16)
        $g = [Convert]::ToInt32($Matches[3], 16)
        $b = [Convert]::ToInt32($Matches[4], 16)
        return (($b -shl 16) -bor ($g -shl 8) -bor $r)
    }
    return 0x00F5F2FD
}

function Get-UiTheme {
    return @{
        Name            = '樱·浅色'
        BgWindow        = '#FFFDF2F5'
        BgSidebar       = '#FFFFF7F9'
        Card            = '#FFFFFFFF'
        Accent          = '#FFF76C9B'
        AccentSoft      = '#1AF76C9B'
        AccentHover     = '#FFF98BB2'
        TextMain        = '#FF2B2026'
        TextSec         = '#FF6B5560'
        TextTer         = '#FF9C8892'
        TextFaint       = '#FFBFADB4'
        Success         = '#FF1E9E62'
        Warning         = '#FFB7791F'
        Danger          = '#FFD94565'
        OverlayRow      = '#08B00000'
        OverlayStroke   = '#14B00000'
        OverlayStrokeWeak = '#0AB00000'
        OverlayBtn      = '#0FB00000'
        OverlayBtnHover = '#1FB00000'
        OverlayPill     = '#0FB00000'
        Scrollbar       = '#33000000'
        IsLight         = $true
    }
}

# ═══════════════════════════════════════════════════════════
#  界面
# ═══════════════════════════════════════════════════════════

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="环境管理" Width="1280" Height="840" MinWidth="1060" MinHeight="680"
        Background="__BG_WINDOW__"
        FontFamily="Microsoft YaHei UI, Segoe UI"
        UseLayoutRounding="True" SnapsToDevicePixels="True"
        TextOptions.TextFormattingMode="Display"
        TextOptions.TextRenderingMode="ClearType">

  <Window.Resources>
    <SolidColorBrush x:Key="BgSidebar"   Color="__BG_SIDEBAR__"/>
    <SolidColorBrush x:Key="BgWindow"    Color="__BG_WINDOW__"/>
    <SolidColorBrush x:Key="CardBg"      Color="__CARD__"/>
    <SolidColorBrush x:Key="RowBg"       Color="__OVERLAY_ROW__"/>
    <SolidColorBrush x:Key="Stroke"      Color="__OVERLAY_STROKE__"/>
    <SolidColorBrush x:Key="StrokeWeak"  Color="__OVERLAY_STROKEWEAK__"/>
    <SolidColorBrush x:Key="TxtMain"     Color="__TXT_MAIN__"/>
    <SolidColorBrush x:Key="TxtSec"      Color="__TXT_SEC__"/>
    <SolidColorBrush x:Key="TxtTer"      Color="__TXT_TER__"/>
    <SolidColorBrush x:Key="TxtFaint"    Color="__TXT_FAINT__"/>
    <SolidColorBrush x:Key="Accent"      Color="__ACCENT__"/>
    <SolidColorBrush x:Key="AccentHover" Color="__ACCENT_HOVER__"/>
    <SolidColorBrush x:Key="AccentSoft"  Color="__ACCENT_SOFT__"/>
    <SolidColorBrush x:Key="AccentTint"  Color="__ACCENT_SOFT__"/>
    <SolidColorBrush x:Key="Success"     Color="__SUCCESS__"/>
    <SolidColorBrush x:Key="Warning"     Color="__WARNING__"/>
    <SolidColorBrush x:Key="Danger"      Color="__DANGER__"/>

    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="{StaticResource CardBg}"/>
      <Setter Property="BorderBrush" Value="{StaticResource StrokeWeak}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="10"/>
      <Setter Property="Padding" Value="20"/>
    </Style>

    <Style x:Key="PageTitle" TargetType="TextBlock">
      <Setter Property="FontSize" Value="26"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="{StaticResource TxtMain}"/>
    </Style>
    <Style x:Key="PageSub" TargetType="TextBlock">
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Foreground" Value="{StaticResource TxtTer}"/>
      <Setter Property="Margin" Value="0,6,0,0"/>
    </Style>
    <Style x:Key="SectionTitle" TargetType="TextBlock">
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="{StaticResource TxtSec}"/>
      <Setter Property="Margin" Value="0,0,0,14"/>
    </Style>
    <Style x:Key="Cap" TargetType="TextBlock">
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Foreground" Value="{StaticResource TxtTer}"/>
    </Style>
    <Style x:Key="Mono" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="Consolas, Cascadia Mono"/>
      <Setter Property="FontSize" Value="11.5"/>
    </Style>

    <Style x:Key="NavItem" TargetType="RadioButton">
      <Setter Property="Height" Value="36"/>
      <Setter Property="Margin" Value="10,1,10,1"/>
      <Setter Property="Foreground" Value="{StaticResource TxtSec}"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="Bd" Background="Transparent" CornerRadius="6">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="4"/>
                  <ColumnDefinition Width="38"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Border x:Name="Bar" Grid.Column="0" Width="3" Height="16"
                        Background="Transparent" CornerRadius="1.5"
                        HorizontalAlignment="Center"/>
                <TextBlock x:Name="Ico" Grid.Column="1" Text="{TemplateBinding Tag}"
                           FontFamily="Segoe MDL2 Assets" FontSize="13"
                           VerticalAlignment="Center" HorizontalAlignment="Center"
                           Foreground="{StaticResource TxtTer}"/>
                <ContentPresenter Grid.Column="2" VerticalAlignment="Center" Margin="0,0,12,0"/>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="__OVERLAY_BTN__"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{StaticResource AccentTint}"/>
                <Setter TargetName="Bar" Property="Background" Value="{StaticResource Accent}"/>
                <Setter TargetName="Ico" Property="Foreground" Value="{StaticResource Accent}"/>
                <Setter Property="Foreground" Value="{StaticResource TxtMain}"/>
                <Setter Property="FontWeight" Value="SemiBold"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="NavGroup" TargetType="TextBlock">
      <Setter Property="FontSize" Value="10"/>
      <Setter Property="Foreground" Value="{StaticResource TxtFaint}"/>
      <Setter Property="Margin" Value="24,20,0,7"/>
    </Style>

    <Style x:Key="GhostBtn" TargetType="Button">
      <Setter Property="Background" Value="__OVERLAY_BTN__"/>
      <Setter Property="Foreground" Value="{StaticResource TxtSec}"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Height" Value="32"/>
      <Setter Property="Padding" Value="16,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" Background="{TemplateBinding Background}" CornerRadius="6"
                    Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="B" Property="Background" Value="__OVERLAY_BTNHOVER__"/>
                <Setter Property="Foreground" Value="{StaticResource TxtMain}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.4"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="PrimaryBtn" TargetType="Button">
      <Setter Property="Background" Value="{StaticResource Accent}"/>
      <Setter Property="Foreground" Value="{StaticResource BgWindow}"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Height" Value="32"/>
      <Setter Property="Padding" Value="18,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" Background="{TemplateBinding Background}" CornerRadius="6"
                    Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="B" Property="Background" Value="{StaticResource AccentHover}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.4"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="TinyBtn" TargetType="Button">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="{StaticResource TxtTer}"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Height" Value="24"/>
      <Setter Property="Padding" Value="10,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" Background="{TemplateBinding Background}" CornerRadius="4"
                    Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="B" Property="Background" Value="__OVERLAY_BTNHOVER__"/>
                <Setter Property="Foreground" Value="{StaticResource Accent}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.35"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="DangerTinyBtn" TargetType="Button" BasedOn="{StaticResource TinyBtn}">
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="Foreground" Value="{StaticResource Danger}"/>
        </Trigger>
      </Style.Triggers>
    </Style>

    <Style x:Key="SearchBox" TargetType="TextBox">
      <Setter Property="Background" Value="__OVERLAY_ROW__"/>
      <Setter Property="Foreground" Value="{StaticResource TxtMain}"/>
      <Setter Property="CaretBrush" Value="{StaticResource Accent}"/>
      <Setter Property="SelectionBrush" Value="{StaticResource Accent}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="BorderBrush" Value="{StaticResource Stroke}"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="Height" Value="34"/>
      <Setter Property="Padding" Value="12,0"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="B" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}"
                            VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="B" Property="BorderBrush" Value="{StaticResource Accent}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="8"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent">
              <Track x:Name="PART_Track" IsDirectionReversed="True">
                <Track.Thumb>
                  <Thumb>
                    <Thumb.Template>
                      <ControlTemplate TargetType="Thumb">
                        <Border Background="__SCROLLBAR__" CornerRadius="4" Margin="2,0"/>
                      </ControlTemplate>
                    </Thumb.Template>
                  </Thumb>
                </Track.Thumb>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Row" TargetType="Border">
      <Setter Property="Background" Value="{StaticResource RowBg}"/>
      <Setter Property="CornerRadius" Value="6"/>
      <Setter Property="Padding" Value="14,0"/>
      <Setter Property="Height" Value="40"/>
      <Setter Property="Margin" Value="0,0,0,4"/>
    </Style>

    <!-- 深色下拉框 -->
    <Style x:Key="DarkCombo" TargetType="ComboBox">
      <Setter Property="Foreground" Value="{StaticResource TxtMain}"/>
      <Setter Property="Background" Value="__OVERLAY_BTN__"/>
      <Setter Property="BorderBrush" Value="{StaticResource Stroke}"/>
      <Setter Property="FontSize" Value="11.5"/>
      <Setter Property="Height" Value="30"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <ToggleButton x:Name="Toggle" Focusable="False" ClickMode="Press"
                            IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton">
                    <Border x:Name="BD" Background="__OVERLAY_BTN__"
                            BorderBrush="{StaticResource Stroke}" BorderThickness="1" CornerRadius="6">
                      <Grid>
                        <Grid.ColumnDefinitions>
                          <ColumnDefinition Width="*"/>
                          <ColumnDefinition Width="26"/>
                        </Grid.ColumnDefinitions>
                        <!-- 用 SelectionBoxItem 显示当前选中项 -->
                        <ContentPresenter Grid.Column="0" Margin="11,0,0,0"
                                          VerticalAlignment="Center" HorizontalAlignment="Left"
                                          Content="{Binding SelectionBoxItem, RelativeSource={RelativeSource AncestorType=ComboBox}}"/>
                        <TextBlock Grid.Column="1" Text="&#xE70D;"
                                   FontFamily="Segoe MDL2 Assets" FontSize="9"
                                   Foreground="{StaticResource TxtTer}"
                                   HorizontalAlignment="Center" VerticalAlignment="Center"/>
                      </Grid>
                    </Border>
                    <ControlTemplate.Triggers>
                      <Trigger Property="IsMouseOver" Value="True">
                        <Setter TargetName="BD" Property="Background" Value="#1AFFFFFF"/>
                      </Trigger>
                    </ControlTemplate.Triggers>
                  </ControlTemplate>
                </ToggleButton.Template>
              </ToggleButton>
              <Popup x:Name="PART_Popup" AllowsTransparency="True" Placement="Top"
                     IsOpen="{TemplateBinding IsDropDownOpen}" PopupAnimation="Fade">
                <Border Background="#FF241B21" BorderBrush="#20FFFFFF" BorderThickness="1"
                        CornerRadius="6" Margin="0,4,0,4" MinWidth="180" MaxHeight="220">
                  <ScrollViewer VerticalScrollBarVisibility="Auto">
                    <ItemsPresenter Margin="4"/>
                  </ScrollViewer>
                </Border>
              </Popup>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ComboBoxItem">
      <Setter Property="Foreground" Value="{StaticResource TxtSec}"/>
      <Setter Property="Padding" Value="10,7"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBoxItem">
            <Border x:Name="IB" Background="Transparent" CornerRadius="4" Padding="{TemplateBinding Padding}">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="IB" Property="Background" Value="#14FF7AB8"/>
                <Setter Property="Foreground" Value="{StaticResource TxtMain}"/>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="IB" Property="Background" Value="__OVERLAY_BTNHOVER__"/>
                <Setter Property="Foreground" Value="{StaticResource Accent}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="236"/>
      <ColumnDefinition Width="*"/>
    </Grid.ColumnDefinitions>

    <!-- 侧边栏 -->
    <Border Grid.Column="0" Background="{StaticResource BgSidebar}">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <Grid Grid.Row="0" Margin="20,24,20,8">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>
          <Border Grid.Column="0" Width="32" Height="32" CornerRadius="8"
                  Background="{StaticResource AccentSoft}">
            <TextBlock Text="&#xE770;" FontFamily="Segoe MDL2 Assets" FontSize="15"
                       Foreground="{StaticResource Accent}"
                       HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <StackPanel Grid.Column="1" Margin="11,0,0,0" VerticalAlignment="Center">
            <TextBlock Text="环境管理" FontSize="13" FontWeight="SemiBold"
                       Foreground="{StaticResource TxtMain}" Margin="0,0,0,2"/>
            <TextBlock Text="Environment Manager" FontSize="9.5"
                       Foreground="{StaticResource TxtFaint}"/>
          </StackPanel>
        </Grid>

        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Disabled">
          <StackPanel>
            <TextBlock Text="总览" Style="{StaticResource NavGroup}" Margin="24,14,0,7"/>
            <RadioButton x:Name="NavOverview" Style="{StaticResource NavItem}"
                         Content="概览" Tag="&#xE80F;" GroupName="nav" IsChecked="True"/>

            <TextBlock Text="软件管理" Style="{StaticResource NavGroup}"/>
            <RadioButton x:Name="NavApps" Style="{StaticResource NavItem}"
                         Content="已装软件" Tag="&#xE7B8;" GroupName="nav"/>
            <RadioButton x:Name="NavUpdates" Style="{StaticResource NavItem}"
                         Content="检查更新" Tag="&#xE777;" GroupName="nav"/>
            <RadioButton x:Name="NavBuckets" Style="{StaticResource NavItem}"
                         Content="Buckets" Tag="&#xE8F1;" GroupName="nav"/>

            <TextBlock Text="系统" Style="{StaticResource NavGroup}"/>
            <RadioButton x:Name="NavTools" Style="{StaticResource NavItem}"
                         Content="运行时" Tag="&#xE90F;" GroupName="nav"/>
            <RadioButton x:Name="NavPath" Style="{StaticResource NavItem}"
                         Content="PATH 变量" Tag="&#xE8AB;" GroupName="nav"/>
          </StackPanel>
        </ScrollViewer>

        <StackPanel Grid.Row="2" Margin="20,12,20,18">
          <Button x:Name="BtnRefresh" Style="{StaticResource GhostBtn}" Content="重新检测"
                  HorizontalAlignment="Stretch"/>
          <TextBlock x:Name="TxtStamp" Text="" FontSize="10"
                     Foreground="{StaticResource TxtFaint}" Margin="2,10,0,0"/>
        </StackPanel>
      </Grid>
    </Border>

    <!-- 主区域 -->
    <Grid Grid.Column="1">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <StackPanel Grid.Row="0" Margin="32,26,32,20">
        <TextBlock x:Name="TxtTitle" Text="概览" Style="{StaticResource PageTitle}"/>
        <TextBlock x:Name="TxtSub" Text="" Style="{StaticResource PageSub}"/>
      </StackPanel>

      <!-- 概览 -->
      <ScrollViewer x:Name="PgOverview" Grid.Row="1" Margin="32,0,24,0"
                    VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
        <StackPanel Margin="0,0,8,24">
          <Border Style="{StaticResource Card}" Margin="0,0,0,14">
            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="1"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <StackPanel Grid.Column="0" VerticalAlignment="Center" Width="172">
                <TextBlock Text="环境健康度" Style="{StaticResource Cap}"/>
                <StackPanel Orientation="Horizontal" Margin="0,2,0,0">
                  <TextBlock x:Name="TxtScore" Text="--" FontSize="44" FontWeight="SemiBold"
                             Foreground="{StaticResource Accent}"/>
                  <TextBlock Text="/100" FontSize="13" Foreground="{StaticResource TxtTer}"
                             VerticalAlignment="Bottom" Margin="4,0,0,10"/>
                </StackPanel>
              </StackPanel>
              <Border Grid.Column="1" Background="{StaticResource Stroke}" Margin="0,4,24,4"/>
              <StackPanel Grid.Column="2" VerticalAlignment="Center" Margin="24,0,0,0">
                <TextBlock x:Name="TxtVerdict" Text="正在检测…" FontSize="13"
                           FontWeight="SemiBold" Foreground="{StaticResource TxtSec}"/>
                <TextBlock x:Name="TxtAdvice" Text="" FontSize="12"
                           Foreground="{StaticResource TxtTer}" Margin="0,7,0,0"
                           TextWrapping="Wrap" LineHeight="19"/>
              </StackPanel>
            </Grid>
          </Border>

          <Grid Margin="0,0,0,14">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/><ColumnDefinition Width="12"/>
              <ColumnDefinition Width="*"/><ColumnDefinition Width="12"/>
              <ColumnDefinition Width="*"/><ColumnDefinition Width="12"/>
              <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <Border Grid.Column="0" Style="{StaticResource Card}" Padding="18,16">
              <StackPanel>
                <TextBlock Text="PATH 条目" Style="{StaticResource Cap}"/>
                <TextBlock x:Name="StatPath" Text="--" FontSize="26" FontWeight="SemiBold"
                           Foreground="{StaticResource TxtMain}" Margin="0,5,0,0"/>
              </StackPanel>
            </Border>
            <Border Grid.Column="2" Style="{StaticResource Card}" Padding="18,16">
              <StackPanel>
                <TextBlock Text="失效路径" Style="{StaticResource Cap}"/>
                <TextBlock x:Name="StatBroken" Text="--" FontSize="26" FontWeight="SemiBold"
                           Foreground="{StaticResource Success}" Margin="0,5,0,0"/>
              </StackPanel>
            </Border>
            <Border Grid.Column="4" Style="{StaticResource Card}" Padding="18,16">
              <StackPanel>
                <TextBlock Text="重复路径" Style="{StaticResource Cap}"/>
                <TextBlock x:Name="StatDup" Text="--" FontSize="26" FontWeight="SemiBold"
                           Foreground="{StaticResource Success}" Margin="0,5,0,0"/>
              </StackPanel>
            </Border>
            <Border Grid.Column="6" Style="{StaticResource Card}" Padding="18,16">
              <StackPanel>
                <TextBlock Text="Scoop 软件" Style="{StaticResource Cap}"/>
                <TextBlock x:Name="StatApps" Text="--" FontSize="26" FontWeight="SemiBold"
                           Foreground="{StaticResource TxtMain}" Margin="0,5,0,0"/>
              </StackPanel>
            </Border>
          </Grid>

          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="系统信息" Style="{StaticResource SectionTitle}"/>
              <Grid x:Name="GridSysInfo">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Grid.RowDefinitions>
                  <RowDefinition Height="Auto"/>
                  <RowDefinition Height="Auto"/>
                  <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>
              </Grid>
            </StackPanel>
          </Border>
        </StackPanel>
      </ScrollViewer>

      <!-- 已装软件 -->
      <Grid x:Name="PgApps" Grid.Row="1" Margin="32,0,24,0" Visibility="Collapsed">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>

        <Border Grid.Row="0" Style="{StaticResource Card}" Margin="0,0,8,14">
          <StackPanel>
            <Grid Margin="0,0,0,4">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <TextBlock Grid.Column="0" Text="搜索并安装" Style="{StaticResource SectionTitle}" Margin="0"/>
              <TextBlock Grid.Column="1" x:Name="TxtSearchHint" Text="输入关键字后按回车搜索"
                         Style="{StaticResource Cap}" VerticalAlignment="Center"/>
            </Grid>
            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <TextBox x:Name="TxtSearch" Grid.Column="0" Style="{StaticResource SearchBox}"/>
              <Button x:Name="BtnSearch" Grid.Column="1" Style="{StaticResource PrimaryBtn}"
                      Content="搜索" Margin="10,0,0,0"/>
              <Button x:Name="BtnClearSearch" Grid.Column="2" Style="{StaticResource GhostBtn}"
                      Content="清空" Margin="8,0,0,0"/>
            </Grid>
            <CheckBox x:Name="ChkSearchBinaries" Margin="0,10,0,0"
                      Foreground="{StaticResource TxtTer}" FontSize="11">
              <TextBlock Text="同时匹配可执行文件名（如 python.exe）" FontSize="11"
                         Foreground="{StaticResource TxtTer}"/>
            </CheckBox>
            <!-- 结果多时内部滚动，避免撑破整页把下面的列表挤没 -->
            <ScrollViewer x:Name="ScrollSearch" Margin="0,14,0,0"
                          VerticalScrollBarVisibility="Auto"
                          HorizontalScrollBarVisibility="Disabled">
            <ItemsControl x:Name="ListSearch" Margin="0,0,4,0">
              <ItemsControl.ItemTemplate>
                <DataTemplate>
                  <Border Style="{StaticResource Row}">
                    <Grid>
                      <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="220"/>
                        <ColumnDefinition Width="100"/>
                        <ColumnDefinition Width="76"/>
                        <ColumnDefinition Width="110"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                      </Grid.ColumnDefinitions>
                      <TextBlock Grid.Column="0" Text="{Binding Name}" FontSize="12.5"
                                 Foreground="{StaticResource TxtMain}" VerticalAlignment="Center"
                                 TextTrimming="CharacterEllipsis"/>
                      <TextBlock Grid.Column="1" Text="{Binding Version}" Style="{StaticResource Mono}"
                                 Foreground="{StaticResource TxtSec}" VerticalAlignment="Center"/>
                      <TextBlock Grid.Column="2" Text="{Binding Bucket}" FontSize="11"
                                 Foreground="{StaticResource TxtTer}" VerticalAlignment="Center"
                                 TextTrimming="CharacterEllipsis"/>
                      <TextBlock Grid.Column="3" Text="{Binding StateText}" FontSize="10.5"
                                 Foreground="{Binding StateBrush}" VerticalAlignment="Center"/>
                      <Border Grid.Column="4"/>
                      <Button Grid.Column="5" Style="{StaticResource TinyBtn}"
                              Content="{Binding ActionLabel}" Tag="{Binding Tag}"
                              IsEnabled="{Binding ActionEnabled}" VerticalAlignment="Center"/>
                    </Grid>
                  </Border>
                </DataTemplate>
              </ItemsControl.ItemTemplate>
            </ItemsControl>
            </ScrollViewer>
          </StackPanel>
        </Border>

        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto"
                      HorizontalScrollBarVisibility="Disabled" Margin="0,0,8,24">
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <Grid Margin="0,0,0,14">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock Grid.Column="0" x:Name="TxtAppsTitle" Text="已装软件"
                           Style="{StaticResource SectionTitle}" Margin="0"/>
                <Button Grid.Column="1" x:Name="BtnAppsReload" Style="{StaticResource GhostBtn}"
                        Content="刷新" Height="26" FontSize="11" Padding="12,0"/>
              </Grid>
              <ItemsControl x:Name="ListApps">
                <ItemsControl.ItemTemplate>
                  <DataTemplate>
                    <Border Style="{StaticResource Row}">
                      <Grid>
                        <Grid.ColumnDefinitions>
                          <ColumnDefinition Width="240"/>
                          <ColumnDefinition Width="110"/>
                          <ColumnDefinition Width="*"/>
                          <ColumnDefinition Width="Auto"/>
                          <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <TextBlock Grid.Column="0" Text="{Binding Name}" FontSize="12.5"
                                   Foreground="{StaticResource TxtMain}" VerticalAlignment="Center"
                                   TextTrimming="CharacterEllipsis"/>
                        <TextBlock Grid.Column="1" Text="{Binding Version}" Style="{StaticResource Mono}"
                                   Foreground="{StaticResource TxtSec}" VerticalAlignment="Center"/>
                        <TextBlock Grid.Column="2" Text="{Binding Bucket}" FontSize="11"
                                   Foreground="{StaticResource TxtTer}" VerticalAlignment="Center"/>
                        <Button Grid.Column="3" Style="{StaticResource TinyBtn}" Content="卸载"
                                Tag="{Binding TagUninstall}" VerticalAlignment="Center"/>
                        <Button Grid.Column="4" Style="{StaticResource TinyBtn}" Content="详情"
                                Tag="{Binding TagInfo}" VerticalAlignment="Center" Margin="2,0,0,0"/>
                      </Grid>
                    </Border>
                  </DataTemplate>
                </ItemsControl.ItemTemplate>
              </ItemsControl>
              <TextBlock x:Name="TxtAppsEmpty" Text="尚未通过 Scoop 安装软件"
                         Style="{StaticResource Cap}" Margin="0,4,0,0" Visibility="Collapsed"/>
            </StackPanel>
          </Border>
        </ScrollViewer>
      </Grid>

      <!-- 检查更新 -->
      <ScrollViewer x:Name="PgUpdates" Grid.Row="1" Margin="32,0,24,0" Visibility="Collapsed"
                    VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
        <StackPanel Margin="0,0,8,24">
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <Grid Margin="0,0,0,14">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <StackPanel Grid.Column="0">
                  <TextBlock Text="可更新软件" Style="{StaticResource SectionTitle}" Margin="0"/>
                  <TextBlock x:Name="TxtUpdateMeta" Text="正在检查…" Style="{StaticResource Cap}"
                             Margin="0,6,0,0"/>
                </StackPanel>
                <Button Grid.Column="1" x:Name="BtnCheckUpdate" Style="{StaticResource GhostBtn}"
                        Content="重新检查" Height="28" FontSize="11" Padding="14,0"/>
                <Button Grid.Column="2" x:Name="BtnUpdateAll" Style="{StaticResource PrimaryBtn}"
                        Content="全部更新" Height="28" FontSize="11" Padding="14,0" Margin="8,0,0,0"/>
              </Grid>
              <ItemsControl x:Name="ListUpdates">
                <ItemsControl.ItemTemplate>
                  <DataTemplate>
                    <Border Style="{StaticResource Row}">
                      <Grid>
                        <Grid.ColumnDefinitions>
                          <ColumnDefinition Width="240"/>
                          <ColumnDefinition Width="*"/>
                          <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <TextBlock Grid.Column="0" Text="{Binding Name}" FontSize="12.5"
                                   Foreground="{StaticResource TxtMain}" VerticalAlignment="Center"/>
                        <TextBlock Grid.Column="1" Text="{Binding Change}" Style="{StaticResource Mono}"
                                   Foreground="{StaticResource Warning}" VerticalAlignment="Center"/>
                        <Button Grid.Column="2" Style="{StaticResource TinyBtn}" Content="更新"
                                Tag="{Binding Tag}" VerticalAlignment="Center"/>
                      </Grid>
                    </Border>
                  </DataTemplate>
                </ItemsControl.ItemTemplate>
              </ItemsControl>
            </StackPanel>
          </Border>
        </StackPanel>
      </ScrollViewer>

      <!-- Buckets -->
      <ScrollViewer x:Name="PgBuckets" Grid.Row="1" Margin="32,0,24,0" Visibility="Collapsed"
                    VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
        <StackPanel Margin="0,0,8,24">
          <Border Style="{StaticResource Card}" Margin="0,0,0,14">
            <StackPanel>
              <TextBlock Text="添加 Bucket" Style="{StaticResource SectionTitle}"/>
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBox x:Name="TxtBucketName" Grid.Column="0" Style="{StaticResource SearchBox}"/>
                <Button x:Name="BtnAddBucket" Grid.Column="1" Style="{StaticResource PrimaryBtn}"
                        Content="添加" Margin="10,0,0,0"/>
              </Grid>
              <TextBlock Text="常用：extras / versions / nirsoft / sysinternals / java / php"
                         Style="{StaticResource Cap}" Margin="0,10,0,0"/>
            </StackPanel>
          </Border>
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock x:Name="TxtBucketMeta" Text="已添加的 Bucket"
                         Style="{StaticResource SectionTitle}"/>
              <ItemsControl x:Name="ListBuckets">
                <ItemsControl.ItemTemplate>
                  <DataTemplate>
                    <Border Style="{StaticResource Row}">
                      <Grid>
                        <Grid.ColumnDefinitions>
                          <ColumnDefinition Width="130"/>
                          <ColumnDefinition Width="84"/>
                          <ColumnDefinition Width="*"/>
                          <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <TextBlock Grid.Column="0" Text="{Binding Name}" FontSize="12.5"
                                   FontWeight="SemiBold" Foreground="{StaticResource TxtMain}"
                                   VerticalAlignment="Center"/>
                        <TextBlock Grid.Column="1" Text="{Binding CountText}" Style="{StaticResource Mono}"
                                   Foreground="{StaticResource TxtTer}" VerticalAlignment="Center"/>
                        <TextBlock Grid.Column="2" Text="{Binding Source}" Style="{StaticResource Mono}"
                                   FontSize="10.5" Foreground="{StaticResource TxtFaint}"
                                   VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
                        <Button Grid.Column="3" Style="{StaticResource DangerTinyBtn}" Content="移除"
                                Tag="{Binding Tag}" VerticalAlignment="Center"/>
                      </Grid>
                    </Border>
                  </DataTemplate>
                </ItemsControl.ItemTemplate>
              </ItemsControl>
            </StackPanel>
          </Border>
        </StackPanel>
      </ScrollViewer>

      <!-- 运行时 -->
      <ScrollViewer x:Name="PgTools" Grid.Row="1" Margin="32,0,24,0" Visibility="Collapsed"
                    VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
        <StackPanel Margin="0,0,8,24">
          <Border Style="{StaticResource Card}" Margin="0,0,0,14">
            <StackPanel>
              <TextBlock Text="运行时与工具链" Style="{StaticResource SectionTitle}"/>
              <ItemsControl x:Name="ListTools">
                <ItemsControl.ItemTemplate>
                  <DataTemplate>
                    <Border Style="{StaticResource Row}">
                      <Grid>
                        <Grid.ColumnDefinitions>
                          <ColumnDefinition Width="120"/>
                          <ColumnDefinition Width="16"/>
                          <ColumnDefinition Width="*"/>
                          <ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>
                        <TextBlock Grid.Column="0" Text="{Binding Name}" FontSize="12.5"
                                   Foreground="{StaticResource TxtSec}" VerticalAlignment="Center"/>
                        <Ellipse Grid.Column="1" Width="6" Height="6" Fill="{Binding Brush}"
                                 VerticalAlignment="Center" HorizontalAlignment="Left"/>
                        <TextBlock Grid.Column="2" Text="{Binding Version}" Style="{StaticResource Mono}"
                                   Foreground="{Binding TxtBrush}" VerticalAlignment="Center"
                                   TextTrimming="CharacterEllipsis" Margin="0,0,16,0"/>
                        <TextBlock Grid.Column="3" Text="{Binding Where}" FontSize="10.5"
                                   Foreground="{StaticResource TxtFaint}" VerticalAlignment="Center"
                                   TextTrimming="CharacterEllipsis" ToolTip="{Binding Where}"/>
                      </Grid>
                    </Border>
                  </DataTemplate>
                </ItemsControl.ItemTemplate>
              </ItemsControl>
            </StackPanel>
          </Border>

          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="环境变量" Style="{StaticResource SectionTitle}"/>
              <ItemsControl x:Name="ListEnvVars">
                <ItemsControl.ItemTemplate>
                  <DataTemplate>
                    <Border Style="{StaticResource Row}">
                      <Grid>
                        <Grid.ColumnDefinitions>
                          <ColumnDefinition Width="14"/>
                          <ColumnDefinition Width="140"/>
                          <ColumnDefinition Width="*"/>
                          <ColumnDefinition Width="56"/>
                        </Grid.ColumnDefinitions>
                        <Ellipse Grid.Column="0" Width="6" Height="6" Fill="{Binding Brush}"
                                 VerticalAlignment="Center" HorizontalAlignment="Left"/>
                        <TextBlock Grid.Column="1" Text="{Binding Name}" Style="{StaticResource Mono}"
                                   Foreground="{StaticResource TxtSec}" VerticalAlignment="Center"/>
                        <TextBlock Grid.Column="2" Text="{Binding Value}" Style="{StaticResource Mono}"
                                   FontSize="11" Foreground="{StaticResource TxtTer}"
                                   VerticalAlignment="Center" TextTrimming="CharacterEllipsis"
                                   ToolTip="{Binding Value}"/>
                        <TextBlock Grid.Column="3" Text="{Binding Scope}" FontSize="10"
                                   Foreground="{StaticResource TxtFaint}" VerticalAlignment="Center"
                                   HorizontalAlignment="Right"/>
                      </Grid>
                    </Border>
                  </DataTemplate>
                </ItemsControl.ItemTemplate>
              </ItemsControl>
            </StackPanel>
          </Border>
        </StackPanel>
      </ScrollViewer>

      <!-- PATH -->
      <ScrollViewer x:Name="PgPath" Grid.Row="1" Margin="32,0,24,0" Visibility="Collapsed"
                    VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
        <StackPanel Margin="0,0,8,24">
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <Grid Margin="0,0,0,14">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <StackPanel Grid.Column="0">
                  <TextBlock Text="所有 PATH 条目" Style="{StaticResource SectionTitle}" Margin="0"/>
                  <TextBlock x:Name="TxtPathMeta" Text="" Style="{StaticResource Cap}" Margin="0,6,0,0"/>
                </StackPanel>
                <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Top">
                  <Border Background="{StaticResource AccentSoft}" CornerRadius="4" Padding="8,3"
                          Margin="0,0,6,0" VerticalAlignment="Center">
                    <TextBlock Text="用户级" FontSize="10" Foreground="{StaticResource Accent}"/>
                  </Border>
                  <Border Background="__OVERLAY_BTN__" CornerRadius="4" Padding="8,3"
                          Margin="0,0,12,0" VerticalAlignment="Center">
                    <TextBlock Text="系统级" FontSize="10" Foreground="{StaticResource TxtTer}"/>
                  </Border>
                  <Button x:Name="BtnExportPath" Style="{StaticResource GhostBtn}" Content="导出"
                          Height="26" FontSize="11" Padding="12,0" Margin="0,0,8,0"/>
                  <Button x:Name="BtnOpenEnv" Style="{StaticResource GhostBtn}" Content="系统面板"
                          Height="26" FontSize="11" Padding="12,0" Margin="0,0,8,0"/>
                  <Button x:Name="BtnCleanPath" Style="{StaticResource PrimaryBtn}" Content="清理失效"
                          Height="26" FontSize="11" Padding="12,0"/>
                </StackPanel>
              </Grid>
              <ItemsControl x:Name="ListPath">
                <ItemsControl.ItemTemplate>
                  <DataTemplate>
                    <Border Style="{StaticResource Row}" Height="36">
                      <Grid>
                        <Grid.ColumnDefinitions>
                          <ColumnDefinition Width="16"/>
                          <ColumnDefinition Width="*"/>
                          <ColumnDefinition Width="56"/>
                          <ColumnDefinition Width="52"/>
                        </Grid.ColumnDefinitions>
                        <Ellipse Grid.Column="0" Width="6" Height="6" Fill="{Binding Brush}"
                                 VerticalAlignment="Center" HorizontalAlignment="Left"/>
                        <TextBlock Grid.Column="1" Text="{Binding Path}" Style="{StaticResource Mono}"
                                   FontSize="11" Foreground="{Binding TxtBrush}"
                                   VerticalAlignment="Center" TextTrimming="CharacterEllipsis"
                                   ToolTip="{Binding Path}"/>
                        <TextBlock Grid.Column="2" Text="{Binding Scope}" FontSize="10"
                                   Foreground="{Binding ScopeFg}" VerticalAlignment="Center"/>
                        <TextBlock Grid.Column="3" Text="{Binding Note}" FontSize="10"
                                   Foreground="{Binding Brush}" VerticalAlignment="Center"
                                   HorizontalAlignment="Right"/>
                      </Grid>
                    </Border>
                  </DataTemplate>
                </ItemsControl.ItemTemplate>
              </ItemsControl>
            </StackPanel>
          </Border>
        </StackPanel>
      </ScrollViewer>

      <!-- 状态栏 -->
      <Border Grid.Row="2" Background="#0A000000" BorderBrush="{StaticResource StrokeWeak}"
              BorderThickness="0,1,0,0" Padding="32,0,32,0" Height="34">
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <Ellipse x:Name="StatDot" Grid.Column="0" Width="6" Height="6"
                   Fill="{StaticResource TxtFaint}" VerticalAlignment="Center"/>
          <TextBlock x:Name="TxtStatus" Grid.Column="1" Text="就绪" FontSize="11"
                     Foreground="{StaticResource TxtTer}" VerticalAlignment="Center"
                     Margin="9,0,0,0" TextTrimming="CharacterEllipsis"/>
          <TextBlock x:Name="TxtBusy" Grid.Column="2" Text="" FontSize="10.5"
                     Foreground="{StaticResource Accent}" VerticalAlignment="Center"/>
        </Grid>
      </Border>
    </Grid>
  </Grid>
</Window>
'@

# ── 应用主题：把占位符替换成实际色值 ──
# 用 String.Replace 而非 -replace：后者把替换串当正则模板，
# 色值里的 $ 与特殊字符会被误解析，导致替换成空串。
$script:UiTheme = Get-UiTheme

$tokenMap = @{
    '__BG_WINDOW__'    = [string]$script:UiTheme.BgWindow
    '__BG_SIDEBAR__'   = [string]$script:UiTheme.BgSidebar
    '__CARD__'         = [string]$script:UiTheme.Card
    '__TXT_MAIN__'     = [string]$script:UiTheme.TextMain
    '__TXT_SEC__'      = [string]$script:UiTheme.TextSec
    '__TXT_TER__'      = [string]$script:UiTheme.TextTer
    '__TXT_FAINT__'    = [string]$script:UiTheme.TextFaint
    '__ACCENT__'       = [string]$script:UiTheme.Accent
    '__ACCENT_HOVER__' = [string]$script:UiTheme.AccentHover
    '__ACCENT_SOFT__'  = [string]$script:UiTheme.AccentSoft
    '__SUCCESS__'      = [string]$script:UiTheme.Success
    '__WARNING__'      = [string]$script:UiTheme.Warning
    '__DANGER__'       = [string]$script:UiTheme.Danger
    '__OVERLAY_ROW__'        = [string]$script:UiTheme.OverlayRow
    '__OVERLAY_STROKE__'     = [string]$script:UiTheme.OverlayStroke
    '__OVERLAY_STROKEWEAK__' = [string]$script:UiTheme.OverlayStrokeWeak
    '__OVERLAY_BTN__'        = [string]$script:UiTheme.OverlayBtn
    '__OVERLAY_BTNHOVER__'   = [string]$script:UiTheme.OverlayBtnHover
    '__OVERLAY_PILL__'       = [string]$script:UiTheme.OverlayPill
    '__SCROLLBAR__'          = [string]$script:UiTheme.Scrollbar
}
foreach ($k in $tokenMap.Keys) {
    $xaml = $xaml.Replace($k, $tokenMap[$k])
}

$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$win = [Windows.Markup.XamlReader]::Load($reader)

$names = @(
    'NavOverview','NavApps','NavUpdates','NavBuckets','NavTools','NavPath',
    'BtnRefresh','TxtStamp',
    'TxtTitle','TxtSub',
    'PgOverview','PgApps','PgUpdates','PgBuckets','PgTools','PgPath',
    'TxtScore','TxtVerdict','TxtAdvice',
    'StatPath','StatBroken','StatDup','StatApps',
    'GridSysInfo',
    'TxtSearch','BtnSearch','BtnClearSearch','ListSearch','TxtSearchHint','ChkSearchBinaries','ScrollSearch',
    'TxtAppsTitle','BtnAppsReload','ListApps','TxtAppsEmpty',
    'TxtUpdateMeta','BtnCheckUpdate','BtnUpdateAll','ListUpdates',
    'TxtBucketName','BtnAddBucket','TxtBucketMeta','ListBuckets',
    'ListTools','ListEnvVars',
    'TxtPathMeta','ListPath','BtnCleanPath','BtnExportPath','BtnOpenEnv',
    'StatDot','TxtStatus','TxtBusy'
)
$script:el = @{}
foreach ($n in $names) { $script:el[$n] = $win.FindName($n) }

function B([string]$hex) {
    try {
        return New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($hex))
    } catch {
        return New-Object Windows.Media.SolidColorBrush ([Windows.Media.Colors]::White)
    }
}
$script:BR = @{
    ok      = B $script:UiTheme.Success
    broken  = B $script:UiTheme.Danger
    dup     = B $script:UiTheme.Warning
    accent  = B $script:UiTheme.Accent
    text    = B $script:UiTheme.TextSec
    textDim = B $script:UiTheme.TextTer
    faint   = B $script:UiTheme.TextFaint
    main    = B $script:UiTheme.TextMain
}

# WPF 的 #AARRGGBB 转 Win32 COLORREF (0x00BBGGRR)
function Get-CaptionColorRef([string]$argb) {
    if ($argb -match '^#([0-9A-F]{2})([0-9A-F]{2})([0-9A-F]{2})([0-9A-F]{2})$') {
        $r = [Convert]::ToInt32($Matches[2], 16)
        $g = [Convert]::ToInt32($Matches[3], 16)
        $b = [Convert]::ToInt32($Matches[4], 16)
        return (($b -shl 16) -bor ($g -shl 8) -bor $r)
    }
    return 0x001A1418
}

# 应用图标：优先项目内 assets，其次外部路径，找不到则用系统默认
function Get-AppIcon {
    $cands = @(
        (Join-Path $PSScriptRoot 'assets\icon.ico'),
        (Join-Path $PSScriptRoot 'icon.ico'),
        'D:\edge\ico\图标.ico'
    )
    foreach ($p in $cands) {
        if ($p -and (Test-Path -LiteralPath $p)) {
            try {
                $bmp = New-Object Windows.Media.Imaging.BitmapImage
                $bmp.BeginInit()
                $bmp.UriSource = New-Object Uri($p, [UriKind]::Absolute)
                $bmp.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
                $bmp.EndInit()
                $bmp.Freeze()
                return $bmp
            } catch { }
        }
    }
    return $null
}

function Show-Status([string]$text, [string]$kind = 'info') {
    $script:el.TxtStatus.Text = $text
    $script:el.StatDot.Fill = switch ($kind) {
        'ok'   { $script:BR.ok }
        'err'  { $script:BR.broken }
        'busy' { $script:BR.accent }
        'warn' { $script:BR.dup }
        default { $script:BR.faint }
    }
    $script:el.TxtStatus.Foreground =
        if ($kind -eq 'err') { $script:BR.broken }
        elseif ($kind -eq 'ok') { $script:BR.text }
        else { $script:BR.textDim }
}

# ═══════════════════════════════════════════════════════════
#  异步任务
# ═══════════════════════════════════════════════════════════

$script:bg = $null
$script:timer = New-Object Windows.Threading.DispatcherTimer
$script:timer.Interval = [TimeSpan]::FromMilliseconds(350)

function Start-Bg([string]$label, [string]$scriptText, [scriptblock]$onDone) {
    if ($script:bg) { Show-Status '上一个任务尚未结束，请稍候' 'warn'; return }
    # 把占位符换成实际 shims 路径：脚本内容里不写死盘符
    $scriptText = $scriptText.Replace('__SHIMS__', $script:ScoopShims)
    # 左侧显示具体动作，右侧只做忙状态标记，避免两处重复同一句话
    Show-Status "$label …" 'busy'
    $script:el.TxtBusy.Text = '执行中'
    $ps = [PowerShell]::Create()
    [void]$ps.AddScript($scriptText)
    $h = $ps.BeginInvoke()
    $script:bg = @{ PS = $ps; H = $h; Label = $label; Done = $onDone }
    $script:timer.Start()
}

$script:timer.Add_Tick({
    $st = $script:bg
    if (-not $st) { $script:timer.Stop(); return }
    if (-not $st.H.IsCompleted) { return }

    $err = $null
    $res = $null
    try {
        # 取全部输出：搜索会返回对象数组，只取首元素会丢掉其余结果
        $res = @($st.PS.EndInvoke($st.H))
    } catch { $err = $_.Exception.Message }

    try { $st.PS.Dispose() } catch { }
    $script:bg = $null
    $script:timer.Stop()
    $script:el.TxtBusy.Text = ''

    if ($err) { Show-Status "$($st.Label) 失败：$err" 'err'; return }
    if ($st.Done) {
        try { & $st.Done $res }
        catch { Show-Status "处理结果出错：$($_.Exception.Message)" 'err' }
    }
})

# ═══════════════════════════════════════════════════════════
#  页面导航
# ═══════════════════════════════════════════════════════════

$script:pages = [ordered]@{
    'NavOverview' = @{ P = $script:el.PgOverview; T = '概览';       S = '环境变量与工具链的整体状态' }
    'NavApps'     = @{ P = $script:el.PgApps;     T = '已装软件';   S = '搜索、安装与卸载 Scoop 软件包' }
    'NavUpdates'  = @{ P = $script:el.PgUpdates;  T = '检查更新';   S = '列出有新版本的软件包' }
    'NavBuckets'  = @{ P = $script:el.PgBuckets;  T = 'Buckets';    S = '软件包来源仓库的管理' }
    'NavTools'    = @{ P = $script:el.PgTools;    T = '运行时';     S = '编程语言运行时与关键环境变量' }
    'NavPath'     = @{ P = $script:el.PgPath;     T = 'PATH 变量';  S = '系统搜索路径的健康状况' }
}
$script:navKeys = @($script:pages.Keys)
$script:suppressNav = $false

function Show-Page([string]$key) {
    if (-not $script:pages.Contains($key)) { return }
    $script:suppressNav = $true
    foreach ($k in $script:navKeys) { $script:el[$k].IsChecked = ($k -eq $key) }
    $script:suppressNav = $false

    foreach ($k in $script:navKeys) {
        $script:pages[$k].P.Visibility = if ($k -eq $key) { 'Visible' } else { 'Collapsed' }
    }
    $script:el.TxtTitle.Text = $script:pages[$key].T
    $script:el.TxtSub.Text   = $script:pages[$key].S
}

foreach ($k in $script:navKeys) {
    # 必须把键值“冻结”到控件自身：PowerShell 事件脚本块在触发时才读取循环变量，
    # 循环结束后它已是最后一个值，会导致点任何导航项都跳到同一页。
    # Tag 已被 XAML 用作图标字形，这里用 Uid 存键。
    $script:el[$k].Uid = $k
    $script:el[$k].Add_Checked({
        param($s, $e)
        if ($script:suppressNav) { return }
        $key = [string]$s.Uid
        if ($key) { Show-Page $key }
    })
}

# ═══════════════════════════════════════════════════════════
#  渲染
# ═══════════════════════════════════════════════════════════

function Render-Overview {
    $paths = Get-PathEntries
    $broken = @($paths | Where-Object { $_.State -eq 'broken' })
    $dups   = @($paths | Where-Object { $_.State -eq 'dup' })
    $apps   = Get-ScoopApps

    $script:el.StatPath.Text   = $paths.Count
    $script:el.StatBroken.Text = $broken.Count
    $script:el.StatDup.Text    = $dups.Count
    $script:el.StatApps.Text   = $apps.Count
    $script:el.StatBroken.Foreground = if ($broken.Count) { $script:BR.broken } else { $script:BR.ok }
    $script:el.StatDup.Foreground    = if ($dups.Count)    { $script:BR.dup }    else { $script:BR.ok }

    $score = [Math]::Max(0, 100 - ($broken.Count * 12) - ($dups.Count * 6))
    $script:el.TxtScore.Text = $score
    $script:el.TxtScore.Foreground =
        if ($score -ge 90) { $script:BR.ok } elseif ($score -ge 70) { $script:BR.dup } else { $script:BR.broken }

    if ($score -ge 95) {
        $script:el.TxtVerdict.Text = '环境状态良好'
        $script:el.TxtVerdict.Foreground = $script:BR.ok
        $script:el.TxtAdvice.Text = '没有发现失效或重复的路径，工具链解析正常。'
    } elseif ($score -ge 70) {
        $script:el.TxtVerdict.Text = '存在少量问题'
        $script:el.TxtVerdict.Foreground = $script:BR.dup
        $script:el.TxtAdvice.Text = "发现 $($broken.Count) 条失效路径、$($dups.Count) 条重复路径，建议清理。"
    } else {
        $script:el.TxtVerdict.Text = '需要立即处理'
        $script:el.TxtVerdict.Foreground = $script:BR.broken
        $script:el.TxtAdvice.Text = "失效路径过多（$($broken.Count) 条），可能导致命令解析变慢或失败。"
    }

    $grid = $script:el.GridSysInfo
    $grid.Children.Clear()
    $rows = Get-SysInfo
    for ($i = 0; $i -lt $rows.Count; $i++) {
        $r = [Math]::Floor($i / 2); $c = $i % 2

        $cell = New-Object Windows.Controls.Grid
        $cell.Margin = New-Object Windows.Thickness (0, $(if ($r -eq 0) { 0 } else { 10 }), $(if ($c -eq 0) { 32 } else { 0 }), 0)

        $cd1 = New-Object Windows.Controls.ColumnDefinition
        $cd1.Width = New-Object Windows.GridLength 92
        $cd2 = New-Object Windows.Controls.ColumnDefinition
        $cd2.Width = New-Object Windows.GridLength 1, ([Windows.GridUnitType]::Star)
        $cell.ColumnDefinitions.Add($cd1)
        $cell.ColumnDefinitions.Add($cd2)

        $k = New-Object Windows.Controls.TextBlock
        $k.Text = $rows[$i].K
        $k.FontSize = 12
        $k.Foreground = $script:BR.textDim
        $k.VerticalAlignment = 'Center'
        [Windows.Controls.Grid]::SetColumn($k, 0)

        $v = New-Object Windows.Controls.TextBlock
        $v.Text = $rows[$i].V
        $v.FontSize = 12
        $v.Foreground = $script:BR.text
        $v.VerticalAlignment = 'Center'
        $v.TextTrimming = 'CharacterEllipsis'
        [Windows.Controls.Grid]::SetColumn($v, 1)

        [void]$cell.Children.Add($k)
        [void]$cell.Children.Add($v)
        [Windows.Controls.Grid]::SetRow($cell, $r)
        [Windows.Controls.Grid]::SetColumn($cell, $c)
        [void]$grid.Children.Add($cell)
    }
}

function Render-Apps {
    $apps = Get-ScoopApps
    # 缓存已装名单，供搜索结果与详情弹窗复用
    $script:installedMap = @{}
    foreach ($a in $apps) { $script:installedMap[$a.Name.ToLower()] = $a.Version }

    $vm = @()
    foreach ($a in $apps) {
        $vm += [pscustomobject]@{
            Name         = $a.Name
            Version      = $a.Version
            Bucket       = $a.Bucket
            TagUninstall = "uninstall|$($a.Name)"
            TagInfo      = "info|$($a.Name)"
        }
    }
    $script:el.ListApps.ItemsSource = $vm
    $script:el.TxtAppsTitle.Text = "已装软件 · $($apps.Count) 个"
    $script:el.TxtAppsEmpty.Visibility = if ($apps.Count) { 'Collapsed' } else { 'Visible' }
}

function Render-Buckets {
    $bs = Get-Buckets
    $vm = @()
    foreach ($b in $bs) {
        $cnt = if ($b.Count) { "$($b.Count) 个包" } else { '—' }
        $vm += [pscustomobject]@{
            Name      = $b.Name
            CountText = $cnt
            Source    = $b.Source
            Tag       = "removebucket|$($b.Name)"
        }
    }
    $script:el.ListBuckets.ItemsSource = $vm
    $script:el.TxtBucketMeta.Text = "已添加的 Bucket · $($bs.Count) 个"
}

function Render-Tools {
    $tools = Get-ToolVersions
    $script:el.ListTools.ItemsSource = @($tools | ForEach-Object {
        [pscustomobject]@{
            Name     = $_.Name
            Version  = $_.Version
            Where    = $_.Where
            Brush    = if ($_.Ok) { $script:BR.ok } else { $script:BR.faint }
            TxtBrush = if ($_.Ok) { $script:BR.text } else { $script:BR.faint }
        }
    })

    $vars = Get-EnvVarList
    $script:el.ListEnvVars.ItemsSource = @($vars | ForEach-Object {
        $b = if ($null -eq $_.Ok) { $script:BR.faint } elseif ($_.Ok) { $script:BR.ok } else { $script:BR.broken }
        [pscustomobject]@{ Name = $_.Name; Value = $_.Value; Scope = $_.Scope; Brush = $b }
    })
}

function Render-Path {
    $paths = Get-PathEntries
    $order = @{ 'broken' = 0; 'dup' = 1; 'ok' = 2 }
    $sorted = @($paths | Sort-Object { $order[$_.State] })

    $vm = @()
    foreach ($p in $sorted) {
        $vm += [pscustomobject]@{
            Path     = $p.Path
            Scope    = $p.Scope
            Note     = $p.Note
            Brush    = switch ($p.State) { 'broken' { $script:BR.broken } 'dup' { $script:BR.dup } default { $script:BR.ok } }
            TxtBrush = if ($p.State -eq 'ok') { $script:BR.text } else { $script:BR.broken }
            ScopeFg  = if ($p.Scope -eq '用户') { $script:BR.accent } else { $script:BR.textDim }
        }
    }
    $script:el.ListPath.ItemsSource = $vm

    $uc = @($paths | Where-Object { $_.Scope -eq '用户' }).Count
    $mc = @($paths | Where-Object { $_.Scope -eq '系统' }).Count
    $bc = @($paths | Where-Object { $_.State -eq 'broken' }).Count
    $dc = @($paths | Where-Object { $_.State -eq 'dup' }).Count
    $script:el.TxtPathMeta.Text = "共 $($paths.Count) 条 · 用户级 $uc · 系统级 $mc · 失效 $bc · 重复 $dc"

    $script:el.BtnCleanPath.IsEnabled = ($bc + $dc) -gt 0
}

# 清理 PATH：先备份，再写回，失败可回滚
function Invoke-CleanPath {
    $all = Get-PathEntries
    $bad = @($all | Where-Object { $_.State -ne 'ok' })
    if (-not $bad.Count) { Show-Status '没有需要清理的路径' 'info'; return }

    $ans = [Windows.MessageBox]::Show(
        "将清理 $($bad.Count) 条失效/重复路径。`n`n清理前会自动备份到桌面。是否继续？",
        '确认清理 PATH',
        [Windows.MessageBoxButton]::YesNo,
        [Windows.MessageBoxImage]::Question)
    if ($ans -ne [Windows.MessageBoxResult]::Yes) { Show-Status '已取消清理' 'info'; return }

    $bkDir = Join-Path ([Environment]::GetFolderPath('Desktop')) "PATH-backup-$(Get-Date -f 'yyyyMMdd-HHmmss')"
    try {
        New-Item -ItemType Directory -Path $bkDir -Force | Out-Null
        [Environment]::GetEnvironmentVariable('PATH', 'User')    | Set-Content (Join-Path $bkDir 'PATH-user.txt')    -Encoding utf8
        [Environment]::GetEnvironmentVariable('PATH', 'Machine') | Set-Content (Join-Path $bkDir 'PATH-machine.txt') -Encoding utf8
    } catch {
        Show-Status "备份失败，已中止：$($_.Exception.Message)" 'err'
        return
    }

    $sb = @"
`$ErrorActionPreference = 'Stop'
function Clean([string]`$raw) {
    `$seen = @{}
    `$keep = @()
    foreach (`$p in (`$raw -split ';' | Where-Object { `$_ })) {
        `$key = (`$p.TrimEnd('\')).ToLower()
        if (-not (Test-Path -LiteralPath `$p)) { continue }
        if (`$seen.ContainsKey(`$key)) { continue }
        `$seen[`$key] = `$true
        `$keep += `$p
    }
    return (`$keep -join ';')
}
`$u = Clean ([Environment]::GetEnvironmentVariable('PATH','User'))
`$m = Clean ([Environment]::GetEnvironmentVariable('PATH','Machine'))
[Environment]::SetEnvironmentVariable('PATH', `$u, 'User')
[Environment]::SetEnvironmentVariable('PATH', `$m, 'Machine')
"removed"
"@
    Start-Bg '清理 PATH' $sb {
        param($res)
        Render-Path
        Render-Overview
        Show-Status "已清理，备份保存在 $(Split-Path $bkDir -Leaf)" 'ok'
    }.GetNewClosure()
}

# 导出当前 PATH 到文本，便于排查
function Export-PathList {
    $all = Get-PathEntries
    $f = Join-Path ([Environment]::GetFolderPath('Desktop')) ("PATH-export-{0}.txt" -f (Get-Date -f 'yyyyMMdd-HHmmss'))
    try {
        $lines = @('序号 作用域 状态 路径')
        $i = 0
        foreach ($p in $all) {
            $i++
            $st = switch ($p.State) { 'broken' { '失效' } 'dup' { '重复' } default { '正常' } }
            $lines += "{0,3}  {1}  {2}  {3}" -f $i, $p.Scope, $st, $p.Path
        }
        $lines | Set-Content $f -Encoding utf8
        Show-Status "已导出到 $f" 'ok'
    } catch {
        Show-Status "导出失败：$($_.Exception.Message)" 'err'
    }
}

# 直接打开系统环境变量编辑面板（兜底，供手工调整）
function Open-EnvPanel {
    try {
        Start-Process 'rundll32.exe' -ArgumentList 'sysdm.cpl,EditEnvironmentVariables'
        Show-Status '已打开系统环境变量面板' 'info'
    } catch {
        Show-Status "无法打开：$($_.Exception.Message)" 'err'
    }
}

# 把后台采集的 JSON 写入缓存，然后重绘界面
function Apply-Data([string]$json) {
    $o = $json | ConvertFrom-Json
    if (-not $o) { Show-Status '数据为空' 'err'; return }

    $script:cache = @{
        Paths   = @($o.Paths | ForEach-Object {
            [pscustomobject]@{
                Path = $_.Path; Scope = $_.Scope; State = $_.State
                Note = switch ($_.State) { 'broken' { '不存在' } 'dup' { '重复' } default { '' } }
            }
        })
        Apps    = @($o.Apps | ForEach-Object {
            [pscustomobject]@{ Name = $_.N; Version = $_.V; Bucket = $_.B }
        })
        Buckets = @($o.Buckets | ForEach-Object {
            [pscustomobject]@{ Name = $_.N; Source = $_.Src; Count = $_.C }
        })
        Tools   = @($o.Tools | ForEach-Object {
            [pscustomobject]@{ Name = $_.N; Version = $_.V; Where = $_.W; Ok = [bool]$_.OK }
        })
        Vars    = @($o.Vars | ForEach-Object {
            [pscustomobject]@{ Name = $_.N; Value = $_.V; Scope = $_.S; Ok = $_.OK }
        })
        Sys     = $o.Sys
    }

    # 已装名单供搜索与详情复用
    $script:installedMap = @{}
    foreach ($a in $script:cache.Apps) { $script:installedMap[$a.Name.ToLower()] = $a.Version }

    try { Render-All } catch { Show-Status "渲染失败：$($_.Exception.Message)" 'err' }
    Show-Status '数据已更新' 'ok'
}

function Render-All {
    # 同步版本：只用于数据已经在手上的场合（如主题切换只换色）
    try { Render-Overview } catch { Show-Status "概览渲染失败：$($_.Exception.Message)" 'err' }
    try { Render-Apps }     catch { Show-Status "软件列表失败：$($_.Exception.Message)" 'err' }
    try { Render-Buckets }  catch { Show-Status "Bucket 列表失败：$($_.Exception.Message)" 'err' }
    try { Render-Tools }    catch { Show-Status "运行时信息失败：$($_.Exception.Message)" 'err' }
    try { Render-Path }     catch { Show-Status "PATH 列表失败：$($_.Exception.Message)" 'err' }
    Update-Stamp
}

# 只重画、不重新采集：主题切换走这条，避免调外部进程
function Redraw-All {
    try { Render-OverviewView } catch { }
    try { Render-AppsView }     catch { }
    try { Render-BucketsView }  catch { }
    try { Render-ToolsView }    catch { }
    try { Render-PathView }     catch { }
    Update-Stamp
}

function Update-Stamp {
    $themeLabel = if ($script:UiTheme.SkinName) { "跟随皮肤 · $($script:UiTheme.Name)" } else { $script:UiTheme.Name }
    $script:el.TxtStamp.Text = "$themeLabel · " + (Get-Date -Format 'HH:mm')
}

# 采集脚本：后台线程与截图模式共用
$script:DataScript = @'
$ErrorActionPreference = 'SilentlyContinue'
`$env:Path = "$($script:ScoopShims);" + `$env:Path
function Clean([string]$raw) {
    $seen = @{}
    $keep = @()
    foreach ($p in ($raw -split ';' | Where-Object { $_ })) {
        $k = ($p.TrimEnd('\')).ToLower()
        if (-not (Test-Path -LiteralPath $p)) { continue }
        if ($seen.ContainsKey($k)) { continue }
        $seen[$k] = $true; $keep += $p
    }
    return ($keep -join ';')
}

# PATH
$u = [Environment]::GetEnvironmentVariable('PATH','User')
$m = [Environment]::GetEnvironmentVariable('PATH','Machine')
$uI = @($u -split ';' | Where-Object { $_ })
$mI = @($m -split ';' | Where-Object { $_ })
$fk = @{}
foreach ($k in @($uI | ForEach-Object { $_.TrimEnd('\').ToLower() }) + @($mI | ForEach-Object { $_.TrimEnd('\').ToLower() })) {
    if ($fk.ContainsKey($k)) { $fk[$k]++ } else { $fk[$k] = 1 }
}
$paths = @()
foreach ($set in @(@{I=$uI;S='用户'}, @{I=$mI;S='系统'})) {
    foreach ($p in $set.I) {
        $k = $p.TrimEnd('\').ToLower()
        $ex = Test-Path -LiteralPath $p
        $dup = $fk[$k] -gt 1
        $st = if (-not $ex) { 'broken' } elseif ($dup) { 'dup' } else { 'ok' }
        $paths += [pscustomobject]@{ Path=$p; Scope=$set.S; State=$st }
    }
}

# Scoop
$apps = @()
$r = & $script:ScoopCmd list 2>$null
if ($r -and $r[0].PSObject.Properties['Name']) {
    foreach ($x in $r) { if ($x.Name) { $apps += [pscustomobject]@{ N=$x.Name; V=$x.Version; B=$x.Source } } }
} else {
    foreach ($line in ($r | Out-String -Width 200) -split "`n") {
        $t = $line.TrimEnd()
        if ($t -match '^\s*(\S+)\s+(\S+)\s+(\S+)' -and $Matches[1] -notmatch '^-+$|^Name$|^Installed$') {
            $apps += [pscustomobject]@{ N=$Matches[1]; V=$Matches[2]; B=$Matches[3] }
        }
    }
}

$bks = @()
$rb = & $script:ScoopCmd bucket list 2>$null
foreach ($line in ($rb | Out-String -Width 200) -split "`n") {
    $t = $line.TrimEnd()
    if ($t -match '^\s*(\S+)\s+(\S+)\s+(\d+)\s*$') {
        $bks += [pscustomobject]@{ N=$Matches[1]; Src=$Matches[2]; C=[int]$Matches[3] }
    }
}

# 工具版本
$tools = @()
$defs = @(
    @{N='Node.js';C='node';A='--version';P='^v'},
    @{N='npm';C='npm';A='--version';P=''},
    @{N='Python';C='python';A='--version';P='^Python\s+'},
    @{N='Java';C='java';A='--version';P='^java\s+'},
    @{N='Maven';C='mvn';A='--version';P='^Apache Maven\s+'},
    @{N='Git';C='git';A='--version';P='^git version\s+'},
    @{N='GitHub CLI';C='gh';A='--version';P='^gh version\s+'},
    @{N='aria2';C='aria2c';A='--version';P='^aria2 version\s+'}
)
foreach ($d in $defs) {
    $c = Get-Command $d.C -ErrorAction SilentlyContinue
    if (-not $c) { $tools += [pscustomobject]@{ N=$d.N; V='未安装'; W=''; OK=$false }; continue }
    $v = '已安装'
    try {
        $raw = & $d.C $d.A.Split(' ') 2>&1
        $f = @($raw | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ }) | Select-Object -First 1
        if ($f) { if ($d.P) { $f = $f -replace $d.P, '' }; $v = ($f -split '\s+')[0]; if ($v.Length -gt 24) { $v = $v.Substring(0,24) + '…' } }
    } catch { $v = '读取失败' }
    $tools += [pscustomobject]@{ N=$d.N; V=$v; W=$c.Source; OK=$true }
}
$scv = '已安装'
try {
    $sr = @(& $script:ScoopCmd --version 2>$null | ForEach-Object { $_.ToString() })
    $hit = $sr | Where-Object { $_ -match '\d+\.\d+\.\d+' } | Select-Object -First 1
    if ($hit -and $hit -match '(\d+\.\d+\.\d+)') { $scv = 'v' + $Matches[1] }
} catch { }
$scPath = (Get-Command scoop -ErrorAction SilentlyContinue).Source
$tools += [pscustomobject]@{ N='Scoop'; V=$scv; W=$scPath; OK=$true }

# 环境变量
$vars = @()
foreach ($n in @('JAVA_HOME','MAVEN_HOME','NVM_HOME','NVM_SYMLINK','PNPM_HOME','SCOOP','SCOOP_GLOBAL')) {
    $val = [Environment]::GetEnvironmentVariable($n,'User')
    $sc2 = '用户'
    if (-not $val) { $val = [Environment]::GetEnvironmentVariable($n,'Machine'); $sc2 = '系统' }
    if ($val) { $vars += [pscustomobject]@{ N=$n; V=$val; S=$sc2; OK=(Test-Path -LiteralPath $val) } }
    else { $vars += [pscustomobject]@{ N=$n; V='未设置'; S=''; OK=$null } }
}

# 系统信息
$os = '未知'
try { $o = Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 3; if ($o.Caption) { $os = $o.Caption -replace 'Microsoft\s*','' } } catch { }

ConvertTo-Json -Compress -Depth 6 -InputObject @{
    Paths = $paths
    Apps  = $apps
    Buckets = $bks
    Tools = $tools
    Vars  = $vars
    Sys   = @{ Computer=$env:COMPUTERNAME; User=$env:USERNAME; OS=$os; PS=$PSVersionTable.PSVersion.ToString(); DotNet=[Environment]::Version.ToString() }
}
'@
# 注入实际 shims 路径
$script:DataScript = $script:DataScript.Replace('__SHIMS__', $script:ScoopShims)

# 同步采集（仅截图模式用）：跑同一份采集脚本并等结果
function Get-SyncDataJson {
    $ps = [PowerShell]::Create()
    [void]$ps.AddScript($script:DataScript)
    $h = $ps.BeginInvoke()
    $h.AsyncWaitHandle.WaitOne(60000) | Out-Null
    $r = $ps.EndInvoke($h) | Select-Object -First 1
    $ps.Dispose()
    return ($r | Out-String)
}

# 异步刷新：数据采集放后台线程，UI 不冻结
$script:dataLoading = $false
function Start-DataLoad {
    if ($script:dataLoading) { return }
    $script:dataLoading = $true
    Show-Status '正在读取环境数据…' 'busy'

    $sb = $script:DataScript

    $ps = [PowerShell]::Create()
    [void]$ps.AddScript($sb)
    $h = $ps.BeginInvoke()
    $script:load = @{ PS = $ps; H = $h }

    # 定时器必须挂在 $script: 上：局部变量失去引用后会被 GC 回收，
    # Tick 就再也不会触发（数据永远填不进去）。
    $script:loadTimer = New-Object Windows.Threading.DispatcherTimer
    $script:loadTimer.Interval = [TimeSpan]::FromMilliseconds(200)
    $script:loadTimer.Add_Tick({
        if (-not $script:load) {
            $script:loadTimer.Stop()
            $script:dataLoading = $false
            return
        }
        if (-not $script:load.H.IsCompleted) { return }

        $script:loadTimer.Stop()
        $res = $null
        $errMsg = $null
        try { $res = $script:load.PS.EndInvoke($script:load.H) | Select-Object -First 1 }
        catch { $errMsg = $_.Exception.Message }
        try { $script:load.PS.Dispose() } catch { }
        $script:load = $null
        $script:dataLoading = $false

        if ($errMsg) { Show-Status "读取失败：$errMsg" 'err'; return }
        if (-not $res) { Show-Status '数据读取失败（无输出）' 'err'; return }
        try { Apply-Data ($res | Out-String) }
        catch { Show-Status "解析失败：$($_.Exception.Message)" 'err' }
    })
    $script:loadTimer.Start()
}

# ═══════════════════════════════════════════════════════════
#  操作
# ═══════════════════════════════════════════════════════════

# 搜索结果区高度：随窗口变化，占可用高度的 ~38%，并限制上下界
function Update-SearchHeight {
    try {
        $h = $win.ActualHeight
        if ($h -le 0) { return }
        $v = [int]($h * 0.38)
        if ($v -lt 180) { $v = 180 }
        if ($v -gt 620) { $v = 620 }
        $script:el.ScrollSearch.MaxHeight = $v
    } catch { }
}

function Start-Search([string]$term) {
    if (-not $script:ScoopOk) { Show-Status 'scoop 不可用，无法搜索' 'err'; return }
    if (-not $term) { Show-Status '请输入搜索关键字' 'warn'; return }
    $script:lastTerm = $term
    $safe = $term.Replace("'", "''")
    # scoop search 会同时匹配包名和 Binaries 列（可执行文件名），
    # 例如搜 python 会带出 pulumi（含 pulumi-language-python.exe）。
    # 这里把 Binaries 也解析出来，交给界面按关键字决定是否保留。
    # 注意：$safe 不能包在单引号里，否则 here-string 不插值。
    $sb = @"
`$env:Path = '__SHIMS__;' + `$env:Path
`$raw = & $script:ScoopCmd search "$safe" 2>`$null
`$lines = @((`$raw | Out-String -Width 400) -split "``n")
`$hdr = `$lines | Where-Object { `$_ -match '^Name\s+Version' } | Select-Object -First 1
`$posV = 0; `$posS = 0; `$posB = 0
if (`$hdr) {
    `$posV = `$hdr.IndexOf('Version')
    `$posS = `$hdr.IndexOf('Source')
    `$posB = `$hdr.IndexOf('Binaries')
}
`$items = @()
foreach (`$line in `$lines) {
    `$t = `$line.TrimEnd()
    if (-not `$t) { continue }
    if (`$t -match '^Results from|^No matches|^Name\s+Version|^-{3,}') { continue }
    if (`$posV -gt 0 -and `$posS -gt `$posV -and `$t.Length -gt `$posV) {
        # 先把行补到表头宽度，再按位置切列——避免短行触发 Substring 越界
        `$w = `$posV
        if (`$posB -gt 0) { `$w = `$posB + 60 }
        `$pad = `$t
        if (`$pad.Length -lt `$w) { `$pad = `$pad.PadRight(`$w) }
        `$n = `$pad.Substring(0, `$posV).Trim()
        `$v = if (`$posS -gt `$posV) { `$pad.Substring(`$posV, `$posS - `$posV).Trim() } else { '' }
        `$src = if (`$posB -gt `$posS) { `$pad.Substring(`$posS, `$posB - `$posS).Trim() } else { '' }
        `$b = if (`$posB -gt 0) { `$pad.Substring(`$posB).Trim() } else { '' }
        if (`$n) { `$items += [pscustomobject]@{ N = `$n; V = `$v; B = `$src; Bin = `$b } }
    }
}
`$items | Select-Object -First 200
"@
    Start-Bg "搜索 $term" $sb ({
        param($res)
        $items = @($res | Where-Object { $_ })
        # 只按包名匹配（默认）；勾选「含二进制」时才保留仅在 Binaries 里命中的结果
        $kw = [string]$script:lastTerm
        $kw = $kw.ToLower()
        if (-not $script:installedMap) { $script:installedMap = @{} }
        $nameHits = @()
        $binOnlyHits = @()
        foreach ($i in $items) {
            $nm = [string]$i.N
            $nmL = $nm.ToLower()
            if ($nmL.Contains($kw)) {
                $nameHits += $i
            } elseif ($script:SearchBinaries) {
                $binL = [string]$i.Bin
                $binL = $binL.ToLower()
                if ($binL.Contains($kw)) { $binOnlyHits += $i }
            }
        }
        $items = @($nameHits + $binOnlyHits)

        $vm = @()
        $hitInstalled = 0
        foreach ($i in $items) {
            # 对比已装名单：已装则标记版本，未装则允许安装
            $k = ([string]$i.N).ToLower()
            $isInstalled = $script:installedMap.ContainsKey($k)
            if ($isInstalled) { $hitInstalled++ }
            $vm += [pscustomobject]@{
                Name          = $i.N
                Version       = $i.V
                Bucket        = $i.B
                Tag           = if ($isInstalled) { "info|$($i.N)" } else { "install|$($i.N)" }
                ActionLabel   = if ($isInstalled) { '已安装' } else { '安装' }
                ActionEnabled = -not $isInstalled
                StateText     = if ($isInstalled) { "已装 $($script:installedMap[$k])" } else { '' }
                StateBrush    = if ($isInstalled) { $script:BR.ok } else { $script:BR.faint }
            }
        }
        $script:el.ListSearch.ItemsSource = $vm

        if ($vm.Count) {
            $uninstalled = $vm.Count - $hitInstalled
            $script:el.TxtSearchHint.Text = "找到 $($vm.Count) 个 · 已装 $hitInstalled · 可装 $uninstalled"
            Show-Status "找到 $($vm.Count) 个结果，其中 $hitInstalled 个已安装" 'ok'
        } else {
            $script:el.TxtSearchHint.Text = "没有找到「$script:lastTerm」相关软件包"
            Show-Status "未找到 $script:lastTerm" 'warn'
        }
    })
}

function Start-Install([string]$name) {
    $safe = $name.Replace("'", "''")
    $sb = @"
`$env:Path = '__SHIMS__;' + `$env:Path
`$out = & scoop install '$safe' 2>&1
(`$out | ForEach-Object { `$_.ToString() }) -join "``n"
"@
    Start-Bg "安装 $name" $sb {
        param($res)
        $text = if ($res -is [array]) { ($res | ForEach-Object { "$_" }) -join "`n" } else { [string]$res }
        if ($text -match 'successfully installed|is already installed') {
            Show-Status "已安装 $name" 'ok'
        } else {
            $tail = ($text -split "`n" | Where-Object { $_ -match '\S' } | Select-Object -Last 1)
            Show-Status "安装 $name 失败：$tail" 'err'
        }
        Render-All
    }
}

function Start-Uninstall([string]$name) {
    $safe = $name.Replace("'", "''")
    $sb = @"
`$env:Path = '__SHIMS__;' + `$env:Path
`$out = & scoop uninstall '$safe' 2>&1
(`$out | ForEach-Object { `$_.ToString() }) -join "``n"
"@
    Start-Bg "卸载 $name" $sb {
        param($res)
        $text = if ($res -is [array]) { ($res | ForEach-Object { "$_" }) -join "`n" } else { [string]$res }
        if ($text -match 'was uninstalled|uninstalled successfully|is not installed') {
            Show-Status "已卸载 $name" 'ok'
        } else {
            $tail = ($text -split "`n" | Where-Object { $_ -match '\S' } | Select-Object -Last 1)
            Show-Status "卸载 $name：$tail" 'warn'
        }
        Render-All
    }
}

function Start-UpdateOne([string]$name) {
    $safe = $name.Replace("'", "''")
    $sb = @"
`$env:Path = '__SHIMS__;' + `$env:Path
`$out = & scoop update '$safe' 2>&1
(`$out | ForEach-Object { `$_.ToString() }) -join "``n"
"@
    Start-Bg "更新 $name" $sb {
        param($res)
        $text = if ($res -is [array]) { ($res | ForEach-Object { "$_" }) -join "`n" } else { [string]$res }
        if ($text -match 'successfully|already installed|up to date') {
            Show-Status "已更新 $name" 'ok'
        } else {
            $tail = ($text -split "`n" | Where-Object { $_ -match '\S' } | Select-Object -Last 1)
            Show-Status "更新 $name 失败：$tail" 'err'
        }
        Render-All
        Start-UpdateCheck
    }
}

function Start-UpdateAll {
    $sb = @'
`$env:Path = "$($script:ScoopShims);" + `$env:Path
$out = & scoop update * 2>&1
($out | ForEach-Object { $_.ToString() }) -join "`n"
'@
    Start-Bg '全部更新' $sb {
        param($res)
        Show-Status '全部更新已执行完毕' 'ok'
        Render-All
        Start-UpdateCheck
    }
}

function Start-UpdateCheck {
    if (-not $script:ScoopOk) {
        $script:el.TxtUpdateMeta.Text = 'scoop 不可用，无法检查更新'
        return
    }
    $script:el.TxtUpdateMeta.Text = '正在检查…'
    $script:el.TxtUpdateMeta.Foreground = $script:BR.textDim
    $sb = @'
`$env:Path = "$($script:ScoopShims);" + `$env:Path
$out = & $script:ScoopCmd status 2>$null
$text = ($out | Out-String -Width 300)
$items = @()
foreach ($l in ($text -split "`n")) {
    $t = $l.TrimEnd()
    if ($t -match '^\s*(\S+)\s*:\s*(\S+)\s*->\s*(\S+)') {
        $items += [pscustomobject]@{ N = $Matches[1]; From = $Matches[2]; To = $Matches[3] }
    }
}
# 跨进程返回对象会丢属性，序列化成 JSON 传
ConvertTo-Json -InputObject @{ Items = $items; Ok = $true } -Depth 4 -Compress
'@
    Start-Bg '检查更新' $sb {
        param($res)
        $items = @()
        try {
            $obj = ($res | Out-String).Trim() | ConvertFrom-Json
            if ($obj -and $obj.Items) { $items = @($obj.Items) }
        } catch { $items = @() }
        $vm = @()
        foreach ($i in $items) {
            $vm += [pscustomobject]@{
                Name   = $i.N
                Change = "$($i.From)  →  $($i.To)"
                Tag    = "updateone|$($i.N)"
            }
        }
        $script:el.ListUpdates.ItemsSource = $vm
        if ($vm.Count) {
            $script:el.TxtUpdateMeta.Text = "$($vm.Count) 个软件有新版本"
            $script:el.TxtUpdateMeta.Foreground = $script:BR.dup
            Show-Status "$($vm.Count) 个软件可更新" 'warn'
        } else {
            $script:el.TxtUpdateMeta.Text = '所有软件均为最新版本'
            $script:el.TxtUpdateMeta.Foreground = $script:BR.ok
            Show-Status '全部为最新版本' 'ok'
        }
    }
}

function Start-AddBucket([string]$name) {
    if (-not $name) { Show-Status '请输入 Bucket 名称' 'warn'; return }
    $safe = $name.Replace("'", "''")
    $sb = @"
`$env:Path = '__SHIMS__;' + `$env:Path
`$out = & scoop bucket add '$safe' 2>&1
(`$out | ForEach-Object { `$_.ToString() }) -join "``n"
"@
    Start-Bg "添加 $name" $sb {
        param($res)
        $text = if ($res -is [array]) { ($res | ForEach-Object { "$_" }) -join "`n" } else { [string]$res }
        if ($text -match 'was added|already exists|Adding') {
            Show-Status "已添加 bucket $name" 'ok'
        } else {
            $tail = ($text -split "`n" | Where-Object { $_ -match '\S' } | Select-Object -Last 1)
            Show-Status "添加失败：$tail" 'err'
        }
        Render-Buckets
    }
}

function Start-RemoveBucket([string]$name) {
    $safe = $name.Replace("'", "''")
    $sb = @"
`$env:Path = '__SHIMS__;' + `$env:Path
`$out = & scoop bucket rm '$safe' 2>&1
(`$out | ForEach-Object { `$_.ToString() }) -join "``n"
"@
    Start-Bg "移除 $name" $sb {
        param($res)
        Show-Status "已移除 bucket $name" 'ok'
        Render-Buckets
    }
}

function Show-AppDetail([string]$name) {
    $safe = $name.Replace("'", "''")
    $sb = @"
`$env:Path = '__SHIMS__;' + `$env:Path
`$out = & scoop info '$safe' 2>&1
(`$out | ForEach-Object { `$_.ToString() }) -join "``n"
"@
    Start-Bg "读取 $name 详情" $sb {
        param($res)
        Open-DetailWindow $name ($(if ($res -is [array]) { ($res | ForEach-Object { "$_" }) -join "`n" } else { [string]$res }))
    }.GetNewClosure()
}

# 详情弹窗：只读原文 + 复制 + 已装状态徽章
function Open-DetailWindow([string]$name, [string]$text) {
    $d = New-Object Windows.Window
    $d.Title = "软件详情 · $name"
    $d.Width = 720
    $d.Height = 560
    $d.MinWidth = 520
    $d.MinHeight = 400
    $d.WindowStartupLocation = 'CenterOwner'
    $d.Owner = $win
    $d.Background = (B $script:UiTheme.BgWindow)
    $d.FontFamily = New-Object Windows.Media.FontFamily 'Microsoft YaHei UI'
    $d.UseLayoutRounding = $true
    try { $ico = Get-AppIcon; if ($ico) { $d.Icon = $ico } } catch { }

    $grid = New-Object Windows.Controls.Grid
    foreach ($h in @('Auto','*','Auto')) {
        $rd = New-Object Windows.Controls.RowDefinition
        $rd.Height = if ($h -eq 'Auto') {
            New-Object Windows.GridLength 1, ([Windows.GridUnitType]::Auto)
        } else {
            New-Object Windows.GridLength 1, ([Windows.GridUnitType]::Star)
        }
        $grid.RowDefinitions.Add($rd)
    }

    # 头部：名称 + 已装徽章
    $head = New-Object Windows.Controls.StackPanel
    $head.Margin = New-Object Windows.Thickness 24, 22, 24, 14

    $titleRow = New-Object Windows.Controls.StackPanel
    $titleRow.Orientation = 'Horizontal'

    $tbTitle = New-Object Windows.Controls.TextBlock
    $tbTitle.Text = $name
    $tbTitle.FontSize = 22
    $tbTitle.FontWeight = 'SemiBold'
    $tbTitle.Foreground = $script:BR.main
    [void]$titleRow.Children.Add($tbTitle)

    $isInstalled = $script:installedMap.ContainsKey($name.ToLower())
    if ($isInstalled) {
        $badge = New-Object Windows.Controls.Border
        $badge.Background = (B '#265FD39A')
        $badge.CornerRadius = New-Object Windows.CornerRadius 4
        $badge.Padding = New-Object Windows.Thickness 8, 3, 8, 3
        $badge.Margin = New-Object Windows.Thickness 10, 6, 0, 0
        $bt = New-Object Windows.Controls.TextBlock
        $bt.Text = '已安装 ' + $script:installedMap[$name.ToLower()]
        $bt.FontSize = 10.5
        $bt.Foreground = $script:BR.ok
        $badge.Child = $bt
        [void]$titleRow.Children.Add($badge)
    }
    [void]$head.Children.Add($titleRow)

    $sub = New-Object Windows.Controls.TextBlock
    $sub.Text = 'scoop info 原始输出'
    $sub.FontSize = 11
    $sub.Foreground = $script:BR.textDim
    $sub.Margin = New-Object Windows.Thickness 0, 6, 0, 0
    [void]$head.Children.Add($sub)

    [Windows.Controls.Grid]::SetRow($head, 0)
    [void]$grid.Children.Add($head)

    # 正文
    $card = New-Object Windows.Controls.Border
    $card.Background = (B $script:UiTheme.Card)
    $card.CornerRadius = New-Object Windows.CornerRadius 10
    $card.BorderThickness = New-Object Windows.Thickness 1
    $card.BorderBrush = (B $script:UiTheme.OverlayStrokeWeak)
    $card.Margin = New-Object Windows.Thickness 24, 0, 24, 0
    $card.Padding = New-Object Windows.Thickness 4

    $tb = New-Object Windows.Controls.TextBox
    $tb.Text = if ($text -and $text.Trim()) { $text } else { '（未取到详情输出）' }
    $tb.IsReadOnly = $true
    $tb.TextWrapping = 'NoWrap'
    $tb.AcceptsReturn = $true
    $tb.BorderThickness = New-Object Windows.Thickness 0
    $tb.Background = [Windows.Media.Brushes]::Transparent
    $tb.Foreground = $script:BR.text
    $tb.FontFamily = New-Object Windows.Media.FontFamily 'Consolas, Cascadia Mono'
    $tb.FontSize = 12
    $tb.Padding = New-Object Windows.Thickness 12, 10, 12, 10
    $tb.VerticalScrollBarVisibility = 'Auto'
    $tb.HorizontalScrollBarVisibility = 'Auto'
    $card.Child = $tb
    [Windows.Controls.Grid]::SetRow($card, 1)
    [void]$grid.Children.Add($card)

    # 底部
    $foot = New-Object Windows.Controls.StackPanel
    $foot.Orientation = 'Horizontal'
    $foot.HorizontalAlignment = 'Right'
    $foot.Margin = New-Object Windows.Thickness 24, 14, 24, 20

    $btnCopy = New-Object Windows.Controls.Button
    $btnCopy.Content = '复制信息'
    $btnCopy.Width = 96
    $btnCopy.Height = 32
    $btnCopy.Margin = New-Object Windows.Thickness 0, 0, 8, 0
    $btnCopy.Cursor = 'Hand'
    $btnCopy.Background = (B $script:UiTheme.OverlayBtn)
    $btnCopy.Foreground = $script:BR.text
    $btnCopy.BorderThickness = New-Object Windows.Thickness 0
    $btnCopy.Add_Click({
        try {
            [Windows.Clipboard]::SetText($tb.Text)
            Show-Status "已复制 $name 的详情" 'ok'
        } catch { Show-Status "复制失败：$($_.Exception.Message)" 'err' }
    }.GetNewClosure())

    $btnClose = New-Object Windows.Controls.Button
    $btnClose.Content = '关闭'
    $btnClose.Width = 84
    $btnClose.Height = 32
    $btnClose.Cursor = 'Hand'
    $btnClose.Background = (B $script:UiTheme.Accent)
    $btnClose.Foreground = (B $script:UiTheme.BgWindow)
    $btnClose.FontWeight = 'SemiBold'
    $btnClose.BorderThickness = New-Object Windows.Thickness 0
    $btnClose.Add_Click({ $d.Close() }.GetNewClosure())

    [void]$foot.Children.Add($btnCopy)
    [void]$foot.Children.Add($btnClose)
    [Windows.Controls.Grid]::SetRow($foot, 2)
    [void]$grid.Children.Add($foot)

    $d.Content = $grid
    try {
        $dh = (New-Object Windows.Interop.WindowInteropHelper $d).EnsureHandle()
        if ($dh -ne [IntPtr]::Zero) { [DwmDark]::ApplyLight($dh, (Get-CaptionColorRef $script:UiTheme.BgWindow), (Get-CaptionColorRef $script:UiTheme.TextMain)) }
    } catch { }
    [void]$d.ShowDialog()
}

function Handle-RowAction($btn) {
    $tag = [string]$btn.Tag
    if (-not $tag) { return }
    $parts = $tag -split '\|', 2
    if ($parts.Count -lt 2) { return }
    switch ($parts[0]) {
        'install'      { Start-Install $parts[1] }
        'uninstall'    { Start-Uninstall $parts[1] }
        'updateone'    { Start-UpdateOne $parts[1] }
        'info'         { Show-AppDetail $parts[1] }
        'removebucket' { Start-RemoveBucket $parts[1] }
    }
}

foreach ($lc in @($script:el.ListSearch, $script:el.ListApps, $script:el.ListUpdates, $script:el.ListBuckets)) {
    $lc.AddHandler([Windows.Controls.Button]::ClickEvent, [Windows.RoutedEventHandler]{
        param($s, $e)
        Handle-RowAction $e.OriginalSource
    })
}

$script:SearchBinaries = $false
$script:el.ChkSearchBinaries.Add_Click({
    $script:SearchBinaries = [bool]$script:el.ChkSearchBinaries.IsChecked
    if ($script:el.TxtSearch.Text.Trim()) { Start-Search ($script:el.TxtSearch.Text.Trim()) }
})
$script:el.BtnSearch.Add_Click({ Start-Search ($script:el.TxtSearch.Text.Trim()) })
$script:el.TxtSearch.Add_KeyDown({
    param($s, $e)
    if ($e.Key -eq 'Return') { Start-Search ($script:el.TxtSearch.Text.Trim()) }
})
$script:el.BtnClearSearch.Add_Click({
    $script:el.TxtSearch.Text = ''
    $script:el.ListSearch.ItemsSource = $null
    $script:el.TxtSearchHint.Text = '输入关键字后按回车搜索'
    Show-Status '已清空搜索结果' 'info'
})
$script:el.BtnAppsReload.Add_Click({ Render-Apps; Show-Status '软件列表已刷新' 'ok' })
$script:el.BtnCleanPath.Add_Click({ Invoke-CleanPath })
$script:el.BtnExportPath.Add_Click({ Export-PathList })
$script:el.BtnOpenEnv.Add_Click({ Open-EnvPanel })
$script:el.BtnCheckUpdate.Add_Click({ Start-UpdateCheck })
$script:el.BtnUpdateAll.Add_Click({ Start-UpdateAll })
$script:el.BtnAddBucket.Add_Click({ Start-AddBucket ($script:el.TxtBucketName.Text.Trim()) })
$script:el.TxtBucketName.Add_KeyDown({
    param($s, $e)
    if ($e.Key -eq 'Return') { Start-AddBucket ($script:el.TxtBucketName.Text.Trim()) }
})
$script:el.BtnRefresh.Add_Click({
    # 异步重新采集，UI 不冻结
    Start-DataLoad
})

# ── 主题切换：XAML 资源在加载时已绑定，切换需重启窗口 ──
# ── 热切换主题：直接改写 XAML 资源，无需重启 ──
$win.Add_KeyDown({
    param($s, $e)
    if ($e.Key -eq 'F5') { Render-All; Show-Status '已刷新' 'ok' }
    if ($e.Key -eq 'F' -and ([Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Control)) {
        Show-Page 'NavApps'
        $script:el.TxtSearch.Focus() | Out-Null
    }
})

# ═══════════════════════════════════════════════════════════
#  自截图（仅调试）
# ═══════════════════════════════════════════════════════════

function Save-Shot([string]$path) {
    try {
        $root = $win.Content
        $w = [int][Math]::Ceiling($root.ActualWidth)
        $h = [int][Math]::Ceiling($root.ActualHeight)
        if ($w -le 0 -or $h -le 0) { return $false }
        $rtb = New-Object Windows.Media.Imaging.RenderTargetBitmap(
            $w, $h, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
        $rtb.Render($root)
        $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
        $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($rtb))
        $fs = [IO.File]::Create($path)
        $enc.Save($fs)
        $fs.Close()
        return $true
    } catch { return $false }
}

# ═══════════════════════════════════════════════════════════
#  启动
# ═══════════════════════════════════════════════════════════

$win.Add_Loaded({
    try {
        $h = (New-Object Windows.Interop.WindowInteropHelper $win).Handle
        if ($h -ne [IntPtr]::Zero) { [DwmDark]::ApplyLight($h, (Get-CaptionColorRef $script:UiTheme.BgWindow), (Get-CaptionColorRef $script:UiTheme.TextMain)) }
    } catch { }

    # 窗口图标
    try {
        $ico = Get-AppIcon
        if ($ico) { $win.Icon = $ico }
    } catch { }

    Show-Page $Page
    Update-SearchHeight
    $win.Add_SizeChanged({ Update-SearchHeight })

    # 异步加载数据：窗口先显示出来，数据到位后再填充
    if ($Shot) {
        # 截图模式要等数据到位，改同步采集
        try { Apply-Data ((Get-SyncDataJson)) } catch { Show-Status "初始化失败：$($_.Exception.Message)" 'err' }
    } else {
        Start-DataLoad
    }

    if ($Shot) {
        $win.Left = 30; $win.Top = 20
        $t = New-Object Windows.Threading.DispatcherTimer
        $t.Interval = [TimeSpan]::FromMilliseconds(1500)
        $t.Add_Tick({
            $t.Stop()
            $ok = Save-Shot $Shot
            Write-Host "SHOT_OK=$ok PATH=$Shot"
            $win.Close()
        }.GetNewClosure())
        $t.Start()
    } else {
        Start-UpdateCheck
    }
})

if ($Shot) {
    $win.WindowStartupLocation = 'Manual'
} else {
    $win.WindowStartupLocation = 'CenterScreen'
}
# 截图模式下由 Loaded 里的定时器渲染完 PNG 后调用 $win.Close() 结束 ShowDialog
[void]$win.ShowDialog()
