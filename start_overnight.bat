@echo off
echo ============================================
echo   Starting overnight RF scoring + pipeline
echo   %date% %time%
echo ============================================
echo.
echo Log: output\logs\overnight_master.log
echo Monitor: type output\logs\overnight_master.log
echo Worker logs: type output\logs\overnight_worker_*.log
echo Progress: dir data_panels\rf_scored\*.parquet ^| find /c ".parquet"
echo.
echo This window will stay open. Safe to minimize.
echo ============================================
echo.

"C:\Program Files\R\R-4.4.1\bin\Rscript.exe" "C:\Users\ammonsj\Ideas\R\overnight_scoring.R" > "C:\Users\ammonsj\Ideas\output\logs\overnight_master.log" 2>&1

echo.
echo ============================================
echo   Overnight run finished at %date% %time%
echo   Check output\logs\overnight_master.log
echo ============================================
pause
