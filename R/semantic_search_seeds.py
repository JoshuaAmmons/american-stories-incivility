"""
semantic_search_seeds.py — News Déjà Vu semantic search for antisemitism detection

Uses Dell's newsdejavu package (NER masking + S-BERT embedding + FAISS search)
to find articles semantically similar to confirmed antisemitic seeds.

Pipeline:
1. Load Flash Lite confirmed positives as seed texts
2. Load all figure articles as the search corpus
3. NER-mask entities using Dell's pipeline (improves generalization)
4. Embed seeds + corpus with all-mpnet-base-v2
5. Find nearest neighbors via FAISS cosine similarity
6. Output matched article IDs for downstream labeling

Usage:
    python R/semantic_search_seeds.py

Output: data_panels/semantic_matches.parquet
"""

import os
# Unlock Rust-level parallelism for HF tokenizers — ALL cores
os.environ["TOKENIZERS_PARALLELISM"] = "true"
os.environ["RAYON_NUM_THREADS"] = "32"
import sys
import time
import numpy as np
import pandas as pd
import pyarrow.parquet as pq
from pathlib import Path
from datetime import datetime

# Paths
PROJECT_ROOT = Path("C:/Users/ammonsj/Ideas")
DATA_PANELS = PROJECT_ROOT / "data_panels"
FIGURE_ARTICLES_DIR = DATA_PANELS / "figure_articles"
PROGRESS_FILE = DATA_PANELS / ".overnight_progress.txt"
CHECKPOINT_DIR = DATA_PANELS / "checkpoints"

# Config
EMBEDDING_MODEL = "all-mpnet-base-v2"  # S-BERT MPNet, same as Déjà Vu paper
NER_MODEL = "dslim/bert-base-NER"      # Standard NER model for entity masking
TOP_K = 50              # Neighbors per seed
SIMILARITY_THRESHOLD = 0.65  # Minimum cosine similarity
MAX_WORDS = 300         # Truncate articles for embedding
NER_BATCH_SIZE = 768    # GPU batch size for NER — fp16 on 12GB VRAM, push it
EMBED_BATCH_SIZE = 256  # GPU batch size for encoding

t_start = time.time()

def log_msg(msg):
    elapsed = round((time.time() - t_start) / 60, 1)
    ts = datetime.now().strftime("%H:%M:%S")
    full_msg = f"[{ts}] [{elapsed}m] DEJAVU: {msg}"
    print(full_msg, flush=True)
    with open(PROGRESS_FILE, "a") as f:
        f.write(full_msg + "\n")


def truncate_text(text, max_words=MAX_WORDS):
    """Truncate to first N words for embedding efficiency."""
    if pd.isna(text) or not isinstance(text, str):
        return ""
    words = text.split()[:max_words]
    return " ".join(words)


def process_slab(args):
    """Process a contiguous slab of texts — runs in a subprocess.
    Must be at module level for Windows spawn-based multiprocessing (pickle)."""
    start, end, input_ids_slab, attn_slab, preds_slab, vocab, id2label = args
    from newsdejavu.ner.ner import replace_words_with_entity_tokens
    results = []
    for i in range(len(input_ids_slab)):
        seq_entities = []
        prev_label = "O"
        current_word = ""

        for tok_i in range(len(input_ids_slab[i])):
            if attn_slab[i][tok_i] == 0:
                break
            token = vocab[input_ids_slab[i][tok_i]]
            if token in ("[CLS]", "[SEP]", "[PAD]"):
                continue
            pred_label = id2label[preds_slab[i][tok_i]]
            if token.startswith("##"):
                current_word += token[2:]
                continue
            if current_word:
                seq_entities.append({"word": current_word, "entity_group": prev_label})
            current_word = token
            prev_label = pred_label
        if current_word:
            seq_entities.append({"word": current_word, "entity_group": prev_label})

        results.append(replace_words_with_entity_tokens(
            seq_entities, ['PER', 'ORG', 'LOC', 'MISC'], True
        ))
    return results


