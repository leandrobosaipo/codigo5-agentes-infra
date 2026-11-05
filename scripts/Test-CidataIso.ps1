#requires -Version 5.1
# Hosted Windows runner: harmless content only; no Hyper-V or drive mounts.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$dir=Join-Path ([IO.Path]::GetTempPath()) ('cidata-fixture-'+[guid]::NewGuid())
$null=New-Item -ItemType Directory -Path $dir
$seed=Join-Path $dir 'seed'
$null=New-Item -ItemType Directory -Path $seed
$iso=Join-Path $dir 'fixture.iso'
$writer=Join-Path $PSScriptRoot 'New-CidataIso.ps1'
try {
    [IO.File]::WriteAllText((Join-Path $seed 'user-data'),"#cloud-config"+[char]10+"hostname: synthetic"+[char]10)
    [IO.File]::WriteAllText((Join-Path $seed 'meta-data'),"instance-id: synthetic"+[char]10)
    $plan=& $writer -SeedFiles $seed -IsoFile $iso
    if($plan.mode -ne 'plan' -or [IO.File]::Exists($iso)){throw 'Unexpected effect in dry-run.'}
    $result=& $writer -SeedFiles $seed -IsoFile $iso -Apply
    if($result.label -cne 'CIDATA' -or $result.files -ne 2 -or $result.sha256 -ne (Get-FileHash $iso).Hash) {
        throw 'Fixture ISO readback failed.'
    }
    $rejected=$false
    try { $null=& $writer -SeedFiles $seed -IsoFile $iso -Apply } catch {$rejected=$_.Exception.Message -like 'Expected exactly two*'}
    if(!$rejected){throw 'Existing ISO was not refused.'}
    'OK: CIDATA PVD, Joliet paths, exact file bytes and collision handling.'
} finally {
    foreach ($name in @('user-data','meta-data')) {
        $path=Join-Path $seed $name
        if([IO.File]::Exists($path)){[IO.File]::Delete($path)}
    }
    if([IO.File]::Exists($iso)){[IO.File]::Delete($iso)}
    [IO.Directory]::Delete($seed,$false)
    [IO.Directory]::Delete($dir,$false)
}
