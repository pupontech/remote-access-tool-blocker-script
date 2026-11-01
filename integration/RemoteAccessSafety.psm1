Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:RemoteAccessSafetyFormsLoaded = $false
# Captured at script scope: inside a function $PSScriptRoot can resolve to the CALLER's root.
$script:SafetyModuleRoot = $PSScriptRoot

function Get-RemoteAccessSafetyCatalog {
    [CmdletBinding()]
    param(
        [object]$Catalog
    )

    if ($null -eq $Catalog) {
        $path = Join-Path $script:SafetyModuleRoot 'RemoteAccessSafety.i18n.json'
        if (-not (Test-Path -LiteralPath $path)) { throw "Localized safety text is missing: $path" }
        $Catalog = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    foreach ($language in @('en', 'he')) {
        $languageProperty = $Catalog.PSObject.Properties[$language]
        if ($null -eq $languageProperty) { throw "Missing language: $language" }
        $dictionary = $languageProperty.Value
        foreach ($field in @('LanguageName', 'Title', 'Yes', 'No', 'Cancel', 'LanguageLabel', 'Instruction')) {
            $property = $dictionary.PSObject.Properties[$field]
            if ($null -eq $property -or $property.Value -isnot [string] -or [string]::IsNullOrEmpty([string]$property.Value)) {
                throw "Invalid $language.$field"
            }
        }
        $stagesProperty = $dictionary.PSObject.Properties['Stages']
        if ($null -eq $stagesProperty -or @($stagesProperty.Value).Count -ne 3) { throw "Invalid $language.Stages" }
        $stageIndex = 0
        foreach ($stage in @($stagesProperty.Value)) {
            $stageIndex++
            $warningProperty = $stage.PSObject.Properties['Warning']
            if ($null -eq $warningProperty -or $warningProperty.Value -isnot [string] -or [string]::IsNullOrEmpty([string]$warningProperty.Value)) {
                throw "Invalid $language stage $stageIndex warning"
            }
            $phraseProperty = $stage.PSObject.Properties['Phrase']
            $phraseValue = if ($null -eq $phraseProperty) { $null } else { $phraseProperty.Value }
            if ($stageIndex -eq 1) {
                # Only the first dialog asks for a sentence, so it must be present.
                if ($phraseValue -isnot [string] -or [string]::IsNullOrEmpty([string]$phraseValue)) {
                    throw "Invalid $language stage 1 phrase"
                }
            } elseif ($null -ne $phraseValue) {
                # Later dialogs must never demand more typing.
                throw "$language stage $stageIndex must not require a typed phrase"
            }
        }
    }
    return $Catalog
}

function Get-RemoteAccessSafetyPhrase {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Catalog,
        [Parameter(Mandatory = $true)][ValidateSet('en', 'he')][string]$Language,
        [Parameter(Mandatory = $true)][ValidateRange(1, 3)][int]$Stage
    )

    $stageInfo = @($Catalog.$Language.Stages)[$Stage - 1]
    $property = $stageInfo.PSObject.Properties['Phrase']
    if ($null -eq $property -or $property.Value -isnot [string]) { return '' }
    [string]$property.Value
}

function Test-RemoteAccessSafetyPhrase {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$Text,
        [ValidateSet('en', 'he')][string]$Language,
        [ValidateRange(1, 3)][int]$Stage,
        [object]$Catalog
    )

    try {
        if ($null -eq $Text) { return [bool]$false }
        $catalogValue = Get-RemoteAccessSafetyCatalog -Catalog $Catalog
        $expected = Get-RemoteAccessSafetyPhrase -Catalog $catalogValue -Language $Language -Stage $Stage
        if ([string]::IsNullOrEmpty($expected)) { return [bool]$false }
        return [bool]([string]::Equals($Text, $expected, [StringComparison]::Ordinal))
    } catch {
        return [bool]$false
    }
}

