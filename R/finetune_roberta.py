"""
R/finetune_roberta.py — Fine-tune RoBERTa Large for antisemitism classification

Called from rmd/05b_roberta_antisemitism.Rmd via reticulate.

GPU target: NVIDIA RTX 4000 Ada Generation (12GB VRAM)
- batch_size=2, gradient_accumulation=8 -> effective batch 16
- fp16 mixed precision
- max_seq_length=512

Usage (standalone):
    python R/finetune_roberta.py

Usage (from R via reticulate):
    reticulate::source_python("R/finetune_roberta.py")
    results = finetune_roberta(labels_path, model_output_dir, seed=42)
"""

import os
import sys
import json
import numpy as np
import pandas as pd
import torch
from pathlib import Path
from sklearn.metrics import (
    accuracy_score, f1_score, roc_auc_score, confusion_matrix,
    classification_report
)
from transformers import (
    RobertaTokenizerFast,
    RobertaForSequenceClassification,
    TrainingArguments,
    Trainer,
    EarlyStoppingCallback,
)
from datasets import Dataset

# --- Paths ---
PROJECT_ROOT = Path("C:/Users/ammonsj/Ideas")
DATA_PANELS = PROJECT_ROOT / "data_panels"
MODELS_DIR = PROJECT_ROOT / "models"
ROBERTA_MODEL_DIR = MODELS_DIR / "roberta_antisemitism"


def load_labels(labels_path=None):
    """Load and merge LLM labels with verified human labels."""
    if labels_path is None:
        labels_path = DATA_PANELS / "antisem_labels_raw.csv"

    labels = pd.read_csv(labels_path)
    print(f"Label source: {labels_path}")

    # Drop rows with missing labels
    labels = labels.dropna(subset=["label"])
    labels["label"] = labels["label"].astype(int)

    print(f"Total labeled articles: {len(labels)}")
    print(f"Label distribution:\n{labels['label'].value_counts()}")

    # Load article text from sample parquet
    import pyarrow.parquet as pq
    sample_path = DATA_PANELS / "labeling_sample_final.parquet"
    if not sample_path.exists():
        sample_path = DATA_PANELS / "antisem_labeling_sample.parquet"
    sample = pq.read_table(sample_path).to_pandas()

    # Merge text with labels
    df = labels.merge(sample[["article_id", "article"]], on="article_id", how="inner")
    print(f"Articles with text: {len(df)}")

    return df


