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
    param(
        [switch] $EnsureVolume
    )

    $volume = if ($EnsureVolume) { Ensure-DeployVolume } else { Get-PreferredDeployVolume }
    if (-not $volume) {
        throw "Deploy volume '$script:DeployVolumeLabel' not found."
    }

    if (-not $volume.DriveLetter) {
        $partition = Get-Partition -UniqueId $volume.UniqueId -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $partition) {
            throw "Deploy volume has no drive letter and could not be resolved."
        }

        $newLetter = Get-FreeDriveLetter
        Set-Partition -DiskNumber $partition.DiskNumber -PartitionNumber $partition.PartitionNumber -NewDriveLetter $newLetter -ErrorAction Stop
        $volume = Get-PreferredDeployVolume
    }

    return "{0}:\{1}" -f $volume.DriveLetter.ToString().ToUpperInvariant(), $script:DeployFolderName
}
