param([string]$FixtureRoot)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$utf8=New-Object Text.UTF8Encoding($false)
function Read-Json([string]$p){Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json}
function Hash([string]$p){(Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash}
function Hash-Text([string]$s){$h=[Security.Cryptography.SHA256]::Create();try{([BitConverter]::ToString($h.ComputeHash($utf8.GetBytes($s)))).Replace('-','')}finally{$h.Dispose()}}
function Inside([string]$base,[string]$rel){$b=[IO.Path]::GetFullPath($base).TrimEnd('\');$p=[IO.Path]::GetFullPath((Join-Path $b $rel));if(!$p.StartsWith($b+'\',[StringComparison]::OrdinalIgnoreCase)){throw "Path escapes target: $rel"};return $p}
function Undo-Edits([string]$s,$edits){
 # Rebuild one official file by replaying the recorded edits backwards. Every replacement
 # span is confirmed in the current file, so a mismatch stops before anything is written.
 $builder=New-Object Text.StringBuilder;$position=0;$delta=0
 foreach($e in @($edits|Sort-Object start)){
  $start=[int]$e.start+$delta;[string]$replacement=$e.replacement
  if($start-lt$position){throw 'Edit list overlap'}
  if($start+$replacement.Length-gt$s.Length){throw 'Edit list exceeds the current file'}
  [void]$builder.Append($s,$position,$start-$position)
  if($s.Substring($start,$replacement.Length)-cne$replacement){throw 'Current file does not match the recorded replacement at the recorded offset'}
  [void]$builder.Append([string]$e.old)
  $position=$start+$replacement.Length;$delta+=$replacement.Length-([int]$e.end-[int]$e.start)
 }
 [void]$builder.Append($s,$position,$s.Length-$position)
 $builder.ToString()
}
function Catalog-Text($c){
 if($c.PSObject.Properties['payloadHash']-and (Hash (Inside $PSScriptRoot $c.payload))-ne $c.payloadHash){throw 'Chinese catalog payload corrupted; no backup rebuilt'}
 $v=Read-Json (Inside $PSScriptRoot $c.payload)
 if($c.PSObject.Properties['enRel']){
  $enFile=Inside $app $c.enRel;if((Hash $enFile)-ne $c.enHash){throw 'English catalog version mismatch; no backup rebuilt'}
  $en=Read-Json $enFile
  foreach($prop in $v.PSObject.Properties){$existing=$en.PSObject.Properties[$prop.Name];if(!$existing){throw ('Translation key absent from the current catalog: '+$prop.Name)};$existing.Value=$prop.Value}
  $v=$en
 }
 $v|ConvertTo-Json -Depth 100
}
$m=Read-Json (Join-Path $PSScriptRoot 'payload\manifest.json')
$fixture=![string]::IsNullOrEmpty($FixtureRoot)
if($fixture){
 $app=[IO.Path]::GetFullPath($FixtureRoot).TrimEnd('\')
 if(!(Test-Path -LiteralPath (Join-Path $app '.claude-han-fixture'))){throw 'Fixture marker missing; production installations cannot use FixtureRoot'}
 $state=Join-Path $app '.state';$configPaths=@(Join-Path $app 'user\config.json')
}else{
 $pkg=@(Get-AppxPackage -Name Claude);if($pkg.Count-ne 1){throw 'Expected one installed official Claude MSIX package for this user'};$pkg=$pkg[0]
 if($pkg.PackageFamilyName-ne $m.family-or $pkg.Version.ToString()-ne $m.packageVersion){throw "Unsupported version: $($pkg.Version). This package supports only $($m.packageVersion). No files changed."}
 $app=Join-Path $pkg.InstallLocation 'app';$state=Join-Path $env:LOCALAPPDATA ('ClaudeUIZh\'+$m.packageVersion)
 $pdat=Join-Path (Join-Path $env:LOCALAPPDATA 'Packages') $pkg.PackageFamilyName
 $configPaths=@((Join-Path $env:APPDATA 'Claude\config.json'),(Join-Path $env:APPDATA 'Claude-3p\config.json'),(Join-Path $pdat 'LocalCache\Roaming\Claude\config.json'),(Join-Path $pdat 'LocalCache\Roaming\Claude-3p\config.json'))
}
$mutexName='Local\ClaudeUIZh-'+$m.packageVersion;if($fixture){$mutexName+='-fixture-'+(Hash-Text $app).Substring(0,16)}
$mutex=[Threading.Mutex]::new($false,$mutexName)
$locked=$false
New-Item -ItemType Directory -Path $state -Force | Out-Null
$journalPath=Join-Path $state 'journal.json'
$log=Join-Path $state ('Rebuild-'+(Get-Date -Format yyyyMMdd-HHmmss)+'.log')
Start-Transcript -LiteralPath $log -Force | Out-Null
try{
 $locked=$mutex.WaitOne(0);if(!$locked){throw 'Another installer, restorer or rebuild is running'}
 if(Test-Path -LiteralPath $journalPath){$j=Read-Json $journalPath;throw "A local journal already exists (state: $($j.phase)): $journalPath. Rebuild runs only when it is missing. No files changed."}
 # Nothing is written to $state until every installed byte and every rebuilt original has been checked.
 $planned=New-Object Collections.Generic.List[object]
 foreach($patch in $m.patches){
  $p=Inside $app $patch.relative
  if(!(Test-Path -LiteralPath $p)){throw "Installed resource missing: $($patch.relative). No backup rebuilt."}
  if((Hash $p)-ne $patch.after){throw "Installed resource differs from this package: $($patch.relative). No backup rebuilt."}
  $original=Undo-Edits ([IO.File]::ReadAllText($p,$utf8)) $patch.edits
  if((Hash-Text $original)-ne $patch.before){throw "Rebuilt original does not match the official hash: $($patch.relative). No backup rebuilt."}
  $planned.Add(@{relative=$patch.relative;existed=$true;before=$patch.before;after=$patch.after;text=$original})
 }
 foreach($c in @($m.catalogs)+@($m.statsig)){
  $p=Inside $app $c.target
  if(!(Test-Path -LiteralPath $p)){throw "Installed catalog missing: $($c.target). No backup rebuilt."}
  $after=Hash-Text (Catalog-Text $c)
  if((Hash $p)-ne $after){throw "Installed catalog differs from this package: $($c.target). No backup rebuilt."}
  # These catalogs did not exist before the installer ran, so restoring removes them.
  $planned.Add(@{relative=$c.target;existed=$false;before='';after=$after;text=$null})
 }
 $configRecords=@()
 for($i=0;$i-lt$configPaths.Count;$i++){
  $p=$configPaths[$i]
  if(!(Test-Path -LiteralPath $p)){$configRecords+=@(@{index=$i;existed=$false;hadLocale=$false;locale=$null});continue}
  $v=Read-Json $p
  $hasLocale=[bool]$v.PSObject.Properties['locale']
  if($hasLocale-and [string]$v.locale-ne 'zh-CN'){throw "Unexpected locale value in $p. No backup rebuilt."}
  # A file holding only our locale field is one this installer created; the locale field
  # itself was added by the installer, so no earlier value can be recovered.
  $other=@($v.PSObject.Properties|Where-Object{$_.Name-ne 'locale'}).Count
  $configRecords+=@(@{index=$i;existed=[bool]($other-gt 0);hadLocale=$false;locale=$null})
 }
 $backup=Join-Path $state ('backup-'+(Get-Date -Format yyyyMMdd-HHmmss)+'-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
 New-Item -ItemType Directory -Path $backup -Force|Out-Null
 $aclMap=@{};$files=@();$done=0
 foreach($r in $planned){
  $p=Inside $app $r.relative;$b=$null
  if($r.existed){
   $aclMap[$r.relative]=(Get-Acl -LiteralPath $p).Sddl
   $b=(Split-Path -Leaf $backup)+'\'+$r.relative;$bp=Inside $state $b
   New-Item -ItemType Directory -Path (Split-Path $bp -Parent) -Force|Out-Null
   [IO.File]::WriteAllText($bp,$r.text,$utf8)
   if((Hash $bp)-ne $r.before){throw ('Rebuilt backup hash mismatch: '+$r.relative)}
  }
  $d=Split-Path $p -Parent;$rel=if($d-eq $app){'.'}else{$d.Substring($app.Length+1)};$aclMap[$rel]=(Get-Acl -LiteralPath $d).Sddl
  $files+=@(@{relative=$r.relative;existed=[bool]$r.existed;backup=$b;before=$r.before;after=$r.after})
  $done++;if($done%100-eq 0){Write-Output "Rebuilding backup: $done / $($planned.Count)"}
 }
 $aclRecords=@();foreach($key in $aclMap.Keys){$aclRecords+=@(@{relative=$key;sddl=$aclMap[$key]})}
 $journal=[pscustomobject]@{schema=1;version=$m.packageVersion;phase='installed';utc=[DateTime]::UtcNow.ToString('o');backupSource='reconstructed-from-manifest';files=$files;acls=$aclRecords;configs=$configRecords;createdDirs=@();temps=@()}
 [IO.File]::WriteAllText($journalPath,($journal|ConvertTo-Json -Depth 100),$utf8)
 # Re-read what was written and check it the way Verify.cmd does before reporting success.
 $check=Read-Json $journalPath
 if($check.phase-ne 'installed'){throw 'Journal self-check failed'}
 foreach($r in $check.files){
  $p=Inside $app $r.relative
  if(!(Test-Path -LiteralPath $p)-or(Hash $p)-ne $r.after){throw ('Journal self-check failed, installed resource: '+$r.relative)}
  if($r.existed-and(Hash (Inside $state $r.backup))-ne $r.before){throw ('Journal self-check failed, rebuilt backup: '+$r.relative)}
 }
 foreach($a in $check.acls){$p=if($a.relative-eq '.'){$app}else{Inside $app $a.relative};if((Get-Acl -LiteralPath $p).Sddl-ne $a.sddl){throw ('Journal self-check failed, access rule: '+$a.relative)}}
 Write-Output ("Rebuilt the local backup and journal: $($files.Count) resources recorded, $(@($m.patches).Count) official originals reconstructed and hash-verified, $(@($m.catalogs).Count+1) added catalogs recorded.")
 Write-Output 'No application file was modified by this action.'
 Write-Output "Backup: $state"
 Write-Output 'Status.cmd, Verify.cmd and Restore.cmd can be used again.'
}catch{
 throw
}finally{
 if($locked){$mutex.ReleaseMutex()};$mutex.Dispose();Stop-Transcript|Out-Null
}
