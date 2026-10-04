param([ValidateSet('Install','Restore','Status')][string]$Action='Install')
$ErrorActionPreference='Stop'
$script=Join-Path $PSScriptRoot 'Install.ps1'
if($Action-eq 'Status'){& $script -Action $Action;exit}
$argLine='-NoProfile -ExecutionPolicy Bypass -File "'+$script+'" -Action '+$Action
$p=Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $argLine -Verb RunAs -WindowStyle Hidden -PassThru
$p.WaitForExit()
if($p.ExitCode-eq 0){Write-Host '操作完成。以后继续使用原来的 Claude 启动入口。'}else{Write-Host ('操作失败，退出码：'+$p.ExitCode+'。请查看日志；未匹配版本或外部改动不会强行覆盖。')}
Write-Host "日志与备份：$env:LOCALAPPDATA\ClaudeUIZh\2.19675.0.0"
if($p.ExitCode-ne 0){exit $p.ExitCode}
