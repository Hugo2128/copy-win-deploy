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
$office = $config.office

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

if (-not $office.enabled) {
    Write-Host "Office installation is disabled."
    exit 0
}

$cacheDir = Resolve-DeployPath $office.cacheDir
$odtPath = Join-Path $cacheDir "setup.exe"
$tempConfigPath = Join-Path $cacheDir "office-2024-runtime.xml"

New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null

$officeKeyFile = Resolve-DeployPath $office.keyFile
$officeConfigFile = Resolve-DeployPath $office.configPath

if (-not (Test-Path -LiteralPath $officeKeyFile)) {
    throw "Office key file not found: $officeKeyFile"
}

if (-not (Test-Path -LiteralPath $officeConfigFile)) {
    throw "Office config not found: $officeConfigFile"
}

if (-not (Test-Path -LiteralPath $odtPath)) {
    Invoke-WebRequest -Uri $office.odtUrl -OutFile $odtPath -UseBasicParsing
}

$officeKey = (Get-Content -LiteralPath $officeKeyFile -Raw).Trim()
if ([string]::IsNullOrWhiteSpace($officeKey)) {
    throw "Office key file is empty: $officeKeyFile"
}

$officeXml = Get-Content -LiteralPath $officeConfigFile -Raw
$officeXml = $officeXml.Replace("__OFFICE_KEY__", $officeKey)
Set-Content -LiteralPath $tempConfigPath -Value $officeXml -Encoding UTF8

Write-Host "Installing Microsoft Office 2024 Pro Plus..."
& $odtPath /configure $tempConfigPath

if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne $null) {
    throw "Office installer exited with code $LASTEXITCODE"
}
