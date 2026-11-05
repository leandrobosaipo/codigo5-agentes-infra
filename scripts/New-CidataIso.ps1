#requires -Version 5.1
# Copies two private NoCloud files into a new ISO. The caller owns the directory ACL.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$SeedFiles,[Parameter(Mandatory)][string]$IsoFile,[switch]$Apply)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$names=@('user-data','meta-data')
$entries=@(Get-ChildItem -LiteralPath $SeedFiles -Force)
if ($entries.Count -ne 2 -or (Test-Path -LiteralPath $IsoFile)) { throw 'Expected exactly two seed files and an unused ISO path.' }
foreach ($entry in $entries) {
    if ($entry.Name -cnotin $names -or $entry.PSIsContainer -or $entry.Length -gt 64KB -or
        $entry.Length -lt 1 -or ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Unexpected NoCloud seed input.'
    }
}
if (!$Apply) { [pscustomobject]@{mode='plan';label='CIDATA';files=2};return }
if (!( 'Codigo5IsoWriter' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
public static class Codigo5IsoWriter {
    public static void Write(object source, string path, int bytes) {
        var input = (IStream)source;
        var read = Marshal.AllocHGlobal(4);
        try {
            using (var file = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None)) {
                var buffer = new byte[32768];
                int total = 0;
                while (total < bytes) {
                    input.Read(buffer, Math.Min(buffer.Length, bytes - total), read);
                    int count = Marshal.ReadInt32(read);
                    if (count < 1 || count > buffer.Length || total + count > bytes) throw new InvalidDataException("Invalid IMAPI stream");
                    file.Write(buffer, 0, count);
                    total += count;
                }
            }
        } finally { Marshal.FreeHGlobal(read); }
    }
}
'@
}
$fsi=New-Object -ComObject IMAPI2FS.MsftFileSystemImage
$fsi.FileSystemsToCreate=3
$fsi.VolumeName='CIDATA'
$fsi.Root.AddTree((Get-Item -LiteralPath $SeedFiles).FullName,$false)
$image=$fsi.CreateResultImage()
$length=[int64]$image.TotalBlocks * $image.BlockSize
if ($image.BlockSize -ne 2048 -or $length -le 0 -or $length -gt 4MB) { throw 'Unexpected IMAPI image size.' }
[Codigo5IsoWriter]::Write($image.ImageStream,$IsoFile,[int]$length)

# Read the PVD and Joliet directory directly. No drive is mounted and no seed
# text is emitted. Compare the exact data ranges with the original files.
$iso=[IO.File]::ReadAllBytes($IsoFile)
$ascii=[Text.Encoding]::ASCII
$joliet=-1
$label=$null
for($lba=16;$lba -lt 48;$lba++) {
    $pos=$lba*2048
    if ($pos+2048 -gt $iso.Length -or $ascii.GetString($iso,$pos+1,5) -ne 'CD001') { break }
    if ($iso[$pos] -eq 1) {$label=$ascii.GetString($iso,$pos+40,32).Trim()}
    if ($iso[$pos] -eq 2 -and $ascii.GetString($iso,$pos+88,2) -eq '%/') {$joliet=$pos}
    if ($iso[$pos] -eq 255) {break}
}
if ($label -cne 'CIDATA' -or $joliet -lt 0) {throw 'Missing CIDATA label or Joliet directory.'}
$root=$joliet+156
$start=[int64][BitConverter]::ToUInt32($iso,$root+2)*2048
$end=$start+[BitConverter]::ToUInt32($iso,$root+10)
if ($start -le 0 -or $end -gt $iso.Length) {throw 'Invalid ISO root extent.'}
$found=@()
for ($p=$start;$p -lt $end;) {
    $record=$iso[$p]
    if ($record -eq 0) {$p=([math]::Floor($p/2048)+1)*2048;continue}
    $nameLength=$iso[($p+32)]
    if ($record -lt 34 -or $p+$record -gt $end -or 33+$nameLength -gt $record) {throw 'Invalid ISO directory record.'}
    if ($nameLength -gt 1) {
        $name=[Text.Encoding]::BigEndianUnicode.GetString($iso,$p+33,$nameLength) -creplace ';1$',''
        if ($name -cnotin $names -or $name -cin $found) {throw 'Unexpected or duplicated seed filename.'}
        $offset=[int64][BitConverter]::ToUInt32($iso,$p+2)*2048
        $size=[BitConverter]::ToUInt32($iso,$p+10)
        if ($offset+$size -gt $iso.Length -or $size -gt 64KB) {throw 'Invalid seed extent.'}
        $hasher=[Security.Cryptography.SHA256]::Create()
        try {$actual=[BitConverter]::ToString($hasher.ComputeHash($iso,[int]$offset,[int]$size)).Replace('-','')}
        finally {$hasher.Dispose()}
        if ((Get-FileHash -LiteralPath (Join-Path $SeedFiles $name)).Hash -ne $actual) {throw 'Seed file readback mismatch.'}
        $found+=$name
    }
    $p+=$record
}
if ($found.Count -ne 2) {throw 'Seed readback is incomplete.'}
[pscustomobject]@{label=$label;files=$found.Count;bytes=$length;sha256=(Get-FileHash -LiteralPath $IsoFile).Hash}
