Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Confirm-AllowRemoteAccess {
    [CmdletBinding()]
    param()

    Write-Host 'WARNING: Remote access can expose your files, passwords, and banking information.' -ForegroundColor Red
    Write-Host 'Never allow a stranger or an unexpected caller to connect. Caller ID is not proof.' -ForegroundColor Red
    Write-Host 'If an unexpected caller asks for access, hang up. Independently find the company official number on a trusted website, bill, or card, then manually dial it.' -ForegroundColor Red
    Write-Host 'Do not use a number or link supplied by the caller, and do not trust search ads.' -ForegroundColor Red
    Write-Host 'Never share passwords or one-time codes, and never access your bank while connected.' -ForegroundColor Red
    Write-Host 'Only proceed for a technician you know and trust in person, or support you independently contacted and verified.' -ForegroundColor Red

    $required = @(
        'I VERIFIED THE PERSON'
        'I UNDERSTAND THE RISK'
        'ALLOW REMOTE ACCESS'
    )

    for ($index = 0; $index -lt $required.Count; $index++) {
        if ($index -eq 1) { Write-Host 'WARNING: You are about to remove a safety barrier. A scammer may steal your money or private information.' -ForegroundColor Red }
        if ($index -eq 2) { Write-Host 'FINAL WARNING: Do not continue because a caller is pressuring you. Cancel if you have any doubt.' -ForegroundColor Red }
        try {
            $answer = Read-Host ("Type exactly: {0}" -f $required[$index])
        } catch {
            return [bool]$false
        }

        if ($null -eq $answer -or ([string]$answer) -cne $required[$index]) {
            return [bool]$false
        }
    }

    return [bool]$true
}

Export-ModuleMember -Function Confirm-AllowRemoteAccess
