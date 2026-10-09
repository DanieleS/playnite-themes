# Loads every theme XAML file with WPF's XamlReader while Playnite's own assemblies are loaded, the same way
# Playnite does when it applies a theme (Xaml.FromFile -> XamlReader.Load). Catches unknown types, unknown
# properties, bad enum values and malformed markup before anyone opens Playnite.
#
# Runs in Windows PowerShell 5.1 (.NET Framework, STA), like Playnite itself.
#   powershell -File scripts/ci/parse-xaml.ps1 -PlayniteDir <extracted portable Playnite> -ThemesDir themes

param(
    [Parameter(Mandatory = $true)][string]$PlayniteDir,
    [Parameter(Mandatory = $true)][string]$ThemesDir
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

# The portable archive may or may not have a top-level folder.
$found = Get-ChildItem -Path $PlayniteDir -Recurse -Filter Playnite.dll | Select-Object -First 1
if (-not $found) { throw "Playnite.dll not found under $PlayniteDir" }
$PlayniteDir = $found.DirectoryName

# Resolve Playnite's dependencies from its install folder.
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

foreach ($asm in 'Playnite.SDK.dll', 'Playnite.dll', 'Playnite.FullscreenApp.exe') {
    $path = Join-Path $PlayniteDir $asm
    if (-not (Test-Path $path)) { throw "Missing $path" }
    [void][System.Reflection.Assembly]::LoadFrom($path)
}

$failures = 0
$files = Get-ChildItem -Path $ThemesDir -Recurse -Filter *.xaml | Sort-Object FullName
foreach ($file in $files) {
    $rel = $file.FullName.Substring((Resolve-Path $ThemesDir).Path.Length + 1)
    $stream = [System.IO.File]::OpenRead($file.FullName)
    try {
        [void][System.Windows.Markup.XamlReader]::Load($stream)
        Write-Host "ok   $rel"
    }
    catch {
        $failures++
        $err = $_.Exception
        while ($err.InnerException) { $err = $err.InnerException }
        Write-Host "FAIL $rel"
        Write-Host "     $($err.Message)"
    }
    finally {
        $stream.Dispose()
    }
}

Write-Host ""
Write-Host "$($files.Count) files, $failures failure(s)"
if ($failures -gt 0) { exit 1 }
