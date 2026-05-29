"""
R/score_roberta.py — Score full corpus with fine-tuned RoBERTa Large

Processes year-by-year parquet files through the fine-tuned antisemitism
classifier on GPU. Outputs p_antisem probability per article.

GPU target: NVIDIA RTX 4000 Ada Generation (12GB VRAM)
- Inference batch_size=32, fp16, no gradients

Usage (standalone):
    python R/score_roberta.py

Usage (from R via reticulate):
    reticulate::source_python("R/score_roberta.py")
    score_corpus(model_dir, input_dir, output_dir)
"""

import os
import sys
import gc
import numpy as np
import torch
import pyarrow.parquet as pq
import pyarrow as pa
from pathlib import Path
from transformers import RobertaTokenizerFast, RobertaForSequenceClassification

# --- Paths ---
PROJECT_ROOT = Path("C:/Users/ammonsj/Ideas")
DATA_PARQUET = PROJECT_ROOT / "data_parquet"
DATA_PANELS = PROJECT_ROOT / "data_panels"
MODELS_DIR = PROJECT_ROOT / "models"
ROBERTA_MODEL_DIR = MODELS_DIR / "roberta_antisemitism"
ROBERTA_SCORED_DIR = DATA_PANELS / "roberta_scored"


def score_corpus(model_dir=None, input_dir=None, output_dir=None,
                 batch_size=32, max_length=512):
    """Score all articles in the corpus with the fine-tuned RoBERTa model."""

    if model_dir is None:
        model_dir = str(ROBERTA_MODEL_DIR)
    if input_dir is None:
        input_dir = str(DATA_PARQUET / "articles_antisem_scored")
    if output_dir is None:
        output_dir = str(ROBERTA_SCORED_DIR)

    os.makedirs(output_dir, exist_ok=True)

    # --- GPU check ---
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    if device.type == "cuda":
        gpu_name = torch.cuda.get_device_name(0)
        gpu_mem = torch.cuda.get_device_properties(0).total_memory / 1e9
        print(f"GPU: {gpu_name} ({gpu_mem:.1f} GB)")
    else:
        print("WARNING: Running on CPU. This will be very slow.")

    # --- Load model ---
    print(f"Loading model from {model_dir}...")
    tokenizer = RobertaTokenizerFast.from_pretrained(model_dir)
    model = RobertaForSequenceClassification.from_pretrained(model_dir)
    model = model.to(device)
    model.eval()

    # Use fp16 for inference if on GPU
    use_fp16 = device.type == "cuda"
    if use_fp16:
        model = model.half()

    print(f"Model loaded. Batch size: {batch_size}, Max length: {max_length}")

    # --- Find input files ---
    input_path = Path(input_dir)
    parquet_files = sorted(input_path.glob("antisem_scored_*.parquet"))
    print(f"Found {len(parquet_files)} year files to score")

    total_scored = 0

    for pf in parquet_files:
        year = pf.stem.replace("antisem_scored_", "")
        out_path = Path(output_dir) / f"roberta_scored_{year}.parquet"

        if out_path.exists():
            print(f"Year {year} already scored, skipping.")
            continue

        print(f"\nScoring year {year}...")

        # Read parquet
        table = pq.read_table(pf)
        df = table.to_pandas()
        n_articles = len(df)

        if n_articles == 0:
            print(f"  No articles, skipping.")
            continue

        # Score in batches
        all_probs = np.zeros(n_articles, dtype=np.float32)
        texts = df["article"].fillna("").tolist()

        for start in range(0, n_articles, batch_size):
            end = min(start + batch_size, n_articles)
            batch_texts = texts[start:end]

            # Tokenize
            encodings = tokenizer(
                batch_texts,
                truncation=True,
                max_length=max_length,
                padding="max_length",
                return_tensors="pt",
            )

            input_ids = encodings["input_ids"].to(device)
            attention_mask = encodings["attention_mask"].to(device)

            # Inference
            with torch.no_grad():
                if use_fp16:
                    with torch.amp.autocast("cuda"):
                        outputs = model(input_ids=input_ids,
                                       attention_mask=attention_mask)
                else:
                    outputs = model(input_ids=input_ids,
                                   attention_mask=attention_mask)

                probs = torch.softmax(outputs.logits.float(), dim=-1)
                # Class 1 = antisemitic
                all_probs[start:end] = probs[:, 1].cpu().numpy()

            # Progress
            if (start // batch_size) % 50 == 0 and start > 0:
                print(f"  Processed {end}/{n_articles} articles "
                      f"({end/n_articles*100:.1f}%)")

        # Build output dataframe
        # Keep metadata columns, add p_antisem
        keep_cols = [
            "article_id", "newspaper_name", "year", "year_month", "date",
            "front_page", "n_words", "page_num", "ocr_quality",
            "antisem_score",
        ]
        out_cols = {c: df[c] for c in keep_cols if c in df.columns}
        out_cols["p_antisem"] = all_probs

        import pandas as pd
        out_df = pd.DataFrame(out_cols)

        # Write to temporary file first (atomic write)
        tmp_path = str(out_path) + ".tmp"
        pq.write_table(pa.Table.from_pandas(out_df), tmp_path)
        os.replace(tmp_path, str(out_path))

        total_scored += n_articles
        print(f"  Scored {n_articles} articles. "
              f"Mean p_antisem: {all_probs.mean():.4f}, "
              f"Share > 0.5: {(all_probs > 0.5).mean():.4f}")

        # Clean up GPU memory
        del input_ids, attention_mask, outputs, probs, encodings
        if device.type == "cuda":
            torch.cuda.empty_cache()
        gc.collect()

    print(f"\n=== Scoring complete ===")
    print(f"Total articles scored: {total_scored}")
    print(f"Output directory: {output_dir}")

    return total_scored


# --- Standalone execution ---
if __name__ == "__main__":
    model_dir = sys.argv[1] if len(sys.argv) > 1 else None
    input_dir = sys.argv[2] if len(sys.argv) > 2 else None
    output_dir = sys.argv[3] if len(sys.argv) > 3 else None
    score_corpus(model_dir, input_dir, output_dir)