function Set-RemoteAccessSafetyDirection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Form,
        [Parameter(Mandatory = $true)][ValidateSet('en', 'he')][string]$Language
    )

    # RightToLeftLayout is deliberately NOT assigned: on a form that is already visible it
    # re-creates the window handle, which can throw inside the change handler. Per-control
    # RightToLeft plus an explicit button flow direction gives the same RTL result safely.
    $rightToLeft = if ($Language -eq 'he') { [System.Windows.Forms.RightToLeft]::Yes } else { [System.Windows.Forms.RightToLeft]::No }
    $align = if ($Language -eq 'he') { [System.Drawing.ContentAlignment]::MiddleRight } else { [System.Drawing.ContentAlignment]::MiddleLeft }
    $Form.RightToLeft = $rightToLeft
    foreach ($control in $Form.Tag.DirectionControls) {
        if ($null -ne $control) { $control.RightToLeft = $rightToLeft }
    }
    foreach ($label in $Form.Tag.AlignedLabels) {
        if ($null -ne $label) { $label.TextAlign = $align }
    }
    if ($null -ne $Form.Tag.ButtonPanel) {
        $Form.Tag.ButtonPanel.FlowDirection = if ($Language -eq 'he') {
            [System.Windows.Forms.FlowDirection]::RightToLeft
        } else {
            [System.Windows.Forms.FlowDirection]::LeftToRight
        }
    }
}

