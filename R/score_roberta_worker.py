"""
R/score_roberta_worker.py — Score specific years with RoBERTa

Designed to run multiple instances in parallel, each on a different set of years.
All workers share one GPU (RoBERTa Large fp16 ~700MB, plenty of room on 12GB).

Processes large years in row-group chunks to avoid loading entire files into RAM.
Each chunk is saved as a separate parquet part file, then merged at the end.
Crash-safe: completed chunks are skipped on resume.

Usage:
    python R/score_roberta_worker.py --name SMALL --batch-size 128 --years 1960 1959 1958
    python R/score_roberta_worker.py --name MEDIUM --batch-size 96 --years 1947 1946 1945
    python R/score_roberta_worker.py --name LARGE --batch-size 48 --years 1910 1914 1915
"""

import os
import sys
import gc
import argparse
import time
import numpy as np
import torch
import pyarrow.parquet as pq
import pyarrow as pa
import pandas as pd
from pathlib import Path
from transformers import RobertaTokenizerFast, RobertaForSequenceClassification

# Force unbuffered output so logs appear in real-time
sys.stdout.reconfigure(line_buffering=True)
sys.stderr.reconfigure(line_buffering=True)

PROJECT_ROOT = Path("C:/Users/ammonsj/Ideas")
ROBERTA_MODEL_DIR = PROJECT_ROOT / "models" / "roberta_antisemitism"
INPUT_DIR = PROJECT_ROOT / "data_parquet" / "articles_antisem_scored"
OUTPUT_DIR = PROJECT_ROOT / "data_panels" / "roberta_scored"

KEEP_COLS = [
    "article_id", "newspaper_name", "year", "year_month", "date",
    "front_page", "n_words", "page_num", "ocr_quality",
    "antisem_score",
]


def score_chunk(df, tokenizer, model, device, use_fp16, batch_size,
                max_length, name, year, chunk_idx, n_chunks):
    """Score a single chunk (subset of a year) and return the output DataFrame."""
    n_articles = len(df)
    if n_articles == 0:
        return pd.DataFrame()

    texts = df["article"].fillna("").tolist()

    # Sort by text length so similar-length articles batch together,
    # minimizing wasted padding tokens (huge speedup with dynamic padding)
    lengths = [len(t) for t in texts]
    sort_idx = np.argsort(lengths)
    sorted_texts = [texts[i] for i in sort_idx]

    sorted_probs = np.zeros(n_articles, dtype=np.float32)
    t0 = time.time()

    for start in range(0, n_articles, batch_size):
        end = min(start + batch_size, n_articles)
        batch_texts = sorted_texts[start:end]

        encodings = tokenizer(
            batch_texts,
            truncation=True,
            max_length=max_length,
            padding=True,  # dynamic padding — 5x faster for short texts
            return_tensors="pt",
        )

        input_ids = encodings["input_ids"].to(device)
        attention_mask = encodings["attention_mask"].to(device)

        with torch.no_grad():
            if use_fp16:
                with torch.amp.autocast("cuda"):
                    outputs = model(input_ids=input_ids,
                                    attention_mask=attention_mask)
            else:
                outputs = model(input_ids=input_ids,
                                attention_mask=attention_mask)

            probs = torch.softmax(outputs.logits.float(), dim=-1)
            sorted_probs[start:end] = probs[:, 1].cpu().numpy()

        del input_ids, attention_mask, outputs, probs, encodings

        batch_num = start // batch_size
        if batch_num % 25 == 0 and start > 0:
            elapsed = time.time() - t0
            rate = end / elapsed
            eta = (n_articles - end) / rate if rate > 0 else 0
            print(f"[{name}]   {year} chunk {chunk_idx+1}/{n_chunks}: "
                  f"{end}/{n_articles} ({end/n_articles*100:.1f}%) "
                  f"ETA: {eta/60:.0f}min")

    # Unsort: map probabilities back to original article order
    all_probs = np.zeros(n_articles, dtype=np.float32)
    all_probs[sort_idx] = sorted_probs

    # Build output DataFrame
    out_cols = {c: df[c].values for c in KEEP_COLS if c in df.columns}
    out_cols["p_antisem"] = all_probs
    out_df = pd.DataFrame(out_cols)

    # Free memory
    del df, texts, sorted_texts, sorted_probs, all_probs, lengths, sort_idx
    if device.type == "cuda":
        torch.cuda.empty_cache()
    gc.collect()

    return out_df


