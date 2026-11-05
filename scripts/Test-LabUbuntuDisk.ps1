#requires -Version 5.1
# Dry-run fixture. All Hyper-V reads are mocked; disk I/O uses a private fixture ZIP in TEMP.
[CmdletBinding()]
param([string]$SourceText)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if (!$SourceText) { $SourceText = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Set-LabUbuntuDisk.ps1') -Raw }
$runner=[scriptblock]::Create($SourceText)
Add-Type -AssemblyName System.IO.Compression
$fixtureZip=[IO.Path]::Combine([IO.Path]::GetTempPath(), [guid]::NewGuid().ToString()+'.zip')
$id=[guid]::NewGuid()
$root='C:\ProgramData\Codigo5\Labs\synthetic'
$originalPath=$root+'\system.vhdx'
$oldHash='8'*64
$oldDiskId=[guid]::NewGuid().ToString()
$imageCommit='a'*40
$data=[Text.Encoding]::UTF8.GetBytes('synthetic payload')
$image=[ordered]@{schema=1;sourceCommit=$imageCommit;workflowRun='41';output=[ordered]@{
    file='ubuntu-noble-amd64.vhdx';fileBytes=$data.Length;sha256=('2'*64);qemuCompare='passed';
    conversionSubformat='dynamic';sourceVirtualBytes=1GB;outputVirtualBytes=1GB}}
$meta=[Text.Encoding]::UTF8.GetBytes(($image|ConvertTo-Json -Depth 4))
$original=@{state='verified-off';vmId=$id.ToString();name='synthetic';root=$root;disk=$originalPath;
    diskId=$oldDiskId;diskSha256BeforeFirstBoot=$oldHash}
$freeBytes=54GB
$hasNic=$false
function Join-Path($Path,$ChildPath) {
    if ($ChildPath -like 'artifact-*.zip') { return $fixtureZip }
    Microsoft.PowerShell.Management\Join-Path $Path $ChildPath
}
function Test-Path { param($LiteralPath); $false }
function Get-Item { param($LiteralPath,[switch]$Force); [pscustomobject]@{Attributes=[IO.FileAttributes]::Normal} }
function Get-FileHash {
    param($LiteralPath,$InputStream)
    if ($null -ne $InputStream) { return Microsoft.PowerShell.Utility\Get-FileHash -InputStream $InputStream }
    if ($LiteralPath -eq $originalPath -or $LiteralPath -eq ($root+'\04-verified.json')) {
        return [pscustomobject]@{Hash=$oldHash}
    }
    throw 'Unexpected file read'
}
function Get-Content { param($LiteralPath,[switch]$Raw); $original | ConvertTo-Json }
function Get-VM { param($Id); [pscustomobject]@{Name='synthetic';State='Off';Generation=2;Version='9.2';ProcessorCount=2;MemoryStartup=2GB;DynamicMemoryEnabled=$false;AutomaticStartAction='Nothing';CheckpointType='Disabled';AutomaticCheckpointsEnabled=$false} }
function Get-VMSecurity { param($VM); [pscustomobject]@{TpmEnabled=$false} }
function Get-VMFirmware { param($VM); [pscustomobject]@{SecureBoot='On';SecureBootTemplate='MicrosoftUEFICertificateAuthority'} }
function Get-VMSnapshot { param($VM) }
function Get-VMNetworkAdapter { param($VM); if($hasNic){'fixture-adapter'} }
function Get-VMDvdDrive { param($VM) }
function Get-VMHardDiskDrive { param($VM); [pscustomobject]@{Path=$originalPath;ControllerType='SCSI';ControllerNumber=0;ControllerLocation=0} }
function Get-VHD { param($Path); [pscustomobject]@{DiskIdentifier=$oldDiskId} }
function Get-CimInstance { param($ClassName,$Filter); [pscustomobject]@{FreeSpace=$freeBytes} }
function New-Item { throw 'WRITE TRAP' }
function Set-VMHardDiskDrive { throw 'WRITE TRAP' }
function Resize-VHD { throw 'WRITE TRAP' }
function Assert-Refused($Options,$Message) {
    $errorMessage=$null
    try { $null = & $runner @Options } catch { $errorMessage=$_.Exception.Message }
    if (!$errorMessage -or !$errorMessage.Contains($Message)) {throw "Expected '$Message', got '$errorMessage'."}
}
try {
    $stream=[IO.File]::Open($fixtureZip,'CreateNew','Write','None')
    try {
        $zip=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create,$true)
        try {
            foreach ($entry in @('manifest.json','ubuntu-noble-amd64.vhdx')) {
                $s=$zip.CreateEntry($entry).Open()
                try { if($entry -eq 'manifest.json'){$s.Write($meta,0,$meta.Length)}else{$s.Write($data,0,$data.Length)} } finally {$s.Dispose()}
            }
        } finally {$zip.Dispose()}
    } finally {$stream.Dispose()}
    $metaStream=[IO.MemoryStream]::new($meta)
    try {$metaHash=(Microsoft.PowerShell.Utility\Get-FileHash -InputStream $metaStream).Hash} finally {$metaStream.Dispose()}
    $zipHash=(Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $fixtureZip).Hash
    $opts=@{VMId=$id;VMName='synthetic';OriginalManifestSha256=$oldHash;ImageCommit=$imageCommit;
        BuildRunId='41';ArtifactId='57';ArchiveSha256=$zipHash;ImageManifestSha256=$metaHash}
    $plan=& $runner @opts | ConvertFrom-Json
    if ($plan.mode -ne 'plan' -or $plan.vmId -ne $id.ToString() -or $plan.newLimitGiB -ne 20) { throw 'Fixture plan mismatch.' }
    $bad=$opts.Clone(); $bad.ArchiveSha256='0'*64; Assert-Refused $bad 'Archive hash or size mismatch'
    $bad=$opts.Clone(); $bad.ImageManifestSha256='0'*64; Assert-Refused $bad 'Image manifest hash mismatch'
    $bad=$opts.Clone(); $bad.BuildRunId='42'; Assert-Refused $bad 'trusted workflow'
    $bad=$opts.Clone(); $bad.VMId=[guid]::NewGuid(); Assert-Refused $bad 'trusted receipt'
    $hasNic=$true; Assert-Refused $opts 'isolation state'; $hasNic=$false
    $freeBytes=48GB; Assert-Refused $opts '49 GiB'
    'OK: offline disk plan and six fail-closed fixtures.'
} finally {
    if ([IO.File]::Exists($fixtureZip)) { [IO.File]::Delete($fixtureZip) }
}
