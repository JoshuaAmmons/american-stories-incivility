# _launch_gpu_workers.ps1 — (Re)launch the two GPU RoBERTa scoring workers.
#
# Safe to run after a crash/reboot/restart: each worker skips already-finished
# years (roberta_scored_<year>.parquet) and already-finished parts
# (parts_<year>/part_NNN.parquet), so it resumes exactly where it left off.
#
# Uses cmd-shell redirection + `python -u` for real-time logs (unlike
# Start-Process -RedirectStandardOutput, which buffers output to disk).
#
# Usage: powershell -ExecutionPolicy Bypass -File R\_launch_gpu_workers.ps1

$ErrorActionPreference = "Stop"
$root   = "C:\Users\ammonsj\Ideas"
$py     = "C:\Users\ammonsj\AppData\Local\Programs\Python\Python313\python.exe"
$stamp  = Get-Date -Format "yyyyMMdd_HHmm"

if (-not (Test-Path $py)) { Write-Error "Python not found: $py"; exit 1 }
if (-not (Test-Path (Join-Path $root 'models\roberta_antisemitism'))) { Write-Error "Model dir missing."; exit 1 }

# Guard against double-launch
$existing = @(Get-CimInstance Win32_Process -Filter "Name='python.exe'" |
    Where-Object { $_.CommandLine -like '*score_roberta_worker.py*' -and $_.CommandLine -like '*--name GPU*' })
if ($existing.Count -gt 0) {
    $ids = ($existing | ForEach-Object { $_.ProcessId }) -join ', '
    Write-Output "GPU workers already running (PIDs: $ids). Aborting to avoid duplicates."
    exit 0
}

# Same year lists the workers have always used. Finished years are skipped
# instantly (year-level out_path check); the first unfinished year resumes
# from its saved parts.
$log1 = "output\logs\worker_gpu1_$stamp.log"
$log2 = "output\logs\worker_gpu2_$stamp.log"
$cmd1 = "$py -u R\score_roberta_worker.py --name GPU1 --batch-size 6 --sub-chunk-size 20000 --years 1921 1898 1897 1900 1901 1896 1895 > $log1 2>&1"
$cmd2 = "$py -u R\score_roberta_worker.py --name GPU2 --batch-size 6 --sub-chunk-size 20000 --years 1895 1896 1901 1900 1897 1898 > $log2 2>&1"

$p1 = Start-Process cmd.exe -ArgumentList "/c", $cmd1 -WorkingDirectory $root -WindowStyle Hidden -PassThru
$p2 = Start-Process cmd.exe -ArgumentList "/c", $cmd2 -WorkingDirectory $root -WindowStyle Hidden -PassThru

Write-Output "GPU1 launched. cmd wrapper PID $($p1.Id), log: $log1"
Write-Output "GPU2 launched. cmd wrapper PID $($p2.Id), log: $log2"
Write-Output "(PID shown is the cmd wrapper; the python child does the scoring. Finished years are skipped; first unfinished year resumes from saved parts.)"
