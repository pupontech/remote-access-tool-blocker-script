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
        foreach ($stage in @($stagesProperty.Value)) {
            foreach ($field in @('Warning', 'Phrase')) {
                $property = $stage.PSObject.Properties[$field]
                if ($null -eq $property -or $property.Value -isnot [string] -or [string]::IsNullOrEmpty([string]$property.Value)) {
                    throw "Invalid $language stage $field"
                }
            }
        }
    }
    return $Catalog
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
        $expected = [string]$catalogValue.$Language.Stages[$Stage - 1].Phrase
        return [bool]([string]::Equals($Text, $expected, [StringComparison]::Ordinal))
    } catch {
        return [bool]$false
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
    $form = New-Object System.Windows.Forms.Form
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MinimizeBox = $false
    $form.MaximizeBox = $false
    $form.AutoSize = $false
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $form.Icon = [System.Drawing.SystemIcons]::Warning
    $workArea = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $form.ClientSize = New-Object System.Drawing.Size([Math]::Min(760, [Math]::Max(360, $workArea.Width - 80)), [Math]::Min(650, [Math]::Max(360, $workArea.Height - 100)))
    $form.Padding = New-Object System.Windows.Forms.Padding(12)

    $layout = New-Object System.Windows.Forms.TableLayoutPanel
    $layout.AutoSize = $false
    $layout.Dock = [System.Windows.Forms.DockStyle]::Fill
    $layout.ColumnCount = 2
    $layout.RowCount = 7
    $layout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 25))) | Out-Null
    $layout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 75))) | Out-Null
    foreach ($height in @(38, 0, 0, 42, 42, 32, 44)) { [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, $height))) }
    $layout.RowStyles[1].SizeType = [System.Windows.Forms.SizeType]::Percent
    $layout.RowStyles[1].Height = 100

    $languageLabel = New-Object System.Windows.Forms.Label
    $languageLabel.AutoSize = $true
    $languageCombo = New-Object System.Windows.Forms.ComboBox
    $languageCombo.AccessibleName = 'SafetyLanguage'
    $languageCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    [void]$languageCombo.Items.Add([string]$catalogValue.en.LanguageName)
    [void]$languageCombo.Items.Add([string]$catalogValue.he.LanguageName)
    $languageCombo.Width = 180
    $warningBox = New-Object System.Windows.Forms.TextBox
    $warningBox.AccessibleName = 'SafetyWarning'
    $warningBox.Multiline = $true
    $warningBox.ReadOnly = $true
    $warningBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $warningBox.WordWrap = $true
    $warningBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $warningBox.MinimumSize = New-Object System.Drawing.Size(0, 100)
    $warningBox.ForeColor = [System.Drawing.Color]::DarkRed
    $warningBox.BackColor = [System.Drawing.SystemColors]::Window
    $phraseLabel = New-Object System.Windows.Forms.Label
    $phraseLabel.AccessibleName = 'SafetyPhrase'
    $phraseLabel.AutoSize = $false
    $phraseLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $phraseLabel.UseMnemonic = $false
    $phraseLabel.MaximumSize = [System.Drawing.Size]::Empty
    $phraseLabel.Font = New-Object System.Drawing.Font($form.Font, [System.Drawing.FontStyle]::Bold)
    $instruction = New-Object System.Windows.Forms.Label
    $instruction.AutoSize = $false
    $instruction.Dock = [System.Windows.Forms.DockStyle]::Fill
    $inputBox = New-Object System.Windows.Forms.TextBox
    $inputBox.AccessibleName = 'SafetyInput'
    $inputBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $yesButton = New-Object System.Windows.Forms.Button
    $yesButton.AccessibleName = 'SafetyYes'
    $noButton = New-Object System.Windows.Forms.Button
    $noButton.AccessibleName = 'SafetyNo'
    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.AccessibleName = 'SafetyCancel'
    $yesButton.Enabled = $false
    $noButton.DialogResult = [System.Windows.Forms.DialogResult]::No
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $noButton.TabIndex = 0
    $cancelButton.TabIndex = 1
    $yesButton.TabIndex = 2
    $buttons = New-Object System.Windows.Forms.FlowLayoutPanel
    $buttons.AutoSize = $false
    $buttons.Dock = [System.Windows.Forms.DockStyle]::Fill
    $buttons.WrapContents = $false
    foreach ($button in @($yesButton, $noButton, $cancelButton)) { $button.Size = New-Object System.Drawing.Size(96, 32) }
    $buttons.FlowDirection = [System.Windows.Forms.FlowDirection]::RightToLeft
    [void]$buttons.Controls.Add($cancelButton)
    [void]$buttons.Controls.Add($noButton)
    [void]$buttons.Controls.Add($yesButton)

    $tag = [pscustomobject]@{
        Language = $Language; RequiredPhrase = ''; Approved = [bool]$false; YesButton = $yesButton; NoButton = $noButton; CancelButton = $cancelButton
        LanguageCombo = $languageCombo; InputBox = $inputBox; WarningBox = $warningBox; PhraseLabel = $phraseLabel; Catalog = $catalogValue; Stage = $Stage
        LanguageLabel = $languageLabel; Instruction = $instruction; Form = $form
    }
    $form.Tag = $tag
    $controls = @($languageLabel, $languageCombo, $warningBox, $phraseLabel, $instruction, $inputBox, $buttons)
    [void]$layout.Controls.Add($languageLabel, 0, 0); [void]$layout.Controls.Add($languageCombo, 1, 0)
    [void]$layout.Controls.Add($warningBox, 0, 1); $layout.SetColumnSpan($warningBox, 2); $layout.SetRowSpan($warningBox, 2)
    [void]$layout.Controls.Add($phraseLabel, 0, 3); $layout.SetColumnSpan($phraseLabel, 2)
    [void]$layout.Controls.Add($instruction, 0, 4); $layout.SetColumnSpan($instruction, 2)
    [void]$layout.Controls.Add($inputBox, 0, 5); $layout.SetColumnSpan($inputBox, 2)
    [void]$layout.Controls.Add($buttons, 0, 6); $layout.SetColumnSpan($buttons, 2)
    [void]$form.Controls.Add($layout)
    $form.AcceptButton = $noButton
    $form.CancelButton = $cancelButton

    $setLanguage = {
        param([string]$selectedLanguage)
        $current = $tag.Catalog.$selectedLanguage
        $tag.Language = $selectedLanguage
        $tag.RequiredPhrase = [string]$current.Stages[$tag.Stage - 1].Phrase
        $tag.Approved = [bool]$false
        $form.Text = ('{0} ({1}/3)' -f $current.Title, $tag.Stage)
        $languageLabel.Text = $current.LanguageLabel
        $warningBox.Text = [string]$current.Stages[$tag.Stage - 1].Warning
        $phraseLabel.Text = [string]$current.Stages[$tag.Stage - 1].Phrase
        $instruction.Text = $current.Instruction
        $yesButton.Text = $current.Yes; $noButton.Text = $current.No; $cancelButton.Text = $current.Cancel
        $inputBox.Clear(); $yesButton.Enabled = $false
        $rtl = $selectedLanguage -eq 'he'
        $form.RightToLeft = if ($rtl) { [System.Windows.Forms.RightToLeft]::Yes } else { [System.Windows.Forms.RightToLeft]::No }
        $form.RightToLeftLayout = $rtl
        $inputBox.RightToLeft = $form.RightToLeft
        $warningBox.RightToLeft = $form.RightToLeft
        $phraseLabel.RightToLeft = $form.RightToLeft
        $phraseLabel.TextAlign = if ($rtl) { [System.Drawing.ContentAlignment]::MiddleRight } else { [System.Drawing.ContentAlignment]::MiddleLeft }
        $instruction.TextAlign = $phraseLabel.TextAlign
        $instruction.RightToLeft = $form.RightToLeft
        $languageLabel.RightToLeft = $form.RightToLeft
    }.GetNewClosure()
    $languageCombo.add_SelectedIndexChanged({
        $selectedLanguage = if ($languageCombo.SelectedIndex -eq 1) { 'he' } else { 'en' }
        & $setLanguage $selectedLanguage
    }.GetNewClosure())
    $inputBox.add_TextChanged({ $yesButton.Enabled = [string]::Equals($inputBox.Text, $tag.RequiredPhrase, [StringComparison]::Ordinal) }.GetNewClosure())
    $yesButton.add_Click({
        if ($yesButton.Enabled -and [string]::Equals($inputBox.Text, $tag.RequiredPhrase, [StringComparison]::Ordinal)) {
            $tag.Approved = [bool]$true
            $form.DialogResult = [System.Windows.Forms.DialogResult]::Yes
        } else { $tag.Approved = [bool]$false; $yesButton.Enabled = $false }
    }.GetNewClosure())
    $languageCombo.SelectedIndex = if ($Language -eq 'he') { 1 } else { 0 }
    $workArea = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $form.MaximumSize = New-Object System.Drawing.Size([Math]::Max(500, $workArea.Width - 40), [Math]::Max(400, $workArea.Height - 40))
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
        return [pscustomobject]@{ Approved = [bool]($form.Tag.Approved -and $dialogResult -eq [System.Windows.Forms.DialogResult]::Yes); Language = [string]$form.Tag.Language }
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
        try { $answer = Show-RemoteAccessSafetyPrompt -Stage $stage -Language $language } catch { return [bool]$false }
        try {
            if ($null -eq $answer -or $answer.Approved -isnot [bool] -or -not $answer.Approved -or $answer.Language -notin @('en', 'he')) { return [bool]$false }
            $language = [string]$answer.Language
        } catch { return [bool]$false }
    }
    return [bool]$true
}

Export-ModuleMember -Function Confirm-AllowRemoteAccess
