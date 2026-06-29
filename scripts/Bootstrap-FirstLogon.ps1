#Requires -RunAsAdministrator

$ErrorActionPreference = "Stop"

$HelperPath = Join-Path $PSScriptRoot "Deploy-Paths.ps1"
. $HelperPath

$BasePath = Get-DeployBasePath -EnsureVolume
$RepoPath = Join-Path $BasePath "repo"
$LogPath = Join-Path $BasePath "logs"
$StatePath = Join-Path $BasePath "state"
$CachePath = Join-Path $BasePath "cache"
$SecretsPath = Join-Path $BasePath "secrets"
$RepoUrl = "https://github.com/Hugo2128/copy-win-deploy.git"
$TaskName = "Copyshop Pull And Apply"
$PullScript = Join-Path $RepoPath "scripts\Pull-And-Apply.ps1"

New-Item -ItemType Directory -Path $BasePath, $LogPath, $StatePath, $CachePath, $SecretsPath -Force | Out-Null

$LogFile = Join-Path $LogPath ("bootstrap-" + (Get-Date -Format "yyyy-MM-dd-HH-mm-ss") + ".log")
Start-Transcript -Path $LogFile -Append

function Wait-ForInternet {
    $deadline = (Get-Date).AddMinutes(15)
    while ((Get-Date) -lt $deadline) {
        try {
            Invoke-WebRequest -Uri "https://github.com" -Method Head -UseBasicParsing -TimeoutSec 10 | Out-Null
            return
        } catch {
            Start-Sleep -Seconds 5
        }
    }

    throw "Internet connection did not become available in time."
}

function Wait-ForWinget {
    $deadline = (Get-Date).AddMinutes(15)
    while ((Get-Date) -lt $deadline) {
        if (Get-Command winget.exe -ErrorAction SilentlyContinue) {
            return
        }
        Start-Sleep -Seconds 5
    }

    throw "winget.exe did not become available in time."
}

function Get-TargetComputerName {
    $currentName = $env:COMPUTERNAME.ToUpperInvariant()

    for ($i = 1; $i -le 3; $i++) {
        $candidate = "KUNDEN-PC-{0:D2}" -f $i
        if ($currentName -eq $candidate) {
            return $candidate
        }

        $inUse = $false
        try {
            $inUse = Test-Connection -ComputerName $candidate -Count 1 -Quiet -ErrorAction SilentlyContinue
        } catch {
            $inUse = $false
        }

        if (-not $inUse) {
            return $candidate
        }
    }

    return $currentName
}

function Ensure-GitInstalled {
    if (Get-Command git.exe -ErrorAction SilentlyContinue) {
        return
    }

    winget install --id Git.Git --exact --silent --accept-package-agreements --accept-source-agreements --disable-interactivity

    if (-not (Get-Command git.exe -ErrorAction SilentlyContinue)) {
        $gitCmd = Get-ChildItem -Path "C:\Program Files\Git\cmd\git.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($gitCmd) {
            $env:PATH = "$($gitCmd.Directory.FullName);$env:PATH"
        }
    }

    if (-not (Get-Command git.exe -ErrorAction SilentlyContinue)) {
        throw "Git installation via winget failed."
    }
}

function Initialize-Repo {
    if (-not (Test-Path -LiteralPath $RepoPath)) {
        git clone --branch main --single-branch $RepoUrl $RepoPath
        return
    }

    git -C $RepoPath fetch origin --prune
    git -C $RepoPath checkout main
    git -C $RepoPath reset --hard origin/main
}

function Register-PullTask {
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$PullScript`""
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -StartWhenAvailable

    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
}

try {
    Wait-ForInternet
    Wait-ForWinget

    $targetName = Get-TargetComputerName
    if ($env:COMPUTERNAME.ToUpperInvariant() -ne $targetName) {
        Rename-Computer -NewName $targetName -Force
    }

    Ensure-GitInstalled
    Initialize-Repo
    Register-PullTask

    Restart-Computer -Force
} finally {
    Stop-Transcript
}
