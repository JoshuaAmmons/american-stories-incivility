#!/bin/bash
# launch_parallel_scoring.sh — Launch 8 parallel RF scoring workers
# Each worker gets ~13 years. Logs go to output/logs/worker_N.log
# Monitor: tail -f output/logs/worker_*.log
# Check progress: ls data_panels/rf_scored/*.parquet | wc -l  (target: 172)

cd "C:/Users/ammonsj/Ideas"

RSCRIPT="/c/Program Files/R/R-4.4.1/bin/Rscript.exe"
LOGDIR="output/logs"
mkdir -p "$LOGDIR"

# Get years that still need scoring
MISSING_YEARS=($(comm -23 \
  <(ls data_parquet/articles_scored/ | sed 's/scored_//;s/.parquet//' | sort) \
  <(ls data_panels/rf_scored/ | sed 's/rf_scored_//;s/.parquet//' | sort)))

N_YEARS=${#MISSING_YEARS[@]}
N_WORKERS=8

echo "=== Parallel RF Scoring ==="
echo "Missing years: $N_YEARS"
echo "Workers: $N_WORKERS"
echo "Years per worker: ~$(( (N_YEARS + N_WORKERS - 1) / N_WORKERS ))"
echo ""

# Split years into batches and launch workers
for ((w=0; w<N_WORKERS; w++)); do
  # Calculate batch slice
  batch_start=$(( w * N_YEARS / N_WORKERS ))
  batch_end=$(( (w + 1) * N_YEARS / N_WORKERS ))
  BATCH=("${MISSING_YEARS[@]:$batch_start:$((batch_end - batch_start))}")

  if [ ${#BATCH[@]} -eq 0 ]; then
    continue
  fi

  LOGFILE="$LOGDIR/worker_${w}.log"
  echo "Worker $w: years ${BATCH[0]}..${BATCH[-1]} (${#BATCH[@]} years) -> $LOGFILE"

  "$RSCRIPT" R/score_worker.R ${BATCH[@]} > "$LOGFILE" 2>&1 &
done

echo ""
echo "All workers launched. Monitor with:"
echo "  tail -f output/logs/worker_*.log"
echo "  ls data_panels/rf_scored/*.parquet | wc -l"
echo ""
echo "When all workers finish (target: 172 files), run:"
echo "  Rscript run_pipeline.R 7 10"

wait
echo "=== All workers finished! ==="
