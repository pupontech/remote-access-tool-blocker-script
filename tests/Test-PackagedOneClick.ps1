param([Parameter(Mandatory=$true)][string]$Archive)
$ErrorActionPreference='Stop'
if ($env:OS -ne 'Windows_NT') { Write-Host 'SKIP: packaged CMD launch requires native Windows.'; exit 0 }
$principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'This fixture requires the hosted runner administrator token, not an interactive UAC test.'}
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$fixture=Join-Path $env:RUNNER_TEMP ('Remote access [test] (1) O''Brien & safe! '+[guid]::NewGuid().ToString('N'))
try {
    [IO.Compression.ZipFile]::ExtractToDirectory([IO.Path]::GetFullPath($Archive),$fixture)
    foreach($name in 'START-HERE.bat','Allow Remote Access.bat','Start-Here.ps1','RemoteAccessSafety.psm1') {
        if(-not (Test-Path -LiteralPath (Join-Path $fixture $name))) { throw "Packaged entry point missing: $name" }
    }
    # Replace ONLY the extracted controller with an inert double before executing
    # the real packaged BAT/wrapper. Never run the actual policy installation on CI.
    $controller=@'
param([string]$Action)
if ($Action -ne 'Install') { exit 9 }
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'fixture-controller-ran.txt'),$Action)
exit 0
'@
    [IO.File]::WriteAllText((Join-Path $fixture 'Invoke-RemoteAccessProtection.ps1'),$controller)
    $psi=New-Object Diagnostics.ProcessStartInfo
    $psi.FileName=$env:ComSpec
    $psi.Arguments='/d /c ""'+(Join-Path $fixture 'START-HERE.bat')+'""'
    $psi.UseShellExecute=$false
    $psi.RedirectStandardInput=$true
    $psi.RedirectStandardOutput=$true
    $psi.RedirectStandardError=$true
    $process=New-Object Diagnostics.Process
    $process.StartInfo=$psi
    if(-not $process.Start()) { throw 'Packaged launcher did not start' }
    $stdout=$process.StandardOutput.ReadToEndAsync()
    $stderr=$process.StandardError.ReadToEndAsync()
    $process.StandardInput.Close() # Prove blocking needs no keyboard input at all.
    if(-not $process.WaitForExit(30000)) {
        & "$env:SystemRoot\System32\taskkill.exe" /PID $process.Id /T /F | Out-Null
        throw 'Packaged no-input launcher timed out'
    }
    $output=$stdout.GetAwaiter().GetResult()+$stderr.GetAwaiter().GetResult()
    if($process.ExitCode -ne 0){throw "Wrong packaged launch behavior: exit=$($process.ExitCode) $output"}
    if((Get-Content -LiteralPath (Join-Path $fixture 'fixture-controller-ran.txt') -Raw) -ne 'Install'){throw 'Inert installation boundary was not reached'}
    Write-Host 'PASS: extracted START-HERE.bat reaches inert Install without stdin from spaces/brackets/parentheses/apostrophe/ampersand/exclamation path. No actual policy installation.'
} finally {
    if(Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
exit 0
