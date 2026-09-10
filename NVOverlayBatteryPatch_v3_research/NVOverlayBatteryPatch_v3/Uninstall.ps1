$ErrorActionPreference = "Stop"

function Is-Administrator {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Is-Administrator)) {
    $args = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", ('"{0}"' -f $PSCommandPath)
    )
    Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList $args
    exit
}

$InstallDir = Join-Path $env:ProgramData "NVOverlayBatteryPatch"
$BackupsDir = Join-Path $InstallDir "backups"
$StateFile = Join-Path $InstallDir "state.json"
$NvidiaRoot = Join-Path $env:ProgramFiles "NVIDIA Corporation\NVIDIA App"
$OscDir = Join-Path $NvidiaRoot "osc"
$OverlayExe = Join-Path $NvidiaRoot "CEF\NVIDIA Overlay.exe"
$PatchMarker = "NVBO_PATCH_V3"

Write-Host "NVOverlay Battery Patch v3 wird entfernt..."

Get-Process -Name "NvBatteryProvider" -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue

Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" `
    -Name "NVOverlayBatteryProvider" -ErrorAction SilentlyContinue

Unregister-ScheduledTask -TaskName "NVOverlayBatteryPatch" `
    -Confirm:$false -ErrorAction SilentlyContinue

$restored = $false

# Only restore a file if the CURRENT active file still contains our v3 marker.
# If NVIDIA has already updated to a clean newer build, leave that newer build untouched.
if (Test-Path $StateFile) {
    try {
        $state = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
        $target = [string]$state.target
        $sourceHash = [string]$state.sourceSha256
        $targetFileName = [string]$state.targetFileName

        if ($target -and (Test-Path $target)) {
            $current = [System.IO.File]::ReadAllText($target)
            if ($current.Contains($PatchMarker) -and $sourceHash) {
                $backup = Join-Path (Join-Path $BackupsDir $sourceHash) $targetFileName
                if (Test-Path $backup) {
                    $bytes = [System.IO.File]::ReadAllBytes($backup)
                    [System.IO.File]::WriteAllBytes($target, $bytes)
                    $restored = $true
                    Write-Host ("Sauberes NVIDIA-Original wiederhergestellt: " + $target)
                }
                else {
                    Write-Warning ("Passendes SHA-256-Backup fehlt: " + $backup)
                }
            }
        }
    }
    catch {
        Write-Warning ("state.json konnte nicht ausgewertet werden: " + $_.Exception.Message)
    }
}

# Compatibility cleanup for upgrades from v1/v2: if a current file still carries
# an old marker and the old sidecar exists, restore it too.
if (Test-Path $OscDir) {
    Get-ChildItem -Path $OscDir -Filter "main.*.js" -File -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $txt = [System.IO.File]::ReadAllText($_.FullName)
            if (($txt.Contains("NVBO_PATCH_V2") -or $txt.Contains("NVBO_PATCH_V1")) -and
                (Test-Path ($_.FullName + ".nvbo-original"))) {
                $bytes = [System.IO.File]::ReadAllBytes($_.FullName + ".nvbo-original")
                [System.IO.File]::WriteAllBytes($_.FullName, $bytes)
                $restored = $true
                Write-Host ("Altes Patch-Original wiederhergestellt: " + $_.FullName)
            }
        }
        catch {}
    }
}

if ($restored) {
    Get-Process -Name "NVIDIA Overlay" -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    if (Test-Path $OverlayExe) {
        Start-Process -FilePath $OverlayExe
    }
}

Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "Entfernung abgeschlossen."
if (-not $restored) {
    Write-Host "Keine aktuell gepatchte NVIDIA-Datei musste zurueckgesetzt werden."
    Write-Host "Eine bereits von NVIDIA ersetzte neuere Version wurde bewusst nicht angefasst."
}
Write-Host ""
Read-Host "Enter druecken zum Schliessen"
