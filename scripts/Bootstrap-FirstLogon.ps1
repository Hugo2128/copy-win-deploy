#Requires -RunAsAdministrator

$ErrorActionPreference = "Stop"

$script:DeployVolumeLabel = "COPYDEPLOY"
$script:DeployFolderName = "CopyshopDeploy"
$script:PreferredDriveLetter = "D"
$script:MinimumDeploySizeBytes = 20GB

function Get-PreferredDeployVolume {
    $volume = Get-Volume -FileSystemLabel $script:DeployVolumeLabel -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($volume) {
        return $volume
    }

    return $null
}

function Get-FreeDriveLetter {
    param(
        [string[]] $PreferredLetters = @($script:PreferredDriveLetter, "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z")
    )

    $usedLetters = @(Get-Volume | Where-Object DriveLetter | ForEach-Object { $_.DriveLetter.ToString().ToUpperInvariant() })
    foreach ($letter in $PreferredLetters) {
        if ($usedLetters -notcontains $letter.ToUpperInvariant()) {
            return $letter.ToUpperInvariant()
        }
    }

    throw "No free drive letter available for deploy volume."
}

function Ensure-DeployVolume {
    $existing = Get-PreferredDeployVolume
    if ($existing) {
        return $existing
    }

    $systemPartition = Get-Partition -DriveLetter C -ErrorAction Stop
    $supportedSize = Get-PartitionSupportedSize -DriveLetter C -ErrorAction Stop
    $currentSize = [int64] $systemPartition.Size
    $targetSystemSize = $currentSize - $script:MinimumDeploySizeBytes

    if ($targetSystemSize -lt $supportedSize.SizeMin) {
        throw "Not enough shrinkable space on C: to create the deploy volume."
    }

    Resize-Partition -DriveLetter C -Size $targetSystemSize -ErrorAction Stop | Out-Null

    $newPartition = New-Partition -DiskNumber $systemPartition.DiskNumber -UseMaximumSize -AssignDriveLetter -ErrorAction Stop
    Format-Volume -Partition $newPartition -FileSystem NTFS -NewFileSystemLabel $script:DeployVolumeLabel -Confirm:$false -Force | Out-Null

    $preferredLetter = $script:PreferredDriveLetter
    $freeLetter = Get-FreeDriveLetter
    $targetLetter = if ($freeLetter -eq $preferredLetter) { $preferredLetter } else { $freeLetter }

    $newPartition = Get-Partition -DiskNumber $newPartition.DiskNumber -PartitionNumber $newPartition.PartitionNumber -ErrorAction Stop
    if ($newPartition.DriveLetter -and $newPartition.DriveLetter.ToString().ToUpperInvariant() -ne $targetLetter) {
        Set-Partition -DriveLetter $newPartition.DriveLetter -NewDriveLetter $targetLetter -ErrorAction Stop
    }

    return Get-PreferredDeployVolume
}

function Get-DeployBasePath {
    $volume = Ensure-DeployVolume
    if (-not $volume) {
        throw "Deploy volume '$script:DeployVolumeLabel' not found."
    }

    return "{0}:\{1}" -f $volume.DriveLetter.ToString().ToUpperInvariant(), $script:DeployFolderName
}

$BasePath = Get-DeployBasePath
$RepoPath = Join-Path $BasePath "repo"
$LogPath = Join-Path $BasePath "logs"
$StatePath = Join-Path $BasePath "state"
$CachePath = Join-Path $BasePath "cache"
$SecretsPath = Join-Path $BasePath "secrets"
$RepoUrl = "https://github.com/Hugo2128/copy-win-deploy.git"
$TaskName = "Copyshop Pull And Apply"
$PullScript = Join-Path $RepoPath "scripts\Pull-And-Apply.ps1"
$StagedOfficeKeyPath = "C:\Windows\Setup\Scripts\office-key.txt"

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

function Stage-OfficeKey {
    if (-not (Test-Path -LiteralPath $StagedOfficeKeyPath)) {
        return
    }

    $targetKeyPath = Join-Path $SecretsPath "office-key.txt"
    Copy-Item -LiteralPath $StagedOfficeKeyPath -Destination $targetKeyPath -Force
    Remove-Item -LiteralPath $StagedOfficeKeyPath -Force -ErrorAction SilentlyContinue
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

function Invoke-InitialApply {
    if (-not (Test-Path -LiteralPath $PullScript)) {
        throw "Pull-And-Apply script not found: $PullScript"
    }

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $PullScript
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne $null) {
        throw "Initial Pull-And-Apply failed with code $LASTEXITCODE"
    }
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
    Stage-OfficeKey
    Register-PullTask
    Invoke-InitialApply

    Restart-Computer -Force
} finally {
    Stop-Transcript
}
