"""
Batch text extraction for all Literature PDFs.
Uses PyMuPDF for embedded text; falls back to pytesseract OCR for scanned pages.
"""

import fitz  # PyMuPDF
import pytesseract
from PIL import Image
import io
import os
import sys
import time

pytesseract.pytesseract.tesseract_cmd = r"C:\Program Files\Tesseract-OCR\tesseract.exe"

LIT_DIR = r"C:\Users\ammonsj\Ideas\Literature"
TXT_DIR = os.path.join(LIT_DIR, "txt")
RAUCH_DIR = os.path.join(LIT_DIR, "The Constitution of Knowledge")

os.makedirs(TXT_DIR, exist_ok=True)

# Minimum text chars per page to consider it "has embedded text"
MIN_TEXT_PER_PAGE = 50
DPI = 200
MAX_OCR_PAGES = 30  # Skip files that need more than this many OCR pages (use dedicated OCR script)

# PDFs that are entirely scanned and should use the dedicated OCR pipeline
SKIP_PATTERNS = ["FBI File"]


def extract_text_from_pdf(pdf_path):
    """Extract text from PDF. Uses embedded text if available, OCR otherwise.
    Returns early if too many pages need OCR (use dedicated OCR script instead).
    """
    doc = fitz.open(pdf_path)
    all_text = []
    ocr_pages = 0
    text_pages = 0

    for i in range(len(doc)):
        page = doc[i]
        text = page.get_text()

        if len(text.strip()) >= MIN_TEXT_PER_PAGE:
            all_text.append(f"--- Page {i+1} ---\n{text}")
            text_pages += 1
        else:
            if ocr_pages >= MAX_OCR_PAGES:
                doc.close()
                raise RuntimeError(
                    f"Too many OCR pages ({ocr_pages}+). "
                    f"Use dedicated OCR script for this file."
                )
            # Page has no/little embedded text -- OCR it
            try:
                mat = fitz.Matrix(DPI / 72, DPI / 72)
                pix = page.get_pixmap(matrix=mat)
                img_data = pix.tobytes("png")
                img = Image.open(io.BytesIO(img_data))
                ocr_text = pytesseract.image_to_string(img, lang='eng', config='--psm 6 --oem 3')
                all_text.append(f"--- Page {i+1} [OCR] ---\n{ocr_text}")
                ocr_pages += 1
            except Exception as e:
                all_text.append(f"--- Page {i+1} [ERROR: {e}] ---\n")

    doc.close()
    return "\n\n".join(all_text), text_pages, ocr_pages


def process_file(pdf_path, output_path):
    """Process a single PDF and save to txt."""
    # Skip files matching known scanned-doc patterns
    basename = os.path.basename(pdf_path)
    for pat in SKIP_PATTERNS:
        if pat in basename:
            return "SKIP (scanned, use OCR script)"

    if os.path.exists(output_path) and os.path.getsize(output_path) > 100:
        return "SKIP"

    try:
        text, text_pages, ocr_pages = extract_text_from_pdf(pdf_path)
        with open(output_path, 'w', encoding='utf-8') as f:
            f.write(f"Source: {os.path.basename(pdf_path)}\n")
            f.write(f"Text pages: {text_pages}, OCR pages: {ocr_pages}\n")
            f.write(f"{'='*80}\n\n")
            f.write(text)
        return f"OK (text={text_pages}, ocr={ocr_pages})"
    except Exception as e:
        return f"ERROR: {e}"


def main():
    # 1) Rauch chapters
    print("=" * 60)
    print("PART 1: Rauch - The Constitution of Knowledge")
    print("=" * 60)
    if os.path.isdir(RAUCH_DIR):
        rauch_pdfs = sorted([f for f in os.listdir(RAUCH_DIR) if f.endswith('.pdf')])
        for pdf in rauch_pdfs:
            pdf_path = os.path.join(RAUCH_DIR, pdf)
            txt_name = pdf.replace('.pdf', '.txt')
            out_path = os.path.join(TXT_DIR, txt_name)
            t0 = time.time()
            result = process_file(pdf_path, out_path)
            elapsed = time.time() - t0
            print(f"  {pdf}: {result} ({elapsed:.1f}s)")
    else:
        print("  Rauch directory not found, skipping.")

    # 2) All remaining PDFs in Literature/
    print()
    print("=" * 60)
    print("PART 2: Remaining Literature PDFs")
    print("=" * 60)

    pdfs = sorted([f for f in os.listdir(LIT_DIR)
                   if f.endswith('.pdf') and os.path.isfile(os.path.join(LIT_DIR, f))])

    total = len(pdfs)
    done = 0
    skipped = 0
    errors = 0

    for i, pdf in enumerate(pdfs):
        pdf_path = os.path.join(LIT_DIR, pdf)
        txt_name = pdf.replace('.pdf', '.txt')
        out_path = os.path.join(TXT_DIR, txt_name)

        t0 = time.time()
        result = process_file(pdf_path, out_path)
        elapsed = time.time() - t0

        if result == "SKIP":
            skipped += 1
            status = "SKIP (exists)"
        elif result.startswith("ERROR"):
            errors += 1
            status = result
        else:
            done += 1
            status = result

        print(f"  [{i+1}/{total}] {pdf}: {status} ({elapsed:.1f}s)")

    print()
    print(f"Done! Processed: {done}, Skipped: {skipped}, Errors: {errors}")


if __name__ == '__main__':
    main()
