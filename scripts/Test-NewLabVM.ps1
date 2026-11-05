#requires -Version 5.1
[CmdletBinding()]
param([string]$ProvisionSource)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$useCheckout = !$ProvisionSource
if ($useCheckout) {
    $scriptFile = Join-Path $PSScriptRoot 'New-LabVM.ps1'
    $configFile = Join-Path (Split-Path $PSScriptRoot -Parent) 'config\lab.example.json'
    $ProvisionSource = Get-Content -LiteralPath $scriptFile -Raw
}
$tokens = $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($ProvisionSource, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "Provisioner parser errors: $($errors.Count)" }
$subject = $ast.GetScriptBlock()
$folder = 'C:\ProgramData\Codigo5\Labs\codigo5-agentes-lab'
$fixture = @{ diskGiB = 54; memoryGiB = 8; vmExists = $false; leafExists = $false; reparse = $false;
              version = '9.2'; service = 'Running'; fs = 'NTFS' }
function Get-VM { if ($fixture.vmExists) { [pscustomobject]@{ Name = 'codigo5-agentes-lab' } } }
function Get-VMHostSupportedVersion { [pscustomobject]@{Version = $fixture.version} }
function Get-Service { param($Name); [pscustomobject]@{Status = $fixture.service} }
function Get-CimInstance {
    param($ClassName, $Filter)
    switch ($ClassName) {
        'Win32_LogicalDisk' { [pscustomobject]@{DriveType = 3; FileSystem = $fixture.fs; FreeSpace = $fixture.diskGiB * 1GB} }
        'Win32_OperatingSystem' { [pscustomobject]@{FreePhysicalMemory = $fixture.memoryGiB * 1MB} }
        default { throw 'Unexpected CIM class' }
    }
}
function Test-Path {
    param($LiteralPath)
    if ($LiteralPath -eq $folder) { return $fixture.leafExists }
    $LiteralPath -in @('C:\ProgramData', 'C:\ProgramData\Codigo5', 'C:\ProgramData\Codigo5\Labs')
}
function Get-Item {
    param($LiteralPath, [switch]$Force)
    $attr = [IO.FileAttributes]::Directory
    if ($fixture.reparse) { $attr = $attr -bor [IO.FileAttributes]::ReparsePoint }
    [pscustomobject]@{ Attributes = $attr; PSIsContainer = $true }
}
function New-Item { throw 'WRITE TRAP' }
function New-VHD { throw 'WRITE TRAP' }
function New-VM { throw 'WRITE TRAP' }

$plan = & $subject | ConvertFrom-Json
if ($plan.mode -ne 'plan' -or $plan.requiredFreeGiB -ne 53 -or $plan.root -ne $folder -or
    $plan.networkAdapters -ne 0 -or $plan.staticMemoryGiB -ne 2 -or $plan.diskLimitGiB -ne 20 -or
    $plan.vmConfigurationVersion -ne '9.2' -or $plan.secureBoot -ne 'MicrosoftUEFICertificateAuthority') {
    throw 'Default dry-run plan differs from the expected offline VM budget.'
}
function Assert-Blocked($Field, $Value, $Message) {
    $saved = $fixture[$Field]
    $fixture[$Field] = $Value
    try {
        $caught = $null
        try { $null = & $subject } catch { $caught = $_.Exception.Message }
        if (!$caught -or !$caught.Contains($Message)) { throw "Expected refusal of fixture $Field (got '$caught')." }
    } finally { $fixture[$Field] = $saved }
}
Assert-Blocked diskGiB 52.99 'at least 53 GiB'
Assert-Blocked memoryGiB 3.99 'Insufficient free memory'
Assert-Blocked vmExists $true 'VM name is already registered'
Assert-Blocked leafExists $true 'Target directory exists'
Assert-Blocked reparse $true 'reparse point'
Assert-Blocked version '8.0' 'requires Hyper-V VM configuration version'
Assert-Blocked service 'Stopped' 'service must be running'
Assert-Blocked fs 'FAT32' 'NTFS'
$fixture.diskGiB = 53
$boundary = & $subject | ConvertFrom-Json
if ($boundary.requiredFreeGiB -ne $boundary.observedFreeGiB) { throw 'Exact budget boundary rejected.' }
function Assert-ApplyBlocked($Runner, [hashtable]$Options, [string]$Message) {
    $caught = $null
    try { $null = & $Runner -Apply @Options } catch { $caught = $_.Exception.Message }
    if (!$caught -or !$caught.Contains($Message)) { throw "Expected provenance refusal '$Message' (got '$caught')." }
}
Assert-ApplyBlocked $subject @{} 'Apply requires the reviewed script/config files'
if (!$useCheckout) {
    'OK: in-memory parser, 2 plans, 8 host refusals and missing provenance. File digest tests require checkout mode.'
    return
}
$scriptDigest = (Get-FileHash -LiteralPath $scriptFile -Algorithm SHA256).Hash
$configDigest = (Get-FileHash -LiteralPath $configFile -Algorithm SHA256).Hash
$release = @{
    ExpectedScriptSha256 = ('0' * 64); ExpectedConfigSha256 = $configDigest
    ConfigPath = $configFile; SourceCommit = ('1' * 40)
}
Assert-ApplyBlocked $scriptFile $release 'File SHA256 differs from release'
$release.ExpectedScriptSha256 = $scriptDigest
$release.ExpectedConfigSha256 = '0' * 64
Assert-ApplyBlocked $scriptFile $release 'Config SHA256 differs from release'
$release.ExpectedConfigSha256 = $configDigest
$release.CpuCount = 1
Assert-ApplyBlocked $scriptFile $release 'Resource plan differs from release configuration'
'OK: checkout parser, 2 plans, 8 host refusals and 4 provenance/configuration refusals.'
