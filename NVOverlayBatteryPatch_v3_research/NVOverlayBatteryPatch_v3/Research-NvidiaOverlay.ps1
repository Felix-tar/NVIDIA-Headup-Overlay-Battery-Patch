param(
    [string]$OutputDirectory = "",
    [switch]$NoFullFrontend
)

$ErrorActionPreference = "Stop"
$ResearchVersion = "1.0.0"
$NvidiaRoot = Join-Path $env:ProgramFiles "NVIDIA Corporation\NVIDIA App"
$OscDir = Join-Path $NvidiaRoot "osc"
$OverlayExe = Join-Path $NvidiaRoot "CEF\NVIDIA Overlay.exe"
$InstalledPatchDir = Join-Path $env:ProgramData "NVOverlayBatteryPatch"
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

function Sanitize-Text([string]$Text) {
    if ($null -eq $Text) { return $Text }
    $result = $Text
    if ($env:USERPROFILE) {
        $result = $result.Replace($env:USERPROFILE, "%USERPROFILE%")
    }
    if ($env:USERNAME) {
        $result = $result.Replace($env:USERNAME, "%USERNAME%")
    }
    if ($env:COMPUTERNAME) {
        $result = $result.Replace($env:COMPUTERNAME, "%COMPUTERNAME%")
    }
    return $result
}

function Get-Sha256([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Get-ActiveMainFile {
    $index = Join-Path $OscDir "index.html"
    if (Test-Path -LiteralPath $index) {
        try {
            $html = [System.IO.File]::ReadAllText($index)
            $m = [regex]::Match($html, '(?i)(?<name>main\.[A-Za-z0-9._-]+\.js)')
            if ($m.Success) {
                $candidate = Join-Path $OscDir $m.Groups["name"].Value
                if (Test-Path -LiteralPath $candidate) {
                    return Get-Item -LiteralPath $candidate
                }
            }
        }
        catch {}
    }

    return Get-ChildItem -Path $OscDir -Filter "main.*.js" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
}

function Get-NvidiaAppVersion {
    try {
        if (Test-Path -LiteralPath $OverlayExe) {
            return [Diagnostics.FileVersionInfo]::GetVersionInfo($OverlayExe).FileVersion
        }
    }
    catch {}
    return "unknown"
}

function Add-Section([System.Text.StringBuilder]$Builder, [string]$Title, [string[]]$Lines) {
    [void]$Builder.AppendLine("")
    [void]$Builder.AppendLine("## " + $Title)
    [void]$Builder.AppendLine("")
    foreach ($line in $Lines) {
        [void]$Builder.AppendLine($line)
    }
}

if (-not (Test-Path -LiteralPath $OscDir)) {
    Write-Host "NVIDIA OSC-Ordner nicht gefunden:" -ForegroundColor Red
    Write-Host "  $OscDir"
    exit 10
}

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $downloads = Join-Path $env:USERPROFILE "Downloads"
    if (Test-Path -LiteralPath $downloads) {
        $OutputDirectory = $downloads
    }
    else {
        $OutputDirectory = $env:TEMP
    }
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$WorkDir = Join-Path $env:TEMP ("NVBO_Research_" + $Timestamp)
$ZipPath = Join-Path $OutputDirectory ("NVBO_Research_" + $Timestamp + ".zip")

Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $ZipPath -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $WorkDir "frontend") -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $WorkDir "diagnostics") -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $WorkDir "repo-context") -Force | Out-Null

$main = Get-ActiveMainFile
if (-not $main) {
    Write-Host "Keine aktive main.*.js gefunden." -ForegroundColor Red
    exit 11
}

$indexPath = Join-Path $OscDir "index.html"
$mainText = [System.IO.File]::ReadAllText($main.FullName)
$mainHash = Get-Sha256 $main.FullName
$appVersion = Get-NvidiaAppVersion
$patchMarker = "none"
if ($mainText.Contains("NVBO_PATCH_V3")) { $patchMarker = "NVBO_PATCH_V3" }
elseif ($mainText.Contains("NVBO_PATCH_V2")) { $patchMarker = "NVBO_PATCH_V2" }
elseif ($mainText.Contains("NVBO_PATCH_V1")) { $patchMarker = "NVBO_PATCH_V1" }