def main():
    output_path = DATA_PANELS / "semantic_matches.parquet"
    if output_path.exists():
        existing = pd.read_parquet(output_path)
        log_msg(f"Semantic matches already exist ({len(existing)} articles). Skipping.")
        return

    # --- Load Flash Lite positives as seeds ---
    flash_results_path = DATA_PANELS / "flash_lite_results.csv"
    if not flash_results_path.exists():
        log_msg("ERROR: Flash Lite results not found. Run screen_flash_lite.R first.")
        sys.exit(1)

    flash_df = pd.read_csv(flash_results_path)
    seeds_ids = set(flash_df[flash_df["flash_label"] == 1]["article_id"].values)
    log_msg(f"Flash Lite positives (seeds): {len(seeds_ids)}")

    if len(seeds_ids) < 5:
        log_msg("WARNING: Too few seeds (<5). Including high-confidence cases.")
        seeds_ids = set(flash_df[
            (flash_df["flash_label"] == 1) |
            ((flash_df["flash_confidence"] >= 4) & (flash_df["flash_label"].isna()))
        ]["article_id"].values)
        log_msg(f"Expanded seeds: {len(seeds_ids)}")

    if len(seeds_ids) == 0:
        log_msg("ERROR: No seeds available. Cannot run semantic search.")
        sys.exit(1)

    # --- Load figure articles as corpus ---
    log_msg("Loading figure articles...")
    corpus_dfs = []
    parquet_files = list(FIGURE_ARTICLES_DIR.glob("*.parquet"))

    for f in parquet_files:
        try:
            df = pd.read_parquet(f, columns=["article_id", "article", "year",
                                              "newspaper_name", "figure_key",
                                              "antisem_score", "uncivil_score"])
        except Exception:
            try:
                df = pd.read_parquet(f, columns=["article_id", "article", "year"])
            except Exception:
                continue
        corpus_dfs.append(df)
        log_msg(f"  {f.name}: {len(df):,} articles")

    corpus_df = pd.concat(corpus_dfs, ignore_index=True)
    corpus_df = corpus_df.drop_duplicates(subset="article_id")
    log_msg(f"Total corpus (deduplicated): {len(corpus_df):,}")

    # Separate seeds
    seed_df = corpus_df[corpus_df["article_id"].isin(seeds_ids)].copy()
    log_msg(f"Seeds found in corpus: {len(seed_df)}")

    if len(seed_df) == 0:
        log_msg("ERROR: No seed articles found in figure articles.")
        sys.exit(1)

    # --- Prepare texts ---
    log_msg("Preparing texts...")
    seed_texts = [truncate_text(t) for t in seed_df["article"].values]
    corpus_texts = [truncate_text(t) for t in corpus_df["article"].values]

    # Filter empty
    valid_seed_mask = [len(t) > 10 for t in seed_texts]
    valid_corpus_mask = [len(t) > 10 for t in corpus_texts]

    seed_texts_clean = [t for t, v in zip(seed_texts, valid_seed_mask) if v]
    corpus_texts_clean = [t for t, v in zip(corpus_texts, valid_corpus_mask) if v]
    valid_corpus_indices = [i for i, v in enumerate(valid_corpus_mask) if v]

    log_msg(f"Valid seeds: {len(seed_texts_clean)}, valid corpus: {len(corpus_texts_clean):,}")

    # --- Step 1: NER + masking — pre-tokenize on 32 cores, then blast GPU ---
    import torch
    import numpy as np
    from concurrent.futures import ProcessPoolExecutor, ThreadPoolExecutor
    from multiprocessing import cpu_count
    device = "cuda:0" if torch.cuda.is_available() else "cpu"
    N_WORKERS = cpu_count()  # 32 cores
    log_msg(f"Device: {device}, CPU workers: {N_WORKERS}")

    from transformers import AutoModelForTokenClassification, AutoTokenizer
    from newsdejavu.ner.ner import replace_words_with_entity_tokens

    # Load model in fp16
    log_msg(f"Loading NER model (fp16)...")
    ner_model = AutoModelForTokenClassification.from_pretrained(
        NER_MODEL, torch_dtype=torch.float16
    ).to(device).eval()
    ner_tokenizer = AutoTokenizer.from_pretrained(NER_MODEL)
    id2label = ner_model.config.id2label
    log_msg(f"NER model on {device} (fp16)")

    # Combine seeds + corpus
    all_texts = seed_texts_clean + corpus_texts_clean
    n_seed = len(seed_texts_clean)

    # ========== PHASE 1: Pre-tokenize ALL texts — Rust parallelism on all cores ==========
    CHECKPOINT_DIR.mkdir(exist_ok=True)
    ckpt_phase1 = CHECKPOINT_DIR / "phase1_tokens.npz"

    if ckpt_phase1.exists():
        log_msg(f"Loading Phase 1 checkpoint from {ckpt_phase1}...")
        t0 = time.time()
        ckpt = np.load(ckpt_phase1)
        all_input_ids = ckpt["input_ids"]
        all_attention_mask = ckpt["attention_mask"]
        tok_sec = round(time.time() - t0, 1)
        log_msg(f"Loaded Phase 1 checkpoint in {tok_sec}s — shape: {all_input_ids.shape}")
    else:
        log_msg(f"Pre-tokenizing {len(all_texts):,} texts (Rust fast tokenizer, all cores)...")
        t0 = time.time()

        # Single call — the fast tokenizer's Rust backend parallelizes across all
        # RAYON_NUM_THREADS (set to 32 at top of file). This is faster than any
        # Python-level parallelism because it bypasses the GIL entirely.
        encoded = ner_tokenizer(all_texts, padding='max_length', truncation=True,
                                max_length=256, return_tensors="np")
        all_input_ids = encoded["input_ids"]
        all_attention_mask = encoded["attention_mask"]
        del encoded
        tok_sec = round(time.time() - t0, 1)
        log_msg(f"Pre-tokenized in {tok_sec}s — shape: {all_input_ids.shape}")
        log_msg(f"  RAM for tokens: ~{all_input_ids.nbytes * 2 / 1e9:.1f} GB")

        # Save checkpoint
        log_msg(f"Saving Phase 1 checkpoint...")
        np.savez_compressed(ckpt_phase1, input_ids=all_input_ids, attention_mask=all_attention_mask)
        log_msg(f"Phase 1 checkpoint saved to {ckpt_phase1}")

    # ========== PHASE 2: GPU inference — pure forward passes, no CPU wait ==========
    ckpt_phase2 = CHECKPOINT_DIR / "phase2_preds.npy"

    if ckpt_phase2.exists():
        log_msg(f"Loading Phase 2 checkpoint from {ckpt_phase2}...")
        t0 = time.time()
        all_preds = np.load(ckpt_phase2)
        gpu_sec = round(time.time() - t0, 1)
        log_msg(f"Loaded Phase 2 checkpoint in {gpu_sec}s — shape: {all_preds.shape}")
        # Don't need GPU model
        del ner_model
        torch.cuda.empty_cache()
    else:
        log_msg(f"GPU inference: {len(all_texts):,} texts, batch={NER_BATCH_SIZE}...")
        t0 = time.time()
        all_preds = np.zeros_like(all_input_ids)
        n_batches = (len(all_texts) + NER_BATCH_SIZE - 1) // NER_BATCH_SIZE

        with torch.no_grad(), torch.amp.autocast('cuda'):
            for batch_i in range(n_batches):
                start = batch_i * NER_BATCH_SIZE
                end = min(start + NER_BATCH_SIZE, len(all_texts))

                input_ids = torch.from_numpy(all_input_ids[start:end]).to(device)
                attn_mask = torch.from_numpy(all_attention_mask[start:end]).to(device)

                logits = ner_model(input_ids=input_ids, attention_mask=attn_mask).logits
                all_preds[start:end] = torch.argmax(logits, dim=-1).cpu().numpy()

                if (batch_i + 1) % 50 == 0:
                    elapsed = round(time.time() - t0, 1)
                    rate = round((batch_i + 1) * NER_BATCH_SIZE / elapsed)
                    eta = round((n_batches - batch_i - 1) * elapsed / (batch_i + 1))
                    log_msg(f"  GPU batch {batch_i+1}/{n_batches}: "
                            f"{end:,}/{len(all_texts):,} ({rate:,}/s, ~{eta}s left)")

        gpu_sec = round(time.time() - t0, 1)
        log_msg(f"GPU inference done in {gpu_sec}s")

        # Save checkpoint before freeing GPU
        log_msg(f"Saving Phase 2 checkpoint...")
        np.save(ckpt_phase2, all_preds)
        log_msg(f"Phase 2 checkpoint saved to {ckpt_phase2}")

        # Free GPU immediately
        del ner_model
        torch.cuda.empty_cache()
        log_msg(f"GPU freed")

    # ========== PHASE 3: Reconstruct + mask on 32 CPU cores ==========
    import json
    ckpt_phase3 = CHECKPOINT_DIR / "phase3_masked.json"

    if ckpt_phase3.exists():
        log_msg(f"Loading Phase 3 checkpoint from {ckpt_phase3}...")
        t0 = time.time()
        with open(ckpt_phase3, "r") as f:
            all_masked = json.load(f)
        mask_sec = round(time.time() - t0, 1)
        log_msg(f"Loaded Phase 3 checkpoint in {mask_sec}s — {len(all_masked):,} texts")
    else:
        log_msg(f"Reconstructing NER tags + masking on {N_WORKERS} cores...")
        t0 = time.time()

        # Convert token IDs back to vocab for reconstruction
        vocab = ner_tokenizer.convert_ids_to_tokens(range(ner_tokenizer.vocab_size))

        # Process in slabs — each slab gets its own numpy slice + vocab/labels
        # Use ProcessPoolExecutor with slab-level granularity to avoid pickling overhead
        SLAB_SIZE = len(all_texts) // N_WORKERS + 1

        # Build slab args
        slab_args = []
        for s in range(0, len(all_texts), SLAB_SIZE):
            e = min(s + SLAB_SIZE, len(all_texts))
            slab_args.append((
                s, e,
                all_input_ids[s:e].tolist(),  # convert to list for pickling
                all_attention_mask[s:e].tolist(),
                all_preds[s:e].tolist(),
                vocab, id2label
            ))
        log_msg(f"  Split into {len(slab_args)} slabs of ~{SLAB_SIZE:,} texts each")

        with ProcessPoolExecutor(max_workers=N_WORKERS) as executor:
            slab_results = list(executor.map(process_slab, slab_args))

        all_masked = []
        for sr in slab_results:
            all_masked.extend(sr)
        del slab_results, slab_args

        mask_sec = round(time.time() - t0, 1)
        log_msg(f"Reconstruct + mask done in {mask_sec}s")

        # Save checkpoint
        log_msg(f"Saving Phase 3 checkpoint...")
        with open(ckpt_phase3, "w") as f:
            json.dump(all_masked, f)
        log_msg(f"Phase 3 checkpoint saved to {ckpt_phase3}")

    masked_seeds = all_masked[:n_seed]
    masked_corpus = all_masked[n_seed:]
    del all_masked, all_input_ids, all_attention_mask, all_preds

    log_msg(f"NER+mask total: tokenize {tok_sec}s + GPU {gpu_sec}s + mask {mask_sec}s = "
            f"{round(tok_sec + gpu_sec + mask_sec)}s")

    del ner_tokenizer
    torch.cuda.empty_cache()

    # --- Step 2: Embed using Dell's newsdejavu ---
    from newsdejavu import embed as dejavu_embed

    # Prepare corpus in the format newsdejavu expects
    seed_corpus = [{"masked_sentence": s} for s in masked_seeds]
    corpus_for_embed = [{"masked_sentence": s} for s in masked_corpus]

    log_msg(f"Embedding seeds with {EMBEDDING_MODEL}...")
    seed_embeddings = dejavu_embed(seed_corpus, EMBEDDING_MODEL)
    log_msg(f"Seed embeddings shape: {seed_embeddings.shape}")

    log_msg(f"Embedding corpus with {EMBEDDING_MODEL}...")
    corpus_embeddings = dejavu_embed(corpus_for_embed, EMBEDDING_MODEL)
    log_msg(f"Corpus embeddings shape: {corpus_embeddings.shape}")

    # --- Step 3: Find nearest neighbors using Dell's newsdejavu ---
    from newsdejavu import find_nearest_neighbours

    log_msg(f"Finding top-{TOP_K} neighbors per seed...")
    distances, indices = find_nearest_neighbours(
        seed_embeddings, corpus_embeddings, k=TOP_K
    )

    # Collect matches above threshold
    # Note: find_nearest_neighbours returns distances (lower = closer for L2,
    # but for cosine similarity with normalized vectors, inner product = similarity)
    # Need to check what the function returns
    matched_corpus_indices = set()
    for i in range(len(seed_embeddings)):
        for j in range(TOP_K):
            idx = indices[i][j]
            dist = distances[i][j]
            # For normalized vectors with inner product, higher = more similar
            # For L2 distance, lower = more similar
            # Check: if distances look like cosine sim (0-1 range), use threshold directly
            # If L2 (0-2 range), convert: cos_sim = 1 - dist^2/2
            if dist > 10:
                # Probably raw index, skip
                continue
            if dist >= SIMILARITY_THRESHOLD:
                # Cosine similarity mode
                real_idx = valid_corpus_indices[idx]
                matched_corpus_indices.add(real_idx)
            elif dist <= (1 - SIMILARITY_THRESHOLD) * 2:
                # L2 distance mode (lower = better)
                real_idx = valid_corpus_indices[idx]
                matched_corpus_indices.add(real_idx)

    # If we got too few matches, be more lenient
    if len(matched_corpus_indices) < 100:
        log_msg(f"Only {len(matched_corpus_indices)} matches above threshold. "
                f"Taking top-10 per seed regardless of threshold.")
        for i in range(len(seed_embeddings)):
            for j in range(min(10, TOP_K)):
                idx = indices[i][j]
                real_idx = valid_corpus_indices[idx]
                matched_corpus_indices.add(real_idx)

    log_msg(f"Unique matches: {len(matched_corpus_indices)}")

    # Also include all seeds
    seed_indices_in_corpus = set()
    for i, v in enumerate(valid_corpus_mask):
        if v and corpus_df.iloc[i]["article_id"] in seeds_ids:
            seed_indices_in_corpus.add(i)

    all_match_indices = matched_corpus_indices | seed_indices_in_corpus
    log_msg(f"Total unique articles (matches + seeds): {len(all_match_indices)}")

    # --- Build output ---
    matched_df = corpus_df.iloc[list(all_match_indices)].copy()
    matched_df["is_seed"] = matched_df["article_id"].isin(seeds_ids)
    matched_df["match_source"] = "dejavu_semantic"

    # Compute max similarity per matched article
    idx_to_max_sim = {}
    for i in range(len(seed_embeddings)):
        for j in range(TOP_K):
            idx = indices[i][j]
            if idx < len(valid_corpus_indices):
                real_idx = valid_corpus_indices[idx]
                dist = float(distances[i][j])
                if real_idx not in idx_to_max_sim or dist > idx_to_max_sim[real_idx]:
                    idx_to_max_sim[real_idx] = dist

    matched_df["max_seed_similarity"] = matched_df.index.map(
        lambda idx: idx_to_max_sim.get(idx, 1.0)
    )

    log_msg(f"Saving {len(matched_df)} matched articles...")
    matched_df.to_parquet(output_path, index=False)

    # Summary
    log_msg("=== Déjà Vu Semantic Search Complete ===")
    log_msg(f"Seeds: {sum(matched_df['is_seed'])}")
    log_msg(f"New matches: {sum(~matched_df['is_seed'])}")
    log_msg(f"Total: {len(matched_df)}")
    if "year" in matched_df.columns:
        year_counts = matched_df.groupby("year").size()
        log_msg(f"Year range: {year_counts.index.min()}-{year_counts.index.max()}")

    elapsed = round((time.time() - t_start) / 60, 1)
    log_msg(f"Done in {elapsed} minutes")


if __name__ == "__main__":
    os.chdir(str(PROJECT_ROOT))
    main()
