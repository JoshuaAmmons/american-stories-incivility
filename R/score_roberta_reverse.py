"""
R/score_roberta_reverse.py — Score corpus in REVERSE year order (1960→1850)

Runs alongside score_roberta.py (which goes 1774→1960) to parallelize.
Both scripts skip already-scored years, so no collision.

Uses larger batch_size since GPU has plenty of VRAM headroom.

Usage:
    python R/score_roberta_reverse.py
    python R/score_roberta_reverse.py --batch-size 128
"""

import os
import sys
import gc
import argparse
import numpy as np
import torch
import pyarrow.parquet as pq
import pyarrow as pa
import pandas as pd
from pathlib import Path
from transformers import RobertaTokenizerFast, RobertaForSequenceClassification

PROJECT_ROOT = Path("C:/Users/ammonsj/Ideas")
ROBERTA_MODEL_DIR = PROJECT_ROOT / "models" / "roberta_antisemitism"
INPUT_DIR = PROJECT_ROOT / "data_parquet" / "articles_antisem_scored"
OUTPUT_DIR = PROJECT_ROOT / "data_panels" / "roberta_scored"


def score_year(year_file, tokenizer, model, device, use_fp16, batch_size, max_length):
    """Score a single year file. Returns number of articles scored."""
    year = year_file.stem.replace("antisem_scored_", "")
    out_path = OUTPUT_DIR / f"roberta_scored_{year}.parquet"

    # Double-check not already done (race condition guard)
    if out_path.exists():
        return 0

    print(f"\n[REVERSE] Scoring year {year} "
          f"({year_file.stat().st_size / 1e6:.0f} MB input)...")

    table = pq.read_table(year_file)
    df = table.to_pandas()
    n_articles = len(df)

    if n_articles == 0:
        print(f"  No articles, skipping.")
        return 0

    all_probs = np.zeros(n_articles, dtype=np.float32)
    texts = df["article"].fillna("").tolist()

    for start in range(0, n_articles, batch_size):
        end = min(start + batch_size, n_articles)
        batch_texts = texts[start:end]

        encodings = tokenizer(
            batch_texts,
            truncation=True,
            max_length=max_length,
            padding="max_length",
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
            all_probs[start:end] = probs[:, 1].cpu().numpy()

        if (start // batch_size) % 50 == 0 and start > 0:
            print(f"  [{year}] {end}/{n_articles} "
                  f"({end/n_articles*100:.1f}%)")

        del input_ids, attention_mask, outputs, probs, encodings

    # Build output
    keep_cols = [
        "article_id", "newspaper_name", "year", "year_month", "date",
        "front_page", "n_words", "page_num", "ocr_quality",
        "antisem_score",
    ]
    out_cols = {c: df[c] for c in keep_cols if c in df.columns}
    out_cols["p_antisem"] = all_probs
    out_df = pd.DataFrame(out_cols)

    tmp_path = str(out_path) + ".tmp"
    pq.write_table(pa.Table.from_pandas(out_df), tmp_path)
    os.replace(tmp_path, str(out_path))

    print(f"  [{year}] Done: {n_articles} articles. "
          f"Mean p_antisem: {all_probs.mean():.4f}, "
          f"Share > 0.5: {(all_probs > 0.5).mean():.4f}")

    del df, table, texts, all_probs, out_df
    if device.type == "cuda":
        torch.cuda.empty_cache()
    gc.collect()

    return n_articles


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--batch-size", type=int, default=128,
                        help="Inference batch size (default: 128)")
    parser.add_argument("--max-length", type=int, default=512)
    args = parser.parse_args()

    os.makedirs(OUTPUT_DIR, exist_ok=True)

    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    if device.type == "cuda":
        gpu_name = torch.cuda.get_device_name(0)
        gpu_mem = torch.cuda.get_device_properties(0).total_memory / 1e9
        print(f"[REVERSE] GPU: {gpu_name} ({gpu_mem:.1f} GB)")
    else:
        print("[REVERSE] WARNING: No GPU!")

    print(f"[REVERSE] Loading model...")
    tokenizer = RobertaTokenizerFast.from_pretrained(str(ROBERTA_MODEL_DIR))
    model = RobertaForSequenceClassification.from_pretrained(str(ROBERTA_MODEL_DIR))
    model = model.to(device)
    model.eval()

    use_fp16 = device.type == "cuda"
    if use_fp16:
        model = model.half()

    print(f"[REVERSE] batch_size={args.batch_size}, max_length={args.max_length}")

    # Get all input files, sorted DESCENDING by year (reverse order)
    parquet_files = sorted(INPUT_DIR.glob("antisem_scored_*.parquet"), reverse=True)
    print(f"[REVERSE] {len(parquet_files)} year files total")

    # Filter to not-yet-scored
    todo = []
    for pf in parquet_files:
        year = pf.stem.replace("antisem_scored_", "")
        out_path = OUTPUT_DIR / f"roberta_scored_{year}.parquet"
        if not out_path.exists():
            todo.append(pf)

    print(f"[REVERSE] {len(todo)} years remaining (scoring newest first)")

    total = 0
    for pf in todo:
        n = score_year(pf, tokenizer, model, device, use_fp16,
                       args.batch_size, args.max_length)
        total += n

    print(f"\n[REVERSE] === Done === Total: {total} articles scored")


if __name__ == "__main__":
    main()
