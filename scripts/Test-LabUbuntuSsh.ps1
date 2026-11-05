#requires -Version 5.1
# Authenticated guest readback only. Finds this VM's IP through Hyper-V or its MAC.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][guid]$VMId,
    [ValidatePattern('^[A-Za-z][A-Za-z0-9-]{0,39}$')][string]$VMName='codigo5-agentes-lab',
    [Parameter(Mandatory)][ValidatePattern('^[1-9][0-9]{0,19}$')][string]$ArtifactId,
    [Parameter(Mandatory)][guid]$DefaultSwitchId,
    [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedSeedReceiptSha256
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$guest="C:\ProgramData\Codigo5\Labs\$VMName\ubuntu-$ArtifactId\first-boot"
$seedPath=Join-Path $guest '01-seed-ready.json'
if((Get-FileHash -LiteralPath $seedPath).Hash -ne $ExpectedSeedReceiptSha256){throw 'Guest identity receipt SHA256 mismatch.'}
$seed=Get-Content -Raw -LiteralPath $seedPath|ConvertFrom-Json
$started=Get-Content -Raw -LiteralPath (Join-Path $guest '02-started.json')|ConvertFrom-Json
$vm=Get-VM -Id $VMId
$adapters=@(Get-VMNetworkAdapter -VM $vm)
if($seed.vmId -ne $VMId.ToString() -or $started.vmId -ne $VMId.ToString() -or
    $seed.instanceId -ne ('codigo5-'+$VMId.ToString()) -or $vm.Name -ne $VMName -or
    $vm.State -ne 'Running' -or $adapters.Count -ne 1 -or $adapters[0].SwitchId -ne $DefaultSwitchId -or
    $seed.switchId -ne $DefaultSwitchId.ToString()){throw 'Unexpected guest, NIC or switch.'}
$known=Join-Path $guest 'known_hosts'
$key=Join-Path $guest 'client_ed25519'
if([IO.File]::ReadAllText($known).Trim() -cne ('codigo5-lab-guest '+$seed.hostPublic)){
    throw 'Guest host-key pin differs from its provisioned value.'
}
$sw=Get-VMSwitch -Id $DefaultSwitchId
if($sw.Name -ne 'Default Switch' -or $sw.SwitchType -ne 'Internal'){throw 'Unexpected switch.'}
$ifIndex=(Get-NetAdapter -Name ('vEthernet ('+$sw.Name+')')).ifIndex
$hostIps=@(Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 | Where-Object AddressState -eq 'Preferred')
if($hostIps.Count -ne 1){throw 'Could not identify one active host subnet.'}
$hostBytes=([Net.IPAddress]::Parse($hostIps[0].IPAddress)).GetAddressBytes()
$prefix=$hostIps[0].PrefixLength
function Test-GuestAddress($Address) {
    $ip=$null
    if(![Net.IPAddress]::TryParse([string]$Address,[ref]$ip) -or
        $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
        $ip.ToString() -eq $hostIps[0].IPAddress){return $false}
    $bytes=$ip.GetAddressBytes()
    for($i=0;$i -lt $prefix;$i++){
        $idx=[int][math]::Floor($i/8)
        $mask=128 -shr ($i%8)
        if(($bytes[$idx] -band $mask) -ne ($hostBytes[$idx] -band $mask)){return $false}
    }
    return $true
}
$ips=@($adapters[0].IPAddresses | Where-Object {Test-GuestAddress $_} | Sort-Object -Unique)
$method='Hyper-V'
if(!$ips.Count){
    $method='neighbor-mac'
    $mac=$adapters[0].MacAddress.Replace('-','').Replace(':','')
    if($mac -notmatch '^[0-9a-fA-F]{12}$' -or $mac -eq '000000000000'){throw 'Guest MAC not ready.'}
    $ips=@(Get-NetNeighbor -InterfaceIndex $ifIndex -AddressFamily IPv4 |
        Where-Object {$_.State -in 'Reachable','Stale','Delay','Probe','Permanent' -and
          $_.LinkLayerAddress -and $_.LinkLayerAddress.Replace('-','').Replace(':','') -eq $mac -and
          (Test-GuestAddress $_.IPAddress)} | Select-Object -ExpandProperty IPAddress | Sort-Object -Unique)
}
if($ips.Count -ne 1){throw 'Guest IP pending or ambiguous. Repeat discovery without scanning.'}
$ssh=(Get-Command ssh.exe -CommandType Application).Source
$options=@('-T','-F','NUL','-i',$key,'-o','BatchMode=yes','-o','IdentitiesOnly=yes','-o','ConnectTimeout=8',
  '-o','StrictHostKeyChecking=yes','-o','HostKeyAlias=codigo5-lab-guest','-o','HostKeyAlgorithms=ssh-ed25519',
  '-o','UpdateHostKeys=no','-o','GlobalKnownHostsFile=NUL','-o',('UserKnownHostsFile='+$known))
$command='hostname; . /etc/os-release; echo $ID; echo $VERSION_ID; uname -m; cat /var/lib/cloud/data/instance-id; timeout 90 cloud-init status --wait'
# Capture only the expected, non-secret identification fields; discard SSH diagnostics.
$ErrorActionPreference='Continue'
$lines=@(& $ssh @options ('labops@'+$ips[0]) $command 2>$null)
$code=$LASTEXITCODE
$ErrorActionPreference='Stop'
if($code -ne 0){throw "Pinned SSH / cloud-init readback returned $code. Inspect without loosening verification."}
foreach($value in @('agentes-lab','ubuntu','24.04','x86_64',$seed.instanceId)){
    if($value -cnotin $lines){throw 'Authenticated guest identity differs from the expected Ubuntu instance.'}
}
if(!(($lines -join ' ') -match 'status:\s*done')){throw 'Cloud-init completion was not observed.'}
[ordered]@{vmId=$VMId.ToString();instance=$seed.instanceId;ipv4=$ips[0];discovery=$method;ssh='pinned';
    distribution='Ubuntu';version='24.04';architecture='x86_64';cloudInit='done'}|ConvertTo-Json
