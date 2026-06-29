#Requires -RunAsAdministrator

$ErrorActionPreference = "Stop"

$HelperPath = Join-Path $PSScriptRoot "Deploy-Paths.ps1"
. $HelperPath

$BasePath = Get-DeployBasePath
$RepoPath = Join-Path $BasePath "repo"
$ConfigPath = Join-Path $RepoPath "config\apps.json"

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "apps.json not found: $ConfigPath"
}

$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$driverConfig = $config.drivers

function Resolve-DeployPath {
    param([string] $PathValue)

    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        return $PathValue
    }

    if ([System.IO.Path]::IsPathRooted($PathValue)) {
        return $PathValue
    }

    return Join-Path $BasePath $PathValue
}

if (-not $driverConfig.enabled) {
    Write-Host "Driver installation is disabled."
    exit 0
}

foreach ($package in $driverConfig.packages) {
    if (-not $package.enabled) {
        continue
    }

    if ([string]::IsNullOrWhiteSpace($package.url)) {
        Write-Warning "Skipping driver package '$($package.name)' because no download URL is configured."
        continue
    }

    $extractDir = Resolve-DeployPath $package.extractDir
    $downloadDir = Split-Path -Path $extractDir -Parent
    New-Item -ItemType Directory -Path $downloadDir, $extractDir -Force | Out-Null

    $archivePath = Join-Path $downloadDir $package.fileName
    Invoke-WebRequest -Uri $package.url -OutFile $archivePath -UseBasicParsing

    if ($package.downloadOnly -eq $true) {
        Write-Host "Downloaded driver package: $($package.name) -> $archivePath"
        continue
    }

    if ($archivePath.ToLowerInvariant().EndsWith('.zip')) {
        Expand-Archive -LiteralPath $archivePath -DestinationPath $extractDir -Force
    }

    switch ($package.installType) {
        "pnputil-inf" {
            $infPath = Join-Path $extractDir $package.infPath
            if (-not (Test-Path -LiteralPath $infPath)) {
                throw "INF not found for $($package.name): $infPath"
            }

            pnputil.exe /add-driver $infPath /install
            if ($LASTEXITCODE -ne 0) {
                throw "pnputil failed for $($package.name) with code $LASTEXITCODE"
            }
        }
        "vendor-exe" {
            $installerPath = Join-Path $extractDir $package.installerPath
            if (-not (Test-Path -LiteralPath $installerPath)) {
                $installerPath = $archivePath
            }

            & $installerPath $package.silentArgs
            if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne $null) {
                throw "Driver installer failed for $($package.name) with code $LASTEXITCODE"
            }
        }
        default {
            throw "Unsupported installType '$($package.installType)' for driver package '$($package.name)'"
        }
    }
}
