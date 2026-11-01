param([string]$EvidenceDir)
$ErrorActionPreference='Stop'
if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){Write-Host 'SKIP: bilingual native dialog proof requires Windows.';exit 0}
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
 [DllImport("user32.dll")] public static extern int GetDlgCtrlID(IntPtr h);
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
 throw "Dialog not found: stage=$Stage expected='$ExpectedTitle' exited=$($Process.HasExited)"
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
function Get-Input { param([IntPtr]$Window) Find-Control $Window '*EDIT*' -SingleLineEdit }
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
$fixture=Join-Path $base ('bilingual-safety-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
$childFile=Join-Path $fixture 'dialog-child.ps1'
[IO.File]::WriteAllText($childFile,@'
$ErrorActionPreference='Stop'
Import-Module $env:RATB_PROBE_MODULE -Force
$m=Get-Module RemoteAccessSafety
& $m {
 foreach($language in 'en','he'){
  $dialog=New-RemoteAccessSafetyDialog -Stage 1 -Language $language
  try{
   if($dialog.Tag.YesButton.Enabled){ throw 'Yes initially enabled' }
   if(-not [object]::ReferenceEquals($dialog.AcceptButton,$dialog.Tag.NoButton)){ throw 'Default is not No' }
   if(-not [object]::ReferenceEquals($dialog.CancelButton,$dialog.Tag.CancelButton)){ throw 'Escape is not Cancel' }
   if($language -eq 'he' -and ($dialog.RightToLeft -ne [Windows.Forms.RightToLeft]::Yes -or -not $dialog.RightToLeftLayout)){ throw 'Hebrew RTL is missing' }
   if($dialog.Tag.RequiredPhrase -cne $dialog.Tag.Catalog.$language.Stages[0].Phrase){ throw 'Initial required phrase is wrong' }
  }finally{ $dialog.Dispose() }
 }
 # Drive the REAL language selector and assert the live control state it produces.
 $dialog=New-RemoteAccessSafetyDialog -Stage 1 -Language en
 try{
  $tag=$dialog.Tag
  $tag.InputBox.Text=$tag.Catalog.en.Stages[0].Phrase
  if(-not $tag.YesButton.Enabled){ throw 'Exact English phrase did not enable Yes' }
  $tag.LanguageCombo.SelectedIndex=1
  if($tag.Language -ne 'he'){ throw 'Selector did not switch to Hebrew' }
  if($tag.InputBox.Text -ne ''){ throw 'Switching language did not clear the typed phrase' }
  if($tag.YesButton.Enabled){ throw 'Yes stayed enabled after switching language' }
  if($tag.RequiredPhrase -cne $tag.Catalog.he.Stages[0].Phrase){ throw 'Required phrase did not switch to Hebrew' }
  if($dialog.RightToLeft -ne [Windows.Forms.RightToLeft]::Yes -or -not $dialog.RightToLeftLayout){ throw 'Hebrew RTL was not applied by the selector' }
  if($dialog.Text -cne ($tag.Catalog.he.Title+' (1/3)')){ throw 'Dialog title did not switch to Hebrew' }
  if($tag.YesButton.Text -cne $tag.Catalog.he.Yes -or $tag.NoButton.Text -cne $tag.Catalog.he.No -or $tag.CancelButton.Text -cne $tag.Catalog.he.Cancel){ throw 'Buttons were not relabelled' }
  $tag.InputBox.Text=$tag.Catalog.en.Stages[0].Phrase
  if($tag.YesButton.Enabled){ throw 'English phrase unlocked Yes while Hebrew was selected' }
  $tag.InputBox.Text=$tag.Catalog.he.Stages[0].Phrase
  if(-not $tag.YesButton.Enabled){ throw 'Hebrew phrase did not unlock Yes' }
  $tag.LanguageCombo.SelectedIndex=0
  if($tag.YesButton.Enabled -or $tag.InputBox.Text -ne '' -or $dialog.RightToLeftLayout){ throw 'Switching back to English did not reset the dialog' }
 }finally{ $dialog.Dispose() }
}
if($env:RATB_PROBE_LANGUAGE){
 $dialog=& $m { param($lang) New-RemoteAccessSafetyDialog -Stage 1 -Language $lang } $env:RATB_PROBE_LANGUAGE
 $result=$dialog.ShowDialog()
 $approved=[bool]($dialog.Tag.Approved -and $result -eq 'Yes')
 $dialog.Dispose()
 [IO.File]::WriteAllText($env:RATB_PROBE_RESULT,[string]$approved)
 exit 0
}
$value=@(Confirm-AllowRemoteAccess)
if($value.Count -ne 1 -or $value[0] -isnot [bool]){ throw 'Bad confirmation result' }
[IO.File]::WriteAllText($env:RATB_PROBE_RESULT,[string]$value[0])
exit 0
'@)
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
  $psi=New-Object Diagnostics.ProcessStartInfo
  $psi.FileName=(Get-Process -Id $PID).Path
  $psi.Arguments='-NoProfile -STA -ExecutionPolicy Bypass -File "'+$childFile+'"'
  $psi.UseShellExecute=$false;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
  $psi.EnvironmentVariables['RATB_PROBE_MODULE']=$modulePath;$psi.EnvironmentVariables['RATB_PROBE_RESULT']=$resultFile;$psi.EnvironmentVariables['RATB_PROBE_EVIDENCE']=$EvidenceDir
  if($case.Language -eq 'he'){ $psi.EnvironmentVariables['RATB_PROBE_LANGUAGE']='he' }
  $process=New-Object Diagnostics.Process;$process.StartInfo=$psi
  if(-not $process.Start()){ throw 'Native dialog child failed to start' }
  $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
  $language=if($case.Language){[string]$case.Language}else{'en'}
  for($stage=1;$stage -le $case.Count;$stage++){
   Write-Host "Native proof: $($case.Case) stage $stage"
   $title=[string]$catalog.$language.Title+' ('+$stage+'/3)'
   $window=Wait-Dialog $process $stage $title
   $yesText=[string]$catalog.$language.Yes
   Assert-YesEnabled $window $yesText $false 'empty input'
   $rtl=([BilingualProbe]::GetWindowLong($window,-20) -band 0x400000) -ne 0
   if($rtl -ne ($language -eq 'he')){ throw "RTL layout does not match language $language" }
   $combo=Get-LanguageBox $window
   $itemCount=[BilingualProbe]::SendMessage($combo,0x0146,[IntPtr]::Zero,[IntPtr]::Zero).ToInt64()
   if($itemCount -ne 2){ throw "Language selector has $itemCount entries; expected English and Hebrew" }
   $selected=[BilingualProbe]::SendMessage($combo,0x0147,[IntPtr]::Zero,[IntPtr]::Zero).ToInt64()
   $expectedIndex=if($language -eq 'he'){1}else{0}
   if($selected -ne $expectedIndex){ throw "Dialog did not start in $language" }
   # Localized field labels must actually be present on the live dialog.
   foreach($label in @([string]$catalog.$language.LanguageLabel,[string]$catalog.$language.Instruction,[string]$catalog.$language.Stages[$stage-1].Phrase)){
    $found=$false
    foreach($child in Get-Children $window){
     if([BilingualProbe]::Class($child) -like '*STATIC*' -and [BilingualProbe]::Title($child) -eq $label){ $found=$true; break }
    }
    if(-not $found){ throw "Localized label missing on dialog: $label" }
   }
   foreach($buttonText in @([string]$catalog.$language.Yes,[string]$catalog.$language.No,[string]$catalog.$language.Cancel)){
    [void](Get-Button $window $buttonText)
   }
   $warning=[BilingualProbe]::Text((Get-Warning $window))
   $expected=[string]$catalog.$language.Stages[$stage-1].Warning
   if($warning.Replace("`r`n","`n") -ne $expected.Replace("`r`n","`n")){ throw "Wrong $language warning text in the native control" }
   $other=if($language -eq 'en'){'he'}else{'en'}
   Set-InputText $window ([string]$catalog.$other.Stages[$stage-1].Phrase)
   Assert-YesEnabled $window $yesText $false 'phrase from the other language must not unlock Yes'
   Set-InputText $window 'incorrect phrase'
   Assert-YesEnabled $window $yesText $false 'wrong phrase must not unlock Yes'
   $button=if($stage -eq $case.Count){$case.End}else{'Yes'}
   if($button -eq 'Yes'){
    Set-InputText $window ([string]$catalog.$language.Stages[$stage-1].Phrase)
    Assert-YesEnabled $window $yesText $true 'exact selected-language phrase must unlock Yes'
   }
   Save-Image $window ("$language-stage-$stage.png")
   if($button -eq 'Close'){ [void][BilingualProbe]::PostMessage($window,0x0010,[IntPtr]::Zero,[IntPtr]::Zero) }
   else{ [void][BilingualProbe]::SendMessage((Get-Button $window ([string]$catalog.$language.$button)),0x00F5,[IntPtr]::Zero,[IntPtr]::Zero) }
  }
  if(-not $process.WaitForExit(15000)){ throw "Dialog sequence did not finish: $($case.Case)" }
  $output=$stdout.GetAwaiter().GetResult()+$stderr.GetAwaiter().GetResult()
  if($process.ExitCode -ne 0){ throw "Native child failed: $output" }
  if(-not (Test-Path -LiteralPath $resultFile)){ throw 'No native result file' }
  $result=[IO.File]::ReadAllText($resultFile)
  if($result -ne $case.Expected){ throw "Wrong result $($case.Case): $result" }
  $records += [pscustomobject]@{Case=$case.Case;Dialogs=$case.Count;Result=$result;Native=$true;DefaultButton='No';TypedPhraseGate=$true;Language=$language}
  Write-Host "PASS: bilingual native $($case.Case), result=$result."
  $process.Dispose();$process=$null
 }
 [IO.File]::WriteAllText((Join-Path $EvidenceDir 'results.json'),($records|ConvertTo-Json -Depth 4))
}finally{
 if($null -ne $process){ if(-not $process.HasExited){ $process.Kill(); [void]$process.WaitForExit(5000) }; $process.Dispose() }
 if(Test-Path -LiteralPath $fixture){ Remove-Item -LiteralPath $fixture -Recurse -Force }
}
exit 0
