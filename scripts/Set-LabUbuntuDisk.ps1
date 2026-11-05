#requires -Version 5.1
<#
.SYNOPSIS
Verify a GitHub Actions image archive and plan a disk replacement on the stopped lab VM.
.DESCRIPTION
The release executor supplies trusted identities from the successful workflow and its step
summary, copying the ZIP byte-for-byte to Bootstrap\<ImageCommit>\artifact-<ArtifactId>.zip.
The original VHDX stays on disk. Apply changes only the existing SCSI attachment on this VM.
On interruption inspect the attachment, the new directory and its receipts before proceeding.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][guid]$VMId,
    [ValidatePattern('^[A-Za-z][A-Za-z0-9-]{0,39}$')][string]$VMName = 'codigo5-agentes-lab',
    [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$OriginalManifestSha256,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}$')][string]$ImageCommit,
    [Parameter(Mandatory)][ValidatePattern('^[1-9][0-9]{0,19}$')][string]$BuildRunId,
    [Parameter(Mandatory)][ValidatePattern('^[1-9][0-9]{0,19}$')][string]$ArtifactId,
    [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ArchiveSha256,
    [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ImageManifestSha256,
    [ValidatePattern('^[a-f0-9]{40}$')][string]$SourceCommit,
    [ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedScriptSha256,
    [switch]$Apply
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Join-Path 'C:\ProgramData\Codigo5\Labs' $VMName
$receiptPath = Join-Path $root '04-verified.json'
$originalDisk = Join-Path $root 'system.vhdx'
$stage = Join-Path 'C:\ProgramData\Codigo5\Bootstrap' $ImageCommit
$archive = Join-Path $stage "artifact-$ArtifactId.zip"
$work = Join-Path $root "ubuntu-$ArtifactId"
$newDisk = Join-Path $work 'ubuntu-noble-amd64.vhdx'

function Write-StageRecord($File, $Record) {
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($Record | ConvertTo-Json -Depth 4))
    $stream = [IO.File]::Open($File, 'CreateNew', 'Write', 'None')
    try { $stream.Write($bytes,0,$bytes.Length) } finally { $stream.Dispose() }
    (Get-FileHash -LiteralPath $File).Hash
}
function Assert-OriginalAttachment {
    $vm = Get-VM -Id $VMId
    if ($vm.Name -ne $VMName -or $vm.State -ne 'Off' -or $vm.Generation -ne 2 -or
        $vm.Version -ne '9.2' -or $vm.ProcessorCount -ne 2 -or $vm.MemoryStartup -ne 2GB -or
        $vm.DynamicMemoryEnabled -or (Get-VMSecurity -VM $vm).TpmEnabled -or
        $vm.AutomaticStartAction -ne 'Nothing' -or $vm.CheckpointType -ne 'Disabled' -or
        $vm.AutomaticCheckpointsEnabled -or @(Get-VMSnapshot -VM $vm).Count -ne 0 -or
        @(Get-VMNetworkAdapter -VM $vm).Count -ne 0 -or @(Get-VMDvdDrive -VM $vm).Count -ne 0) {
        throw 'VM identity or isolation state differs from the expected original.'
    }
    $firmware = Get-VMFirmware -VM $vm
    if ($firmware.SecureBoot -ne 'On' -or $firmware.SecureBootTemplate -ne 'MicrosoftUEFICertificateAuthority') {
        throw 'Unexpected VM Secure Boot configuration.'
    }
    $disk = @(Get-VMHardDiskDrive -VM $vm)
    if ($disk.Count -ne 1 -or $disk[0].Path -ne $originalDisk -or
        $disk[0].ControllerType -ne 'SCSI' -or $disk[0].ControllerNumber -ne 0 -or
        $disk[0].ControllerLocation -ne 0) { throw 'Unexpected original VM disk attachment.' }
    return $disk[0]
}

if (Test-Path -LiteralPath $work) { throw 'Image staging directory already exists. Reconcile before retrying.' }
foreach ($path in @('C:\ProgramData','C:\ProgramData\Codigo5','C:\ProgramData\Codigo5\Labs',
    $root,$receiptPath,$originalDisk,'C:\ProgramData\Codigo5\Bootstrap',$stage,$archive)) {
    if ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw 'Unexpected reparse point in the lab or source paths.'
    }
}
if ((Get-FileHash -LiteralPath $receiptPath).Hash -ne $OriginalManifestSha256) { throw 'Original receipt hash mismatch.' }
$original = Get-Content -Raw -LiteralPath $receiptPath | ConvertFrom-Json
if ($original.state -ne 'verified-off' -or $original.vmId -ne $VMId.ToString() -or
    $original.name -ne $VMName -or $original.root -ne $root -or $original.disk -ne $originalDisk -or
    [string](Get-VHD -Path $originalDisk).DiskIdentifier -ne $original.diskId -or
    (Get-FileHash -LiteralPath $originalDisk).Hash -ne $original.diskSha256BeforeFirstBoot) {
    throw 'Original disk or machine does not match the trusted receipt.'
}
$null = Assert-OriginalAttachment
# The archive is already occupying C:. The image may grow to 20 GiB and the
# powered-on VM needs up to 4 GiB for state. Keep 25 GiB available to Windows.
if ((Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'").FreeSpace -lt 49GB) {
    throw 'Need 49 GiB free after staging the ZIP.'
}
Add-Type -AssemblyName System.IO.Compression
$file = [IO.File]::Open($archive,'Open','Read','Read')
try {
    if ($file.Length -gt 6GB -or (Get-FileHash -InputStream $file).Hash -ne $ArchiveSha256) { throw 'Archive hash or size mismatch.' }
    $file.Position = 0
    $zip = [IO.Compression.ZipArchive]::new($file, [IO.Compression.ZipArchiveMode]::Read, $true)
    try {
        $meta = $zip.GetEntry('manifest.json')
        $payload = $zip.GetEntry('ubuntu-noble-amd64.vhdx')
        if ($zip.Entries.Count -ne 2 -or !$meta -or !$payload -or $meta.Length -gt 64KB -or
            $payload.Length -le 0 -or $payload.Length -gt 6GB) { throw 'Unexpected artifact entries.' }
        $inputStream = $meta.Open()
        try { $metaHash = (Get-FileHash -InputStream $inputStream).Hash } finally { $inputStream.Dispose() }
        if ($metaHash -ne $ImageManifestSha256) { throw 'Image manifest hash mismatch.' }
        $reader = [IO.StreamReader]::new($meta.Open())
        try { $image = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
        $out = $image.output
        if ($image.schema -ne 1 -or $image.sourceCommit -ne $ImageCommit -or $image.workflowRun -ne $BuildRunId -or
            $out.file -ne $payload.FullName -or $out.fileBytes -ne $payload.Length -or
            $out.sha256 -notmatch '^[a-fA-F0-9]{64}$' -or $out.qemuCompare -ne 'passed' -or
            $out.conversionSubformat -ne 'dynamic' -or $out.outputVirtualBytes -ne $out.sourceVirtualBytes -or
            $out.outputVirtualBytes -le 0 -or $out.outputVirtualBytes -gt 20GB) { throw 'Image manifest does not match the trusted workflow or lab limits.' }
        if (!$Apply) {
            [ordered]@{mode='plan';vmId=$VMId.ToString();artifact=$ArtifactId;run=$BuildRunId;sourceBytes=$payload.Length;
                virtualBytes=$out.outputVirtualBytes;newLimitGiB=20;originalRetained=$true} | ConvertTo-Json
            return
        }
        if (!$PSCommandPath -or !$SourceCommit -or !$ExpectedScriptSha256 -or
            (Get-FileHash -LiteralPath $PSCommandPath).Hash -ne $ExpectedScriptSha256) { throw 'Missing or incorrect provisioning release.' }
        $null = New-Item -ItemType Directory -Path $work
        $stream = [IO.File]::Open($newDisk,'CreateNew','Write','None')
        try {
            $inputStream = $payload.Open()
            try { $inputStream.CopyTo($stream) } finally { $inputStream.Dispose() }
        } finally { $stream.Dispose() }
    } finally { $zip.Dispose() }
} finally { $file.Dispose() }
if ((Get-FileHash -LiteralPath $newDisk).Hash -ne $out.sha256) { throw 'Extracted image SHA256 mismatch.' }
$vhd = Get-VHD -Path $newDisk
if ($vhd.VhdFormat -ne 'VHDX' -or $vhd.VhdType -ne 'Dynamic' -or $vhd.ParentPath -or
    $vhd.Attached -or $vhd.Size -ne $out.outputVirtualBytes) { throw 'Unexpected image format from Hyper-V.' }
if ($vhd.Size -lt 20GB) { Resize-VHD -Path $newDisk -SizeBytes 20GB }
$vhd = Get-VHD -Path $newDisk
if ($vhd.Size -ne 20GB -or $vhd.Attached) { throw 'Resized VHDX did not pass readback.' }
$record = [ordered]@{schema=1;sourceCommit=$SourceCommit;scriptSha256=$ExpectedScriptSha256;vmId=$VMId.ToString();
    originalManifestSha256=$OriginalManifestSha256;originalDisk=$originalDisk;originalDiskId=$original.diskId;
    artifact=$ArtifactId;imageCommit=$ImageCommit;buildRun=$BuildRunId;archiveSha256=$ArchiveSha256;
    imageManifestSha256=$ImageManifestSha256;imageSha256=$out.sha256;newDisk=$newDisk;newDiskId=[string]$vhd.DiskIdentifier;
    preparedDiskSha256=(Get-FileHash -LiteralPath $newDisk).Hash}
$preparedHash = Write-StageRecord (Join-Path $work '01-image-prepared.json') $record
$slot = Assert-OriginalAttachment
Set-VMHardDiskDrive -VMHardDiskDrive $slot -Path $newDisk
$vm = Get-VM -Id $VMId
$attached = @(Get-VMHardDiskDrive -VM $vm)
if ($vm.State -ne 'Off' -or $attached.Count -ne 1 -or $attached[0].Path -ne $newDisk -or
    @(Get-VMNetworkAdapter -VM $vm).Count -ne 0 -or !(Test-Path -LiteralPath $originalDisk)) {
    throw 'Disk switch requires inspection. Do not retry by name.'
}
$result = [ordered]@{state='ubuntu-disk-attached-off';vmId=$VMId.ToString();preparedSha256=$preparedHash;
    networkAdapters=0;disk=$newDisk;utc=[DateTime]::UtcNow.ToString('o')}
$resultHash = Write-StageRecord (Join-Path $work '02-attached-off.json') $result
[ordered]@{readback=$result;manifestSha256=$resultHash} | ConvertTo-Json
