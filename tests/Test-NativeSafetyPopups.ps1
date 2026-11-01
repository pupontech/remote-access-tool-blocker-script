param([string]$EvidenceDir)
$ErrorActionPreference='Stop'
if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){Write-Host 'SKIP: bilingual native dialog proof requires Windows.';exit 0}
$root=Split-Path $PSScriptRoot -Parent
if(-not $EvidenceDir){$EvidenceDir=Join-Path $root 'dist/native-safety-proof'}
New-Item -ItemType Directory -Path $EvidenceDir -Force | Out-Null
$modulePath=Join-Path $root 'integration/RemoteAccessSafety.psm1'
$catalog=[IO.File]::ReadAllText((Join-Path $root 'integration/RemoteAccessSafety.i18n.json'),[Text.Encoding]::UTF8)|ConvertFrom-Json
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class TypedSafetyDialogProbe {
 public delegate bool EnumProc(IntPtr h,IntPtr l);
 [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb,IntPtr l);
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h,StringBuilder s,int max);
 [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern IntPtr GetParent(IntPtr h);
 [DllImport("user32.dll")] public static extern int GetDlgCtrlID(IntPtr h);
 [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h,int index);
 [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h,uint msg,IntPtr w,IntPtr l);
 [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h,uint msg,IntPtr w,IntPtr l);
 [StructLayout(LayoutKind.Sequential)] public struct Rect {public int Left,Top,Right,Bottom;}
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h,out Rect r);
 public static string Title(IntPtr h){var s=new StringBuilder(1024);GetWindowText(h,s,s.Capacity);return s.ToString();}
 public static IntPtr Find(int wantedPid,int stage){
  IntPtr found=IntPtr.Zero;string suffix="("+stage+"/3)";
  EnumWindows(delegate(IntPtr h,IntPtr l){uint pid;GetWindowThreadProcessId(h,out pid);
   if(pid!=(uint)wantedPid || !IsWindowVisible(h))return true;
   if(!Title(h).EndsWith(suffix,StringComparison.Ordinal))return true;
   found=h;return false;},IntPtr.Zero);return found;
 }
}
'@
function Get-OwnedDialog {
 param($Process,[int]$Stage,[string]$ExpectedTitle='')
 $deadline=[DateTime]::UtcNow.AddSeconds(20)
 while([DateTime]::UtcNow -lt $deadline -and -not $Process.HasExited){
  $window=[TypedSafetyDialogProbe]::Find($Process.Id,$Stage)
  if($window -ne [IntPtr]::Zero -and (-not $ExpectedTitle -or [TypedSafetyDialogProbe]::Title($window) -eq $ExpectedTitle)){return $window}
  Start-Sleep -Milliseconds 100
 }
 throw "Owned dialog missing: stage=$Stage expected=$ExpectedTitle childExited=$($Process.HasExited)"
}
function Get-UiControl {
 param([IntPtr]$Window,[string]$Name)
 $element=[Windows.Automation.AutomationElement]::FromHandle($Window)
 $condition=New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::NameProperty,$Name)
 $control=$element.FindFirst([Windows.Automation.TreeScope]::Descendants,$condition)
 if($null -eq $control){throw "Missing UI control $Name in $([TypedSafetyDialogProbe]::Title($Window))"}
 return $control
}
function Get-InputValue {
 param([IntPtr]$Window,[string]$Name='SafetyInput')
 $control=Get-UiControl $Window $Name
 $pattern=$control.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern)
 return $pattern.Current.Value
}
function Set-InputValue {
 param([IntPtr]$Window,[string]$Value)
 $control=Get-UiControl $Window 'SafetyInput'
 $pattern=$control.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern)
 $pattern.SetValue($Value)
 Start-Sleep -Milliseconds 100
}
function Assert-YesEnabled {
 param([IntPtr]$Window,[bool]$Expected,[string]$Reason)
 $control=Get-UiControl $Window 'SafetyYes'
 if($control.Current.IsEnabled -ne $Expected){throw "Yes enabled=$($control.Current.IsEnabled), expected=$Expected ($Reason)"}
}
function Set-Language {
 param($Process,[int]$Stage,[IntPtr]$Window,[string]$Language)
 $combo=Get-UiControl $Window 'SafetyLanguage'
 $handle=[IntPtr]$combo.Current.NativeWindowHandle
 if($handle -eq [IntPtr]::Zero){throw 'Language selector has no native handle'}
 $index=if($Language -eq 'he'){1}else{0}
 [void][TypedSafetyDialogProbe]::SendMessage($handle,0x14E,[IntPtr]$index,[IntPtr]::Zero)
 $id=[TypedSafetyDialogProbe]::GetDlgCtrlID($handle)
 $parent=[TypedSafetyDialogProbe]::GetParent($handle)
 [void][TypedSafetyDialogProbe]::PostMessage($parent,0x111,[IntPtr](($id -band 0xffff) -bor 0x10000),$handle)
 Start-Sleep -Milliseconds 200 # RTL changes may recreate the native form handle.
 $title=$catalog.$Language.Title+' ('+$Stage+'/3)'
 return (Get-OwnedDialog $Process $Stage $title)
}
function Invoke-UiButton {
 param([IntPtr]$Window,[string]$Name)
 $control=Get-UiControl $Window $Name
 $pattern=$control.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern)
 try{$pattern.Invoke()}catch{if([TypedSafetyDialogProbe]::IsWindow($Window)){throw}}
}
function Save-DialogImage {
 param([IntPtr]$Window,[string]$Name)
 $rect=New-Object TypedSafetyDialogProbe+Rect
 if(-not [TypedSafetyDialogProbe]::GetWindowRect($Window,[ref]$rect)){throw 'Dialog rectangle unavailable'}
 $bitmap=New-Object Drawing.Bitmap(($rect.Right-$rect.Left),($rect.Bottom-$rect.Top))
 $graphics=[Drawing.Graphics]::FromImage($bitmap)
 try{Start-Sleep -Milliseconds 150;$graphics.CopyFromScreen($rect.Left,$rect.Top,0,0,$bitmap.Size);$bitmap.Save((Join-Path $EvidenceDir $Name),[Drawing.Imaging.ImageFormat]::Png)}finally{$graphics.Dispose();$bitmap.Dispose()}
}
$base=if($env:RUNNER_TEMP){$env:RUNNER_TEMP}else{[IO.Path]::GetTempPath()}
$fixture=Join-Path $base ('typed-native-safety-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
$childScript=@'
$ErrorActionPreference='Stop'
Import-Module $env:RATB_PROBE_MODULE -Force
$m=Get-Module RemoteAccessSafety
& $m {
 foreach($language in 'en','he'){
  $dialog=New-RemoteAccessSafetyDialog -Stage 1 -Language $language
  try{
   if($dialog.Tag.YesButton.Enabled){throw 'Yes initially enabled'}
   if(-not [object]::ReferenceEquals($dialog.AcceptButton,$dialog.Tag.NoButton)){throw 'Default is not No'}
   if(-not [object]::ReferenceEquals($dialog.CancelButton,$dialog.Tag.CancelButton)){throw 'Escape is not Cancel'}
   if($language -eq 'he' -and ($dialog.RightToLeft -ne [Windows.Forms.RightToLeft]::Yes -or -not $dialog.RightToLeftLayout)){throw 'Hebrew RTL is missing'}
  }finally{$dialog.Dispose()}
 }
}
$value=@(Confirm-AllowRemoteAccess)
if($value.Count -ne 1 -or $value[0] -isnot [bool]){throw 'Bad confirmation result'}
[IO.File]::WriteAllText($env:RATB_PROBE_RESULT,[string]$value[0])
exit 0
'@
$childFile=Join-Path $fixture 'dialog-child.ps1'
[IO.File]::WriteAllText($childFile,$childScript)
$records=@();$process=$null
try{
 foreach($case in @(
  @{Name='no-first';Count=1;End='SafetyNo';Languages=@('en');Expected='False'},
  @{Name='no-second';Count=2;End='SafetyNo';Languages=@('en','en');Expected='False'},
  @{Name='no-third';Count=3;End='SafetyNo';Languages=@('en','en','en');Expected='False'},
  @{Name='cancel';Count=1;End='SafetyCancel';Languages=@('he');Expected='False'},
  @{Name='close';Count=1;End='Close';Languages=@('en');Expected='False'},
  @{Name='english-all';Count=3;End='SafetyYes';Languages=@('en','en','en');Expected='True'},
  @{Name='hebrew-all';Count=3;End='SafetyYes';Languages=@('he','he','he');Expected='True'},
  @{Name='switch-language';Count=3;End='SafetyYes';Languages=@('he','en','he');Expected='True'}
 )){
  $resultFile=Join-Path $fixture ($case.Name+'.txt')
  $psi=New-Object Diagnostics.ProcessStartInfo
  $psi.FileName=(Get-Process -Id $PID).Path
  $psi.Arguments='-NoProfile -STA -ExecutionPolicy Bypass -File "'+$childFile+'"'
  $psi.UseShellExecute=$false;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
  $psi.EnvironmentVariables['RATB_PROBE_MODULE']=$modulePath;$psi.EnvironmentVariables['RATB_PROBE_RESULT']=$resultFile
  $process=New-Object Diagnostics.Process;$process.StartInfo=$psi
  if(-not $process.Start()){throw 'Native dialog child failed to start'}
  $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
  $currentLanguage='en'
  for($stage=1;$stage -le $case.Count;$stage++){
   Write-Host "Native proof: $($case.Name) stage $stage"
   $window=Get-OwnedDialog $process $stage ($catalog.$currentLanguage.Title+' ('+$stage+'/3)')
   Assert-YesEnabled $window $false 'empty input'
   $language=$case.Languages[$stage-1]
   if($language -ne $currentLanguage){
    # An approved phrase must not survive switching language.
    Set-InputValue $window $catalog.$currentLanguage.Stages[$stage-1].Phrase
    Assert-YesEnabled $window $true 'exact pre-switch phrase'
    $window=Set-Language $process $stage $window $language
    Assert-YesEnabled $window $false 'language switch reset'
    if((Get-InputValue $window) -ne ''){throw 'Language switch did not clear typed input'}
    $currentLanguage=$language
   }
   $rtl=([TypedSafetyDialogProbe]::GetWindowLong($window,-20) -band 0x400000) -ne 0
   if($rtl -ne ($language -eq 'he')){throw "Native RTL mismatch for $language"}
   $warning=Get-InputValue $window 'SafetyWarning'
   $expected=$catalog.$language.Stages[$stage-1].Warning
   if($warning.Replace("`r`n","`n") -ne $expected.Replace("`r`n","`n")){throw 'Wrong language warning text in actual native control'}
   $other=if($language -eq 'en'){'he'}else{'en'}
   Set-InputValue $window $catalog.$other.Stages[$stage-1].Phrase
   Assert-YesEnabled $window $false 'other-language phrase rejected'
   Set-InputValue $window 'incorrect phrase'
   Assert-YesEnabled $window $false 'wrong phrase rejected'
   $final=$stage -eq $case.Count
   $button=if($final){$case.End}else{'SafetyYes'}
   if($button -eq 'SafetyYes'){
    Set-InputValue $window $catalog.$language.Stages[$stage-1].Phrase
    Assert-YesEnabled $window $true 'correct selected-language phrase'
   }
   if($case.Name -in 'english-all','hebrew-all'){Save-DialogImage $window ($case.Name+'-stage-'+$stage+'.png')}
   if($button -eq 'Close'){[void][TypedSafetyDialogProbe]::PostMessage($window,0x10,[IntPtr]::Zero,[IntPtr]::Zero)}else{Invoke-UiButton $window $button}
  }
  if(-not $process.WaitForExit(10000)){throw "Dialog sequence did not finish: $($case.Name)"}
  $output=$stdout.GetAwaiter().GetResult()+$stderr.GetAwaiter().GetResult()
  if($process.ExitCode -ne 0){throw "Native child failed: $output"}
  if(-not (Test-Path -LiteralPath $resultFile)){throw 'No native result file'}
  $result=[IO.File]::ReadAllText($resultFile)
  if($result -ne $case.Expected){throw "Wrong result $($case.Name): $result"}
  $records += [pscustomobject]@{Case=$case.Name;Dialogs=$case.Count;Result=$result;Native=$true;DefaultButton='No';TypedPhraseGate=$true;Language=($case.Languages -join ',')}
  Write-Host "PASS: bilingual native $($case.Name), result=$result."
  $process.Dispose();$process=$null
 }
 [IO.File]::WriteAllText((Join-Path $EvidenceDir 'results.json'),($records|ConvertTo-Json -Depth 4))
}finally{
 if($null -ne $process){if(-not $process.HasExited){$process.Kill();[void]$process.WaitForExit(5000)};$process.Dispose()}
 if(Test-Path -LiteralPath $fixture){Remove-Item -LiteralPath $fixture -Recurse -Force}
}
exit 0