def score_year(year, tokenizer, model, device, use_fp16, batch_size,
               max_length, name, sub_chunk_size=0):
    """Score a single year file, processing one row group at a time.

    If sub_chunk_size > 0, each row group is further split into sub-chunks
    of that many articles, each saved as its own part file. This lets slow
    CPU workers checkpoint every ~50K articles instead of every ~1M.
    """
    input_file = INPUT_DIR / f"antisem_scored_{year}.parquet"
    out_path = OUTPUT_DIR / f"roberta_scored_{year}.parquet"
    parts_dir = OUTPUT_DIR / f"parts_{year}"

    if out_path.exists():
        print(f"[{name}] Year {year} already done, skipping.")
        return 0

    if not input_file.exists():
        print(f"[{name}] Year {year} input not found, skipping.")
        return 0

    input_mb = input_file.stat().st_size / 1e6
    pf = pq.ParquetFile(input_file)
    n_row_groups = pf.metadata.num_row_groups
    n_total = pf.metadata.num_rows

    # Calculate total number of parts across all row groups
    if sub_chunk_size > 0:
        # Count how many sub-chunks each row group will produce
        total_parts = 0
        for rg_idx in range(n_row_groups):
            rg_rows = pf.metadata.row_group(rg_idx).num_rows
            total_parts += (rg_rows + sub_chunk_size - 1) // sub_chunk_size
    else:
        total_parts = n_row_groups

    print(f"[{name}] Scoring year {year} ({input_mb:.0f} MB, "
          f"{n_total} articles, {n_row_groups} row groups, "
          f"{total_parts} parts)...")
    t0 = time.time()

    os.makedirs(parts_dir, exist_ok=True)

    scored_total = 0
    part_counter = 0  # global part index across all row groups

    for rg_idx in range(n_row_groups):
        rg_rows = pf.metadata.row_group(rg_idx).num_rows

        if sub_chunk_size > 0 and rg_rows > sub_chunk_size:
            # Split this row group into sub-chunks
            n_sub = (rg_rows + sub_chunk_size - 1) // sub_chunk_size

            # Check if ALL sub-chunks for this row group are done
            all_done = True
            sub_scored = 0
            for sub_idx in range(n_sub):
                part_path = parts_dir / f"part_{part_counter + sub_idx:03d}.parquet"
                if part_path.exists():
                    sub_scored += pq.read_metadata(part_path).num_rows
                else:
                    all_done = False

            if all_done:
                scored_total += sub_scored
                print(f"[{name}]   {year} rg {rg_idx+1}/{n_row_groups} "
                      f"({n_sub} sub-chunks): already done, skipping.")
                part_counter += n_sub
                continue

            # Load the row group once, then slice into sub-chunks
            rg_table = pf.read_row_group(rg_idx)
            rg_df = rg_table.to_pandas()
            del rg_table
            gc.collect()

            print(f"[{name}]   {year} rg {rg_idx+1}/{n_row_groups}: "
                  f"loaded {len(rg_df)} articles, splitting into "
                  f"{n_sub} sub-chunks of ~{sub_chunk_size}")

            for sub_idx in range(n_sub):
                part_path = parts_dir / f"part_{part_counter:03d}.parquet"

                if part_path.exists():
                    n_part = pq.read_metadata(part_path).num_rows
                    scored_total += n_part
                    print(f"[{name}]   {year} part {part_counter+1}/{total_parts}: "
                          f"already done ({n_part} articles), skipping.")
                    part_counter += 1
                    continue

                start_row = sub_idx * sub_chunk_size
                end_row = min(start_row + sub_chunk_size, len(rg_df))
                sub_df = rg_df.iloc[start_row:end_row].copy()

                out_df = score_chunk(sub_df, tokenizer, model, device,
                                     use_fp16, batch_size, max_length,
                                     name, year, part_counter, total_parts)

                tmp_path = str(part_path) + ".tmp"
                pq.write_table(pa.Table.from_pandas(out_df), tmp_path)
                os.replace(tmp_path, str(part_path))

                scored_total += len(sub_df)
                elapsed = time.time() - t0
                rate = scored_total / elapsed if elapsed > 0 else 0
                eta = (n_total - scored_total) / rate if rate > 0 else 0
                print(f"[{name}]   {year} part {part_counter+1}/{total_parts} SAVED: "
                      f"{scored_total}/{n_total} total "
                      f"({scored_total/n_total*100:.1f}%) "
                      f"ETA: {eta/60:.0f}min")

                del out_df, sub_df
                gc.collect()
                part_counter += 1

            del rg_df
            gc.collect()

        else:
            # Original behavior: one part per row group
            part_path = parts_dir / f"part_{part_counter:03d}.parquet"

            if part_path.exists():
                n_part = pq.read_metadata(part_path).num_rows
                scored_total += n_part
                print(f"[{name}]   {year} part {part_counter+1}/{total_parts}: "
                      f"already done ({n_part} articles), skipping.")
                part_counter += 1
                continue

            rg_table = pf.read_row_group(rg_idx)
            chunk_df = rg_table.to_pandas()
            n_chunk = len(chunk_df)
            del rg_table
            gc.collect()

            print(f"[{name}]   {year} part {part_counter+1}/{total_parts}: "
                  f"loaded {n_chunk} articles")

            out_df = score_chunk(chunk_df, tokenizer, model, device, use_fp16,
                                 batch_size, max_length, name, year,
                                 part_counter, total_parts)

            tmp_path = str(part_path) + ".tmp"
            pq.write_table(pa.Table.from_pandas(out_df), tmp_path)
            os.replace(tmp_path, str(part_path))

            scored_total += n_chunk
            elapsed = time.time() - t0
            rate = scored_total / elapsed if elapsed > 0 else 0
            eta = (n_total - scored_total) / rate if rate > 0 else 0
            print(f"[{name}]   {year} part {part_counter+1}/{total_parts} SAVED: "
                  f"{scored_total}/{n_total} total "
                  f"({scored_total/n_total*100:.1f}%) "
                  f"ETA: {eta/60:.0f}min")

            del out_df, chunk_df
            gc.collect()
            part_counter += 1

    # Merge all parts into the final file
    print(f"[{name}]   {year}: merging {part_counter} parts...")
    part_files = sorted(parts_dir.glob("part_*.parquet"))
    tables = []
    for p in part_files:
        t = pq.read_table(p)
        # Cast page_num to double for consistency across parts
        # (some parts saved it as int32, others as double depending on source)
        if 'page_num' in t.column_names:
            pn_type = t.schema.field('page_num').type
            if pn_type != pa.float64():
                idx = t.schema.get_field_index('page_num')
                t = t.set_column(idx, 'page_num', t['page_num'].cast(pa.float64()))
        tables.append(t)
    merged = pa.concat_tables(tables)
    del tables

    tmp_path = str(out_path) + ".tmp"
    pq.write_table(merged, tmp_path)
    os.replace(tmp_path, str(out_path))
    del merged
    gc.collect()

    # Clean up part files
    for p in part_files:
        p.unlink()
    try:
        parts_dir.rmdir()
    except OSError:
        pass

    elapsed = time.time() - t0
    rate_mb = input_mb / (elapsed / 3600)
    print(f"[{name}]   {year} DONE: {scored_total} articles in "
          f"{elapsed/60:.1f}min ({rate_mb:.0f} MB/hr).")

    return scored_total


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--name", type=str, default="WORKER",
                        help="Worker name for log prefix")
    parser.add_argument("--batch-size", type=int, default=256)
    parser.add_argument("--max-length", type=int, default=512)
    parser.add_argument("--years", nargs="+", required=True,
                        help="List of years to score")
    parser.add_argument("--cpu", action="store_true",
                        help="Force CPU-only inference (no GPU)")
    parser.add_argument("--threads", type=int, default=8,
                        help="Number of CPU threads (only for --cpu mode)")
    parser.add_argument("--sub-chunk-size", type=int, default=0,
                        help="Split row groups into sub-chunks of this many "
                             "articles for more frequent saves. 0=disabled.")
    args = parser.parse_args()

    os.makedirs(OUTPUT_DIR, exist_ok=True)

    if args.cpu:
        device = torch.device("cpu")
        torch.set_num_threads(args.threads)
        print(f"[{args.name}] CPU mode: {args.threads} threads", flush=True)
    else:
        device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
        if device.type == "cuda":
            gpu_name = torch.cuda.get_device_name(0)
            gpu_mem = torch.cuda.get_device_properties(0).total_memory / 1e9
            free_mem = torch.cuda.mem_get_info()[0] / 1e9
            print(f"[{args.name}] GPU: {gpu_name} "
                  f"({free_mem:.1f}/{gpu_mem:.1f} GB free)")

    print(f"[{args.name}] Loading model...", flush=True)
    tokenizer = RobertaTokenizerFast.from_pretrained(str(ROBERTA_MODEL_DIR))
    model = RobertaForSequenceClassification.from_pretrained(
        str(ROBERTA_MODEL_DIR),
        torch_dtype=torch.float16 if device.type == "cuda" else torch.float32,
    )
    print(f"[{args.name}] Moving model to {device}...", flush=True)
    model = model.to(device)
    model.eval()
    use_fp16 = device.type == "cuda"
    if device.type == "cuda":
        print(f"[{args.name}] Model on GPU. VRAM free: "
              f"{torch.cuda.mem_get_info()[0]/1e9:.1f} GB", flush=True)
    else:
        print(f"[{args.name}] Model on CPU. Threads: "
              f"{torch.get_num_threads()}", flush=True)

    print(f"[{args.name}] Ready: batch_size={args.batch_size}, "
          f"{len(args.years)} years assigned")

    total = 0
    for year in args.years:
        n = score_year(year, tokenizer, model, device, use_fp16,
                       args.batch_size, args.max_length, args.name,
                       sub_chunk_size=args.sub_chunk_size)
        total += n

    print(f"\n[{args.name}] === COMPLETE === {total} articles scored")


if __name__ == "__main__":
    main()
