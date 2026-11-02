# Scratch-only behavior proof: no policy installer, registry or native Windows calls.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$installer = Join-Path $root 'src/appcontrol/Install-RmmAppControl.v2026-11-02.1.ps1'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($installer, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$fn = $ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Install-RevertTool'}, $true)
if (-not $fn) { throw 'Recovery installation function missing' }
Invoke-Expression $fn.Extent.Text
function Write-Log([string]$m) { $script:Messages += $m }
$base = if ($env:TMPDIR) { $env:TMPDIR } else { [IO.Path]::GetTempPath() }
$fixture = Join-Path $base ('windows-only-recovery-' + [guid]::NewGuid().ToString('N'))
try {
    foreach ($layout in 'flat', 'repo') {
        $caseRoot = Join-Path $fixture $layout
        $ScriptRootHere = Join-Path $caseRoot 'source'
        $RepoRootHere = Join-Path $caseRoot 'repository'
        $InstallDir = Join-Path $caseRoot 'installed'
        $PolicyDir = Join-Path $caseRoot 'policy'
        $source = if ($layout -eq 'flat') { $ScriptRootHere } else { Join-Path $RepoRootHere 'revert' }
        foreach ($dir in @($ScriptRootHere,$source,$InstallDir,$PolicyDir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [IO.File]::WriteAllText((Join-Path $source 'Run-Revert.bat'), 'fixture launcher')
        $winName = 'Revert-RemoteAccessBlock-WinOnly.v2026-10-11.1.ps1'
        [IO.File]::WriteAllText((Join-Path $source $winName), 'fixture Windows recovery')
        $obsolete = 'Revert-RemoteAccessBlock.v2000.1.ps1'
        [IO.File]::WriteAllText((Join-Path $source $obsolete), 'must never be selected')
        [IO.File]::WriteAllText((Join-Path $InstallDir $obsolete), 'old installed variant')
        [IO.File]::WriteAllText((Join-Path $source 'eset-remove-guide.txt'), 'must never be copied')
        [IO.File]::WriteAllText((Join-Path $ScriptRootHere 'RemoteAccessSafety.psm1'), 'fixture safety module')
        [IO.File]::WriteAllText((Join-Path $ScriptRootHere 'RemoteAccessSafety.i18n.json'), 'fixture localized warnings')
        $script:Messages = @()
        Install-RevertTool
        if ((Get-Content -LiteralPath (Join-Path $InstallDir $winName) -Raw) -ne 'fixture Windows recovery') { throw 'Wrong recovery payload' }
        if (-not (Test-Path -LiteralPath (Join-Path $InstallDir 'Allow Remote Access.bat'))) { throw 'Named Allow Remote Access recovery launcher missing.' }
        if ((Get-Content -LiteralPath (Join-Path $InstallDir 'RemoteAccessSafety.psm1') -Raw) -ne 'fixture safety module') { throw 'Safety module was not installed with recovery.' }
        if ((Get-Content -LiteralPath (Join-Path $InstallDir 'RemoteAccessSafety.i18n.json') -Raw) -ne 'fixture localized warnings') { throw 'Localized warnings were not installed with recovery.' }
        if (Test-Path -LiteralPath (Join-Path $InstallDir $obsolete)) { throw 'Obsolete full recovery survived' }
        if (Test-Path -LiteralPath (Join-Path $InstallDir 'docs/eset-remove-guide.txt')) { throw 'Website guide copied' }
        if (-not ($script:Messages -match '4 item\(s\) copied')) { throw "Wrong recovery copy count: $($script:Messages -join '; ')" }
        Write-Host "PASS: $layout layout copies only Windows recovery and replaces the old variant."
    }
} finally {
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
