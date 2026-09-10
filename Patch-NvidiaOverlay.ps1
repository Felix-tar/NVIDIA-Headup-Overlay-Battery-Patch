param(
    [switch]$Auto
)

$ErrorActionPreference = "Stop"

$PatchVersion = "3.0.0"
$PatchMarker = "NVBO_PATCH_V3"
$InstallDir = Join-Path $env:ProgramData "NVOverlayBatteryPatch"
$BackupsDir = Join-Path $InstallDir "backups"
$LogFile = Join-Path $InstallDir "patch.log"
$StateFile = Join-Path $InstallDir "state.json"
$NvidiaRoot = Join-Path $env:ProgramFiles "NVIDIA Corporation\NVIDIA App"
$OscDir = Join-Path $NvidiaRoot "osc"
$OverlayExe = Join-Path $NvidiaRoot "CEF\NVIDIA Overlay.exe"

New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
New-Item -ItemType Directory -Path $BackupsDir -Force | Out-Null

function Write-Log([string]$Message) {
    $line = ("{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $Message)
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
    if (-not $Auto) { Write-Host $line }
}

function Save-State([string]$Status, [hashtable]$Extra = @{}) {
    try {
        $state = [ordered]@{
            patchVersion = $PatchVersion
            status = $Status
            timestamp = (Get-Date).ToString("o")
        }
        foreach ($key in $Extra.Keys) {
            $state[$key] = $Extra[$key]
        }
        $json = $state | ConvertTo-Json -Depth 8
        Set-Content -LiteralPath $StateFile -Value $json -Encoding UTF8
    }
    catch {
        Write-Log ("WARNUNG: state.json konnte nicht geschrieben werden: " + $_.Exception.Message)
    }
}

function Fail([string]$Message, [int]$Code = 20, [hashtable]$State = @{}) {
    Write-Log ("FEHLER: " + $Message)
    if ($State.Count -gt 0) {
        if (-not $State.ContainsKey("reason")) { $State["reason"] = $Message }
        Save-State "unsupported" $State
    }
    exit $Code
}

function Get-NvidiaVersion {
    try {
        if (Test-Path $OverlayExe) {
            return [Diagnostics.FileVersionInfo]::GetVersionInfo($OverlayExe).FileVersion
        }
    }
    catch {}
    return "unknown"
}

function Get-ActiveMainFile {
    $index = Join-Path $OscDir "index.html"
    if (Test-Path $index) {
        try {
            $html = [System.IO.File]::ReadAllText($index)
            $m = [regex]::Match($html, '(?i)(?<name>main\.[A-Za-z0-9._-]+\.js)')
            if ($m.Success) {
                $candidate = Join-Path $OscDir $m.Groups["name"].Value
                if (Test-Path $candidate) {
                    return Get-Item -LiteralPath $candidate
                }
            }
        }
        catch {
            Write-Log ("WARNUNG: index.html konnte nicht ausgewertet werden: " + $_.Exception.Message)
        }
    }

    return Get-ChildItem -Path $OscDir -Filter "main.*.js" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
}

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Restore-Bytes([string]$BackupFile, [string]$TargetFile) {
    $bytes = [System.IO.File]::ReadAllBytes($BackupFile)
    [System.IO.File]::WriteAllBytes($TargetFile, $bytes)
}

function Restart-NvidiaOverlay([bool]$WasRunning) {
    if (-not $WasRunning) { return $true }

    Get-Process -Name "NVIDIA Overlay" -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    if (-not (Test-Path $OverlayExe)) {
        return $false
    }

    try {
        Start-Process -FilePath $OverlayExe
    }
    catch {
        return $false
    }

    Start-Sleep -Seconds 8
    return (@(Get-Process -Name "NVIDIA Overlay" -ErrorAction SilentlyContinue).Count -gt 0)
}

if (-not (Test-Path $OscDir)) {
    Fail "NVIDIA-App-OSC-Ordner wurde nicht gefunden: $OscDir" 10
}

$main = Get-ActiveMainFile
if (-not $main) {
    Fail "Keine aktive main.*.js im OSC-Ordner gefunden." 11
}

$nvidiaVersion = Get-NvidiaVersion
Write-Log ("NVOverlay Battery Patch v" + $PatchVersion)
Write-Log ("NVIDIA Version: " + $nvidiaVersion)
Write-Log ("Aktive OSC-Datei: " + $main.FullName)

$current = [System.IO.File]::ReadAllText($main.FullName)

if ($current.Contains($PatchMarker)) {
    Write-Log "Patch v3 ist bereits aktiv."
    # Keep the existing state.json intact because it contains the clean source SHA-256
    # required for a precise uninstall/rollback.
    exit 0
}

# If v1/v2 is installed, always rebuild from the clean sidecar saved by the old installer.
$sourcePath = $main.FullName
$upgradeFrom = $null
if ($current.Contains("NVBO_PATCH_V2") -or $current.Contains("NVBO_PATCH_V1")) {
    $upgradeFrom = if ($current.Contains("NVBO_PATCH_V2")) { "v2" } else { "v1" }
    $sidecar = $main.FullName + ".nvbo-original"
    if (-not (Test-Path $sidecar)) {
        Fail ("Patch " + $upgradeFrom + " erkannt, aber das saubere .nvbo-original fehlt. NVIDIA App bitte reparieren/neu installieren und danach v3 erneut starten.") 21 @{
            nvidiaVersion = $nvidiaVersion
            target = $main.FullName
        }
    }
    $sourcePath = $sidecar
    Write-Log ("Upgrade von " + $upgradeFrom + ": benutze sauberes NVIDIA-Original " + $sidecar)
}

$sourceHash = Get-Sha256 $sourcePath
$sourceText = [System.IO.File]::ReadAllText($sourcePath)
Write-Log ("SHA-256 des sauberen Originals: " + $sourceHash)

# ---------------------------------------------------------------------------
# Patch profiles
# A profile is only applied when EVERY anchor occurs exactly once.
# This makes minor NVIDIA updates that preserve the relevant code compatible,
# while unknown layouts are rejected without touching Program Files.
# ---------------------------------------------------------------------------

$old1 = @'
{metricId:"cpuClock",name:"perfmon.cpuClock",shortName:"perfmon.cpuClockShort",category:f.CPU,visible:!1,value:void 0,unit:"perfmon.megaHertz"}
'@.Trim()
$new1 = @'
{metricId:"cpuClock",name:"Battery",shortName:"BAT",category:f.CPU,visible:!1,value:void 0,unit:void 0,defaultValue:"N/A"}
'@.Trim()

$old2 = @'
Ce.forEach(Me=>{let X;if(Be&&Me.category===I.TE.GPU)
'@.Trim()
$new2 = @'
Ce.forEach(Me=>{if("cpuClock"===Me.metricId){Me.value=window.__NVBO_BAT_TEXT||"N/A",Me.visible=!0,Me.isUnitHidden=!0,Qe+=1;return}if("gpuTemp"===Me.metricId){if(null!=window.__NVBO_GPU_TEMP){Me.value=window.__NVBO_GPU_TEMP,Me.visible=!0,Me.isUnitHidden=!1,Qe+=1;return}if("OFF"===window.__NVBO_GPU_STATE){Me.value="OFF",Me.visible=!0,Me.isUnitHidden=!0,Qe+=1;return}}let X;if(Be&&Me.category===I.TE.GPU)
'@.Trim()

$old3 = @'
this.initStatsAndLoadData(),this.clearDlssMetricValues()}isDlssSupported
'@.Trim()
$new3 = @'
this.initStatsAndLoadData(),this.clearDlssMetricValues(),window.__NVBO_BAT_TIMER||(window.__NVBO_PATCH="NVBO_PATCH_V3",window.__NVBO_BAT_TEXT="N/A",window.__NVBO_GPU_TEMP=null,window.__NVBO_GPU_STATE="N/A",window.__NVBO_BAT_POLL=()=>fetch("http://127.0.0.1:37921/status",{cache:"no-store"}).then(Z=>Z.ok?Z.json():Promise.reject()).then(Z=>{window.__NVBO_BAT_TEXT=Z.display||"N/A";let Y=Number(Z.gpuTempC);window.__NVBO_GPU_TEMP=Number.isFinite(Y)&&Y>0?Y:null,window.__NVBO_GPU_STATE=Z.gpuState||"N/A"}).catch(()=>{window.__NVBO_BAT_TEXT="N/A",window.__NVBO_GPU_TEMP=null,window.__NVBO_GPU_STATE="N/A"}),window.__NVBO_BAT_POLL(),window.__NVBO_BAT_TIMER=setInterval(window.__NVBO_BAT_POLL,1e3))}isDlssSupported
'@.Trim()

$old4 = @'
loadCustomMetricSet(){this.perfData[0]&&
'@.Trim()
$new4 = @'
loadCustomMetricSet(){this.perfmonData.activeMetricSetId=I.Np.Custom,this.perfmonData.activeLayout=I.pw.Linear,this.perfmonData.perfOverlayAbsolutePosition={x:50,y:0},this.perfmonData.customMetrics=["cpuUtil","cpuTemp","gpuUtil","gpuTemp","cpuClock"],this.perfData[0]&&
'@.Trim()

$old5 = @'
subscribe(()=>{this.perfMonService?.setPerfOverlayQuadrant(this.overlaySettings[a.Performance]),this.triggerChange(null)})
'@.Trim()
$new5 = @'
subscribe(()=>{this.overlaySettings[a.Performance]=c.centerTop,this.perfMonService?.setPerfOverlayQuadrant(c.centerTop),this.triggerChange(null)})
'@.Trim()

$old6 = @'
Object.values(r.TEj).filter($n=>!isNaN(Number($n)))
'@.Trim()
$new6 = @'
[r.TEj.CPU,r.TEj.GPU,r.TEj.FPS,r.TEj.Latency,r.TEj.DLSSFG,r.TEj.DLSSSR,r.TEj.DLSSRR,r.TEj.DLSSSM]
'@.Trim()

$profile = [ordered]@{
    Name = "OSC-2026-09-anchor-profile-1"
    TestedSha256 = @("60D68F2040C2B92CF97A13D83F81ACCDF4ABE7D681842D9D51ADEB99C9CAFED5")
    Replacements = @(
        @{ Name = "CPU-Clock-Slot -> Battery"; Old = $old1; New = $new1 },
        @{ Name = "Battery/GPU-Temp values in PerfMon"; Old = $old2; New = $new2 },
        @{ Name = "Battery polling bridge"; Old = $old3; New = $new3 },
        @{ Name = "Custom metrics + top-center coordinate"; Old = $old4; New = $new4 },
        @{ Name = "Top-center quadrant"; Old = $old5; New = $new5 },
        @{ Name = "Stable metric category order"; Old = $old6; New = $new6 }
    )
}

$profileCompatible = $true
$anchorReport = @()
foreach ($r in $profile.Replacements) {
    $count = ([regex]::Matches($sourceText, [regex]::Escape([string]$r.Old))).Count
    $anchorReport += ($r.Name + "=" + $count)
    if ($count -ne 1) {
        $profileCompatible = $false
    }
}

if (-not $profileCompatible) {
    $reason = "Kein sicheres Patch-Profil passt. Anker: " + ($anchorReport -join "; ")
    Write-Log $reason
    Save-State "unsupported" @{
        nvidiaVersion = $nvidiaVersion
        target = $main.FullName
        targetFileName = $main.Name
        sourceSha256 = $sourceHash
        profile = $profile.Name
        reason = $reason
    }
    exit 30
}

$knownHash = ($profile.TestedSha256 -contains $sourceHash)
if ($knownHash) {
    Write-Log ("Profil " + $profile.Name + " passt; SHA-256 ist explizit getestet.")
}
else {
    Write-Log ("Profil " + $profile.Name + " passt ueber alle eindeutigen Anker. SHA-256 ist neu; sichere Anchor-Kompatibilitaet wird verwendet.")
}

# Versioned clean backup in ProgramData. We never restore an old NVIDIA build
# over a newer one: the backup is keyed by the clean source SHA-256.
$backupDir = Join-Path $BackupsDir $sourceHash
New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
$backupFile = Join-Path $backupDir $main.Name

if (-not (Test-Path $backupFile)) {
    Copy-Item -LiteralPath $sourcePath -Destination $backupFile -Force
    Write-Log ("Sauberes Original gesichert: " + $backupFile)
}
else {
    $existingBackupHash = Get-Sha256 $backupFile
    if ($existingBackupHash -ne $sourceHash) {
        Fail "Backup-Hash stimmt nicht mit dem Original ueberein. Sicherheitsabbruch." 33 @{
            nvidiaVersion = $nvidiaVersion
            target = $main.FullName
            sourceSha256 = $sourceHash
        }
    }
}

$meta = [ordered]@{
    patchVersion = $PatchVersion
    backupCreated = (Get-Date).ToString("o")
    nvidiaVersion = $nvidiaVersion
    targetFileName = $main.Name
    sourceSha256 = $sourceHash
    profile = $profile.Name
    explicitlyTestedHash = $knownHash
}
$meta | ConvertTo-Json -Depth 6 |
    Set-Content -LiteralPath (Join-Path $backupDir "meta.json") -Encoding UTF8

$patched = $sourceText
foreach ($r in $profile.Replacements) {
    $patched = $patched.Replace([string]$r.Old, [string]$r.New)
}

# Static validation before touching Program Files.
if (-not $patched.Contains($PatchMarker)) {
    Fail "Interne Patch-Pruefung fehlgeschlagen: Marker fehlt." 34 @{
        nvidiaVersion = $nvidiaVersion
        target = $main.FullName
        sourceSha256 = $sourceHash
    }
}

foreach ($r in $profile.Replacements) {
    if (-not $patched.Contains([string]$r.New)) {
        Fail ("Interne Patch-Pruefung fehlgeschlagen nach '" + $r.Name + "'.") 35 @{
            nvidiaVersion = $nvidiaVersion
            target = $main.FullName
            sourceSha256 = $sourceHash
        }
    }
}

$delta = [Math]::Abs($patched.Length - $sourceText.Length)
if ($delta -gt 20000) {
    Fail ("Patchgroesse ist unerwartet gross (" + $delta + " Zeichen). Sicherheitsabbruch.") 36 @{
        nvidiaVersion = $nvidiaVersion
        target = $main.FullName
        sourceSha256 = $sourceHash
    }
}

$wasRunning = @(Get-Process -Name "NVIDIA Overlay" -ErrorAction SilentlyContinue).Count -gt 0
$tmp = $main.FullName + ".nvbo-v3-new"
$replaceBackup = $main.FullName + ".nvbo-v3-replace-backup"

Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $replaceBackup -Force -ErrorAction SilentlyContinue

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($tmp, $patched, $utf8NoBom)

# Preserve the NVIDIA target ACL on the temporary file before atomic replacement.
try {
    $acl = Get-Acl -LiteralPath $main.FullName
    Set-Acl -LiteralPath $tmp -AclObject $acl
}
catch {
    Write-Log ("WARNUNG: ACL konnte nicht auf Temp-Datei kopiert werden: " + $_.Exception.Message)
}

$tmpText = [System.IO.File]::ReadAllText($tmp)
if (-not $tmpText.Contains($PatchMarker)) {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    Fail "Temp-Datei hat die Vorab-Verifikation nicht bestanden." 37 @{
        nvidiaVersion = $nvidiaVersion
        target = $main.FullName
        sourceSha256 = $sourceHash
    }
}

# Stop CEF only after all static checks passed. This reduces file-lock races
# and keeps downtime to only the final atomic replace + smoke test.
if ($wasRunning) {
    Write-Log "Stoppe NVIDIA Overlay kurz fuer den atomaren Austausch..."
    Get-Process -Name "NVIDIA Overlay" -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
}

try {
    # File.Replace is same-volume and atomic from the point of view of readers.
    [System.IO.File]::Replace($tmp, $main.FullName, $replaceBackup, $true)
}
catch {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    if ($wasRunning -and (Test-Path $OverlayExe)) {
        try { Start-Process -FilePath $OverlayExe } catch {}
    }
    Fail ("Atomarer Dateiaustausch fehlgeschlagen: " + $_.Exception.Message) 38 @{
        nvidiaVersion = $nvidiaVersion
        target = $main.FullName
        sourceSha256 = $sourceHash
    }
}

try {
    $verify = [System.IO.File]::ReadAllText($main.FullName)
    if (-not $verify.Contains($PatchMarker)) {
        throw "Patchmarker fehlt nach dem Schreiben."
    }

    $patchedHash = Get-Sha256 $main.FullName
    Write-Log ("Patch geschrieben. SHA-256 gepatcht: " + $patchedHash)
}
catch {
    try {
        Restore-Bytes $backupFile $main.FullName
    }
    catch {}
    if ($wasRunning -and (Test-Path $OverlayExe)) {
        try { Start-Process -FilePath $OverlayExe } catch {}
    }
    Fail ("Verifikation nach dem Schreiben fehlgeschlagen; Original wurde wiederhergestellt. " + $_.Exception.Message) 39 @{
        nvidiaVersion = $nvidiaVersion
        target = $main.FullName
        sourceSha256 = $sourceHash
    }
}

# Runtime smoke test only when the overlay was already running before the patch.
# If the patched CEF bundle cannot start, roll back automatically.
if ($wasRunning) {
    Write-Log "Starte NVIDIA Overlay fuer Runtime-Selbsttest neu..."
    $healthy = Restart-NvidiaOverlay $true
    if (-not $healthy) {
        Write-Log "Runtime-Selbsttest fehlgeschlagen. Fuehre automatischen Rollback aus."
        try {
            Restore-Bytes $backupFile $main.FullName
            Get-Process -Name "NVIDIA Overlay" -ErrorAction SilentlyContinue |
                Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
            if (Test-Path $OverlayExe) { Start-Process -FilePath $OverlayExe }
        }
        catch {
            Write-Log ("WARNUNG: Rollback/Restart hatte einen Fehler: " + $_.Exception.Message)
        }

        Save-State "rolled-back" @{
            nvidiaVersion = $nvidiaVersion
            target = $main.FullName
            targetFileName = $main.Name
            sourceSha256 = $sourceHash
            profile = $profile.Name
            reason = "NVIDIA Overlay blieb nach Patch-Neustart nicht aktiv."
        }
        exit 40
    }
}

Remove-Item -LiteralPath $replaceBackup -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue

Save-State "patched" @{
    nvidiaVersion = $nvidiaVersion
    target = $main.FullName
    targetFileName = $main.Name
    sourceSha256 = $sourceHash
    patchedSha256 = $patchedHash
    profile = $profile.Name
    explicitlyTestedHash = $knownHash
    upgradedFrom = $upgradeFrom
}

Write-Log "Patch v3 erfolgreich und sicher aktiv."
exit 0
