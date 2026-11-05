#requires -Version 5.1
<#
.SYNOPSIS
Plan the first boot of the offline Ubuntu lab. Apply requires pinned source hashes.
.DESCRIPTION
This stage creates new, private guest keys on Windows, a CIDATA disc, one NIC on
the identified internal Default Switch, and starts only the VM from the disk receipt.
On failure preserve the stage and inspect its receipt, devices, and VM state.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][guid]$VMId,
    [ValidatePattern('^[A-Za-z][A-Za-z0-9-]{0,39}$')][string]$VMName='codigo5-agentes-lab',
    [Parameter(Mandatory)][ValidatePattern('^[1-9][0-9]{0,19}$')][string]$ArtifactId,
    [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$AttachedReceiptSha256,
    [Parameter(Mandatory)][guid]$DefaultSwitchId,
    [ValidatePattern('^[a-f0-9]{40}$')][string]$SourceCommit,
    [ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedScriptSha256,
    [ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedIsoHelperSha256,
    [switch]$Apply
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$lab=Join-Path 'C:\ProgramData\Codigo5\Labs' $VMName
$stage=Join-Path $lab "ubuntu-$ArtifactId"
$guest=Join-Path $stage 'first-boot'
$readyPath=Join-Path $stage '02-attached-off.json'
$diskPath=Join-Path $stage 'ubuntu-noble-amd64.vhdx'
$preparedPath=Join-Path $stage '01-image-prepared.json'
function Check-Guest {
    $vm=Get-VM -Id $VMId
    $drives=@(Get-VMHardDiskDrive -VM $vm)
    $firmware=Get-VMFirmware -VM $vm
    if($vm.Name -ne $VMName -or $vm.State -ne 'Off' -or $vm.Generation -ne 2 -or
       $vm.ProcessorCount -ne 2 -or $vm.MemoryStartup -ne 2GB -or $vm.DynamicMemoryEnabled -or
       $vm.CheckpointType -ne 'Disabled' -or $vm.AutomaticStartAction -ne 'Nothing' -or
       $firmware.SecureBoot -ne 'On' -or $firmware.SecureBootTemplate -ne 'MicrosoftUEFICertificateAuthority' -or
       $drives.Count -ne 1 -or $drives[0].Path -ne $diskPath -or
       @(Get-VMNetworkAdapter -VM $vm).Count -or @(Get-VMDvdDrive -VM $vm).Count -or @(Get-VMSnapshot -VM $vm).Count){
        throw 'Expected a verified, disconnected, stopped VM with its Ubuntu disk.'
    }
    $vm
}
function New-PrivateKey([string]$Path) {
    $info=[Diagnostics.ProcessStartInfo]::new()
    $info.FileName=(Get-Command ssh-keygen.exe -CommandType Application).Source
    $info.Arguments='-q -t ed25519 -N "" -C codigo5-lab -f "'+$Path+'"'
    $info.UseShellExecute=$false
    $info.RedirectStandardOutput=$true
    $info.RedirectStandardError=$true
    $proc=[Diagnostics.Process]::Start($info)
    try {
        if(!$proc.WaitForExit(25000) -or $proc.ExitCode -ne 0){throw 'Could not generate a fresh lab key.'}
    } finally {$proc.Dispose()}
    $public=[IO.File]::ReadAllText($Path+'.pub').Trim()
    if($public -notmatch '^ssh-ed25519 [A-Za-z0-9+/]+={0,2}( |$)'){throw 'Unexpected public key encoding.'}
    $public
}
function Write-NewText([string]$Path,[string]$Text) {
    $b=[Text.UTF8Encoding]::new($false).GetBytes($Text)
    $f=[IO.File]::Open($Path,'CreateNew','Write','None')
    try{$f.Write($b,0,$b.Length)}finally{$f.Dispose()}
}
foreach($p in @('C:\ProgramData','C:\ProgramData\Codigo5','C:\ProgramData\Codigo5\Labs',$lab,$stage,$readyPath,$preparedPath,$diskPath)){
    if((Get-Item -LiteralPath $p -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Unexpected reparse point.'}
}
if(Test-Path -LiteralPath $guest){throw 'First boot directory exists. Reconcile before another operation.'}
if((Get-FileHash -LiteralPath $readyPath).Hash -ne $AttachedReceiptSha256){throw 'Attached disk receipt hash mismatch.'}
$ready=Get-Content -Raw -LiteralPath $readyPath|ConvertFrom-Json
if($ready.vmId -ne $VMId.ToString() -or $ready.state -ne 'ubuntu-disk-attached-off' -or $ready.disk -ne $diskPath -or
   (Get-FileHash -LiteralPath $preparedPath).Hash -ne $ready.preparedSha256){throw 'Disk receipt chain mismatch.'}
$prepared=Get-Content -Raw -LiteralPath $preparedPath|ConvertFrom-Json
$vhd=Get-VHD -Path $diskPath
if($prepared.vmId -ne $VMId.ToString() -or $prepared.newDisk -ne $diskPath -or [string]$vhd.DiskIdentifier -ne $prepared.newDiskId -or
   $vhd.VhdType -ne 'Dynamic' -or $vhd.Size -ne 20GB -or (Get-FileHash -LiteralPath $diskPath).Hash -ne $prepared.preparedDiskSha256){
    throw 'Guest storage changed since the offline readback.'
}
$vm=Check-Guest
$switch=Get-VMSwitch -Id $DefaultSwitchId
if($switch.Name -ne 'Default Switch' -or $switch.SwitchType -ne 'Internal'){throw 'Expected the identified internal Default Switch.'}
$volume=Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
if($volume.FreeSpace -lt (25GB + 4GB + 20GB - $vhd.FileSize) -or
   (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory -lt 4MB){throw 'Guest boot budget is unavailable.'}
if(!$Apply){[ordered]@{mode='plan';vmId=$VMId.ToString();switchId=$switch.Id.ToString();stage='first-boot';user='labops'}|ConvertTo-Json;return}
$helper=Join-Path $PSScriptRoot 'New-CidataIso.ps1'
if(!$SourceCommit -or !$ExpectedScriptSha256 -or !$ExpectedIsoHelperSha256 -or
   (Get-FileHash -LiteralPath $PSCommandPath).Hash -ne $ExpectedScriptSha256 -or (Get-FileHash -LiteralPath $helper).Hash -ne $ExpectedIsoHelperSha256){
    throw 'Unverified boot script or IMAPI helper.'
}
$owner=[Security.Principal.WindowsIdentity]::GetCurrent().User
$system=[Security.Principal.SecurityIdentifier]::new('S-1-5-18')
$acl=[Security.AccessControl.DirectorySecurity]::new()
$acl.SetOwner($owner);$acl.SetAccessRuleProtection($true,$false)
foreach($sid in @($owner,$system)){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow'))}
$null=New-Item -ItemType Directory -Path $guest
Set-Acl -LiteralPath $guest -AclObject $acl
$checkAcl=Get-Acl -LiteralPath $guest
if(!$checkAcl.AreAccessRulesProtected -or $checkAcl.Access.Count -ne 2){throw 'Private seed ACL is not in place.'}
$files=Join-Path $guest 'cidata-input'
$null=New-Item -ItemType Directory -Path $files
$clientKey=Join-Path $guest 'client_ed25519'
$hostKey=Join-Path $guest 'guest_host_ed25519'
$clientPublic=New-PrivateKey $clientKey
$hostPublic=New-PrivateKey $hostKey
$indented=([IO.File]::ReadAllLines($hostKey) | ForEach-Object {'    '+$_}) -join [char]10
$instance='codigo5-'+$VMId.ToString()
$config=@(
    '#cloud-config','hostname: agentes-lab','manage_etc_hosts: true','users:','  - name: labops',
    '    lock_passwd: true','    groups: [sudo]','    sudo: ["ALL=(ALL) NOPASSWD:ALL"]','    shell: /bin/bash',
    '    ssh_authorized_keys:',('      - '+$clientPublic),'disable_root: true','ssh_pwauth: false',
    'ssh_deletekeys: true','ssh_genkeytypes: []','ssh_keys:','  ed25519_private: |',$indented,
    ('  ed25519_public: '+$hostPublic),'ssh_publish_hostkeys: {enabled: false}',
    'package_update: false','package_upgrade: false',''
) -join [char]10
Write-NewText (Join-Path $files 'user-data') $config
Write-NewText (Join-Path $files 'meta-data') (('instance-id: '+$instance)+[char]10+'local-hostname: agentes-lab'+[char]10)
Write-NewText (Join-Path $guest 'known_hosts') ('codigo5-lab-guest '+$hostPublic+[char]10)
$iso=Join-Path $guest 'cidata.iso'
$isoResult=& $helper -SeedFiles $files -IsoFile $iso -Apply
$vmSid=[Security.Principal.NTAccount]::new('NT VIRTUAL MACHINE',$VMId.ToString()).Translate([Security.Principal.SecurityIdentifier])
$isoAcl=Get-Acl -LiteralPath $iso
$isoAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($vmSid,'Read','Allow'))
Set-Acl -LiteralPath $iso -AclObject $isoAcl
$record=[ordered]@{schema=1;vmId=$VMId.ToString();instanceId=$instance;switchId=$switch.Id.ToString();
    sourceCommit=$SourceCommit;scriptSha256=$ExpectedScriptSha256;helperSha256=$ExpectedIsoHelperSha256;diskReceipt=$AttachedReceiptSha256;
    isoSha256=$isoResult.sha256;hostPublic=$hostPublic;user='labops';knownHostsAlias='codigo5-lab-guest'}
Write-NewText (Join-Path $guest '01-seed-ready.json') ($record|ConvertTo-Json)
$seedRecordHash=(Get-FileHash -LiteralPath (Join-Path $guest '01-seed-ready.json')).Hash
$vm=Check-Guest
Add-VMDvdDrive -VM $vm -ControllerNumber 0 -ControllerLocation 1 -Path $iso
Add-VMNetworkAdapter -VM $vm -Name 'lab-private' -SwitchName $switch.Name
$drive=@(Get-VMHardDiskDrive -VM $vm)[0]
Set-VMFirmware -VM $vm -FirstBootDevice $drive
$dvd=@(Get-VMDvdDrive -VM $vm)
$net=@(Get-VMNetworkAdapter -VM $vm)
if($dvd.Count -ne 1 -or $dvd[0].Path -ne $iso -or $net.Count -ne 1 -or $net[0].SwitchId -ne $DefaultSwitchId){
    throw 'Boot devices changed. Inspect before starting.'
}
Start-VM -VM $vm
$vm=Get-VM -Id $VMId
if($vm.State -ne 'Running'){throw 'VM start uncertain. Inspect without repeating.'}
$result=[ordered]@{vmId=$VMId.ToString();state='Running';instanceId=$instance;seedSha256=$isoResult.sha256;
    seedReceiptSha256=$seedRecordHash;sshStatus='pending';utc=[DateTime]::UtcNow.ToString('o')}
Write-NewText (Join-Path $guest '02-started.json') ($result|ConvertTo-Json)
$result|ConvertTo-Json