function New-RemoteAccessSafetyDialog {
    [CmdletBinding()]
    param(
        [ValidateRange(1, 3)][int]$Stage,
        [ValidateSet('en', 'he')][string]$Language,
        [object]$Catalog
    )

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Windows Forms requires Windows.' }
    if (-not $script:RemoteAccessSafetyFormsLoaded) {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        $script:RemoteAccessSafetyFormsLoaded = $true
    }
    $catalogValue = Get-RemoteAccessSafetyCatalog -Catalog $Catalog
    $requiresPhrase = $Stage -eq 1

    $form = New-Object System.Windows.Forms.Form
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MinimizeBox = $false
    $form.MaximizeBox = $false
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $form.Icon = [System.Drawing.SystemIcons]::Warning
    $workArea = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $form.ClientSize = New-Object System.Drawing.Size(
        [Math]::Min(760, [Math]::Max(380, $workArea.Width - 80)),
        [Math]::Min(620, [Math]::Max(320, $workArea.Height - 120)))
    $form.Padding = New-Object System.Windows.Forms.Padding(12)

    $root = New-Object System.Windows.Forms.TableLayoutPanel
    $root.Dock = [System.Windows.Forms.DockStyle]::Fill
    $root.ColumnCount = 1
    $root.RowCount = 3
    [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
    [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))

    $languageLabel = New-Object System.Windows.Forms.Label
    $languageLabel.AutoSize = $true
    $languageLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Left
    $languageCombo = New-Object System.Windows.Forms.ComboBox
    $languageCombo.AccessibleName = 'SafetyLanguage'
    $languageCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    [void]$languageCombo.Items.Add([string]$catalogValue.en.LanguageName)
    [void]$languageCombo.Items.Add([string]$catalogValue.he.LanguageName)
    $languageCombo.Width = 180

    $header = New-Object System.Windows.Forms.TableLayoutPanel
    $header.Dock = [System.Windows.Forms.DockStyle]::Fill
    $header.AutoSize = $true
    $header.ColumnCount = 2
    [void]$header.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
    [void]$header.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$header.Controls.Add($languageLabel, 0, 0)
    [void]$header.Controls.Add($languageCombo, 1, 0)

    $warningBox = New-Object System.Windows.Forms.TextBox
    $warningBox.AccessibleName = 'SafetyWarning'
    $warningBox.Multiline = $true
    $warningBox.ReadOnly = $true
    $warningBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $warningBox.WordWrap = $true
    $warningBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $warningBox.ForeColor = [System.Drawing.Color]::DarkRed
    $warningBox.BackColor = [System.Drawing.SystemColors]::Window

    $footer = New-Object System.Windows.Forms.TableLayoutPanel
    $footer.Dock = [System.Windows.Forms.DockStyle]::Fill
    $footer.ColumnCount = 1
    $footer.AutoSize = $true
    $footer.RowCount = if ($requiresPhrase) { 4 } else { 1 }

    $phraseLabel = $null
    $instruction = $null
    $inputBox = $null
    if ($requiresPhrase) {
        $phraseLabel = New-Object System.Windows.Forms.Label
        $phraseLabel.AccessibleName = 'SafetyPhrase'
        $phraseLabel.AutoSize = $true
        $phraseLabel.UseMnemonic = $false
        $phraseLabel.Font = New-Object System.Drawing.Font($form.Font, [System.Drawing.FontStyle]::Bold)
        $instruction = New-Object System.Windows.Forms.Label
        $instruction.AutoSize = $true
        $inputBox = New-Object System.Windows.Forms.TextBox
        $inputBox.AccessibleName = 'SafetyInput'
        $inputBox.Dock = [System.Windows.Forms.DockStyle]::Fill
        $inputBox.Margin = New-Object System.Windows.Forms.Padding(0, 4, 0, 8)
        [void]$footer.Controls.Add($phraseLabel, 0, 0)
        [void]$footer.Controls.Add($instruction, 0, 1)
        [void]$footer.Controls.Add($inputBox, 0, 2)
    }

    $yesButton = New-Object System.Windows.Forms.Button
    $yesButton.AccessibleName = 'SafetyYes'
    $noButton = New-Object System.Windows.Forms.Button
    $noButton.AccessibleName = 'SafetyNo'
    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.AccessibleName = 'SafetyCancel'
    foreach ($button in @($yesButton, $noButton, $cancelButton)) { $button.Size = New-Object System.Drawing.Size(110, 32) }
    $noButton.DialogResult = [System.Windows.Forms.DialogResult]::No
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $noButton.TabIndex = 0
    $cancelButton.TabIndex = 1
    $yesButton.TabIndex = 2

    $buttons = New-Object System.Windows.Forms.FlowLayoutPanel
    $buttons.Dock = [System.Windows.Forms.DockStyle]::Fill
    $buttons.AutoSize = $true
    $buttons.WrapContents = $false
    $buttons.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
    [void]$buttons.Controls.Add($yesButton)
    [void]$buttons.Controls.Add($noButton)
    [void]$buttons.Controls.Add($cancelButton)
    [void]$footer.Controls.Add($buttons, 0, ($footer.RowCount - 1))

    [void]$root.Controls.Add($header, 0, 0)
    [void]$root.Controls.Add($warningBox, 0, 1)
    [void]$root.Controls.Add($footer, 0, 2)
    [void]$form.Controls.Add($root)
    $form.AcceptButton = $noButton
    $form.CancelButton = $cancelButton

    $tag = [pscustomobject]@{
        Language          = ''
        RequiredPhrase    = ''
        Approved          = [bool]$false
        RequiresPhrase    = $requiresPhrase
        Stage             = $Stage
        Catalog           = $catalogValue
        Form              = $form
        YesButton         = $yesButton
        NoButton          = $noButton
        CancelButton      = $cancelButton
        LanguageCombo     = $languageCombo
        LanguageLabel     = $languageLabel
        InputBox          = $inputBox
        Instruction       = $instruction
        PhraseLabel       = $phraseLabel
        WarningBox        = $warningBox
        ButtonPanel       = $buttons
        DirectionControls = @($header, $warningBox, $footer, $buttons, $languageLabel, $languageCombo, $phraseLabel, $instruction, $inputBox)
        AlignedLabels     = @($languageLabel, $phraseLabel, $instruction)
    }
    $form.Tag = $tag

    $applyLanguage = {
        param([string]$selectedLanguage)
        if ($selectedLanguage -notin @('en', 'he')) { return }
        $current = $tag.Catalog.$selectedLanguage
        $stageInfo = @($current.Stages)[$tag.Stage - 1]
        $tag.Language = $selectedLanguage
        $tag.RequiredPhrase = if ($tag.RequiresPhrase) { [string]$stageInfo.Phrase } else { '' }
        $tag.Approved = [bool]$false
        $form.Text = '{0} ({1}/3)' -f $current.Title, $tag.Stage
        $tag.LanguageLabel.Text = [string]$current.LanguageLabel
        # WinForms text boxes need CRLF; the JSON catalog stores LF only, so paragraphs would merge.
        $warningText = ([string]$stageInfo.Warning).Replace([string]([char]13 + [char]10), [string][char]10)
        $tag.WarningBox.Text = $warningText.Replace([string][char]10, [Environment]::NewLine)
        $tag.YesButton.Text = [string]$current.Yes
        $tag.NoButton.Text = [string]$current.No
        $tag.CancelButton.Text = [string]$current.Cancel
        if ($tag.RequiresPhrase) {
            $tag.PhraseLabel.Text = [string]$stageInfo.Phrase
            $tag.Instruction.Text = [string]$current.Instruction
            if ($null -ne $tag.InputBox) { $tag.InputBox.Clear() }
            $tag.YesButton.Enabled = $false
        } else {
            $tag.YesButton.Enabled = $true
        }
        Set-RemoteAccessSafetyDirection -Form $form -Language $selectedLanguage
    }.GetNewClosure()

    $languageCombo.add_SelectedIndexChanged({
        $selectedLanguage = if ($tag.LanguageCombo.SelectedIndex -eq 1) { 'he' } else { 'en' }
        & $applyLanguage $selectedLanguage
    }.GetNewClosure())

    if ($requiresPhrase) {
        $inputBox.add_TextChanged({
            $tag.YesButton.Enabled = [string]::Equals($tag.InputBox.Text, $tag.RequiredPhrase, [StringComparison]::Ordinal)
        }.GetNewClosure())
    }

    $yesButton.add_Click({
        $allowed = if ($tag.RequiresPhrase) {
            [string]::Equals($tag.InputBox.Text, $tag.RequiredPhrase, [StringComparison]::Ordinal)
        } else {
            $true
        }
        if ($allowed) {
            $tag.Approved = [bool]$true
            $form.DialogResult = [System.Windows.Forms.DialogResult]::Yes
        } else {
            $tag.Approved = [bool]$false
            $tag.YesButton.Enabled = $false
        }
    }.GetNewClosure())

    $languageCombo.SelectedIndex = if ($Language -eq 'he') { 1 } else { 0 }
    $form.MaximumSize = New-Object System.Drawing.Size([Math]::Max(420, $workArea.Width - 40), [Math]::Max(360, $workArea.Height - 60))
    return $form
}

