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

function Ensure-ChocolateyInstalled {
    if (Get-Command choco.exe -ErrorAction SilentlyContinue) {
        return
    }

    Write-Host "Installiere Chocolatey via winget..."
    & winget install `
        --id Chocolatey.Chocolatey `
        --exact `
        --source winget `
        --silent `
        --disable-interactivity `
        --accept-package-agreements `
        --accept-source-agreements

    if (-not (Get-Command choco.exe -ErrorAction SilentlyContinue)) {
        $chocoCmd = Get-ChildItem -Path "C:\ProgramData\chocolatey\bin\choco.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($chocoCmd) {
            $env:PATH = "$($chocoCmd.Directory.FullName);$env:PATH"
        }
    }

    if (-not (Get-Command choco.exe -ErrorAction SilentlyContinue)) {
        throw "Chocolatey installation via winget failed."
    }
}

function Install-ChocolateyPackage {
    param($App)

    $arguments = @(
        "upgrade",
        $App.id,
        "-y",
        "--no-progress",
        "--limit-output"
    )

    if (-not [string]::IsNullOrWhiteSpace($App.params)) {
        $arguments += "--params"
        $arguments += $App.params
    }

    $process = Start-Process -FilePath "choco.exe" -ArgumentList $arguments -Wait -PassThru -NoNewWindow
    if ($process.ExitCode -ne 0) {
        throw "Chocolatey install/upgrade failed for $($App.id) with code $($process.ExitCode)"
    }
}

function Install-WingetPackage {
    param($App)

    $scopeArgs = @()
    if ($App.scope -eq "machine") {
        $scopeArgs = @("--scope", "machine")
    }

    & winget install `
        --id $App.id `
        --exact `
        --source winget `
        --silent `
        --disable-interactivity `
        --accept-package-agreements `
        --accept-source-agreements `
        @scopeArgs

    if ($LASTEXITCODE -ne 0) {
        Write-Host "Install nicht erfolgreich oder bereits installiert. Versuche Upgrade: $($App.id)"

        & winget upgrade `
            --id $App.id `
            --exact `
            --source winget `
            --silent `
            --disable-interactivity `
            --accept-package-agreements `
            --accept-source-agreements `
            @scopeArgs

        if ($LASTEXITCODE -ne 0) {
            throw "winget install/upgrade failed for $($App.id) with code $LASTEXITCODE"
        }
    }
}

Write-Host "Aktualisiere winget Quellen..."
winget source update

Ensure-ChocolateyInstalled
$env:ChocolateyUseWindowsCompression = "false"

$failures = @()

foreach ($app in $config.chocolatey) {
    try {
        Write-Host "Installiere oder aktualisiere: $($app.name) [$($app.id)]"

        if ($app.manager -eq "winget") {
            Install-WingetPackage -App $app
        } else {
            Install-ChocolateyPackage -App $app
        }
    } catch {
        $failures += "$($app.name): $($_.Exception.Message)"
        Write-Warning "Failed: $($app.name) - $($_.Exception.Message)"
    }
}

if ($failures.Count -gt 0) {
    throw ("Application install failures:`n" + ($failures -join "`n"))
}

Write-Host "Softwareinstallation abgeschlossen."
