[CmdletBinding()]
param(
    [ValidateRange(1, 4)]
    [int]$Count = 2,
    [switch]$Reinstall
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$SdkRoot = Join-Path $env:LOCALAPPDATA "Android\Sdk"
$EmulatorExe = Join-Path $SdkRoot "emulator\emulator.exe"
$AdbExe = Join-Path $SdkRoot "platform-tools\adb.exe"
$RepoRoot = Split-Path -Parent $PSScriptRoot
$ApkPath = Join-Path $RepoRoot "frontend\build\app\outputs\flutter-apk\app-release.apk"

if (-not (Test-Path $EmulatorExe)) {
    Write-Error "ไม่พบ emulator.exe ที่ $EmulatorExe"
}
if (-not (Test-Path $AdbExe)) {
    Write-Error "ไม่พบ adb.exe ที่ $AdbExe"
}

$AvdList = @(& $EmulatorExe -list-avds 2>$null | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
if ($AvdList.Count -eq 0) {
    Write-Error "ไม่พบ Android Virtual Device (AVD) ในเครื่อง"
}

$AvdName = if ($AvdList -contains "Medium_Phone_API_36.1") {
    "Medium_Phone_API_36.1"
} else {
    $AvdList[0]
}

Write-Host "กำลังเตรียมเปิด Emulator '$AvdName' จำนวน $Count เครื่อง..." -ForegroundColor Cyan

& $AdbExe start-server | Out-Null
$ExistingSerials = @(
    & $AdbExe devices 2>$null |
    Select-String -Pattern "^(emulator-\d+)\s+(device|offline)" |
    ForEach-Object { $_.Matches[0].Groups[1].Value }
)

$Ports = @(5554, 5556, 5558, 5560)[0..($Count - 1)]
$TargetSerials = @()
$SpawnedProcs = @()

foreach ($Port in $Ports) {
    $Serial = "emulator-$Port"
    $TargetSerials += $Serial
    if ($ExistingSerials -contains $Serial) {
        Write-Host "[$Serial] เปิดอยู่แล้ว ข้ามการสตาร์ทใหม่" -ForegroundColor Yellow
        continue
    }

    $Args = @(
        "-avd", $AvdName,
        "-port", "$Port",
        "-read-only",
        "-no-snapshot-load",
        "-no-boot-anim",
        "-gpu", "host",
        "-camera-back", "virtualscene",
        "-camera-front", "emulated"
    )
    Write-Host "[$Serial] กำลังเปิดหน้าต่าง Emulator..." -ForegroundColor Green
    $Proc = Start-Process -FilePath $EmulatorExe -ArgumentList $Args -PassThru
    $SpawnedProcs += @{ Serial = $Serial; Port = $Port; Process = $Proc }
    Start-Sleep -Milliseconds 700
}

Write-Host "กำลังรอ Android บูตให้พร้อมใช้งาน (สูงสุด 90 วินาที)..." -ForegroundColor Cyan
$Deadline = (Get-Date).AddSeconds(90)
$Booted = @{}

while ($Booted.Count -lt $TargetSerials.Count -and (Get-Date) -lt $Deadline) {
    foreach ($Serial in $TargetSerials) {
        if ($Booted.ContainsKey($Serial)) { continue }
        $State = (& $AdbExe -s $Serial get-state 2>$null)
        if ($State -eq "device") {
            $Comp = (& $AdbExe -s $Serial shell getprop sys.boot_completed 2>$null).Trim()
            if ($Comp -eq "1") {
                $Booted[$Serial] = $true
                Write-Host "[$Serial] บูตเสร็จพร้อมเล่นแล้ว!" -ForegroundColor Green
            }
        }
    }
    if ($Booted.Count -lt $TargetSerials.Count) {
        Start-Sleep -Seconds 2
    }
}

# Tile visible emulator windows side-by-side cleanly on primary monitor work area
try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class BcWin32 {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool MoveWindow(IntPtr hWnd, int X, int Y, int nWidth, int nHeight, bool bRepaint);
    [DllImport("user32.dll")]
    public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
}
"@ -ErrorAction SilentlyContinue

    $WorkArea = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $WinWidth = [Math]::Max(340, [Math]::Min(440, [int](($WorkArea.Width - 20) / [Math]::Max(1, $Count))))
    $WinHeight = [Math]::Max(620, [Math]::Min(860, $WorkArea.Height - 40))

    $EmuProcs = @(
        Get-Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.MainWindowHandle -ne [IntPtr]::Zero -and
            $_.MainWindowTitle -like "Android Emulator*"
        } |
        Sort-Object StartTime
    )

    for ($i = 0; $i -lt $EmuProcs.Count; $i++) {
        $p = $EmuProcs[$i]
        $x = $WorkArea.Left + 10 + ($i * ($WinWidth + 8))
        $y = $WorkArea.Top + 20
        [void][BcWin32]::ShowWindowAsync($p.MainWindowHandle, 9)
        [void][BcWin32]::MoveWindow($p.MainWindowHandle, $x, $y, $WinWidth, $WinHeight, $true)
    }
} catch {
    # Non-fatal if window tiling is unavailable
}

foreach ($Serial in $TargetSerials) {
    if (-not $Booted.ContainsKey($Serial)) {
        Write-Warning "[$Serial] ยังบูตไม่ทันในเวลา 90 วินาที"
        continue
    }

    $PkgPath = (& $AdbExe -s $Serial shell pm path com.bcaichat.app 2>$null)
    if ($Reinstall -or [string]::IsNullOrWhiteSpace($PkgPath)) {
        if (Test-Path $ApkPath) {
            Write-Host "[$Serial] กำลังติดตั้ง BC Ai Chat (APK ล่าสุด)..." -ForegroundColor Cyan
            & $AdbExe -s $Serial install -r $ApkPath | Out-Null
        } else {
            Write-Warning "ไม่พบ APK ที่ $ApkPath กรุณา build ก่อน"
        }
    }

    # Pre-grant microphone & camera permissions so calls work immediately
    & $AdbExe -s $Serial shell pm grant com.bcaichat.app android.permission.RECORD_AUDIO 2>$null | Out-Null
    & $AdbExe -s $Serial shell pm grant com.bcaichat.app android.permission.CAMERA 2>$null | Out-Null

    Write-Host "[$Serial] กำลังเปิดแอป BC Ai Chat..." -ForegroundColor Green
    & $AdbExe -s $Serial shell am start -n com.bcaichat.app/.MainActivity | Out-Null
}

Write-Host ""
Write-Host "เปิด Emulator เรียบร้อยแล้ว ($($Booted.Count)/$Count เครื่องพร้อมใช้งาน)" -ForegroundColor Cyan
Write-Host "เมื่อเลิกเล่นแล้ว ปิดหน้าต่าง Emulator หรือสั่ง: `"$AdbExe`" -s emulator-5554 emu kill" -ForegroundColor DarkGray
