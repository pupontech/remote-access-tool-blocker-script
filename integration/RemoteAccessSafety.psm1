Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:RemoteAccessSafetyFormsLoaded = $false

function Show-RemoteAccessSafetyPrompt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$Text
    )

    try {
        if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
            return [bool]$false
        }

        if (-not $script:RemoteAccessSafetyFormsLoaded) {
            Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
            $script:RemoteAccessSafetyFormsLoaded = $true
        }

        $result = [System.Windows.Forms.MessageBox]::Show(
            $Text,
            $Title,
            [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
            [System.Windows.Forms.MessageBoxIcon]::Warning,
            [System.Windows.Forms.MessageBoxDefaultButton]::Button2
        )
        return [bool]($result -eq [System.Windows.Forms.DialogResult]::Yes)
    } catch {
        return [bool]$false
    }
}

function Confirm-AllowRemoteAccess {
    [CmdletBinding()]
    param()

    $title = 'Remote access safety confirmation'
    $prompts = @(
        @(
            'WARNING: Remote access can expose your files, passwords, and banking information.'
            'Never allow a stranger or an unexpected caller to connect. Caller ID is not proof.'
            'If an unexpected caller asks for access, hang up. Independently find the company official number on a trusted website, bill, or card, then manually dial it.'
            'Do not use a number or link supplied by the caller, and do not trust search ads.'
            'Never share passwords or one-time codes, and never access your bank while connected.'
            'Only proceed for a technician you know and trust in person, or support you independently contacted and verified.'
            ''
            'I VERIFIED THE PERSON'
        ) -join [Environment]::NewLine
        @(
            'WARNING: You are about to remove a safety barrier. A scammer may steal your money or private information.'
            ''
            'I UNDERSTAND THE RISK'
        ) -join [Environment]::NewLine
        @(
            'FINAL WARNING: Do not continue because a caller is pressuring you. Cancel if you have any doubt.'
            ''
            'ALLOW REMOTE ACCESS'
        ) -join [Environment]::NewLine
    )

    $stage = 0
    foreach ($prompt in $prompts) {
        $stage++
        try {
            $popupTitle = '{0} ({1} of 3)' -f $title, $stage
            $popupText = $prompt + [Environment]::NewLine + [Environment]::NewLine + 'Choose Yes only if you agree. No or Cancel keeps protection unchanged.'
            $answer = Show-RemoteAccessSafetyPrompt -Title $popupTitle -Text $popupText
        } catch {
            return [bool]$false
        }
        if ($answer -isnot [bool] -or -not $answer) {
            return [bool]$false
        }
    }

    return [bool]$true
}

Export-ModuleMember -Function Confirm-AllowRemoteAccess
