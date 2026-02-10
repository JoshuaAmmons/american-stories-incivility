"""
Download American Stories dataset from HuggingFace year-by-year
and save as Parquet files.

Usage:
    python download_data.py
    python download_data.py 1929 1941   # specific range
"""

import os
import sys
import pyarrow as pa
import pyarrow.parquet as pq
from datasets import load_dataset

DATA_PARQUET = "C:/Users/ammonsj/Ideas/data_parquet"
os.makedirs(DATA_PARQUET, exist_ok=True)

# Determine year range
if len(sys.argv) >= 3:
    start_year = int(sys.argv[1])
    end_year = int(sys.argv[2])
else:
    start_year = 1774
    end_year = 1960

all_years = [str(y) for y in range(start_year, end_year + 1)]

# Check which years already downloaded
existing = set()
for f in os.listdir(DATA_PARQUET):
    if f.startswith("articles_") and f.endswith(".parquet"):
        yr = f.replace("articles_", "").replace(".parquet", "")
        existing.add(yr)

to_download = [y for y in all_years if y not in existing]
print(f"{len(to_download)} years to download, {len(existing)} already done.")

# Download in batches of 5 years
batch_size = 5
for i in range(0, len(to_download), batch_size):
    batch = to_download[i:i + batch_size]
    print(f"\n=== Batch {i // batch_size + 1}: years {batch[0]}-{batch[-1]} ===")

    try:
        ds = load_dataset(
            "dell-research-harvard/AmericanStories",
            "subset_years",
            year_list=batch,
            trust_remote_code=True
        )

        for yr in ds.keys():
            outpath = os.path.join(DATA_PARQUET, f"articles_{yr}.parquet")
            if os.path.exists(outpath):
                print(f"  Year {yr} already exists, skipping.")
                continue

            year_data = ds[yr]
            n = len(year_data)
            if n > 0:
                # Convert to pandas then save as parquet
                pdf = year_data.to_pandas()
                table = pa.Table.from_pandas(pdf)
                pq.write_table(table, outpath)
                print(f"  Saved {n} articles for year {yr} -> {outpath}")
                del pdf, table
            else:
                print(f"  Year {yr} has 0 articles, skipping.")

        del ds
        import gc
        gc.collect()

    except Exception as e:
        print(f"  ERROR in batch: {e}")
        # Try individual years
        for yr in batch:
            outpath = os.path.join(DATA_PARQUET, f"articles_{yr}.parquet")
            if os.path.exists(outpath):
                continue
            try:
                print(f"  Retrying year {yr} individually...")
                ds_single = load_dataset(
                    "dell-research-harvard/AmericanStories",
                    "subset_years",
                    year_list=[yr],
                    trust_remote_code=True
                )
                year_data = ds_single[yr]
                if len(year_data) > 0:
                    pdf = year_data.to_pandas()
                    table = pa.Table.from_pandas(pdf)
                    pq.write_table(table, outpath)
                    print(f"    Saved {len(year_data)} articles for {yr}")
                    del pdf, table
                del ds_single
                import gc
                gc.collect()
            except Exception as e2:
                print(f"    FAILED year {yr}: {e2}")

# Summary
parquet_files = [f for f in os.listdir(DATA_PARQUET)
                 if f.startswith("articles_") and f.endswith(".parquet")]
total_size = sum(os.path.getsize(os.path.join(DATA_PARQUET, f))
                 for f in parquet_files)
print(f"\n=== Summary ===")
print(f"Total Parquet files: {len(parquet_files)}")
print(f"Total size: {total_size / 1e9:.2f} GB")
