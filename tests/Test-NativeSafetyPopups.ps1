param([string]$EvidenceDir)
$ErrorActionPreference='Stop'
if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){Write-Host 'SKIP: real native popup proof requires Windows.';exit 0}
$root=Split-Path $PSScriptRoot -Parent
if(-not $EvidenceDir){$EvidenceDir=Join-Path $root 'dist/native-safety-proof'}
New-Item -ItemType Directory -Path $EvidenceDir -Force | Out-Null
$modulePath=Join-Path $root 'integration/RemoteAccessSafety.psm1'
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class SafetyDialogProbe {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int max);
    [DllImport("user32.dll")] public static extern IntPtr GetDlgItem(IntPtr h, int id);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left,Top,Right,Bottom; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out Rect r);
    public static IntPtr Find(int wantedPid, string wantedTitle) {
        IntPtr found=IntPtr.Zero;
        EnumWindows(delegate(IntPtr h,IntPtr l) {
            uint pid; GetWindowThreadProcessId(h,out pid);
            if(pid!=(uint)wantedPid) return true;
            var title=new StringBuilder(512); GetWindowText(h,title,title.Capacity);
            if(title.ToString()!=wantedTitle) return true;
            found=h; return false;
        },IntPtr.Zero);
        return found;
    }
}
'@
$base=if($env:RUNNER_TEMP){$env:RUNNER_TEMP}else{[IO.Path]::GetTempPath()}
$fixture=Join-Path $base ('native-safety-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
$childScript=@'
$ErrorActionPreference='Stop'
Import-Module $env:RATB_PROBE_MODULE -Force
$value=@(Confirm-AllowRemoteAccess)
if($value.Count -ne 1 -or $value[0] -isnot [bool]){throw 'Bad confirmation result'}
[IO.File]::WriteAllText($env:RATB_PROBE_RESULT,[string]$value[0])
exit 0
'@
$childFile=Join-Path $fixture 'popup-child.ps1'
[IO.File]::WriteAllText($childFile,$childScript)
$records=@();$process=$null
try {
    foreach($case in @(
        @{Name='no-first';Buttons=@(7);Expected='False'},
        @{Name='no-second';Buttons=@(6,7);Expected='False'},
        @{Name='no-third';Buttons=@(6,6,7);Expected='False'},
        @{Name='cancel';Buttons=@(2);Expected='False'},
        @{Name='close';Buttons=@(0);Expected='False'},
        @{Name='yes-all';Buttons=@(6,6,6);Expected='True'}
    )) {
        $resultFile=Join-Path $fixture ($case.Name+'.txt')
        $psi=New-Object Diagnostics.ProcessStartInfo
        $psi.FileName=(Get-Process -Id $PID).Path
        $psi.Arguments='-NoProfile -STA -ExecutionPolicy Bypass -File "'+$childFile+'"'
        $psi.UseShellExecute=$false
        $psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
        $psi.EnvironmentVariables['RATB_PROBE_MODULE']=$modulePath
        $psi.EnvironmentVariables['RATB_PROBE_RESULT']=$resultFile
        $process=New-Object Diagnostics.Process;$process.StartInfo=$psi
        if(-not $process.Start()){throw 'Popup child did not start'}
        $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        for($stage=1;$stage -le $case.Buttons.Count;$stage++) {
            $title='Remote access safety confirmation ({0} of 3)' -f $stage
            $deadline=[DateTime]::UtcNow.AddSeconds(20);$window=[IntPtr]::Zero
            while([DateTime]::UtcNow -lt $deadline -and -not $process.HasExited){
                $window=[SafetyDialogProbe]::Find($process.Id,$title)
                if($window -ne [IntPtr]::Zero){break}
                Start-Sleep -Milliseconds 100
            }
            if($window -eq [IntPtr]::Zero){throw "Native dialog missing: $($case.Name) stage $stage"}
            foreach($buttonId in 6,7,2){if([SafetyDialogProbe]::GetDlgItem($window,$buttonId) -eq [IntPtr]::Zero){throw "Native Yes/No/Cancel button $buttonId missing"}}
            $default=[SafetyDialogProbe]::SendMessage($window,0x400,[IntPtr]::Zero,[IntPtr]::Zero).ToInt64() -band 0xffff
            if($default -ne 7){throw "Unsafe default button: $default instead of No"}
            if($case.Name -eq 'yes-all') {
                $rect=New-Object SafetyDialogProbe+Rect
                if(-not [SafetyDialogProbe]::GetWindowRect($window,[ref]$rect)){throw 'Popup bounds unavailable'}
                $width=$rect.Right-$rect.Left;$height=$rect.Bottom-$rect.Top
                $bitmap=New-Object Drawing.Bitmap($width,$height)
                $graphics=[Drawing.Graphics]::FromImage($bitmap)
                try {
                    Start-Sleep -Milliseconds 150
                    $graphics.CopyFromScreen($rect.Left,$rect.Top,0,0,$bitmap.Size)
                    $bitmap.Save((Join-Path $EvidenceDir ("popup-stage-$stage.png")),[Drawing.Imaging.ImageFormat]::Png)
                } finally {$graphics.Dispose();$bitmap.Dispose()}
            }
            $answer=[int]$case.Buttons[$stage-1]
            if($answer -eq 0){$sent=[SafetyDialogProbe]::PostMessage($window,0x10,[IntPtr]::Zero,[IntPtr]::Zero)}
            else{$sent=[SafetyDialogProbe]::PostMessage($window,0x111,[IntPtr]$answer,[SafetyDialogProbe]::GetDlgItem($window,$answer))}
            if(-not $sent){throw 'Native button post failed'}
        }
        if(-not $process.WaitForExit(10000)){throw "Popup chain did not finish after $($case.Name)"}
        $output=$stdout.GetAwaiter().GetResult()+$stderr.GetAwaiter().GetResult()
        if($process.ExitCode -ne 0){throw "Popup child failed: $output"}
        if(-not (Test-Path -LiteralPath $resultFile)){throw 'No native proof result file'}
        $result=[IO.File]::ReadAllText($resultFile)
        if($result -ne $case.Expected){throw "Wrong native result: $($case.Name) = $result"}
        $records += [pscustomobject]@{Case=$case.Name;Dialogs=$case.Buttons.Count;Result=$result;DefaultButton='No';Native=$true}
        Write-Host "PASS: native $($case.Name), $($case.Buttons.Count) dialogs, result=$result, default=No."
        $process.Dispose();$process=$null
    }
    [IO.File]::WriteAllText((Join-Path $EvidenceDir 'results.json'),($records|ConvertTo-Json -Depth 4))
} finally {
    if($null -ne $process){if(-not $process.HasExited){$process.Kill();[void]$process.WaitForExit(5000)};$process.Dispose()}
    if(Test-Path -LiteralPath $fixture){Remove-Item -LiteralPath $fixture -Recurse -Force}
}
exit 0
