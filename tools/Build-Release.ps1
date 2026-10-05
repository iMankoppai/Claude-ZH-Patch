param([string]$OutputDirectory)
$ErrorActionPreference='Stop'
$taskRepoRoot=Split-Path $PSScriptRoot -Parent
$taskReleaseVersion=(Get-Content -LiteralPath (Join-Path $taskRepoRoot 'VERSION') -Raw).Trim()
if($taskReleaseVersion-notmatch '^\d+\.\d+\.\d+$'){throw 'Invalid release version'}
if(!$OutputDirectory){$OutputDirectory=Join-Path $taskRepoRoot 'dist'}
$taskOutputRoot=[IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $taskOutputRoot -Force | Out-Null
$taskBuildRoot=Join-Path $taskOutputRoot ('build-'+[Guid]::NewGuid().ToString('N'))
$taskPackageName='Claude-ZH-Patch-v'+$taskReleaseVersion
$taskPackageRoot=Join-Path $taskBuildRoot $taskPackageName
New-Item -ItemType Directory -Path $taskPackageRoot -Force | Out-Null
$taskAllowed=@('Install.cmd','Install.ps1','Launch.ps1','Rebuild.cmd','Rebuild.ps1','Restore.cmd','Status.cmd','Verify.cmd','Verify.ps1','payload','词典','验证','README.md','使用说明.md','验证说明.md','CHANGELOG.md','VERSION','LICENSE','LICENSE-upstream.txt','THIRD_PARTY_NOTICES.md','tools')
foreach($taskName in $taskAllowed){Copy-Item -LiteralPath (Join-Path $taskRepoRoot $taskName) -Destination $taskPackageRoot -Recurse}
$taskChecksumRows=@(foreach($taskFile in Get-ChildItem -LiteralPath $taskPackageRoot -Recurse -File|Sort-Object FullName){$taskRelative=$taskFile.FullName.Substring($taskPackageRoot.Length+1).Replace('\','/');(Get-FileHash -LiteralPath $taskFile.FullName).Hash.ToLower()+'  '+$taskRelative})
[IO.File]::WriteAllText((Join-Path $taskPackageRoot 'SHA256SUMS.txt'),($taskChecksumRows-join "`n")+"`n",[Text.UTF8Encoding]::new($false))
$taskZip=Join-Path $taskOutputRoot ($taskPackageName+'.zip')
Compress-Archive -LiteralPath $taskPackageRoot -DestinationPath $taskZip -Force
$taskExtractedRoot=Join-Path $taskBuildRoot 'verified'
Expand-Archive -LiteralPath $taskZip -DestinationPath $taskExtractedRoot
$taskExtractedPackage=Join-Path $taskExtractedRoot $taskPackageName
$taskChecked=0
foreach($taskLine in [IO.File]::ReadAllLines((Join-Path $taskExtractedPackage 'SHA256SUMS.txt'))){$taskHash=$taskLine.Substring(0,64);$taskRelative=$taskLine.Substring(66);if((Get-FileHash -LiteralPath (Join-Path $taskExtractedPackage $taskRelative)).Hash.ToLower()-ne $taskHash){throw ('ZIP hash mismatch: '+$taskRelative)};$taskChecked++}
$taskZipHash=(Get-FileHash -LiteralPath $taskZip).Hash.ToLower()
[IO.File]::WriteAllText((Join-Path $taskOutputRoot 'SHA256SUMS.txt'),$taskZipHash+'  '+[IO.Path]::GetFileName($taskZip)+"`n",[Text.UTF8Encoding]::new($false))
[ordered]@{version=$taskReleaseVersion;archive=$taskZip;sha256=$taskZipHash;checkedFiles=$taskChecked;hashMismatches=0;manifestSha256=(Get-FileHash -LiteralPath (Join-Path $taskPackageRoot 'payload/manifest.json')).Hash}|ConvertTo-Json