# -----------------------------------------------------------------------------
# Frontend files. The full active main bundle is useful for private AI research,
# but can be omitted with -NoFullFrontend. We intentionally do not copy DLLs,
# PAKs, binaries, browser cache, screenshots, credentials, or user documents.
# -----------------------------------------------------------------------------
if (Test-Path -LiteralPath $indexPath) {
    Copy-Item -LiteralPath $indexPath -Destination (Join-Path $WorkDir "frontend\index.html") -Force
}

if (-not $NoFullFrontend) {
    Copy-Item -LiteralPath $main.FullName -Destination (Join-Path $WorkDir ("frontend\" + $main.Name)) -Force

    Get-ChildItem -Path $OscDir -Filter "styles.*.css" -File -ErrorAction SilentlyContinue |
        Select-Object -First 2 |
        ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $WorkDir ("frontend\" + $_.Name)) -Force }

    Get-ChildItem -Path $OscDir -Filter "runtime.*.js" -File -ErrorAction SilentlyContinue |
        Select-Object -First 2 |
        ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $WorkDir ("frontend\" + $_.Name)) -Force }

    $legacySidecar = $main.FullName + ".nvbo-original"
    if (Test-Path -LiteralPath $legacySidecar) {
        Copy-Item -LiteralPath $legacySidecar -Destination (Join-Path $WorkDir ("frontend\" + $main.Name + ".legacy-clean-original")) -Force
    }
}

# NVIDIA overlay text configuration only; no DLLs or .pak resources.
$nvidiaOverlayJson = Join-Path $NvidiaRoot "CEF\Resources\NVIDIA Overlay.json"
if (Test-Path -LiteralPath $nvidiaOverlayJson) {
    Copy-Item -LiteralPath $nvidiaOverlayJson -Destination (Join-Path $WorkDir "diagnostics\NVIDIA Overlay.json") -Force
}

# Current repo/installed patch source is useful to an AI adapting the profile.
$contextCandidates = @(
    @{ Source = (Join-Path $PSScriptRoot "Patch-NvidiaOverlay.ps1"); Name = "Patch-NvidiaOverlay.ps1" },
    @{ Source = (Join-Path $PSScriptRoot "NvBatteryProvider.cs"); Name = "NvBatteryProvider.cs" },
    @{ Source = (Join-Path $PSScriptRoot "README.md"); Name = "README.md" }
)
foreach ($c in $contextCandidates) {
    if (Test-Path -LiteralPath $c.Source) {
        Copy-Item -LiteralPath $c.Source -Destination (Join-Path $WorkDir ("repo-context\" + $c.Name)) -Force
    }
}

if (Test-Path -LiteralPath (Join-Path $InstalledPatchDir "state.json")) {
    Copy-Item -LiteralPath (Join-Path $InstalledPatchDir "state.json") -Destination (Join-Path $WorkDir "diagnostics\installed-state.json") -Force
}
if (Test-Path -LiteralPath (Join-Path $InstalledPatchDir "patch.log")) {
    Get-Content -LiteralPath (Join-Path $InstalledPatchDir "patch.log") -Tail 250 -ErrorAction SilentlyContinue |
        ForEach-Object { Sanitize-Text $_ } |
        Set-Content -LiteralPath (Join-Path $WorkDir "diagnostics\patch-log-tail.txt") -Encoding UTF8
}

# -----------------------------------------------------------------------------
# Inventory and machine diagnostics
# -----------------------------------------------------------------------------
$inventory = Get-ChildItem -Path $OscDir -File -ErrorAction SilentlyContinue |
    Select-Object Name, Length, LastWriteTime, @{Name="SHA256";Expression={ Get-Sha256 $_.FullName }} |
    Sort-Object Name
$inventory | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $WorkDir "diagnostics\osc-inventory.json") -Encoding UTF8

$os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
$computer = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
$video = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Select-Object Name, DriverVersion, VideoProcessor, AdapterRAM)

$processes = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -eq "NVIDIA Overlay.exe" } |
    Select-Object ProcessId, @{Name="CommandLine";Expression={ Sanitize-Text $_.CommandLine }})
$processes | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $WorkDir "diagnostics\overlay-processes.json") -Encoding UTF8

$nvidiaSmi = @()
try {
    $smi = Get-Command nvidia-smi.exe -ErrorAction Stop
    $nvidiaSmi = @(& $smi.Source --query-gpu=name,driver_version,pstate,temperature.gpu,utilization.gpu --format=csv,noheader 2>&1)
}
catch {
    $nvidiaSmi = @("nvidia-smi unavailable: " + $_.Exception.Message)
}
$nvidiaSmi | Set-Content -LiteralPath (Join-Path $WorkDir "diagnostics\nvidia-smi.txt") -Encoding UTF8

$providerText = "Provider unavailable"
try {
    $provider = Invoke-RestMethod -Uri "http://127.0.0.1:37921/status" -UseBasicParsing -TimeoutSec 2
    $providerText = ($provider | ConvertTo-Json -Depth 8)
}
catch {
    $providerText = "Provider unavailable: " + $_.Exception.Message
}
$providerText | Set-Content -LiteralPath (Join-Path $WorkDir "diagnostics\provider-status.txt") -Encoding UTF8

# -----------------------------------------------------------------------------
# Current compatibility anchors + fuzzy semantic search terms.
# The exact patch source is also included in repo-context so an AI can inspect
# the complete current profile rather than relying only on this report.
# -----------------------------------------------------------------------------
$anchorPatterns = [ordered]@{
    "A1 CPU-clock metric definition" = '{metricId:"cpuClock",name:"perfmon.cpuClock"'
    "A2 PerfMon metric loop" = 'Ce.forEach(Me=>{let X;if(Be&&Me.category===I.TE.GPU)'
    "A3 initStatsAndLoadData bridge point" = 'this.initStatsAndLoadData(),this.clearDlssMetricValues()}isDlssSupported'
    "A4 loadCustomMetricSet" = 'loadCustomMetricSet(){this.perfData[0]&&'
    "A5 performance quadrant subscription" = 'setPerfOverlayQuadrant(this.overlaySettings[a.Performance])'
    "A6 metric category ordering" = 'Object.values(r.TEj).filter($n=>!isNaN(Number($n)))'
}

$anchorLines = New-Object System.Collections.Generic.List[string]
foreach ($name in $anchorPatterns.Keys) {
    $pattern = [string]$anchorPatterns[$name]
    $count = ([regex]::Matches($mainText, [regex]::Escape($pattern))).Count
    $anchorLines.Add(("{0}: {1}" -f $name, $count))
}
$anchorLines | Set-Content -LiteralPath (Join-Path $WorkDir "diagnostics\anchor-counts.txt") -Encoding UTF8

$keywords = @(
    "cpuClock",
    "cpuTemp",
    "cpuUtil",
    "gpuTemp",
    "gpuUtil",
    "loadCustomMetricSet",
    "customMetrics",
    "activeMetricSetId",
    "perfOverlayAbsolutePosition",
    "setPerfOverlayQuadrant",
    "centerTop",
    "RegisterPerfStatsNotifications",
    "updatePerfStats",
    "fillPerfMetrics",
    "initStatsAndLoadData",
    "clearDlssMetricValues",
    "Performance",
    "perfmon.cpuClock"
)

$snippetBuilder = New-Object System.Text.StringBuilder
foreach ($keyword in $keywords) {
    $matches = [regex]::Matches($mainText, [regex]::Escape($keyword))
    [void]$snippetBuilder.AppendLine("================================================================================")
    [void]$snippetBuilder.AppendLine("KEYWORD: $keyword    MATCHES: $($matches.Count)")
    [void]$snippetBuilder.AppendLine("================================================================================")

    $max = [Math]::Min($matches.Count, 3)
    for ($i = 0; $i -lt $max; $i++) {
        $m = $matches[$i]
        $before = 1400
        $after = 1800
        $start = [Math]::Max(0, $m.Index - $before)
        $end = [Math]::Min($mainText.Length, $m.Index + $m.Length + $after)
        $length = $end - $start
        $chunk = $mainText.Substring($start, $length)
        [void]$snippetBuilder.AppendLine("")
        [void]$snippetBuilder.AppendLine(("--- match {0}/{1}, source offset {2} ---" -f ($i + 1), $matches.Count, $m.Index))
        [void]$snippetBuilder.AppendLine($chunk)
        [void]$snippetBuilder.AppendLine("")
    }
}
$snippetBuilder.ToString() | Set-Content -LiteralPath (Join-Path $WorkDir "diagnostics\frontend-snippets.txt") -Encoding UTF8

# -----------------------------------------------------------------------------
# Human-readable report
# -----------------------------------------------------------------------------
$report = New-Object System.Text.StringBuilder
[void]$report.AppendLine("# NVOverlay Battery Patch - Research Report")
[void]$report.AppendLine("")
[void]$report.AppendLine("Generated by Research-NvidiaOverlay.ps1 v$ResearchVersion on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz').")
[void]$report.AppendLine("")
[void]$report.AppendLine("> This collector is read-only. It does not patch, stop, restart, or modify NVIDIA software.")

$systemLines = @(
    "- Manufacturer: ``$($computer.Manufacturer)``",
    "- Model: ``$($computer.Model)``",
    "- Windows: ``$($os.Caption)``",
    "- Windows build: ``$($os.BuildNumber)``",
    "- NVIDIA App/Overlay file version: ``$appVersion``"
)
Add-Section $report "System" $systemLines

$gpuLines = New-Object System.Collections.Generic.List[string]
if ($video.Count -eq 0) {
    $gpuLines.Add("- No Win32_VideoController entries returned.")
}
else {
    foreach ($g in $video) {
        $gpuLines.Add(("- ``{0}`` — driver ``{1}`` — processor ``{2}``" -f $g.Name, $g.DriverVersion, $g.VideoProcessor))
    }
}
Add-Section $report "Graphics adapters" $gpuLines.ToArray()

$frontendLines = @(
    "- OSC directory: ``$(Sanitize-Text $OscDir)``",
    "- Active bundle: ``$($main.Name)``",
    "- Active bundle SHA-256: ``$mainHash``",
    "- Active bundle size: ``$($main.Length)`` bytes",
    "- Existing NVBO marker: ``$patchMarker``",
    "- Full frontend included in this package: ``$(-not $NoFullFrontend)``"
)
Add-Section $report "NVIDIA OSC frontend" $frontendLines

Add-Section $report "Current v3 anchor counts" $anchorLines.ToArray()

[void]$report.AppendLine("")
[void]$report.AppendLine("## What an AI/developer should inspect")
[void]$report.AppendLine("")
[void]$report.AppendLine("1. Read ``AI_PROMPT.md`` first.")
[void]$report.AppendLine("2. Compare ``repo-context/Patch-NvidiaOverlay.ps1`` with the active NVIDIA bundle.")
[void]$report.AppendLine("3. Use ``diagnostics/frontend-snippets.txt`` to locate equivalent semantic code paths quickly.")
if (-not $NoFullFrontend) {
    [void]$report.AppendLine("4. Use the full ``frontend/$($main.Name)`` only for private compatibility analysis.")
}
[void]$report.AppendLine("5. Do not make the patch fuzzy just to force compatibility. Create a new explicit profile/anchors for the new NVIDIA layout.")

$report.ToString() | Set-Content -LiteralPath (Join-Path $WorkDir "REPORT.md") -Encoding UTF8

# -----------------------------------------------------------------------------
# AI handoff prompt
# -----------------------------------------------------------------------------
$aiPrompt = @"
# AI compatibility-research prompt for NVOverlayBatteryPatch

You are adapting the open-source NVOverlayBatteryPatch v3 compatibility profile to the NVIDIA App build captured in this research package.

Start by reading:

1. `REPORT.md`
2. `diagnostics/anchor-counts.txt`
3. `diagnostics/frontend-snippets.txt`
4. `repo-context/Patch-NvidiaOverlay.ps1`
5. `repo-context/NvBatteryProvider.cs`
6. the captured `frontend/main.*.js` if present

## Goal

Update the repository so this NVIDIA App build can safely display the same laptop HUD:

`CPU utilization + CPU temperature | BAT percentage / charge-discharge watts / estimated time | GPU utilization + GPU temperature`

The Surface Laptop Studio 2 GPU-temperature fallback must remain intact: use the local provider's NVML value first, `nvidia-smi` fallback second, and show `OFF` instead of a fake `0C` when the dGPU exposes no valid temperature.

## Preserve these safety properties

- Do NOT patch NVIDIA DLLs or executable binaries unless there is no viable frontend solution and the user explicitly chooses a separate research path.
- Do NOT bypass anti-cheat, DRM, signature checks, or other security mechanisms.
- Unknown NVIDIA layouts must remain `unsupported` rather than being patched with fuzzy/broad replacements.
- Every structural anchor used by a compatibility profile must be semantically understood and uniquely matched.
- Keep SHA-256-versioned clean backups.
- Keep temporary-output validation, atomic replacement, runtime smoke test, and rollback.
- Keep the provider bound to localhost only.
- Do not overwrite a newer NVIDIA build with an older backup.

## Compatibility work to perform

Map the new NVIDIA frontend to the six semantic operations currently implemented by the v3 profile:

1. repurpose the `cpuClock` display slot as `BAT`
2. inject BAT text and provider GPU-temperature fallback into the PerfMon metric-update path
3. start the localhost telemetry polling bridge exactly once
4. select the custom metric set: `cpuUtil`, `cpuTemp`, `gpuUtil`, `gpuTemp`, `cpuClock`
5. force the performance overlay to top-center / centerTop
6. preserve a stable metric-category order

For each operation, identify the equivalent code in the captured NVIDIA build. Prefer stable semantic anchors over large fragile minified strings, but still require unambiguous validation.

Then:

- add a new explicit compatibility profile (or safely update the profile system to support multiple profiles)
- add this clean bundle SHA-256 to `TestedSha256` only after the mapping has been verified
- keep old profiles so previously supported NVIDIA versions continue to work
- update README compatibility notes
- explain exactly which anchors changed and why
- provide a diff or complete updated repository files

Do not solve an anchor failure merely by changing `count -eq 1` to a looser condition. The purpose of the research package is to understand the new NVIDIA structure, not disable the safeguards.
"@
$aiPrompt | Set-Content -LiteralPath (Join-Path $WorkDir "AI_PROMPT.md") -Encoding UTF8

# A compact machine-readable manifest for tools/AI.
$manifest = [ordered]@{
    researchVersion = $ResearchVersion
    generatedAt = (Get-Date).ToString("o")
    manufacturer = $computer.Manufacturer
    model = $computer.Model
    windowsCaption = $os.Caption
    windowsBuild = $os.BuildNumber
    nvidiaAppVersion = $appVersion
    activeBundle = $main.Name
    activeBundleSha256 = $mainHash
    activeBundleLength = $main.Length
    patchMarker = $patchMarker
    fullFrontendIncluded = (-not $NoFullFrontend)
    gpu = $video
    anchorCounts = $anchorLines.ToArray()
}
$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $WorkDir "manifest.json") -Encoding UTF8

# Explain the privacy/copyright handling inside the package itself.
$packageNote = @"
NVOverlayBatteryPatch Research Package
======================================

This ZIP was generated locally from the installed NVIDIA App for compatibility research.

It is intended to be shared PRIVATELY with a developer or an AI assistant when adapting the open-source patch to a new NVIDIA frontend build.

Do not commit this generated ZIP or the captured NVIDIA frontend files to the public GitHub repository. The frontend files originate from the local NVIDIA installation and are included only to diagnose compatibility on this machine.

The collector intentionally does NOT include NVIDIA DLLs, EXEs, PAK files, browser cache, credentials, screenshots, personal documents, or network secrets.

Reports sanitize the current Windows username/profile path where practical. The captured NVIDIA frontend itself is copied as-is when full research mode is enabled.

For a smaller package without the full main JavaScript bundle, run:

  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Research-NvidiaOverlay.ps1 -NoFullFrontend
"@
$packageNote | Set-Content -LiteralPath (Join-Path $WorkDir "PRIVATE_RESEARCH_NOTICE.txt") -Encoding UTF8

Compress-Archive -Path (Join-Path $WorkDir "*") -DestinationPath $ZipPath -Force

Write-Host ""
Write-Host "RECHERCHE-PAKET FERTIG" -ForegroundColor Green
Write-Host ""
Write-Host "Datei:"
Write-Host "  $ZipPath"
Write-Host ""
Write-Host "Enthaelt:"
Write-Host "  - NVIDIA App / Windows / GPU Versionsdaten"
Write-Host "  - aktive OSC main.*.js + SHA-256"
Write-Host "  - aktuelle Anchor-Treffer"
Write-Host "  - relevante Code-Snippets"
Write-Host "  - Provider-/nvidia-smi-Diagnose"
Write-Host "  - aktuellen Patch-Quellcode als KI-Kontext"
Write-Host "  - AI_PROMPT.md mit Anpassungsanweisung"
Write-Host ""
Write-Host "WICHTIG: Das ZIP fuer Diagnose privat mit KI/Entwickler teilen,"
Write-Host "nicht die enthaltenen NVIDIA-Frontend-Dateien ins oeffentliche Repo committen."
Write-Host ""

try {
    Start-Process explorer.exe -ArgumentList ('/select,"{0}"' -f $ZipPath)
}
catch {}

Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
