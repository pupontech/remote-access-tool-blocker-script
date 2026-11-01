$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$start = Join-Path $root 'integration/Start-Here.ps1'
$text = Get-Content -LiteralPath $start -Raw
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($start,[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors | Out-String)}
$body=@($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.TryStatementAst] })[0].Extent.Text
$base=if($env:TMPDIR){$env:TMPDIR}else{[IO.Path]::GetTempPath()}
$fixture=Join-Path $base ('no-input-block-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
try {
    [IO.File]::WriteAllText((Join-Path $fixture 'RemoteAccessProtection.psm1'),'never imported in fixture')
    [IO.File]::WriteAllText((Join-Path $fixture 'Invoke-RemoteAccessProtection.ps1'),'never executed in fixture')
    foreach($case in 'Install','Allow','ElevationDenied') {
        $preamble=@'
$ErrorActionPreference='Stop'
$ElevationAttempted=$false
function Read-Host { throw 'UNEXPECTED_KEYBOARD_INPUT' }
function Pause-OneClickConsole { throw 'UNEXPECTED_KEYBOARD_PAUSE' }
function Show-OneClickError { param($Message) Write-Host ('FIXTURE_ERROR: '+$Message) }
function Test-NativeAdministrator { $true }
function Get-InstalledControllerPath { Join-Path $PSScriptRoot 'Invoke-RemoteAccessProtection.ps1' }
function Invoke-Controller { param($ControllerPath,$ControllerAction) Write-Host ('FIXTURE_CONTROLLER: '+$ControllerAction); return 0 }
'@
        $preamble += "`n`$Action = '$(if($case -eq 'Allow'){'Allow'}else{'Install'})'`n"
        if($case -eq 'ElevationDenied') {
            $preamble += "function Test-NativeAdministrator { `$false }`nfunction Invoke-SelfElevated { param(`$ScriptPath) throw 'FIXTURE_UAC_DENIED' }`n"
        }
        $file=Join-Path $fixture ($case+'.ps1')
        [IO.File]::WriteAllText($file,$preamble+"`n"+$body)
        $engine=(Get-Process -Id $PID).Path
        $output=(& $engine -NoProfile -File $file 2>&1 | Out-String);$rc=$LASTEXITCODE
        if($output -match 'UNEXPECTED_KEYBOARD'){throw "Blocking/allowing asked for keyboard input: $output"}
        if($case -eq 'ElevationDenied') {
            if($rc -eq 0 -or $output -match 'FIXTURE_CONTROLLER'){throw "UAC refusal reached controller: $rc $output"}
        } elseif($rc -ne 0 -or $output -notmatch ('FIXTURE_CONTROLLER: '+$case)){throw "Wrong route: $case $rc $output"}
    }
    if($text -match 'Read-Host|Type BLOCK|Pause-OneClickConsole'){throw 'One-click wrapper still contains keyboard prompts.'}
    foreach($name in 'START-HERE.bat','Allow Remote Access.bat') {
        $bytes=[IO.File]::ReadAllBytes((Join-Path (Split-Path $start) $name))
        if(@($bytes|Where-Object {$_ -gt 127}).Count){throw "Non-ASCII $name"}
        $s=[Text.Encoding]::ASCII.GetString($bytes)
        if($s.Replace("`r`n",'').Contains("`n")){throw "Bare LF $name"}
    }
    Write-Host 'PASS: block/install needs no keyboard input, allow routes installed control, and UAC refusal stops.'
} finally { if(Test-Path -LiteralPath $fixture){Remove-Item -LiteralPath $fixture -Recurse -Force} }
exit 0
