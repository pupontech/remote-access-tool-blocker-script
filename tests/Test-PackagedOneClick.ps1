param([Parameter(Mandatory=$true)][string]$Archive)
$ErrorActionPreference='Stop'
if ($env:OS -ne 'Windows_NT') { Write-Host 'SKIP: packaged CMD launch requires native Windows.'; exit 0 }
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$fixture=Join-Path $env:RUNNER_TEMP ('Remote access [test] (1) O''Brien & safe! '+[guid]::NewGuid().ToString('N'))
try {
    [IO.Compression.ZipFile]::ExtractToDirectory([IO.Path]::GetFullPath($Archive),$fixture)
    foreach($name in 'START-HERE.bat','Allow Remote Access.bat','Start-Here.ps1','RemoteAccessSafety.psm1') {
        if(-not (Test-Path -LiteralPath (Join-Path $fixture $name))) { throw "Packaged entry point missing: $name" }
    }
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
    $process.StandardInput.WriteLine('NO')
    $process.StandardInput.WriteLine('')
    $process.StandardInput.Close()
    if(-not $process.WaitForExit(30000)) {
        & "$env:SystemRoot\System32\taskkill.exe" /PID $process.Id /T /F | Out-Null
        throw 'Packaged launcher cancellation timed out'
    }
    $output=$stdout.GetAwaiter().GetResult()+$stderr.GetAwaiter().GetResult()
    if($process.ExitCode -ne 2 -or $output -notmatch 'No elevation or installation was attempted') { throw "Wrong packaged cancel behavior: exit=$($process.ExitCode) $output" }
    Write-Host 'PASS: real extracted START-HERE.bat cancels without installation from spaces/brackets/parentheses/apostrophe/ampersand/exclamation path.'
} finally {
    if(Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
