#Requires -RunAsAdministrator
<#!
Register only Raft's own notification protocol for the machine. This is an
explicit installation step, never called automatically by the running app.
No notification preferences, default-app UserChoice keys, or COM registrations
are changed. Run again after moving the complete Windows bundle.
!#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ExecutablePath,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Fa-f0-9]{64}$')]
    [string]$ExpectedSha256
)
$ErrorActionPreference = 'Stop'
$notificationExe = (Resolve-Path -LiteralPath $ExecutablePath).ProviderPath
if ([IO.Path]::GetFileName($notificationExe) -ne 'raft_flutter.exe' -or
    (Get-FileHash -LiteralPath $notificationExe -Algorithm SHA256).Hash -ne $ExpectedSha256) {
    throw 'The executable name or expected build hash does not match. No registration changed.'
}
$notificationDirectory = Split-Path -Parent $notificationExe
$notificationIcon = Join-Path $notificationDirectory 'raft.ico'
if (-not (Test-Path -LiteralPath $notificationIcon -PathType Leaf) -or
    -not (Test-Path -LiteralPath (Join-Path $notificationDirectory 'data\app.so') -PathType Leaf)) {
    throw 'A complete Release bundle is required. No registration changed.'
}
$notificationProtocol = 'HKLM:\Software\Classes\raft-notification'
$notificationCommand = '"' + $notificationExe + '" "%1"'
if (Test-Path -LiteralPath $notificationProtocol) {
    $notificationOwner = (Get-Item -LiteralPath $notificationProtocol).GetValue('RaftOwner')
    if ($notificationOwner -ne 'app.raft.raft_flutter') {
        throw 'The machine protocol is already owned by another registration. No changes made.'
    }
}
$notificationValues = @{
    $notificationProtocol = @{
        '(default)' = 'URL:Raft notification'
        'URL Protocol' = ''
        'RaftOwner' = 'app.raft.raft_flutter'
        'AppUserModelID' = 'app.raft.raft_flutter'
    }
    ($notificationProtocol + '\Application') = @{
        'ApplicationName' = 'Raft'
        'ApplicationIcon' = $notificationIcon
    }
    ($notificationProtocol + '\DefaultIcon') = @{ '(default)' = $notificationIcon }
    ($notificationProtocol + '\shell\open\command') = @{ '(default)' = $notificationCommand }
}
foreach ($notificationKeyPath in $notificationValues.Keys) {
    # Create missing keys without replacing existing child keys.
    if (-not (Test-Path -LiteralPath $notificationKeyPath)) {
        New-Item -Path $notificationKeyPath -Force | Out-Null
    }
    foreach ($notificationValueName in $notificationValues[$notificationKeyPath].Keys) {
        New-ItemProperty -LiteralPath $notificationKeyPath -Name $notificationValueName `
            -PropertyType String -Value $notificationValues[$notificationKeyPath][$notificationValueName] `
            -Force | Out-Null
    }
}
if ((Get-Item -LiteralPath ($notificationProtocol + '\shell\open\command')).GetValue('') -ne
    $notificationCommand) { throw 'Protocol command readback failed.' }
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class RaftNotificationAssociationUpdate {
    [DllImport("shell32.dll")]
    public static extern void SHChangeNotify(uint eventId, uint flags, IntPtr one, IntPtr two);
}
'@
[RaftNotificationAssociationUpdate]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)
Write-Output 'Registered only raft-notification for the verified Raft Release build.'
