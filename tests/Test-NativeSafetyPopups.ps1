param([string]$EvidenceDir)
$ErrorActionPreference='Stop'
if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){Write-Host 'SKIP: native dialog proof requires Windows.';exit 0}
$root=Split-Path $PSScriptRoot -Parent
if(-not $EvidenceDir){$EvidenceDir=Join-Path $root 'dist/native-safety-proof'}
New-Item -ItemType Directory -Path $EvidenceDir -Force | Out-Null
$modulePath=Join-Path $root 'integration/RemoteAccessSafety.psm1'
$catalog=[IO.File]::ReadAllText((Join-Path $root 'integration/RemoteAccessSafety.i18n.json'),[Text.Encoding]::UTF8)|ConvertFrom-Json
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class BilingualProbe {
 public delegate bool EnumProc(IntPtr h, IntPtr l);
 [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
 [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr l);
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
 [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int max);
 [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int max);
 [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
 [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr h, uint msg, IntPtr w, StringBuilder l);
 [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr h, uint msg, IntPtr w, string l);
 [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
 [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool IsWindowEnabled(IntPtr h);
 [DllImport("user32.dll")] public static extern IntPtr GetParent(IntPtr h);
 [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int index);
 [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left,Top,Right,Bottom; }
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out Rect r);

 public static string Title(IntPtr h){ var s=new StringBuilder(1024); GetWindowText(h,s,s.Capacity); return s.ToString(); }
 public static string Class(IntPtr h){ var s=new StringBuilder(256); GetClassName(h,s,s.Capacity); return s.ToString(); }
 public static string Text(IntPtr h){ var s=new StringBuilder(65536); SendMessage(h,0x000D,(IntPtr)s.Capacity,s); return s.ToString(); }

 public static IntPtr FindDialog(int wantedPid, string suffix){
  IntPtr found=IntPtr.Zero;
  EnumWindows(delegate(IntPtr h,IntPtr l){
   uint pid; GetWindowThreadProcessId(h,out pid);
   if(pid!=(uint)wantedPid || !IsWindowVisible(h)) return true;
   if(!Title(h).EndsWith(suffix,StringComparison.Ordinal)) return true;
   found=h; return false; },IntPtr.Zero);
  return found;
 }

 public static List<IntPtr> Children(IntPtr form){
  var list=new List<IntPtr>();
  EnumChildWindows(form,delegate(IntPtr h,IntPtr l){ list.Add(h); return true; },IntPtr.Zero);
  return list;
 }
}
'@
function Wait-Dialog {
 param($Process,[int]$Stage,[string]$ExpectedTitle,[int]$Seconds=25)
 $suffix="($Stage/3)"
 $deadline=[DateTime]::UtcNow.AddSeconds($Seconds)
 while([DateTime]::UtcNow -lt $deadline -and -not $Process.HasExited){
  $h=[BilingualProbe]::FindDialog($Process.Id,$suffix)
  if($h -ne [IntPtr]::Zero){
   if(-not $ExpectedTitle -or [BilingualProbe]::Title($h) -eq $ExpectedTitle){ return $h }
  }
  Start-Sleep -Milliseconds 100
 }
 $detail=''
 if($script:ProbeError -and (Test-Path -LiteralPath $script:ProbeError)){ $detail+=' error='+(Get-Content -LiteralPath $script:ProbeError -Raw) }
 if($script:ProbeLog -and (Test-Path -LiteralPath $script:ProbeLog)){ $detail+=' log='+((Get-Content -LiteralPath $script:ProbeLog -Raw) -replace "`r?`n",' | ') }
 throw "Dialog not found: stage=$Stage expected='$ExpectedTitle' exited=$($Process.HasExited)$detail"
}
function Get-Children([IntPtr]$Window){ return @([BilingualProbe]::Children($Window)) }
function Find-Control {
 param([IntPtr]$Window,[string]$ClassLike,[string]$ExactText,[switch]$SingleLineEdit,[switch]$MultilineEdit)
 $deadline=[DateTime]::UtcNow.AddSeconds(15)
 while([DateTime]::UtcNow -lt $deadline){
  foreach($child in Get-Children $Window){
   if($ClassLike -and [BilingualProbe]::Class($child) -notlike $ClassLike){ continue }
   $style=[BilingualProbe]::GetWindowLong($child,-16)
   if($SingleLineEdit -and ($style -band 0x4)){ continue }
   if($MultilineEdit -and -not ($style -band 0x4)){ continue }
   if($ExactText -and [BilingualProbe]::Title($child) -cne $ExactText){ continue }
   return $child
  }
  Start-Sleep -Milliseconds 150
 }
 throw "Control not found in '$([BilingualProbe]::Title($Window))' class=$ClassLike text='$ExactText'"
}
function Find-SingleLineEdit {
 # A combo box can own an internal EDIT; only a standalone single-line box counts here.
 param([IntPtr]$Window)
 $deadline=[DateTime]::UtcNow.AddSeconds(15)
 while([DateTime]::UtcNow -lt $deadline){
  foreach($child in Get-Children $Window){
   if([BilingualProbe]::Class($child) -notlike '*EDIT*'){ continue }
   $style=[BilingualProbe]::GetWindowLong($child,-16)
   if($style -band 0x4){ continue }
   $parent=[BilingualProbe]::GetParent($child)
   if($parent -ne [IntPtr]::Zero -and [BilingualProbe]::Class($parent) -like '*COMBOBOX*'){ continue }
   return $child
  }
  Start-Sleep -Milliseconds 150
 }
 return [IntPtr]::Zero
}
function Get-Input {
 param([IntPtr]$Window)
 $handle=Find-SingleLineEdit $Window
 if($handle -eq [IntPtr]::Zero){ throw "Input box not found in '$([BilingualProbe]::Title($Window))'" }
 return $handle
}
function Get-Warning { param([IntPtr]$Window) Find-Control $Window '*EDIT*' -MultilineEdit }
function Get-LanguageBox { param([IntPtr]$Window) Find-Control $Window '*COMBOBOX*' }
function Get-Button { param([IntPtr]$Window,[string]$Text) Find-Control $Window '*BUTTON*' -ExactText $Text }
function Get-InputText { param([IntPtr]$Window) [BilingualProbe]::Text((Get-Input $Window)) }
function Set-InputText {
 param([IntPtr]$Window,[string]$Value)
 $input=Get-Input $Window
 [void][BilingualProbe]::SendMessage($input,0x000C,[IntPtr]::Zero,$Value)
 Start-Sleep -Milliseconds 250
}
function Assert-YesEnabled {
 param([IntPtr]$Window,[string]$YesText,[bool]$Expected,[string]$Reason)
 $yes=Get-Button $Window $YesText
 $actual=[BilingualProbe]::IsWindowEnabled($yes)
 if($actual -ne $Expected){ throw "Yes enabled=$actual expected=$Expected ($Reason)" }
}
function Get-ButtonLeft {
 param([IntPtr]$Window,[string]$Text)
 $rect=New-Object BilingualProbe+Rect
 if(-not [BilingualProbe]::GetWindowRect((Get-Button $Window $Text),[ref]$rect)){ throw 'Button rectangle unavailable' }
 return $rect.Left
}
function Save-Image {
 param([IntPtr]$Window,[string]$Name)
 $rect=New-Object BilingualProbe+Rect
 if(-not [BilingualProbe]::GetWindowRect($Window,[ref]$rect)){ throw 'Dialog rectangle unavailable' }
 $bitmap=New-Object Drawing.Bitmap(($rect.Right-$rect.Left),($rect.Bottom-$rect.Top))
 $graphics=[Drawing.Graphics]::FromImage($bitmap)
 try{
  Start-Sleep -Milliseconds 200
  $graphics.CopyFromScreen($rect.Left,$rect.Top,0,0,$bitmap.Size)
  $bitmap.Save((Join-Path $EvidenceDir $Name),[Drawing.Imaging.ImageFormat]::Png)
 } finally { $graphics.Dispose(); $bitmap.Dispose() }
}
$base=if($env:RUNNER_TEMP){$env:RUNNER_TEMP}else{[IO.Path]::GetTempPath()}
$fixture=Join-Path $base ('safety-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
$childFile=Join-Path $fixture 'dialog-child.ps1'
[IO.File]::WriteAllText($childFile,@'
$ErrorActionPreference='Stop'
$stepLog=$env:RATB_PROBE_LOG
function Step { param([string]$Message) if($stepLog){ [IO.File]::AppendAllText($stepLog,($Message+[Environment]::NewLine)) } }
trap {
 $detail=$_.Exception.ToString()+[Environment]::NewLine+$_.InvocationInfo.PositionMessage
 try{ [IO.File]::WriteAllText($env:RATB_PROBE_ERROR,$detail) }catch{}
 Step ('FAILED-LINE: '+(($_.InvocationInfo.Line -replace '\s+',' ').Trim()))
 Step ('FAILED-TARGET: '+$(if($_.TargetObject){$_.TargetObject.GetType().FullName}else{'none'}))
 Step ('FAILED: '+$_.Exception.Message)
 exit 1
}
Step 'start'
Add-Type -AssemblyName System.Windows.Forms
Step 'forms loaded'
Import-Module $env:RATB_PROBE_MODULE -Force
Step 'module imported'
$m=Get-Module RemoteAccessSafety
& $m {
 # Stage 1 asks for one sentence; stages 2 and 3 must not ask for anything.
 foreach($language in 'en','he'){
  if($stepLog){ [IO.File]::AppendAllText($stepLog,("build stage 1 "+$language+"`n")) }
  $dialog=New-RemoteAccessSafetyDialog -Stage 1 -Language $language
  try{
   if($dialog.Tag.YesButton.Enabled){ throw 'Yes initially enabled on stage 1' }
   if($null -eq $dialog.Tag.InputBox){ throw 'Stage 1 has no input box' }
   if(-not [object]::ReferenceEquals($dialog.AcceptButton,$dialog.Tag.NoButton)){ throw 'Default is not No' }
   if(-not [object]::ReferenceEquals($dialog.CancelButton,$dialog.Tag.CancelButton)){ throw 'Escape is not Cancel' }
   $rtl=$dialog.RightToLeft -eq [Windows.Forms.RightToLeft]::Yes
   if($rtl -ne ($language -eq 'he')){ throw "Stage 1 RTL does not match $language" }
  }finally{ $dialog.Dispose() }
  foreach($stage in 2,3){
   if($stepLog){ [IO.File]::AppendAllText($stepLog,("build stage "+$stage+" "+$language+"`n")) }
   $dialog=New-RemoteAccessSafetyDialog -Stage $stage -Language $language
   try{
    if($null -ne $dialog.Tag.InputBox){ throw "Stage $stage must not create an input box" }
    if($null -ne $dialog.Tag.PhraseLabel){ throw "Stage $stage must not show a phrase label" }
    if(-not $dialog.Tag.YesButton.Enabled){ throw "Stage $stage must allow Yes without typing" }
    if(-not [object]::ReferenceEquals($dialog.AcceptButton,$dialog.Tag.NoButton)){ throw "Stage $stage default is not No" }
    $rtl=$dialog.RightToLeft -eq [Windows.Forms.RightToLeft]::Yes
    if($rtl -ne ($language -eq 'he')){ throw "Stage $stage RTL does not match $language" }
   }finally{ $dialog.Dispose() }
  }
 }
 # Drive the REAL language selector on stage 1 and assert the live control state it produces.
 if($stepLog){ [IO.File]::AppendAllText($stepLog,"selector check`n") }
 $dialog=New-RemoteAccessSafetyDialog -Stage 1 -Language en
 try{
  $tag=$dialog.Tag
  $tag.InputBox.Text=$tag.Catalog.en.Stages[0].Phrase
  if(-not $tag.YesButton.Enabled){ throw 'Exact English sentence did not enable Yes' }
  $tag.LanguageCombo.SelectedIndex=1
  if($tag.Language -ne 'he'){ throw 'Selector did not switch to Hebrew' }
  if($tag.InputBox.Text -ne ''){ throw 'Switching language did not clear the typed sentence' }
  if($tag.YesButton.Enabled){ throw 'Yes stayed enabled after switching language' }
  if($tag.RequiredPhrase -cne $tag.Catalog.he.Stages[0].Phrase){ throw 'Required sentence did not switch to Hebrew' }
  if($dialog.RightToLeft -ne [Windows.Forms.RightToLeft]::Yes){ throw 'Hebrew RTL was not applied by the selector' }
  if($dialog.Text -cne ($tag.Catalog.he.Title+' (1/3)')){ throw 'Dialog title did not switch to Hebrew' }
  if($tag.YesButton.Text -cne $tag.Catalog.he.Yes -or $tag.NoButton.Text -cne $tag.Catalog.he.No -or $tag.CancelButton.Text -cne $tag.Catalog.he.Cancel){ throw 'Buttons were not relabelled' }
  $tag.InputBox.Text=$tag.Catalog.en.Stages[0].Phrase
  if($tag.YesButton.Enabled){ throw 'English sentence unlocked Yes while Hebrew was selected' }
  $tag.InputBox.Text=$tag.Catalog.he.Stages[0].Phrase
  if(-not $tag.YesButton.Enabled){ throw 'Hebrew sentence did not unlock Yes' }
  $tag.LanguageCombo.SelectedIndex=0
  if($tag.YesButton.Enabled -or $tag.InputBox.Text -ne ''){ throw 'Switching back to English did not reset the dialog' }
  if($dialog.RightToLeft -ne [Windows.Forms.RightToLeft]::No){ throw 'English did not restore left-to-right' }
 }finally{ $dialog.Dispose() }
}
if($env:RATB_PROBE_SWITCH){
 # Prove the live switch cannot crash: flip the selector on a VISIBLE dialog with a timer,
 # and assert the live controls follow the language while the window is on screen.
 $dialog=& $m { New-RemoteAccessSafetyDialog -Stage 1 -Language en }
 $tag=$dialog.Tag
 $state=@{Step=0;Error=''}
 $seen=New-Object System.Collections.ArrayList
 $timer=New-Object Windows.Forms.Timer
 $timer.Interval=600
 $timer.add_Tick({
  try{
   $state.Step++
   if($state.Step -gt 4){ $timer.Stop(); $dialog.Close(); return }
   $expected=if(($state.Step % 2) -eq 1){'he'}else{'en'}
   $tag.LanguageCombo.SelectedIndex=$state.Step % 2
   [Windows.Forms.Application]::DoEvents()
   if($tag.Language -ne $expected){ throw "language did not become $expected" }
   if($dialog.Text -cne ($tag.Catalog.$expected.Title+' (1/3)')){ throw "title did not become $expected" }
   $boxText=$tag.WarningBox.Text.Replace("`r`n","`n")
   $expectedText=([string]$tag.Catalog.$expected.Stages[0].Warning).Replace("`r`n","`n")
   if($boxText -ne $expectedText){ throw "warning text did not become $expected" }
   if(-not $dialog.Visible){ throw 'dialog closed during the switch' }
   [void]$seen.Add($expected)
  }catch{
   $state.Error=$_.Exception.ToString()
   try{ [IO.File]::WriteAllText($env:RATB_PROBE_ERROR,$state.Error) }catch{}
   $timer.Stop()
   try{ $dialog.Close() }catch{}
  }
 })
 $timer.Start()
 $dialog.Show()
 $deadline=[DateTime]::UtcNow.AddSeconds(30)
 while($dialog.Visible -and [DateTime]::UtcNow -lt $deadline){ [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 40 }
 if($dialog.Visible){ $timer.Stop(); $dialog.Dispose(); throw 'Live switch dialog never closed' }
 $dialog.Dispose()
 if($state.Error){ throw "Live language switch threw: $($state.Error)" }
 [IO.File]::WriteAllText($env:RATB_PROBE_RESULT,('switches='+$state.Step+';seen='+($seen -join ',')))
 exit 0
}
if($env:RATB_PROBE_LANGUAGE){
 $dialog=& $m { param($lang) New-RemoteAccessSafetyDialog -Stage 1 -Language $lang } $env:RATB_PROBE_LANGUAGE
 $result=$dialog.ShowDialog()
 $approved=[bool]($dialog.Tag.Approved -and $result -eq 'Yes')
 $dialog.Dispose()
 [IO.File]::WriteAllText($env:RATB_PROBE_RESULT,[string]$approved)
 exit 0
}
if($stepLog){ [IO.File]::AppendAllText($stepLog,"confirm`n") }
$value=@(Confirm-AllowRemoteAccess)
if($value.Count -ne 1 -or $value[0] -isnot [bool]){ throw 'Bad confirmation result' }
[IO.File]::WriteAllText($env:RATB_PROBE_RESULT,[string]$value[0])
exit 0
'@)
function Start-ProbeChild {
 param([string]$ResultFile,[string]$ErrorFile,[hashtable]$Extra)
 $psi=New-Object Diagnostics.ProcessStartInfo
 $psi.FileName=(Get-Process -Id $PID).Path
 $psi.Arguments='-NoProfile -STA -ExecutionPolicy Bypass -File "'+$childFile+'"'
 $psi.UseShellExecute=$false;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
 $psi.EnvironmentVariables['RATB_PROBE_MODULE']=$modulePath
 $psi.EnvironmentVariables['RATB_PROBE_RESULT']=$ResultFile
 $psi.EnvironmentVariables['RATB_PROBE_ERROR']=$ErrorFile
 $psi.EnvironmentVariables['RATB_PROBE_LOG']=$ErrorFile+'.log'
 $psi.EnvironmentVariables['RATB_PROBE_EVIDENCE']=$EvidenceDir
 foreach($key in $Extra.Keys){ $psi.EnvironmentVariables[$key]=$Extra[$key] }
 $child=New-Object Diagnostics.Process;$child.StartInfo=$psi
 if(-not $child.Start()){ throw 'Native dialog child failed to start' }
 return $child
}
$records=@();$process=$null
try{
 foreach($case in @(
  @{Case='no-first';Count=1;End='No';Expected='False'},
  @{Case='no-second';Count=2;End='No';Expected='False'},
  @{Case='no-third';Count=3;End='No';Expected='False'},
  @{Case='cancel';Count=1;End='Cancel';Expected='False'},
  @{Case='close-window';Count=1;End='Close';Expected='False'},
  @{Case='approve-all';Count=3;End='Yes';Expected='True'},
  @{Case='hebrew-dialog';Count=1;End='Yes';Language='he';Expected='True'}
 )){
  $resultFile=Join-Path $fixture ($case.Case+'.txt')
  $errorFile=Join-Path $fixture ($case.Case+'.err')
  $script:ProbeError=$errorFile
  $script:ProbeLog=$errorFile+'.log'
  $extra=@{}
  if($case.Language -eq 'he'){ $extra['RATB_PROBE_LANGUAGE']='he' }
  $process=Start-ProbeChild -ResultFile $resultFile -ErrorFile $errorFile -Extra $extra
  $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
  $language=if($case.Language){[string]$case.Language}else{'en'}
  $catalogText=$catalog.$language
  for($stage=1;$stage -le $case.Count;$stage++){
   Write-Host "Native proof: $($case.Case) stage $stage"
   $title=[string]$catalogText.Title+' ('+$stage+'/3)'
   $window=Wait-Dialog $process $stage $title
   $yesText=[string]$catalogText.Yes
   $combo=Get-LanguageBox $window
   $itemCount=[BilingualProbe]::SendMessage($combo,0x0146,[IntPtr]::Zero,[IntPtr]::Zero).ToInt64()
   if($itemCount -ne 2){ throw "Language selector has $itemCount entries; expected English and Hebrew" }
   $selected=[BilingualProbe]::SendMessage($combo,0x0147,[IntPtr]::Zero,[IntPtr]::Zero).ToInt64()
   $expectedIndex=if($language -eq 'he'){1}else{0}
   if($selected -ne $expectedIndex){ throw "Dialog did not start in $language" }
   # The language label must be on the live dialog in the selected language.
   $labelFound=$false
   foreach($child in Get-Children $window){
    if([BilingualProbe]::Class($child) -like '*STATIC*' -and [BilingualProbe]::Title($child) -eq [string]$catalogText.LanguageLabel){ $labelFound=$true; break }
   }
   if(-not $labelFound){ throw "Language label missing on dialog for $language" }
   foreach($buttonText in @([string]$catalogText.Yes,[string]$catalogText.No,[string]$catalogText.Cancel)){
    [void](Get-Button $window $buttonText)
   }
   # Yes, No, Cancel order must follow the reading direction.
   $yesLeft=Get-ButtonLeft $window ([string]$catalogText.Yes)
   $cancelLeft=Get-ButtonLeft $window ([string]$catalogText.Cancel)
   $mirrored=($yesLeft -gt $cancelLeft)
   if($mirrored -ne ($language -eq 'he')){ throw "Button order does not follow RTL for $language (yes=$yesLeft cancel=$cancelLeft)" }
   $warning=[BilingualProbe]::Text((Get-Warning $window))
   $expectedWarning=[string]$catalogText.Stages[$stage-1].Warning
   if($warning.Replace("`r`n","`n") -ne $expectedWarning.Replace("`r`n","`n")){ throw "Wrong $language warning text in the native control" }
   if($stage -eq 1){
    # One sentence, typed once, exact match in the selected language.
    Assert-YesEnabled $window $yesText $false 'empty input'
    $phraseLabelFound=$false
    foreach($child in Get-Children $window){
     if([BilingualProbe]::Class($child) -like '*STATIC*' -and [BilingualProbe]::Title($child) -eq [string]$catalogText.Stages[0].Phrase){ $phraseLabelFound=$true; break }
    }
    if(-not $phraseLabelFound){ throw 'The sentence to type is not shown on stage 1' }
    if(-not [BilingualProbe]::Title((Find-Control $window '*STATIC*' -ExactText ([string]$catalogText.Instruction)))){ throw 'Stage 1 is missing its instruction line' }
    $other=if($language -eq 'en'){'he'}else{'en'}
    Set-InputText $window ([string]$catalog.$other.Stages[0].Phrase)
    Assert-YesEnabled $window $yesText $false 'sentence from the other language must not unlock Yes'
    Set-InputText $window 'incorrect sentence'
    Assert-YesEnabled $window $yesText $false 'wrong sentence must not unlock Yes'
    Set-InputText $window ([string]$catalogText.Stages[0].Phrase)
    Assert-YesEnabled $window $yesText $true 'the exact selected-language sentence must unlock Yes'
   } else {
    # No typing at all on the later dialogs.
    if((Find-SingleLineEdit $window) -ne [IntPtr]::Zero){ throw "Stage $stage must not contain an input box" }
    foreach($phrase in @([string]$catalog.en.Stages[0].Phrase,[string]$catalog.he.Stages[0].Phrase)){
     foreach($child in Get-Children $window){
      if([BilingualProbe]::Class($child) -like '*STATIC*' -and [BilingualProbe]::Title($child) -eq $phrase){ throw "Stage $stage must not ask for a sentence" }
     }
    }
    Assert-YesEnabled $window $yesText $true 'later dialogs must offer Yes immediately'
   }
   Save-Image $window ("$language-stage-$stage.png")
   $button=if($stage -eq $case.Count){$case.End}else{'Yes'}
   if($button -eq 'Close'){ [void][BilingualProbe]::PostMessage($window,0x0010,[IntPtr]::Zero,[IntPtr]::Zero) }
   else{ [void][BilingualProbe]::SendMessage((Get-Button $window ([string]$catalogText.$button)),0x00F5,[IntPtr]::Zero,[IntPtr]::Zero) }
  }
  if(-not $process.WaitForExit(20000)){ throw "Dialog sequence did not finish: $($case.Case)" }
  $output=$stdout.GetAwaiter().GetResult()+$stderr.GetAwaiter().GetResult()
  if($process.ExitCode -ne 0){ throw "Native child failed: $output" }
  if(-not (Test-Path -LiteralPath $resultFile)){ throw 'No native result file' }
  $result=[IO.File]::ReadAllText($resultFile)
  if($result -ne $case.Expected){ throw "Wrong result $($case.Case): $result" }
  $records += [pscustomobject]@{Case=$case.Case;Dialogs=$case.Count;Result=$result;Native=$true;DefaultButton='No';TypedSentences=1;ConfirmOnlyStages=2;Language=$language}
  Write-Host "PASS: native $($case.Case), result=$result."
  $process.Dispose();$process=$null
 }

 # Live language switch on a visible dialog: the crash the owner reported.
 Write-Host 'Native proof: live english-hebrew switch'
 $switchResult=Join-Path $fixture 'switch.txt'
 $switchError=Join-Path $fixture 'switch.err'
 $process=Start-ProbeChild -ResultFile $switchResult -ErrorFile $switchError -Extra @{RATB_PROBE_SWITCH='1'}
 $switchOut=$process.StandardOutput.ReadToEndAsync();$switchErr=$process.StandardError.ReadToEndAsync()
 $englishTitle=[string]$catalog.en.Title+' (1/3)'
 $hebrewTitle=[string]$catalog.he.Title+' (1/3)'
 $window=Wait-Dialog $process 1 $englishTitle 30
 Save-Image $window 'live-switch-english.png'
 $titles=New-Object System.Collections.ArrayList
 $deadline=[DateTime]::UtcNow.AddSeconds(20)
 while([DateTime]::UtcNow -lt $deadline -and -not $process.HasExited){
  if(-not [BilingualProbe]::IsWindow($window)){ break }
  try{
   $title=[BilingualProbe]::Title($window)
   if($title -and -not $titles.Contains($title)){ [void]$titles.Add($title) }
   if($title -eq $hebrewTitle -and -not (Test-Path -LiteralPath (Join-Path $EvidenceDir 'live-switch-hebrew.png'))){
    Save-Image $window 'live-switch-hebrew.png'
   }
  }catch{ }
  Start-Sleep -Milliseconds 80
 }
 if(-not $process.WaitForExit(20000)){ throw 'Live switch child never exited' }
 if($process.ExitCode -ne 0){ throw ("Live switch child failed: "+$switchOut.GetAwaiter().GetResult()+$switchErr.GetAwaiter().GetResult()) }
 if(Test-Path -LiteralPath $switchError){ throw ('Live switch threw: '+(Get-Content -LiteralPath $switchError -Raw)) }
 if(-not (Test-Path -LiteralPath $switchResult)){ throw 'No live switch result file' }
 $switchText=[IO.File]::ReadAllText($switchResult)
 # The child asserts the live controls while the window is visible; the parent requires
 # both directions to have been observed on screen and a clean exit.
 if($switchText -notmatch '^switches=[0-9]+;seen=he,en,he,en$'){ throw "Unexpected live switch result: $switchText (titles seen: $($titles -join ' / '))" }
 if(-not $titles.Contains($englishTitle)){ throw "The visible dialog was never observed in English (saw: $($titles -join ' / '))" }
 $records += [pscustomobject]@{Case='live-language-switch';Dialogs=1;Result='pass';Native=$true;SwitchedBothWays=$true;ProcessExit=0;TitlesSeen=@($titles)}
 Write-Host "PASS: live language switch survived, $switchText; titles observed: $($titles -join ' / ')."
 $process.Dispose();$process=$null
 [IO.File]::WriteAllText((Join-Path $EvidenceDir 'results.json'),($records|ConvertTo-Json -Depth 4))
}finally{
 if($null -ne $process){ if(-not $process.HasExited){ $process.Kill(); [void]$process.WaitForExit(5000) }; $process.Dispose() }
 if(Test-Path -LiteralPath $fixture){ Remove-Item -LiteralPath $fixture -Recurse -Force }
}
exit 0
