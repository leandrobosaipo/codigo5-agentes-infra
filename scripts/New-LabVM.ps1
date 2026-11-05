#requires -Version 5.1
<#
.SYNOPSIS
Plans a new, disconnected Hyper-V lab VM. Writes only when called with -Apply.
.DESCRIPTION
Use Windows PowerShell on the Hyper-V host. The default prints a JSON plan.
For -Apply, run the reviewed file with -ExpectedScriptSha256 from its release.
Receipts capture each completed stage. On a partial failure all objects remain
available for inspection. See RECOVERY.md before unregistering any VM.
#>
[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z][A-Za-z0-9-]{0,39}$')]
    [string]$VMName = 'codigo5-agentes-lab',
    [Alias('RootPath')][ValidatePattern('^C:\\ProgramData\\Codigo5\\Labs\\[A-Za-z][A-Za-z0-9-]{0,39}$')]
    [string]$Root = 'C:\ProgramData\Codigo5\Labs\codigo5-agentes-lab',
    [Alias('ProcessorCount')][ValidateRange(1,2)][int]$CpuCount = 2,
    [ValidateRange(1,2)][int]$MemoryGiB = 2,
    [Alias('VhdMaximumGiB')][ValidateRange(12,20)][int]$DiskGiB = 20,
    [Alias('HostMinimumFreeGiB')][ValidateRange(25,200)][int]$ReserveGiB = 25,
    [ValidateRange(8,32)][int]$AdditionalReserveGiB = 8,
    [string]$ConfigPath,
    [ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$ExpectedScriptSha256,
    [ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$ExpectedConfigSha256,
    [ValidatePattern('^[A-Fa-f0-9]{40}$')][string]$SourceCommit,
    [switch]$Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-LabReceipt([string]$Filename, [object]$Record) {
    $path = Join-Path $Root $Filename
    $json = ConvertTo-Json -InputObject $Record -Depth 5
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
    $stream = [IO.File]::Open($path, 'CreateNew', 'Write', 'None')
    try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
    (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash
}

# Limit the path to the project namespace and check every existing parent.
if ([IO.Path]::GetFullPath($Root) -ne $Root -or
    [IO.Path]::GetFileName($Root) -ne $VMName -or
    $VMName -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') {
    throw 'Invalid or reserved Windows path.'
}
$parents = @('C:\ProgramData', 'C:\ProgramData\Codigo5', 'C:\ProgramData\Codigo5\Labs')
foreach ($p in $parents) {
    if (Test-Path -LiteralPath $p) {
        $dir = Get-Item -LiteralPath $p -Force
        if (!$dir.PSIsContainer -or ($dir.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Unexpected directory or reparse point in lab path.'
        }
    } elseif ($p -eq 'C:\ProgramData') { throw 'ProgramData directory missing.' }
}
if (Test-Path -LiteralPath $Root) { throw 'Target directory exists. Keep it for inspection.' }
if (@(Get-VM | Where-Object { $_.Name -eq $VMName }).Count) { throw 'VM name is already registered.' }
if ((Get-Service -Name vmms).Status -ne 'Running') { throw 'Hyper-V management service must be running.' }
if (!@((Get-VMHostSupportedVersion) | Where-Object { $_.Version.ToString() -eq '9.2' }).Count) {
    throw 'This release requires Hyper-V VM configuration version 9.2.'
}
$volume = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
if ($volume.DriveType -ne 3 -or $volume.FileSystem -ne 'NTFS') { throw 'Expected a fixed NTFS C: volume.' }
$requiredGiB = $ReserveGiB + $DiskGiB + $AdditionalReserveGiB
if ([decimal]$volume.FreeSpace -lt ($requiredGiB * 1GB)) { throw "C: requires at least $requiredGiB GiB free." }
$freeRamKiB = (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory
if ($freeRamKiB -lt (($MemoryGiB + 2) * 1MB)) { throw 'Insufficient free memory for guest and host allowance.' }
$disk = Join-Path $Root 'system.vhdx'
$plan = [ordered]@{
    schema = 1; mode = 'plan'; name = $VMName; root = $Root; disk = $disk
    cpu = $CpuCount; staticMemoryGiB = $MemoryGiB; diskLimitGiB = $DiskGiB
    additionalReserveGiB = $AdditionalReserveGiB; hostReserveGiB = $ReserveGiB
    requiredFreeGiB = $requiredGiB; observedFreeGiB = [math]::Round($volume.FreeSpace / 1GB, 2)
    generation = 2; vmConfigurationVersion = '9.2'; networkAdapters = 0; start = 'Nothing'; secureBoot = 'MicrosoftUEFICertificateAuthority'
}
if (!$Apply) { $plan | ConvertTo-Json; return }

if (!$ExpectedScriptSha256 -or !$PSCommandPath -or !$ConfigPath -or !$ExpectedConfigSha256 -or !$SourceCommit) {
    throw 'Apply requires the reviewed script/config files, both release SHA256 digests, and the source commit.'
}
$sourceHash = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash
if ($sourceHash -ne $ExpectedScriptSha256) { throw 'File SHA256 differs from release.' }
$configHash = (Get-FileHash -LiteralPath $ConfigPath -Algorithm SHA256).Hash
if ($configHash -ne $ExpectedConfigSha256) { throw 'Config SHA256 differs from release.' }
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
if ($config.schema -ne 'codigo5-agentes-lab-v1' -or $config.stage -ne 'vm-stopped' -or
    $config.vmName -ne $VMName -or $config.rootPath -ne $Root -or $config.generation -ne 2 -or
    $config.processorCount -ne $CpuCount -or $config.memoryGiB -ne $MemoryGiB -or
    $config.vhdMaximumGiB -ne $DiskGiB -or $config.hostMinimumFreeGiB -ne $ReserveGiB -or
    $config.additionalReserveGiB -ne $AdditionalReserveGiB -or $config.networkAttached -ne $false -or
    $config.automaticCheckpoints -ne $false -or $config.secureBootTemplate -ne $plan.secureBoot) {
    throw 'Resource plan differs from release configuration.'
}
foreach ($p in $parents) {
    if (!(Test-Path -LiteralPath $p)) { $null = New-Item -ItemType Directory -Path $p }
    $dir = Get-Item -LiteralPath $p -Force
    if (!$dir.PSIsContainer -or ($dir.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Unsafe parent directory.' }
}
# New-Item without -Force fails if a parallel attempt has already claimed this root.
$null = New-Item -ItemType Directory -Path $Root
$plan.mode = 'claimed'
$plan['sourceSha256'] = $sourceHash
$plan['configSha256'] = $configHash
$plan['sourceCommit'] = $SourceCommit
$plan['runId'] = [guid]::NewGuid().ToString()
$claimHash = Write-LabReceipt '01-claim.json' $plan
$newDisk = New-VHD -Path $disk -Dynamic -SizeBytes ($DiskGiB * 1GB)
$diskId = [string]$newDisk.DiskIdentifier
if (!$diskId -or $newDisk.Path -ne $disk) { throw 'Unexpected disk identity. Inspect the claimed directory.' }
$diskReceiptHash = Write-LabReceipt '02-disk.json' ([ordered]@{
    runId = $plan.runId; claimSha256 = $claimHash; disk = $disk; diskId = $diskId
})
$vm = New-VM -Name $VMName -Path $Root -Generation 2 -Version 9.2 -NoVHD -MemoryStartupBytes ($MemoryGiB * 1GB)
$vmId = $vm.Id
$vmReceiptHash = Write-LabReceipt '03-registration.json' ([ordered]@{
    runId = $plan.runId; diskReceiptSha256 = $diskReceiptHash; vmId = $vmId.ToString(); name = $VMName
})
Set-VM -VM $vm -ProcessorCount $CpuCount -AutomaticStartAction Nothing -AutomaticStopAction ShutDown -AutomaticCheckpointsEnabled $false -CheckpointType Disabled
Set-VMMemory -VM $vm -DynamicMemoryEnabled $false
Set-VMFirmware -VM $vm -EnableSecureBoot On -SecureBootTemplate $plan.secureBoot
Get-VMNetworkAdapter -VM $vm | Remove-VMNetworkAdapter -Confirm:$false
Add-VMHardDiskDrive -VM $vm -ControllerType SCSI -ControllerNumber 0 -ControllerLocation 0 -Path $disk

$vm = Get-VM -Id $vmId
$fw = Get-VMFirmware -VM $vm
$attached = @(Get-VMHardDiskDrive -VM $vm)
$vhd = Get-VHD -Path $disk
if ($vm.Name -ne $VMName -or $vm.State -ne 'Off' -or $vm.Generation -ne 2 -or $vm.Version -ne '9.2' -or
    $vm.ProcessorCount -ne $CpuCount -or $vm.DynamicMemoryEnabled -or $vm.MemoryStartup -ne ($MemoryGiB * 1GB) -or
    $vm.AutomaticStartAction -ne 'Nothing' -or $vm.AutomaticStopAction -ne 'ShutDown' -or
    $vm.AutomaticCheckpointsEnabled -or $vm.CheckpointType -ne 'Disabled' -or
    $fw.SecureBoot -ne 'On' -or $fw.SecureBootTemplate -ne $plan.secureBoot -or
    (Get-VMSecurity -VM $vm).TpmEnabled -or @(Get-VMNetworkAdapter -VM $vm).Count -ne 0 -or
    $attached.Count -ne 1 -or $attached[0].Path -ne $disk -or $vhd.VhdType -ne 'Dynamic' -or
    $vhd.Size -ne ($DiskGiB * 1GB) -or [string]$vhd.DiskIdentifier -ne $diskId) {
    throw 'VM readback mismatch. Preserve objects and inspect receipts.'
}
$receipt = [ordered]@{
    schema = 1; runId = $plan.runId; state = 'verified-off'; utc = [DateTime]::UtcNow.ToString('o')
    root = $Root; name = $VMName; vmId = $vmId.ToString(); disk = $disk; diskId = $diskId
    sourceSha256 = $sourceHash; configSha256 = $configHash; sourceCommit = $SourceCommit
    registrationReceiptSha256 = $vmReceiptHash
    diskSha256BeforeFirstBoot = (Get-FileHash -Algorithm SHA256 -LiteralPath $disk).Hash
}
$receiptSha256 = Write-LabReceipt '04-verified.json' $receipt
[ordered]@{verified = $true; vmId = $vmId.ToString(); state = 'Off'; manifest = (Join-Path $Root '04-verified.json'); manifestSha256 = $receiptSha256} | ConvertTo-Json
