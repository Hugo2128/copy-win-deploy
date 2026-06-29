#Requires -RunAsAdministrator

param(
    [int] $OverlaySizeMB = 51200,
    [string] $ProtectedVolume = "C:",
    [string] $ResumeTaskName = "Copyshop Prepare UWF Resume"
)

$ErrorActionPreference = "Stop"

function Get-UwfFeatureState {
    return (Get-WindowsOptionalFeature -Online -FeatureName Client-UnifiedWriteFilter -ErrorAction Stop).State
}

function Register-ResumeTask {
    param(
        [string] $ScriptPath
    )

    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" -OverlaySizeMB $OverlaySizeMB -ProtectedVolume $ProtectedVolume -ResumeTaskName `"$ResumeTaskName`""
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -StartWhenAvailable

    Register-ScheduledTask -TaskName $ResumeTaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
}

function Unregister-ResumeTaskIfPresent {
    $task = Get-ScheduledTask -TaskName $ResumeTaskName -ErrorAction SilentlyContinue
    if ($task) {
        Unregister-ScheduledTask -TaskName $ResumeTaskName -Confirm:$false | Out-Null
    }
}

function Invoke-UwfCommand {
    param(
        [string[]] $Arguments,
        [int[]] $AllowedExitCodes = @(0)
    )

    $process = Start-Process -FilePath "uwfmgr.exe" -ArgumentList $Arguments -Wait -PassThru -NoNewWindow
    if ($AllowedExitCodes -notcontains $process.ExitCode) {
        throw "uwfmgr $($Arguments -join ' ') failed with code $($process.ExitCode)"
    }
}

$scriptPath = $MyInvocation.MyCommand.Path
if (-not $scriptPath) {
    throw "Unable to determine script path for UWF resume registration."
}

$featureState = Get-UwfFeatureState

if ($featureState -eq "Disabled") {
    Write-Host "Enabling UWF feature..."
    $process = Start-Process -FilePath "dism.exe" -ArgumentList @("/online", "/enable-feature", "/featurename:Client-UnifiedWriteFilter", "/all", "/norestart") -Wait -PassThru -NoNewWindow
    if ($process.ExitCode -ne 0 -and $process.ExitCode -ne 3010) {
        throw "DISM failed to enable UWF feature with code $($process.ExitCode)"
    }

    Register-ResumeTask -ScriptPath $scriptPath
    Write-Host "UWF feature enabled. Rebooting once to finish feature installation..."
    Restart-Computer -Force
    exit 0
}

if ($featureState -eq "EnablePending") {
    Register-ResumeTask -ScriptPath $scriptPath
    Write-Host "UWF feature installation is pending. Rebooting once to continue setup..."
    Restart-Computer -Force
    exit 0
}

if ($featureState -ne "Enabled") {
    throw "Unexpected UWF feature state: $featureState"
}

Unregister-ResumeTaskIfPresent

Write-Host "Preparing UWF configuration..."

Invoke-UwfCommand -Arguments @("filter", "disable") -AllowedExitCodes @(0)
Invoke-UwfCommand -Arguments @("overlay", "set-type", "disk")
Invoke-UwfCommand -Arguments @("overlay", "set-size", "$OverlaySizeMB")
Invoke-UwfCommand -Arguments @("volume", "protect", $ProtectedVolume)

Write-Host ""
Write-Host "UWF is prepared but still disabled."
Write-Host "When you are ready, run these commands manually as Administrator:"
Write-Host "  uwfmgr filter enable"
Write-Host "  shutdown /r /t 0"
