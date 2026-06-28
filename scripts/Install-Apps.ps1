#Requires -RunAsAdministrator

$ErrorActionPreference = "Stop"

$RepoPath = "D:\CopyshopDeploy\repo"
$ConfigPath = Join-Path $RepoPath "config\apps.json"

if (-not (Test-Path $ConfigPath)) {
    throw "apps.json nicht gefunden: $ConfigPath"
}

$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

Write-Host "Aktualisiere winget Quellen..."
winget source update

foreach ($app in $config.winget) {
    Write-Host "Installiere oder aktualisiere: $($app.name) [$($app.id)]"

    winget install `
        --id $app.id `
        --exact `
        --silent `
        --accept-package-agreements `
        --accept-source-agreements

    if ($LASTEXITCODE -ne 0) {
        Write-Host "Install nicht erfolgreich oder bereits installiert. Versuche Upgrade: $($app.id)"

        winget upgrade `
            --id $app.id `
            --exact `
            --silent `
            --accept-package-agreements `
            --accept-source-agreements
    }
}

Write-Host "Softwareinstallation abgeschlossen."