# _downstream_watchdog.ps1 -- Fire 06b (panel build) when RoBERTa scoring is
# fully complete, then STOP for review. Does NOT run 07c/08b (Option B).
#
# Completion = ALL year files scored AND no parts_* dirs (nothing mid-merge)
#              AND no GPU scoring workers still running.
#
# When complete it runs `run_pipeline.R 15 15` (step 15 = 06b only), records the
# result, and writes output\logs\06b_READY_FOR_REVIEW.txt.
#
# NOTE: this watchdog is a normal process -- it will NOT survive a machine reboot.
# If the box restarts before scoring finishes, relaunch the GPU workers AND this
# watchdog.
#
# Usage: powershell -ExecutionPolicy Bypass -File R\_downstream_watchdog.ps1

$ErrorActionPreference = "Stop"
$root      = "C:\Users\ammonsj\Ideas"
$Rscript   = "C:\Program Files\R\R-4.4.1\bin\Rscript.exe"
$scoredDir = Join-Path $root "data_panels\roberta_scored"
$inputDir  = Join-Path $root "data_parquet\articles_antisem_scored"
$logFile   = Join-Path $root "output\logs\downstream_watchdog.log"

function Log($m) {
    Add-Content -Path $logFile -Value ("[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $m)
}

# Guard against a second watchdog via a PID lockfile (command-line matching is
# unreliable -- launcher/verify commands also mention this script's name).
$lock = Join-Path $root "output\logs\.downstream_watchdog.lock"
if (Test-Path $lock) {
    $oldpid = (Get-Content $lock -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($oldpid -and (Get-Process -Id ([int]$oldpid) -ErrorAction SilentlyContinue)) {
        Log "Another watchdog (PID $oldpid) already running; exiting this one."
        exit 0
    }
    Log "Stale lock (PID $oldpid not alive) -- taking over."
}
Set-Content -Path $lock -Value $PID

$target = @(Get-ChildItem (Join-Path $inputDir "antisem_scored_*.parquet") -ErrorAction SilentlyContinue).Count
Log "Watchdog started. Target = $target scored years. Plan: auto-run 06b ONLY when scoring fully completes, then STOP for review (07c/08b will NOT run)."

$tick = 0; $lastDone = -1
while ($true) {
    Start-Sleep -Seconds 120
    $tick++
    $done = @(Get-ChildItem (Join-Path $scoredDir "roberta_scored_*.parquet") -ErrorAction SilentlyContinue).Count
    $partsDirs = @(Get-ChildItem $scoredDir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'parts_*' }).Count
    $gpu = @(Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*score_roberta_worker.py*' -and $_.CommandLine -like '*--name GPU*' }).Count

    if ($done -ge $target -and $partsDirs -eq 0 -and $gpu -eq 0) {
        Log "Scoring COMPLETE (done=$done/$target, parts_dirs=0, gpu_workers=0). Launching 06b panel build..."
        break
    }
    if ($done -ne $lastDone -or ($tick % 15 -eq 0)) {
        Log "waiting: done=$done/$target, parts_dirs=$partsDirs, gpu_workers=$gpu"
        $lastDone = $done
    }
}

$stamp    = Get-Date -Format "yyyyMMdd_HHmm"
$buildLog = Join-Path $root "output\logs\06b_build_$stamp.log"
$buildErr = Join-Path $root "output\logs\06b_build_$stamp.err.log"
Log "Running run_pipeline.R 15 15 (06b only). stdout->$buildLog ; live detail in output\logs\06b_treatment_panel_antisem_*.log"

$p = Start-Process -FilePath $Rscript -ArgumentList "$root\run_pipeline.R", "15", "15" `
        -WorkingDirectory $root -RedirectStandardOutput $buildLog -RedirectStandardError $buildErr `
        -WindowStyle Hidden -PassThru -Wait
$rc = $p.ExitCode
Log "06b finished, exit code = $rc."

$panels = @(Get-ChildItem (Join-Path $root "data_panels\did_panel_antisem_*.parquet") -ErrorAction SilentlyContinue)
Log "Panels built: $($panels.Count). [$(($panels | ForEach-Object { $_.BaseName }) -join ', ')]"

$marker = Join-Path $root "output\logs\06b_READY_FOR_REVIEW.txt"
Set-Content -Path $marker -Value @"
06b panel build finished at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), exit code $rc.
Panels built: $($panels.Count) (one per political figure with >=1 treated newspaper).
STOPPED here per plan (Option B) -- 07c and 08b were NOT run.
After reviewing the panels, continue with:  Rscript run_pipeline.R 16 17
"@
Remove-Item $lock -ErrorAction SilentlyContinue
Log "Wrote READY-FOR-REVIEW marker: $marker. Watchdog done."
