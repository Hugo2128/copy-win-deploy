#Requires -RunAsAdministrator

$ErrorActionPreference = "Stop"

$HelperPath = Join-Path $PSScriptRoot "Deploy-Paths.ps1"
. $HelperPath

$BasePath = Get-DeployBasePath
$RepoPath = Join-Path $BasePath "repo"
$ConfigPath = Join-Path $RepoPath "config\apps.json"

if (-not (Test-Path $ConfigPath)) {
    throw "apps.json nicht gefunden: $ConfigPath"
}

$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

Write-Host "Aktualisiere winget Quellen..."
winget source update

foreach ($app in $config.winget) {
    Write-Host "Installiere oder aktualisiere: $($app.name) [$($app.id)]"

    $scopeArgs = @()
    if ($app.scope -eq "machine") {
        $scopeArgs = @("--scope", "machine")
    }

    & winget install `
        --id $app.id `
        --exact `
        --silent `
        --disable-interactivity `
        --accept-package-agreements `
        --accept-source-agreements `
        @scopeArgs

    if ($LASTEXITCODE -ne 0) {
        Write-Host "Install nicht erfolgreich oder bereits installiert. Versuche Upgrade: $($app.id)"

        & winget upgrade `
            --id $app.id `
            --exact `
            --silent `
            --disable-interactivity `
            --accept-package-agreements `
            --accept-source-agreements `
            @scopeArgs

        if ($LASTEXITCODE -ne 0) {
            throw "winget install/upgrade failed for $($app.id) with code $LASTEXITCODE"
        }
    }
}

Write-Host "Softwareinstallation abgeschlossen."
