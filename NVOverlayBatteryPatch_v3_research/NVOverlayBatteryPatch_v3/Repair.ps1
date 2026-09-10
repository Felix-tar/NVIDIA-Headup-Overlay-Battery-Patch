$ErrorActionPreference = "Stop"

$InstallDir = Join-Path $env:ProgramData "NVOverlayBatteryPatch"
$Patch = Join-Path $InstallDir "Patch-NvidiaOverlay.ps1"

if (-not (Test-Path $Patch)) {
    Write-Host "Patch ist nicht installiert. Bitte zuerst Install.cmd ausfuehren."
    Read-Host "Enter druecken"
    exit 1
}

function Is-Administrator {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Is-Administrator)) {
    $args = @("-NoProfile","-ExecutionPolicy","Bypass","-File",('"{0}"' -f $PSCommandPath))
    Start-Process powershell.exe -Verb RunAs -ArgumentList $args
    exit
}

& $Patch
$code = $LASTEXITCODE

Write-Host ""
if ($code -eq 0) {
    Write-Host "Repair/Pruefung erfolgreich."
}
elseif ($code -eq 30) {
    Write-Host "Die installierte NVIDIA-Version passt nicht sicher zum aktuellen Patch-Profil."
    Write-Host "Es wurde absichtlich nichts blind gepatcht."
}
else {
    Write-Host ("Repair beendet mit ExitCode " + $code + ".")
}
Write-Host ("Log: " + (Join-Path $InstallDir "patch.log"))
Write-Host ""
Read-Host "Enter druecken zum Schliessen"
exit $code
