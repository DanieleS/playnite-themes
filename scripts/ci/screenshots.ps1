# Takes screenshots of every theme in a real Playnite fullscreen session.
#
# Builds a portable Playnite install with a sample library (real Steam artwork, playtime, descriptions),
# Extra Metadata Loader with logos, then for each theme starts Playnite.FullscreenApp, drives it with the
# keyboard and captures: library, library after a few moves, game details, main menu.
#
# Must run in 32-bit Windows PowerShell 5.1 (Playnite is a 32-bit .NET Framework app):
#   %SystemRoot%\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -File scripts/ci/screenshots.ps1 `
#       -PlayniteDir playnite -ThemesDir themes -OutDir screenshots [-EmlPext eml.pext] [-Language it_IT]

param(
    [Parameter(Mandatory = $true)][string]$PlayniteDir,
    [Parameter(Mandatory = $true)][string]$ThemesDir,
    [Parameter(Mandatory = $true)][string]$OutDir,
    [string]$EmlPext = "",
    [string]$Language = "en_US",
    [int]$StartupSeconds = 25
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$found = Get-ChildItem -Path $PlayniteDir -Recurse -Filter Playnite.FullscreenApp.exe | Select-Object -First 1
if (-not $found) { throw "Playnite.FullscreenApp.exe not found under $PlayniteDir" }
$PlayniteDir = $found.DirectoryName
$ThemesDir = (Resolve-Path $ThemesDir).Path
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$OutDir = (Resolve-Path $OutDir).Path
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class Win32 {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
"@
[void][Win32]::SetProcessDPIAware()

# --- Display: 1920x1080, the themes' reference size (runners start at 1024x768) --------------------------
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class Display {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
    public struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
        public int dmFields, dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
        public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public short dmLogPixels;
        public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
        public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
    }
    [DllImport("user32.dll")] static extern int EnumDisplaySettings(string deviceName, int modeNum, ref DEVMODE devMode);
    [DllImport("user32.dll")] static extern int ChangeDisplaySettings(ref DEVMODE devMode, int flags);
    public static int Set(int width, int height) {
        var mode = new DEVMODE();
        mode.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
        EnumDisplaySettings(null, -1, ref mode);
        mode.dmPelsWidth = width;
        mode.dmPelsHeight = height;
        mode.dmFields = 0x80000 | 0x100000;
        return ChangeDisplaySettings(ref mode, 0);
    }
}
"@
$result = [Display]::Set(1920, 1080)
Write-Host "ChangeDisplaySettings -> $result"
Start-Sleep -Seconds 3
$bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
Write-Host "Screen: $($bounds.Width)x$($bounds.Height)"

# --- Sample library ---------------------------------------------------------------------------------------
$resolver = [System.ResolveEventHandler] {
    param($sender, $e)
    $name = (New-Object System.Reflection.AssemblyName($e.Name)).Name
    foreach ($ext in '.dll', '.exe') {
        $candidate = Join-Path $PlayniteDir ($name + $ext)
        if (Test-Path $candidate) { return [System.Reflection.Assembly]::LoadFrom($candidate) }
    }
    return $null
}
[System.AppDomain]::CurrentDomain.add_AssemblyResolve($resolver)
foreach ($asm in 'Playnite.SDK.dll', 'Playnite.dll') {
    [void][System.Reflection.Assembly]::LoadFrom((Join-Path $PlayniteDir $asm))
}

$games = Get-Content -Raw -Path (Join-Path $scriptDir 'sample-library.json') | ConvertFrom-Json
$artDir = Join-Path $env:TEMP 'playnite-art'
New-Item -ItemType Directory -Force -Path $artDir | Out-Null
$cdn = 'https://shared.akamai.steamstatic.com/store_item_assets/steam/apps'
function Get-Art([int]$appId, [string]$file) {
    $target = Join-Path $artDir "$appId-$file"
    if (-not (Test-Path $target)) {
        try { Invoke-WebRequest -UseBasicParsing -Uri "$cdn/$appId/$file" -OutFile $target }
        catch { Write-Host "  no $file for $appId"; return $null }
    }
    return $target
}

$libraryDir = Join-Path $PlayniteDir 'library'
if (Test-Path $libraryDir) { Remove-Item -Recurse -Force $libraryDir }
$db = New-Object Playnite.Database.GameDatabase($libraryDir)
$db.OpenDatabase()

$none = [System.Threading.CancellationToken]::None
$steam = $db.Sources.Add('Steam')
$pc = $db.Platforms | Where-Object { $_.Name -like 'PC (Windows)' } | Select-Object -First 1
$statusByName = @{}
foreach ($status in $db.CompletionStatuses) { $statusByName[($status.Name -replace '\s', '').ToLower()] = $status }
$now = Get-Date
$logos = @{}

foreach ($item in $games) {
    $game = New-Object Playnite.SDK.Models.Game($item.name)
    $game.SourceId = $steam.Id
    if ($pc) { $game.PlatformIds = New-Object 'System.Collections.Generic.List[Guid]'; $game.PlatformIds.Add($pc.Id) }
    $game.ReleaseDate = New-Object Playnite.SDK.Models.ReleaseDate([int]$item.year)
    $game.Playtime = [uint64]([double]$item.hours * 3600)
    $game.PlayCount = [uint64]$item.sessions
    $game.IsInstalled = [bool]$item.installed
    $game.Description = $item.description
    $game.Added = $now.AddDays(-400)
    if ([int]$item.lastPlayedDaysAgo -ge 0) { $game.LastActivity = $now.AddDays(-[int]$item.lastPlayedDaysAgo).AddHours(-2) }
    $game.GenreIds = New-Object 'System.Collections.Generic.List[Guid]'
    foreach ($genre in $item.genres) { $game.GenreIds.Add($db.Genres.Add($genre).Id) }
    $game.DeveloperIds = New-Object 'System.Collections.Generic.List[Guid]'
    $game.DeveloperIds.Add($db.Companies.Add($item.developer).Id)
    $statusKey = ($item.completion -replace '\s', '').ToLower()
    if ($statusByName.ContainsKey($statusKey)) { $game.CompletionStatusId = $statusByName[$statusKey].Id }
    $db.Games.Add($game)

    $cover = Get-Art $item.steam 'library_600x900.jpg'
    $hero = Get-Art $item.steam 'library_hero.jpg'
    if ($cover) { $game.CoverImage = $db.AddFile($cover, $game.Id, $true, $none) }
    if ($hero) { $game.BackgroundImage = $db.AddFile($hero, $game.Id, $true, $none) }
    $db.Games.Update($game)

    $logo = Get-Art $item.steam 'logo.png'
    if ($logo) { $logos[$game.Id.ToString()] = $logo }
    Write-Host "  + $($item.name)"
}
$db.Dispose()

# --- Extra Metadata Loader + logos ------------------------------------------------------------------------
if ($EmlPext -and (Test-Path $EmlPext)) {
    $emlDir = Join-Path $PlayniteDir 'Extensions\ExtraMetadataLoader'
    New-Item -ItemType Directory -Force -Path $emlDir | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory((Resolve-Path $EmlPext).Path, $emlDir)
    foreach ($id in $logos.Keys) {
        $dir = Join-Path $PlayniteDir "ExtraMetadata\games\$id"
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Copy-Item $logos[$id] (Join-Path $dir 'Logo.png')
    }
    Write-Host "Extra Metadata Loader installed, $($logos.Count) logos"
}

# --- Playnite configuration -------------------------------------------------------------------------------
$config = @{
    FirstTimeWizardComplete = $true
    ShowElevatedRightsWarning = $false
    DatabasePath            = $libraryDir
    Language                = $Language
    UpdateLevel             = 0
    StartInFullscreen       = $true
}
$config | ConvertTo-Json | Set-Content -Encoding UTF8 (Join-Path $PlayniteDir 'config.json')

function Save-Screen([string]$name) {
    $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bmp = New-Object System.Drawing.Bitmap($b.Width, $b.Height)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
    $path = Join-Path $OutDir "$name.png"
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
    Write-Host "  shot $name.png"
}

function Send([string]$keys, [int]$waitMs = 1200) {
    [System.Windows.Forms.SendKeys]::SendWait($keys)
    Start-Sleep -Milliseconds $waitMs
}

# --- One session per theme --------------------------------------------------------------------------------
$fullscreenThemes = Join-Path $PlayniteDir 'Themes\Fullscreen'
New-Item -ItemType Directory -Force -Path $fullscreenThemes | Out-Null

foreach ($theme in Get-ChildItem -Path $ThemesDir -Directory | Sort-Object Name) {
    $manifest = Get-Content (Join-Path $theme.FullName 'theme.yaml') | Where-Object { $_ -match '^Id:' }
    $themeId = ($manifest -replace '^Id:\s*', '').Trim()
    Write-Host "Theme $($theme.Name) ($themeId)"

    $target = Join-Path $fullscreenThemes $theme.Name
    if (Test-Path $target) { Remove-Item -Recurse -Force $target }
    Copy-Item -Recurse $theme.FullName $target

    @{ Theme = $themeId; IsMusicMuted = $true; EnableMainBackgroundImage = $false } |
        ConvertTo-Json | Set-Content -Encoding UTF8 (Join-Path $PlayniteDir 'fullscreenConfig.json')

    $proc = Start-Process -FilePath (Join-Path $PlayniteDir 'Playnite.FullscreenApp.exe') -PassThru
    Start-Sleep -Seconds $StartupSeconds
    $proc.Refresh()
    if ($proc.MainWindowHandle -ne [IntPtr]::Zero) {
        [void][Win32]::ShowWindow($proc.MainWindowHandle, 3)
        [void][Win32]::SetForegroundWindow($proc.MainWindowHandle)
    }
    Start-Sleep -Seconds 2

    Save-Screen "$($theme.Name)-1-library"
    Send '{RIGHT}'; Send '{RIGHT}'; Send '{RIGHT}' 2500
    Save-Screen "$($theme.Name)-2-library-moved"
    Send 'a' 3000
    Save-Screen "$($theme.Name)-3-details"
    Send '{BACKSPACE}' 800; Send '{ESC}' 1500
    Send '{F1}' 2000
    Save-Screen "$($theme.Name)-4-menu"
    Send '{ESC}' 800

    if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force }
    Start-Sleep -Seconds 3
}

$log = Join-Path $PlayniteDir 'playnite.log'
if (Test-Path $log) { Copy-Item $log (Join-Path $OutDir 'playnite.log') }
Write-Host "Done: $((Get-ChildItem $OutDir -Filter *.png).Count) screenshots"