function Show-RemoteAccessSafetyPrompt {
    [CmdletBinding()]
    param(
        [ValidateRange(1, 3)][int]$Stage,
        [ValidateSet('en', 'he')][string]$Language
    )

    $form = $null
    try {
        $form = New-RemoteAccessSafetyDialog -Stage $Stage -Language $Language
        $dialogResult = $form.ShowDialog()
        $approved = [bool]($form.Tag.Approved -and $dialogResult -eq [System.Windows.Forms.DialogResult]::Yes)
        return [pscustomobject]@{ Approved = $approved; Language = [string]$form.Tag.Language }
    } catch {
        return [pscustomobject]@{ Approved = [bool]$false; Language = $Language }
    } finally {
        if ($null -ne $form) { $form.Dispose() }
    }
}

function Confirm-AllowRemoteAccess {
    [CmdletBinding()]
    param()

    $language = 'en'
    for ($stage = 1; $stage -le 3; $stage++) {
        try {
            $answer = Show-RemoteAccessSafetyPrompt -Stage $stage -Language $language
        } catch {
            return [bool]$false
        }
        if ($null -eq $answer) { return [bool]$false }
        try {
            $approved = $answer.Approved
            $selected = [string]$answer.Language
        } catch {
            return [bool]$false
        }
        if ($approved -isnot [bool] -or -not $approved) { return [bool]$false }
        if ($selected -notin @('en', 'he')) { return [bool]$false }
        $language = $selected
    }
    return [bool]$true
}

Export-ModuleMember -Function Confirm-AllowRemoteAccess
