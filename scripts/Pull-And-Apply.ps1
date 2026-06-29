#Requires -RunAsAdministrator

$ErrorActionPreference = "Stop"

$HelperPath = Join-Path $PSScriptRoot "Deploy-Paths.ps1"
. $HelperPath

$BasePath = Get-DeployBasePath
$RepoPath = Join-Path $BasePath "repo"
$LogPath = Join-Path $BasePath "logs"
$StatePath = Join-Path $BasePath "state"
$CachePath = Join-Path $BasePath "cache"

$MaintenancePath = Join-Path $RepoPath "config\maintenance.json"
$StateFile = Join-Path $StatePath "last-applied-commit.txt"

New-Item -ItemType Directory -Path $LogPath -Force | Out-Null
New-Item -ItemType Directory -Path $StatePath -Force | Out-Null
New-Item -ItemType Directory -Path $CachePath -Force | Out-Null

$LogFile = Join-Path $LogPath ("maintenance-" + (Get-Date -Format "yyyy-MM-dd-HH-mm-ss") + ".log")

Start-Transcript -Path $LogFile -Append

try {
    if (-not (Test-Path $RepoPath)) {
        throw "Repo nicht gefunden: $RepoPath"
    }

    Set-Location $RepoPath

    Write-Host "Hole aktuelle GitHub-Version..."
    git fetch origin
    git reset --hard origin/main

    $CurrentCommit = (git rev-parse HEAD).Trim()

    if (Test-Path $StateFile) {
        $LastAppliedCommit = (Get-Content $StateFile -Raw).Trim()
    } else {
        $LastAppliedCommit = ""
    }

    if (-not (Test-Path $MaintenancePath)) {
        throw "maintenance.json nicht gefunden: $MaintenancePath"
    }

    $maintenance = Get-Content $MaintenancePath -Raw | ConvertFrom-Json

    if ($maintenance.enabled -ne $true) {
        Write-Host "Wartung ist deaktiviert. Keine Aktion."
        exit 0
    }

    if ($CurrentCommit -eq $LastAppliedCommit -and $maintenance.forceApply -ne $true) {
        Write-Host "Dieser Commit wurde bereits angewendet: $CurrentCommit"
        exit 0
    }

    Write-Host "Neuer Commit erkannt: $CurrentCommit"

    if ($maintenance.runWinget -eq $true) {
        & "$RepoPath\scripts\Install-Apps.ps1"
    }

    if ($maintenance.runOffice -eq $true) {
        & "$RepoPath\scripts\Install-Office.ps1"
    }

    if ($maintenance.runDrivers -eq $true) {
        & "$RepoPath\scripts\Install-Drivers.ps1"
    }

    if ($LASTEXITCODE -eq 0 -or $null -eq $LASTEXITCODE) {
        $CurrentCommit | Set-Content $StateFile
        Write-Host "Commit als angewendet gespeichert."
    } else {
        throw "Installationsskript hat Fehlercode $LASTEXITCODE zurückgegeben."
    }
}
catch {
    Write-Error $_
    exit 1
}
finally {
    Stop-Transcript
}
