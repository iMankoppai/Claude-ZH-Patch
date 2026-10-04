param([string]$OutputPath)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
if(!$OutputPath){$OutputPath=Join-Path $PSScriptRoot '本机只读校验.json'}
$report=[ordered]@{schema=1;utc=[DateTime]::UtcNow.ToString('o');scope='Read-only resource and backup verification; does not verify UI, login, VM execution or another physical machine';passed=$false;errors=@()}
function Read-Json($p){Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json}
function Hash($p){(Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash}
function Inside($base,$relative){$b=[IO.Path]::GetFullPath($base).TrimEnd('\');$p=[IO.Path]::GetFullPath((Join-Path $b $relative));if(!$p.StartsWith($b+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Path escapes checked directory'};return $p}
try{
 $m=Read-Json (Join-Path $PSScriptRoot 'payload\manifest.json')
 $report.manifestSha256=Hash (Join-Path $PSScriptRoot 'payload\manifest.json')
 $packages=@(Get-AppxPackage -Name Claude)
 if($packages.Count-ne 1){throw 'Expected one Claude package registered for this Windows user'}
 $pkg=$packages[0];$report.packageVersion=$pkg.Version.ToString()
 if($pkg.PackageFamilyName-ne $m.family -or $report.packageVersion-ne $m.packageVersion){throw 'Installed Claude version does not match this package'}
 $app=Join-Path $pkg.InstallLocation 'app'
 $report.detectedOriginalLaunch=$pkg.PackageFamilyName+'!Claude'
 $report.core=@(foreach($p in $m.core.PSObject.Properties){$h=Hash (Inside $app $p.Name);if($h-ne $p.Value){throw ('Official core mismatch: '+$p.Name)};@{relative=$p.Name;sha256=$h;matchesOfficial=$true}})
 $report.signatures=@(foreach($relative in @('claude.exe','resources/cowork-svc.exe')){$s=(Get-AuthenticodeSignature -LiteralPath (Inside $app $relative)).Status.ToString();if($s-ne 'Valid'){throw ('Official signature invalid: '+$relative)};@{relative=$relative;status=$s}})
 $state=Join-Path $env:LOCALAPPDATA ('ClaudeUIZh\'+$m.packageVersion)
 $jp=Join-Path $state 'journal.json'
 $report.installationState='not-installed'
 $report.resourcesChecked=0;$report.accessRulesChecked=0;$report.backupsChecked=0
 if(Test-Path -LiteralPath $jp){
  $j=Read-Json $jp;$report.installationState=$j.phase
  if($j.version-ne $m.packageVersion){throw 'Backup journal version mismatch'}
  if($j.phase-eq 'prepared'){throw 'Interrupted installation: run Restore.cmd first'}
  foreach($r in $j.files){
   $p=Inside $app $r.relative
   if($j.phase-eq 'installed'){
    if(!(Test-Path -LiteralPath $p)-or(Hash $p)-ne $r.after){throw ('Installed resource mismatch: '+$r.relative)}
   }elseif($j.phase-eq 'restored'){
    if($r.existed){if(!(Test-Path -LiteralPath $p)-or(Hash $p)-ne $r.before){throw ('Restored resource mismatch: '+$r.relative)}}elseif(Test-Path -LiteralPath $p){throw ('Created resource remains after restore: '+$r.relative)}
   }else{throw 'Unknown installation state'}
   $report.resourcesChecked++
   if($r.existed){if((Hash (Inside $state $r.backup))-ne $r.before){throw ('Backup corrupted: '+$r.relative)};$report.backupsChecked++}
  }
  foreach($a in $j.acls){$p=if($a.relative-eq '.'){ $app }else{Inside $app $a.relative};if(Test-Path -LiteralPath $p){if((Get-Acl -LiteralPath $p).Sddl-ne $a.sddl){throw ('Access rule mismatch: '+$a.relative)};$report.accessRulesChecked++}}
 }
 if($report.installationState-eq 'installed'){
  foreach($p in $m.patches){if((Hash (Inside $app $p.relative))-ne $p.after){throw ('Installed revision differs from this package: '+$p.relative)}}
  $report.catalogs=@(foreach($c in $m.catalogs){$v=Read-Json (Inside $PSScriptRoot $c.payload);$actual=Read-Json (Inside $app $c.target);foreach($p in $v.PSObject.Properties){if(!$actual.PSObject.Properties[$p.Name]-or $actual.PSObject.Properties[$p.Name].Value-cne $p.Value){throw ('Catalog mismatch: '+$c.scope+' / '+$p.Name)}};@{scope=$c.scope;translationsChecked=@($v.PSObject.Properties).Count}})
 }
 $svc=Get-Service -Name CoworkVMService -ErrorAction SilentlyContinue
 $report.coworkService=if($svc){$svc.Status.ToString()}else{'not-found'}
 $report.passed=$true
}catch{$report.errors+=($_.Exception.Message)}
[IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath),($report|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
$report|ConvertTo-Json -Depth 12
if(!$report.passed){exit 1}
