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

$SourceDir = Split-Path -Parent $PSCommandPath
$InstallDir = Join-Path $env:ProgramData "NVOverlayBatteryPatch"
$ProviderSource = Join-Path $SourceDir "NvBatteryProvider.cs"
$PatchSource = Join-Path $SourceDir "Patch-NvidiaOverlay.ps1"
$ReadmeSource = Join-Path $SourceDir "README.md"
$ResearchSource = Join-Path $SourceDir "Research-NvidiaOverlay.ps1"
$ResearchCmdSource = Join-Path $SourceDir "Research.cmd"
$ProviderExe = Join-Path $InstallDir "NvBatteryProvider.exe"
$PatchDest = Join-Path $InstallDir "Patch-NvidiaOverlay.ps1"
$ProviderSourceDest = Join-Path $InstallDir "NvBatteryProvider.cs"
$TaskName = "NVOverlayBatteryPatch"

New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $InstallDir "backups") -Force | Out-Null

Write-Host ""
Write-Host "NVOverlay Battery Patch v3"
Write-Host "=========================="
Write-Host ""

if (-not (Test-Path $ProviderSource)) { throw "NvBatteryProvider.cs fehlt." }
if (-not (Test-Path $PatchSource)) { throw "Patch-NvidiaOverlay.ps1 fehlt." }

Copy-Item -LiteralPath $PatchSource -Destination $PatchDest -Force
Copy-Item -LiteralPath $ProviderSource -Destination $ProviderSourceDest -Force
if (Test-Path $ReadmeSource) {
    Copy-Item -LiteralPath $ReadmeSource -Destination (Join-Path $InstallDir "README.md") -Force
}
if (Test-Path $ResearchSource) {
    Copy-Item -LiteralPath $ResearchSource -Destination (Join-Path $InstallDir "Research-NvidiaOverlay.ps1") -Force
}
if (Test-Path $ResearchCmdSource) {
    Copy-Item -LiteralPath $ResearchCmdSource -Destination (Join-Path $InstallDir "Research.cmd") -Force
}

Write-Host "[1/6] Battery/GPU Provider wird lokal kompiliert..."

Get-Process -Name "NvBatteryProvider" -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue

Remove-Item -LiteralPath $ProviderExe -Force -ErrorAction SilentlyContinue

Add-Type -AssemblyName Microsoft.CSharp
$compiler = New-Object Microsoft.CSharp.CSharpCodeProvider
$cp = New-Object System.CodeDom.Compiler.CompilerParameters
$cp.GenerateExecutable = $true
$cp.GenerateInMemory = $false
$cp.IncludeDebugInformation = $false
$cp.OutputAssembly = $ProviderExe
$cp.CompilerOptions = "/target:winexe /optimize+"
[void]$cp.ReferencedAssemblies.Add("System.dll")
[void]$cp.ReferencedAssemblies.Add("System.Core.dll")
[void]$cp.ReferencedAssemblies.Add("System.Management.dll")
[void]$cp.ReferencedAssemblies.Add("System.Windows.Forms.dll")

$code = [System.IO.File]::ReadAllText($ProviderSource)
$result = $compiler.CompileAssemblyFromSource($cp, $code)

if ($result.Errors.HasErrors) {
    $messages = $result.Errors | ForEach-Object { $_.ToString() }
    throw ("C#-Kompilierung fehlgeschlagen:`r`n" + ($messages -join "`r`n"))
}

Write-Host "[2/6] Autostart fuer den Provider wird eingerichtet..."
$runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
New-Item -Path $runKey -Force | Out-Null
New-ItemProperty -Path $runKey -Name "NVOverlayBatteryProvider" `
    -Value ('"{0}"' -f $ProviderExe) -PropertyType String -Force | Out-Null

Write-Host "[3/6] Erhoehte Auto-Reparatur wird eingerichtet..."
try {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

    $psExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    $arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Auto' -f $PatchDest
    $action = New-ScheduledTaskAction -Execute $psExe -Argument $arguments
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $identity
    $principal = New-ScheduledTaskPrincipal -UserId $identity -LogonType Interactive -RunLevel Highest

    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Principal $principal `
        -Description "Safely reapplies NVOverlay Battery Patch v3 after compatible NVIDIA App updates." `
        -Force | Out-Null
}
catch {
    Write-Warning "Scheduled Task konnte nicht erstellt werden. Der Patch funktioniert; nach NVIDIA-Updates ggf. Repair.cmd ausfuehren."
}

Write-Host "[4/6] NVIDIA Overlay wird sicher gepatcht..."
& $PatchDest
$patchExit = $LASTEXITCODE
if ($patchExit -ne 0) {
    Write-Host ""
    Write-Warning ("Patch wurde NICHT angewendet. Sicherheitsabbruch, ExitCode " + $patchExit + ".")
    Write-Warning "Die NVIDIA-Datei wurde bei unbekannter/inakzeptabler Struktur nicht blind veraendert."
    Write-Warning ("Details: " + (Join-Path $InstallDir "patch.log"))
    Write-Host ""
    Read-Host "Enter druecken zum Schliessen"
    exit $patchExit
}

Write-Host "[5/6] Provider wird gestartet..."
Start-Process -FilePath $ProviderExe
Start-Sleep -Seconds 3

Write-Host "[6/6] Lokaler Provider-Selbsttest..."
$providerOk = $false
try {
    $status = Invoke-RestMethod -Uri "http://127.0.0.1:37921/status" -UseBasicParsing -TimeoutSec 3
    if ($status) {
        $providerOk = $true
        Write-Host ("Provider: OK - " + $status.display)
    }
}
catch {
    Write-Warning "Provider antwortet noch nicht. Er wird beim naechsten Windows-Login automatisch gestartet."
}

Write-Host ""
Write-Host "INSTALLATION FERTIG."
Write-Host ""
Write-Host "Zielanzeige:"
Write-Host "  CPU % + CPU Temperatur | BAT % / +/-W / Zeit | GPU % + GPU Temperatur"
Write-Host ""
Write-Host "NVIDIA Hotkey:"
Write-Host "  Alt + R = Overlay ein/aus"
Write-Host ""
Write-Host "Update-Schutz v3:"
Write-Host "  - FileSystemWatcher erkennt neue NVIDIA-OSC-Dateien"
Write-Host "  - 30 s Debounce nach Updates"
Write-Host "  - 5-Minuten-Fallback-Pruefung"
Write-Host "  - SHA-256-versionierte Original-Backups"
Write-Host "  - eindeutige Patch-Anker; unbekannte Versionen werden NICHT blind gepatcht"
Write-Host "  - atomarer Dateiaustausch + Runtime-Smoke-Test + automatischer Rollback"
Write-Host ""
Write-Host "Status:"
Write-Host "  http://127.0.0.1:37921/status"
Write-Host ""
Write-Host "Log:"
Write-Host ("  " + (Join-Path $InstallDir "patch.log"))
Write-Host ""
Write-Host "State:"
Write-Host ("  " + (Join-Path $InstallDir "state.json"))
Write-Host ""
Write-Host "Bei inkompatiblen NVIDIA-Updates / fuer KI-Kompatibilitaetsanalyse:"
Write-Host ("  " + (Join-Path $InstallDir "Research.cmd"))
Write-Host "  Das Tool ist read-only und erstellt ein privates Research-ZIP in Downloads."
Write-Host ""
Read-Host "Enter druecken zum Schliessen"
