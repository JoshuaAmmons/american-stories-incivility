"""
OCR extraction script for FBI File on Charles Coughlin (Part 01 of 02).
Uses PyMuPDF to render pages as images, then pytesseract for OCR.
Processes in batches and saves to text file.
"""

import fitz  # PyMuPDF
import pytesseract
from PIL import Image
import io
import os
import sys
import time

# Configure tesseract path
pytesseract.pytesseract.tesseract_cmd = r"C:\Program Files\Tesseract-OCR\tesseract.exe"

PDF_PATH = r"C:\Users\ammonsj\Ideas\Literature\FBI FileCharles Coughlin Part 01 of 02.pdf"
OUTPUT_DIR = r"C:\Users\ammonsj\Ideas\output\fbi_ocr"
os.makedirs(OUTPUT_DIR, exist_ok=True)

BATCH_SIZE = 50  # pages per batch
DPI = 200  # resolution for rendering

def ocr_page(doc, page_num):
    """Render a single page to image and OCR it."""
    page = doc[page_num]
    # Render page to pixmap at specified DPI
    mat = fitz.Matrix(DPI / 72, DPI / 72)
    pix = page.get_pixmap(matrix=mat)

    # Convert to PIL Image
    img_data = pix.tobytes("png")
    img = Image.open(io.BytesIO(img_data))

    # OCR with tesseract
    text = pytesseract.image_to_string(img, lang='eng',
                                        config='--psm 6 --oem 3')
    return text

def process_batch(doc, start_page, end_page, batch_num):
    """Process a batch of pages and save to file."""
    output_file = os.path.join(OUTPUT_DIR, f"batch_{batch_num:03d}_pages_{start_page+1}-{end_page}.txt")

    # Skip if already processed
    if os.path.exists(output_file) and os.path.getsize(output_file) > 100:
        print(f"  Batch {batch_num} already exists, skipping.")
        return output_file

    results = []
    for pg in range(start_page, end_page):
        try:
            text = ocr_page(doc, pg)
            results.append(f"\n{'='*80}\nPAGE {pg + 1}\n{'='*80}\n{text}\n")
            if (pg - start_page + 1) % 10 == 0:
                print(f"    Processed page {pg + 1}/{end_page}...")
        except Exception as e:
            results.append(f"\n{'='*80}\nPAGE {pg + 1} [ERROR: {e}]\n{'='*80}\n")

    with open(output_file, 'w', encoding='utf-8') as f:
        f.write('\n'.join(results))

    return output_file

def main():
    print(f"Opening PDF: {PDF_PATH}")
    doc = fitz.open(PDF_PATH)
    total_pages = len(doc)
    print(f"Total pages: {total_pages}")

    num_batches = (total_pages + BATCH_SIZE - 1) // BATCH_SIZE
    print(f"Will process in {num_batches} batches of {BATCH_SIZE} pages\n")

    all_batch_files = []

    for batch_num in range(num_batches):
        start_page = batch_num * BATCH_SIZE
        end_page = min(start_page + BATCH_SIZE, total_pages)
        print(f"Processing batch {batch_num + 1}/{num_batches} (pages {start_page + 1}-{end_page})...")
        t0 = time.time()

        output_file = process_batch(doc, start_page, end_page, batch_num + 1)
        all_batch_files.append(output_file)

        elapsed = time.time() - t0
        print(f"  Batch {batch_num + 1} done in {elapsed:.1f}s -> {output_file}\n")

    # Combine all batches into one master file
    master_file = os.path.join(OUTPUT_DIR, "fbi_coughlin_part01_full_ocr.txt")
    print(f"Combining all batches into {master_file}...")
    with open(master_file, 'w', encoding='utf-8') as out:
        out.write("FBI FILE: CHARLES COUGHLIN - PART 01 OF 02\n")
        out.write("OCR EXTRACTION\n")
        out.write(f"Source: {PDF_PATH}\n")
        out.write(f"Total pages: {total_pages}\n")
        out.write(f"{'='*80}\n\n")
        for bf in all_batch_files:
            with open(bf, 'r', encoding='utf-8') as inp:
                out.write(inp.read())

    print(f"\nDone! Master file: {master_file}")
    doc.close()

if __name__ == '__main__':
    main()
