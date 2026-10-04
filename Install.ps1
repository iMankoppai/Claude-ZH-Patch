param([ValidateSet('Install','Restore','Status')][string]$Action='Install',[string]$FixtureRoot,[switch]$NoLaunch)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$utf8=New-Object Text.UTF8Encoding($false)
function Read-Json([string]$p){Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json}
function Remove-Temporary([string]$p){if(Test-Path -LiteralPath $p){$a=Get-Acl -LiteralPath $p;$a.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.WindowsIdentity]::GetCurrent().User,'FullControl','Allow'));Set-Acl -LiteralPath $p -AclObject $a;Remove-Item -LiteralPath $p -Force}}
function Replace-Temporary([string]$temp,[string]$p){
 $exists=Test-Path -LiteralPath $p;$prior=if($exists){(Get-Acl -LiteralPath $p).Sddl}else{(Get-Acl -LiteralPath $temp).Sddl}
 # MSIX child files inherit read-only access, even when their parent has a temporary non-inheriting write rule.
 $a=Get-Acl -LiteralPath $temp;$a.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.WindowsIdentity]::GetCurrent().User,'FullControl','Allow'));Set-Acl -LiteralPath $temp -AclObject $a
 if($exists){[IO.File]::Replace($temp,$p,[NullString]::Value)}else{[IO.File]::Move($temp,$p)}
 $a=Get-Acl -LiteralPath $p;$a.SetSecurityDescriptorSddlForm($prior,[Security.AccessControl.AccessControlSections]::Access);Set-Acl -LiteralPath $p -AclObject $a
}
function Atomic-Text([string]$p,[string]$s,[string]$temp){
 if(Test-Path -LiteralPath $temp){throw 'Unexpected temporary file exists'}
 try{[IO.File]::WriteAllText($temp,$s,$utf8);Replace-Temporary $temp $p}finally{Remove-Temporary $temp}
}
function Save-Json([string]$p,$v){Atomic-Text $p ($v|ConvertTo-Json -Depth 100) ($p+'.claude-han-'+[Guid]::NewGuid().ToString('N')+'.tmp')}
function Hash([string]$p){(Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash}
function Hash-Text([string]$s){$h=[Security.Cryptography.SHA256]::Create();try{([BitConverter]::ToString($h.ComputeHash($utf8.GetBytes($s)))).Replace('-','')}finally{$h.Dispose()}}
function Inside([string]$base,[string]$rel){$b=[IO.Path]::GetFullPath($base).TrimEnd('\');$p=[IO.Path]::GetFullPath((Join-Path $b $rel));if(!$p.StartsWith($b+'\',[StringComparison]::OrdinalIgnoreCase)){throw "Path escapes target: $rel"};return $p}
$m=Read-Json (Join-Path $PSScriptRoot 'payload\manifest.json')
$fixture=![string]::IsNullOrEmpty($FixtureRoot)
if($fixture){
 $app=[IO.Path]::GetFullPath($FixtureRoot).TrimEnd('\')
 if(!(Test-Path -LiteralPath (Join-Path $app '.claude-han-fixture'))){throw 'Fixture marker missing; production installations cannot use FixtureRoot'}
 $state=Join-Path $app '.state';$pkg=$null;$configPaths=@(Join-Path $app 'user\config.json')
}else{
 $pkg=@(Get-AppxPackage -Name Claude);if($pkg.Count-ne 1){throw 'Expected one installed official Claude MSIX package for this user'};$pkg=$pkg[0]
 if($pkg.PackageFamilyName-ne $m.family -or $pkg.Version.ToString()-ne $m.packageVersion){throw "Unsupported version: $($pkg.Version). This package supports only $($m.packageVersion). No files changed."}
 $app=Join-Path $pkg.InstallLocation 'app';$state=Join-Path $env:LOCALAPPDATA ('ClaudeUIZh\'+$m.packageVersion)
 $pdat=Join-Path (Join-Path $env:LOCALAPPDATA 'Packages') $pkg.PackageFamilyName
 $configPaths=@((Join-Path $env:APPDATA 'Claude\config.json'),(Join-Path $env:APPDATA 'Claude-3p\config.json'),(Join-Path $pdat 'LocalCache\Roaming\Claude\config.json'),(Join-Path $pdat 'LocalCache\Roaming\Claude-3p\config.json'))
}
New-Item -ItemType Directory -Path $state -Force | Out-Null
$journalPath=Join-Path $state 'journal.json';$log=Join-Path $state ($Action+'-'+(Get-Date -Format yyyyMMdd-HHmmss)+'.log')
Start-Transcript -LiteralPath $log -Force | Out-Null
$journal=$null;if(Test-Path -LiteralPath $journalPath){$journal=Read-Json $journalPath}
$mutexName='Local\ClaudeUIZh-'+$m.packageVersion;if($fixture){$mutexName+='-fixture-'+(Hash-Text $app).Substring(0,16)}
$mutex=[Threading.Mutex]::new($false,$mutexName)
$locked=$false;$aclRecords=@();$configRecords=@();$wrote=$false
function Verify-Core{
 foreach($p in $m.core.PSObject.Properties){$f=Inside $app $p.Name;if(!(Test-Path -LiteralPath $f)-or(Hash $f)-ne $p.Value){throw "Official core hash mismatch: $($p.Name). No core file will be modified."}}
 if(!$fixture){foreach($r in @('claude.exe','resources/cowork-svc.exe')){if((Get-AuthenticodeSignature -LiteralPath (Inside $app $r)).Status-ne 'Valid'){throw "Official signature invalid: $r"}}}
}
function Stop-Claude{
 if(!$fixture){Get-Process -Name claude -ErrorAction SilentlyContinue | Where-Object {$_.Path-and $_.Path.StartsWith($app+'\',[StringComparison]::OrdinalIgnoreCase)} | Stop-Process -Force}
}
function Enable-RestorePrivilege{
 if($fixture){return}
 if(!('ClaudeUIZhRestorePrivilege' -as [type])){Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class ClaudeUIZhRestorePrivilege {
 [StructLayout(LayoutKind.Sequential)] struct LUID { public uint Low; public int High; }
 [StructLayout(LayoutKind.Sequential)] struct PRIV { public uint Count; public LUID Luid; public uint Attributes; }
 [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
 [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
 [DllImport("advapi32.dll",SetLastError=true)] static extern bool OpenProcessToken(IntPtr p,uint access,out IntPtr token);
 [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool LookupPrivilegeValue(string host,string name,out LUID value);
 [DllImport("advapi32.dll",SetLastError=true)] static extern bool AdjustTokenPrivileges(IntPtr token,bool disable,ref PRIV privileges,uint length,IntPtr previous,IntPtr returned);
 public static void Enable() { IntPtr t; if(!OpenProcessToken(GetCurrentProcess(),0x28,out t))throw new Win32Exception();try{LUID l;if(!LookupPrivilegeValue(null,"SeRestorePrivilege",out l))throw new Win32Exception();PRIV p=new PRIV{Count=1,Luid=l,Attributes=2};if(!AdjustTokenPrivileges(t,false,ref p,0,IntPtr.Zero,IntPtr.Zero))throw new Win32Exception();int e=Marshal.GetLastWin32Error();if(e!=0)throw new Win32Exception(e);}finally{CloseHandle(t);} }
}
'@ }
 [ClaudeUIZhRestorePrivilege]::Enable()
}
function Restore-Acls($records){foreach($a in @($records|Sort-Object {$_.relative.Length} -Descending)){ $p=if($a.relative-eq '.'){ $app }else{Inside $app $a.relative};if(Test-Path -LiteralPath $p){$acl=Get-Acl -LiteralPath $p;$sections=[Security.AccessControl.AccessControlSections]::Access -bor [Security.AccessControl.AccessControlSections]::Owner -bor [Security.AccessControl.AccessControlSections]::Group;$acl.SetSecurityDescriptorSddlForm($a.sddl,$sections);Set-Acl -LiteralPath $p -AclObject $acl;if((Get-Acl -LiteralPath $p).Sddl-ne $a.sddl){throw "Security descriptor restore mismatch: $($a.relative)"}}}}
function Grant-Write($records){
 if($fixture){return};$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
 foreach($a in $records){$p=if($a.relative-eq '.'){ $app }else{Inside $app $a.relative};$acl=Get-Acl -LiteralPath $p;$rule=[Security.AccessControl.FileSystemAccessRule]::new($sid,'FullControl','Allow');$acl.AddAccessRule($rule);Set-Acl -LiteralPath $p -AclObject $acl}
}
function Restore-Config($records){foreach($c in $records){
 $p=$configPaths[[int]$c.index];if(!(Test-Path -LiteralPath $p)){continue};$v=Read-Json $p
 # Restore only our locale field; retain settings changed by the user after installation.
 if(!$v.PSObject.Properties['locale']-or $v.locale-ne 'zh-CN'){continue}
 if($c.hadLocale){$v|Add-Member -NotePropertyName locale -NotePropertyValue $c.locale -Force}else{$v.PSObject.Properties.Remove('locale')}
 if(!$c.existed-and @($v.PSObject.Properties).Count-eq 0){Remove-Item -LiteralPath $p -Force}else{Save-Json $p $v}
}}
function Undo($j){
 if($j.version-ne $m.packageVersion){throw 'Backup version does not match'}
 foreach($r in $j.files){$p=Inside $app $r.relative;$h=if(Test-Path -LiteralPath $p){Hash $p}else{''};if($h-ne $r.after -and $h-ne $r.before){throw "Resource changed outside this installer: $($r.relative). Restore stopped before writing."};if($r.existed){$b=Inside $state $r.backup;if((Hash $b)-ne $r.before){throw "Backup corrupted: $($r.relative)"}}}
 Stop-Claude
 try{
  Grant-Write $j.acls
  $done=0;foreach($r in $j.files){$p=Inside $app $r.relative;if($r.existed){$temp=$p+'.claude-han-'+[Guid]::NewGuid().ToString('N')+'.tmp';Copy-Item -LiteralPath (Inside $state $r.backup) -Destination $temp;try{Replace-Temporary $temp $p}finally{Remove-Temporary $temp}}else{if(Test-Path -LiteralPath $p){Remove-Temporary $p}};$done++;if($done%100-eq 0){Write-Output "Restoring resources: $done / $($j.files.Count)"}}
  if($j.PSObject.Properties['temps']){foreach($rel in $j.temps){if($rel-notmatch '\.claude-han-[a-f0-9]{32}\.tmp$'){throw 'Unexpected temporary path in journal'};Remove-Temporary (Inside $app $rel)}}
  Restore-Config $j.configs
  foreach($d in @($j.createdDirs|Sort-Object Length -Descending)){ $p=Inside $app $d;if((Test-Path -LiteralPath $p)-and @(Get-ChildItem -LiteralPath $p -Force).Count-eq 0){Remove-Item -LiteralPath $p -Force}}
 }finally{Restore-Acls $j.acls}
 $j.phase='restored';Save-Json $journalPath $j;Verify-Core
 Write-Output "Restore complete. Original files, locale and access rules restored. Backup retained: $state"
}
try{
 $locked=$mutex.WaitOne(0);if(!$locked){throw 'Another installer or restorer is running'}
 Verify-Core
 if($Action-eq 'Status'){
  if($journal){Write-Output ('State: '+$journal.phase);if($journal.phase-eq 'installed'){foreach($r in $journal.files){if(!(Test-Path -LiteralPath (Inside $app $r.relative))-or (Hash (Inside $app $r.relative))-ne $r.after){throw "Installed file mismatch: $($r.relative)"}};Write-Output 'All installed file hashes match.'}}
  else{Write-Output 'No installation journal.'};Write-Output "Official core verified. Backup path: $state";return
 }
 if(!$fixture-and !([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Administrator rights are required. Run Install.cmd or Restore.cmd and approve Windows UAC.'}
 Enable-RestorePrivilege
 if($Action-eq 'Restore'){if(!$journal-or $journal.phase-eq 'restored'){Write-Output 'Already restored; no files changed.'}else{Undo $journal};return}
 if($journal-and $journal.phase-eq 'installed'){
  foreach($r in $journal.files){if(!(Test-Path -LiteralPath (Inside $app $r.relative))-or (Hash (Inside $app $r.relative))-ne $r.after){throw "Installed resource changed: $($r.relative). Restore or inspect first."}}
  Write-Output 'Already installed. Verified all hashes; no files or backups rewritten.';return
 }
 if($journal-and $journal.phase-eq 'prepared'){throw 'Previous operation was interrupted. Run Restore.cmd before installing again.'}
 # Prepare and validate every byte before changing any application file.
 $planned=New-Object Collections.Generic.List[object]
 foreach($patch in $m.patches){
  $p=Inside $app $patch.relative;if((Hash $p)-ne $patch.before){throw "Unsupported or modified resource: $($patch.relative). No files changed."}
  $s=[IO.File]::ReadAllText($p,$utf8)
  $builder=New-Object Text.StringBuilder;$position=0
  foreach($e in @($patch.edits|Sort-Object start)){$start=[int]$e.start;$end=[int]$e.end;if($start-lt $position-or $s.Substring($start,$end-$start)-cne $e.old){throw 'AST edit precondition mismatch'};[void]$builder.Append($s,$position,$start-$position);[void]$builder.Append([string]$e.replacement);$position=$end}
  [void]$builder.Append($s,$position,$s.Length-$position);$s=$builder.ToString()
  if((Hash-Text $s)-ne $patch.after){throw 'Result hash mismatch'};$planned.Add(@{relative=$patch.relative;text=$s;before=$patch.before;after=$patch.after})
 }
 foreach($c in $m.catalogs){
  if($c.PSObject.Properties['payloadHash']-and (Hash (Inside $PSScriptRoot $c.payload))-ne $c.payloadHash){throw 'Chinese catalog payload corrupted; no application resources changed'}
  $v=Read-Json (Inside $PSScriptRoot $c.payload)
  if($c.enRel){$enFile=Inside $app $c.enRel;if((Hash $enFile)-ne $c.enHash){throw 'English catalog version mismatch'};$en=Read-Json $enFile;foreach($prop in $v.PSObject.Properties){$existing=$en.PSObject.Properties[$prop.Name];if(!$existing){throw 'Translation key absent from current catalog'};$existing.Value=$prop.Value};$v=$en}
  $s=$v|ConvertTo-Json -Depth 100;$planned.Add(@{relative=$c.target;text=$s;before='';after=(Hash-Text $s)})
 }
 if($m.statsig.PSObject.Properties['payloadHash']-and (Hash (Inside $PSScriptRoot $m.statsig.payload))-ne $m.statsig.payloadHash){throw 'Statsig catalog payload corrupted; no application resources changed'}
 $s=(Read-Json (Inside $PSScriptRoot $m.statsig.payload))|ConvertTo-Json -Depth 100;$planned.Add(@{relative=$m.statsig.target;text=$s;before='';after=(Hash-Text $s)})
 foreach($r in $planned){if($r.before-eq ''-and(Test-Path -LiteralPath (Inside $app $r.relative))){throw "Existing Chinese catalog not owned by this installer: $($r.relative). No files changed."}}
 $backup=Join-Path $state ('backup-'+(Get-Date -Format yyyyMMdd-HHmmss)+'-'+[Guid]::NewGuid().ToString('N').Substring(0,8));New-Item -ItemType Directory -Path $backup -Force|Out-Null
 $files=@();$dirs=@();$aclMap=@{}
 foreach($r in $planned){
  $p=Inside $app $r.relative;$exists=Test-Path -LiteralPath $p;$b=$null
  if($exists){$b=(Split-Path -Leaf $backup)+'\'+$r.relative;$bp=Inside $state $b;New-Item -ItemType Directory -Path (Split-Path $bp -Parent) -Force|Out-Null;Copy-Item -LiteralPath $p -Destination $bp;if((Hash $bp)-ne $r.before){throw 'Backup hash mismatch'};$aclMap[$r.relative]=(Get-Acl -LiteralPath $p).Sddl}
  $d=Split-Path $p -Parent;while(!(Test-Path -LiteralPath $d)){$rel=$d.Substring($app.Length+1);$dirs+=@($rel);$d=Split-Path $d -Parent}
  $rel=if($d-eq $app){'.'}else{$d.Substring($app.Length+1)};$aclMap[$rel]=(Get-Acl -LiteralPath $d).Sddl
  $files+=@(@{relative=$r.relative;existed=[bool]$exists;backup=$b;before=$r.before;after=$r.after})
 }
 foreach($key in $aclMap.Keys){$aclRecords+=@(@{relative=$key;sddl=$aclMap[$key]})}
 for($i=0;$i-lt $configPaths.Count;$i++){$p=$configPaths[$i];$exists=Test-Path -LiteralPath $p;$v=if($exists){Read-Json $p}else{[pscustomobject]@{}};$has=[bool]$v.PSObject.Properties['locale'];$old=if($has){$v.locale}else{$null};$configRecords+=@(@{index=$i;existed=[bool]$exists;hadLocale=$has;locale=$old})}
 $temps=@();foreach($r in $planned){$r.temp=$r.relative+'.claude-han-'+[Guid]::NewGuid().ToString('N')+'.tmp';$temps+=@($r.temp)}
 $journal=[pscustomobject]@{schema=1;version=$m.packageVersion;phase='prepared';utc=[DateTime]::UtcNow.ToString('o');files=$files;acls=$aclRecords;configs=$configRecords;createdDirs=@($dirs|Select-Object -Unique);temps=$temps};Save-Json $journalPath $journal
 Stop-Claude;$wrote=$true
 try{
  Grant-Write $aclRecords
  # New MSIX directories inherit read-only rules. Journal their original security
  # descriptor before granting non-inheriting temporary access, just like existing directories.
  foreach($rel in @($journal.createdDirs|Sort-Object Length)){
   $dir=Inside $app $rel;New-Item -ItemType Directory -Path $dir -Force|Out-Null
   $record=@{relative=$rel;sddl=(Get-Acl -LiteralPath $dir).Sddl}
   $aclRecords+=@($record);$journal.acls=$aclRecords;Save-Json $journalPath $journal
   Grant-Write @($record)
  }
  $done=0;foreach($r in $planned){$p=Inside $app $r.relative;New-Item -ItemType Directory -Path (Split-Path $p -Parent) -Force|Out-Null;Atomic-Text $p $r.text (Inside $app $r.temp);if((Hash $p)-ne $r.after){throw 'Written resource hash mismatch'};$done++;if($done%100-eq 0){Write-Output "Installing resources: $done / $($planned.Count)"}}
  foreach($p in $configPaths){New-Item -ItemType Directory -Path (Split-Path $p -Parent) -Force|Out-Null;$v=if(Test-Path -LiteralPath $p){Read-Json $p}else{[pscustomobject]@{}};$v|Add-Member -NotePropertyName locale -NotePropertyValue 'zh-CN' -Force;Save-Json $p $v}
 }finally{Restore-Acls $aclRecords}
 Verify-Core;$journal.phase='installed';Save-Json $journalPath $journal;$wrote=$false
 Write-Output "Installed: $($files.Count) resources. Official core and signatures unchanged. Backup: $state"
}catch{
 $failure=$_;if($wrote-and $journal){try{Undo $journal}catch{Write-Output ('Automatic rollback could not finish: '+$_+'. Run Restore.cmd.')}};throw $failure
}finally{
 if($locked){$mutex.ReleaseMutex()};$mutex.Dispose();Stop-Transcript|Out-Null
 if(!$fixture-and !$NoLaunch-and $pkg-and $Action-ne 'Status'){Start-Process -FilePath explorer.exe -ArgumentList ('shell:AppsFolder\'+$pkg.PackageFamilyName+'!Claude') -WindowStyle Hidden}
}