def finetune_roberta(labels_path=None, model_output_dir=None, seed=42):
    """Fine-tune RoBERTa Large on antisemitism labels."""

    if model_output_dir is None:
        model_output_dir = str(ROBERTA_MODEL_DIR)

    os.makedirs(model_output_dir, exist_ok=True)

    # --- GPU check ---
    if not torch.cuda.is_available():
        print("WARNING: CUDA not available. Training on CPU will be very slow.")
    else:
        gpu_name = torch.cuda.get_device_name(0)
        gpu_mem = torch.cuda.get_device_properties(0).total_memory / 1e9
        print(f"GPU: {gpu_name} ({gpu_mem:.1f} GB)")

    # --- Load data ---
    df = load_labels(labels_path)

    # --- Train/val split (80/20, stratified) ---
    from sklearn.model_selection import train_test_split
    train_df, val_df = train_test_split(
        df, test_size=0.2, random_state=seed, stratify=df["label"]
    )
    print(f"\nTrain: {len(train_df)} ({train_df['label'].mean():.2%} positive)")
    print(f"Val:   {len(val_df)} ({val_df['label'].mean():.2%} positive)")

    # --- Tokenizer ---
    tokenizer = RobertaTokenizerFast.from_pretrained("roberta-large")
    MAX_LENGTH = 512

    def tokenize_fn(examples):
        return tokenizer(
            examples["article"],
            truncation=True,
            max_length=MAX_LENGTH,
            padding="max_length",
        )

    # --- Create HuggingFace Datasets ---
    train_ds = Dataset.from_pandas(train_df[["article", "label"]].reset_index(drop=True))
    val_ds = Dataset.from_pandas(val_df[["article", "label"]].reset_index(drop=True))

    train_ds = train_ds.map(tokenize_fn, batched=True, remove_columns=["article"])
    val_ds = val_ds.map(tokenize_fn, batched=True, remove_columns=["article"])

    train_ds = train_ds.rename_column("label", "labels")
    val_ds = val_ds.rename_column("label", "labels")

    train_ds.set_format("torch")
    val_ds.set_format("torch")

    # --- Model ---
    model = RobertaForSequenceClassification.from_pretrained(
        "roberta-large",
        num_labels=2,
        problem_type="single_label_classification",
    )

    # --- Training arguments ---
    # RTX 4000 Ada (12GB): batch=2, grad_accum=4 -> effective batch 8 (per Dell 2025)
    training_args = TrainingArguments(
        output_dir=os.path.join(model_output_dir, "checkpoints"),
        num_train_epochs=10,
        per_device_train_batch_size=2,
        per_device_eval_batch_size=4,
        gradient_accumulation_steps=4,
        learning_rate=1e-5,
        weight_decay=0.01,
        warmup_ratio=0.1,
        fp16=torch.cuda.is_available(),
        eval_strategy="epoch",
        save_strategy="epoch",
        load_best_model_at_end=True,
        metric_for_best_model="f1",
        greater_is_better=True,
        save_total_limit=2,
        logging_steps=10,
        seed=seed,
        report_to="none",  # no wandb/tensorboard
    )

    # --- Metrics ---
    def compute_metrics(eval_pred):
        logits, labels = eval_pred
        probs = torch.softmax(torch.tensor(logits), dim=-1).numpy()
        preds = np.argmax(logits, axis=-1)

        metrics = {
            "accuracy": accuracy_score(labels, preds),
            "f1": f1_score(labels, preds, pos_label=1),
        }

        # AUC-ROC (may fail if only one class in batch)
        try:
            metrics["auc_roc"] = roc_auc_score(labels, probs[:, 1])
        except ValueError:
            metrics["auc_roc"] = float("nan")

        return metrics

    # --- Trainer ---
    trainer = Trainer(
        model=model,
        args=training_args,
        train_dataset=train_ds,
        eval_dataset=val_ds,
        compute_metrics=compute_metrics,
        callbacks=[EarlyStoppingCallback(early_stopping_patience=2)],
    )

    # --- Train ---
    print("\n=== Starting fine-tuning ===")
    train_result = trainer.train()
    print(f"\nTraining complete. Best model loaded.")

    # --- Evaluate ---
    eval_result = trainer.evaluate()
    print(f"\n=== Validation Results ===")
    for k, v in eval_result.items():
        print(f"  {k}: {v:.4f}" if isinstance(v, float) else f"  {k}: {v}")

    # --- Detailed classification report ---
    val_preds = trainer.predict(val_ds)
    pred_labels = np.argmax(val_preds.predictions, axis=-1)
    true_labels = val_df["label"].values

    print("\n=== Classification Report ===")
    print(classification_report(true_labels, pred_labels,
                                target_names=["Not antisemitic", "Antisemitic"]))

    print("\n=== Confusion Matrix ===")
    cm = confusion_matrix(true_labels, pred_labels)
    print(f"  TN={cm[0,0]}  FP={cm[0,1]}")
    print(f"  FN={cm[1,0]}  TP={cm[1,1]}")

    # --- Save model ---
    trainer.save_model(model_output_dir)
    tokenizer.save_pretrained(model_output_dir)

    # Save metrics
    metrics_path = os.path.join(model_output_dir, "training_metrics.json")
    with open(metrics_path, "w") as f:
        json.dump({
            "eval_metrics": {k: float(v) if isinstance(v, (float, np.floating)) else v
                            for k, v in eval_result.items()},
            "train_samples": len(train_df),
            "val_samples": len(val_df),
            "label_distribution": {
                "train_positive": float(train_df["label"].mean()),
                "val_positive": float(val_df["label"].mean()),
            },
            "confusion_matrix": cm.tolist(),
        }, f, indent=2)

    print(f"\nModel saved to: {model_output_dir}")
    print(f"Metrics saved to: {metrics_path}")

    return eval_result


# --- Standalone execution ---
if __name__ == "__main__":
    labels_path = sys.argv[1] if len(sys.argv) > 1 else None
    output_dir = sys.argv[2] if len(sys.argv) > 2 else None
    finetune_roberta(labels_path, output_dir)
