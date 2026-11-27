# ── yak-seed 回归测试运行器 (PowerShell) ──
# 用法: ./run_tests.ps1 [-SeedPath <yak-seed.exe 路径>]
param(
    [string]$SeedPath = ""
)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
# 默认产物路径相对脚本目录解析，避免依赖调用方当前目录
$DefaultSeed = Join-Path -Path $ScriptDir -ChildPath "../out/yak-seed.exe"

if ([string]::IsNullOrWhiteSpace($SeedPath)) {
    $SeedPath = $DefaultSeed
}
$Seed = $SeedPath
if (Test-Path -LiteralPath $SeedPath) { $Seed = (Resolve-Path -LiteralPath $SeedPath).Path }

if (-not (Test-Path $Seed)) {
    Write-Host "错误: 找不到 yak-seed: $Seed" -ForegroundColor Red
    exit 2
}

Write-Host "════════════════════════════════════════"
Write-Host "  yak-seed 回归测试"
Write-Host "  解释器: $Seed"
Write-Host "════════════════════════════════════════"
Write-Host ""

$HostWork = Join-Path $ScriptDir '../tmp/tests-ps'
New-Item -ItemType Directory -Force -Path $HostWork | Out-Null
function Quote-Argument([string]$Value) {
    $quoted = [Text.StringBuilder]::new()
    [void]$quoted.Append('"')
    $slashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') { $slashes++; continue }
        if ($character -eq '"') {
            [void]$quoted.Append(('\' * ($slashes * 2 + 1)))
        } else {
            [void]$quoted.Append(('\' * $slashes))
        }
        [void]$quoted.Append($character)
        $slashes = 0
    }
    [void]$quoted.Append(('\' * ($slashes * 2)))
    [void]$quoted.Append('"')
    $quoted.ToString()
}
$pass = 0
$fail = 0
$failedTests = @()

$yakFiles = Get-ChildItem -Path $ScriptDir -Filter "t*.yak" | Sort-Object Name

foreach ($file in $yakFiles) {
    $name = $file.BaseName
    
    # 提取注释标记
    $expectedLines = @()
    $expectedTrap = ""
    $memLimit = ""
    $hostArgs = @()
    $programArgs = @()
    $outputPaths = @{}
    $expectedFiles = @{}
    $expectedHex = @{}
    foreach ($line in Get-Content -LiteralPath $file.FullName -Encoding UTF8) {
        if ($line -match 'expected_stdout:\s*(.+)$') {
            $expectedLines += $matches[1]
        }
        if ($line -match 'expected_trap:\s*(.+)$') {
            $expectedTrap = $matches[1].Trim()
        }
        if ($line -match 'mem_limit:\s*(\d+)') {
            $memLimit = $matches[1]
        }
        if ($line -match '^//\s*(module|input|output_existing):\s*([^=]+)=(.+)$') {
            $kind = $matches[1]
            if ($kind -eq 'output_existing') { $kind = 'output' }
            $hostArgs += "--$kind"
            $hostArgs += $matches[2] + '=' + (Join-Path $ScriptDir $matches[3])
        }
        if ($line -match '^//\s*output:\s*([A-Za-z0-9_-]+)$') {
            $logical = $matches[1]
            $targetPath = [IO.Path]::GetFullPath((Join-Path $HostWork ($name + '.' + $logical + '.output')))
            if (Test-Path -LiteralPath $targetPath) { throw "Unexpected existing test output: $targetPath" }
            $outputPaths[$logical] = $targetPath
            $hostArgs += '--output'
            $hostArgs += $logical + '=' + $targetPath
        }
        if ($line -match '^//\s*expected_file_hex:\s*([^=]+)=([0-9a-f]+)$') { $expectedHex[$matches[1]] = $matches[2] }
        if ($line -match '^//\s*arg:\s*(.*)$') { $programArgs += $matches[1] }
        if ($line -match '^//\s*expected_file:\s*([^=]+)=(.*)$') { $expectedFiles[$matches[1]] = $matches[2] }

    }
    
    # 运行（mem_limit 标记 → 设 YAK_SEED_MEM 环境变量）
    if ($memLimit -ne "") {
        $env:YAK_SEED_MEM = $memLimit
    } else {
        $env:YAK_SEED_MEM = $null
    }
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $Seed
    $arguments = @($file.FullName) + $hostArgs + @('--') + $programArgs
    $info.Arguments = ($arguments | ForEach-Object { Quote-Argument $_ }) -join ' '
    $info.UseShellExecute = $false
    # 子进程输出固定按 UTF-8 解码，与源码及期望文本的编码保持一致。
    $info.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $info.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($info)
    $outTask = $process.StandardOutput.ReadToEndAsync()
    $errTask = $process.StandardError.ReadToEndAsync()
    $timedOut = !$process.WaitForExit(20000)
    if ($timedOut) { $process.Kill(); $process.WaitForExit() }
    $exitCode = if ($timedOut) { 124 } else { $process.ExitCode }
    $stdout = $outTask.Result.Replace("`r", "").TrimEnd("`n")
    $stderr = $errTask.Result.Replace("`r", "").TrimEnd("`n")
    $process.Dispose()
    $env:YAK_SEED_MEM = $null

    # 判定
    $ok = $true
    $reason = ""
    
    if ($expectedTrap -ne "") {
        # 期望 trap
        $combined = "$stdout`n$stderr"
        if ($exitCode -eq 1 -and $stderr.Contains($expectedTrap)) {
            $ok = $true
        } else {
            $ok = $false
            $reason = "expected trap='$expectedTrap' but exit=$exitCode output='$combined'"
        }
    } elseif ($exitCode -ne 0 -or $stderr -ne "") {
        $ok = $false
        $reason = "exit=$exitCode stderr=$stderr"
    } elseif ($expectedLines.Count -gt 0) {
        $expected = ($expectedLines -join "`n").TrimEnd()
        $actual = $stdout.TrimEnd()
        if ($expected -ne $actual) {
            $ok = $false
            $reason = "stdout mismatch: expected='$expected' got='$actual'"
        }
    }
    
    foreach ($logical in $outputPaths.Keys) {
        $targetPath = $outputPaths[$logical]
        if ($expectedTrap -ne "" -and (Test-Path -LiteralPath $targetPath)) { $ok = $false; $reason = 'output rollback failed' }
        if ($expectedFiles.ContainsKey($logical)) {
            if (!(Test-Path -LiteralPath $targetPath) -or [IO.File]::ReadAllText($targetPath) -cne $expectedFiles[$logical]) {
                $ok = $false; $reason = 'output file mismatch'
            }
        }
        if ($expectedHex.ContainsKey($logical)) {
            if (!(Test-Path -LiteralPath $targetPath) -or
                ([BitConverter]::ToString([IO.File]::ReadAllBytes($targetPath)).Replace('-', '').ToLowerInvariant() -cne $expectedHex[$logical])) {
                $ok = $false; $reason = 'binary output mismatch'
            }
        }
        if (Test-Path -LiteralPath $targetPath) { Remove-Item -LiteralPath $targetPath }
    }
    if ($ok) {
        Write-Host "  [PASS] $name"
        $pass++
    } else {
        Write-Host "  [FAIL] $name  ($reason)" -ForegroundColor Red
        $fail++
        $failedTests += $name
    }
}

Write-Host ""
Write-Host "════════════════════════════════════════"
Write-Host ("  通过: {0}  失败: {1}  总计: {2}" -f $pass, $fail, ($pass + $fail))
if ($fail -gt 0) {
    Write-Host ("  失败: {0}" -f ($failedTests -join ", "))
}
Write-Host "════════════════════════════════════════"

Remove-Item -LiteralPath $HostWork
if ($fail -eq 0) { exit 0 } else { exit 1 }
