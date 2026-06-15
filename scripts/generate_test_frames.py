#!/usr/bin/env python3
"""
Generate synthetic FITS test frames for frame registration testing.

Produces 5 frames (512x512, float32) containing Gaussian star profiles.
Each frame has a known transform relative to frame 0 (the reference):

  Frame 0 — reference, no transform
  Frame 1 — translate (+80, +50)
  Frame 2 — translate (-60, +90), rotate +3 deg
  Frame 3 — translate (+120, -70), rotate -5 deg, scale 1.02
  Frame 4 — translate (-30, -100), rotate +7 deg

Stars are placed on a fixed grid with small random offsets so the pattern
is varied but stable across runs (fixed seed).  Poisson noise is added
so the images look plausible.

Output directory: <project-root>/TestData/registration_frames/
"""

import math
import struct
import os
import numpy as np

# ---------------------------------------------------------------------------
# FITS writer (no astropy dependency)
# ---------------------------------------------------------------------------

def _fits_card(key: str, value, comment: str = "") -> bytes:
    """Build one 80-byte FITS header card."""
    key = key.ljust(8)[:8]
    if isinstance(value, bool):
        val_str = f"{'T' if value else 'F':>20}"
    elif isinstance(value, int):
        val_str = f"{value:>20}"
    elif isinstance(value, float):
        val_str = f"{value:>20.10G}"
    elif isinstance(value, str):
        val_str = f"'{value:<8}'"
    else:
        val_str = str(value)
    card = f"{key}= {val_str}"
    if comment:
        card = f"{card} / {comment}"
    card = card[:80].ljust(80)
    return card.encode("ascii")


def write_fits_float32(path: str, data: np.ndarray, extra_headers: dict = None):
    """Write a 2-D float32 array as a minimal FITS primary HDU."""
    assert data.ndim == 2 and data.dtype == np.float32
    height, width = data.shape

    cards = []
    cards.append(_fits_card("SIMPLE", True, "Standard FITS"))
    cards.append(_fits_card("BITPIX", -32, "IEEE single precision float"))
    cards.append(_fits_card("NAXIS", 2, "Number of axes"))
    cards.append(_fits_card("NAXIS1", width, "Width (pixels)"))
    cards.append(_fits_card("NAXIS2", height, "Height (pixels)"))
    if extra_headers:
        for k, v in extra_headers.items():
            cards.append(_fits_card(k, v))
    cards.append(b"END" + b" " * 77)

    # Pad header to multiple of 2880 bytes
    header_bytes = b"".join(cards)
    pad = (2880 - len(header_bytes) % 2880) % 2880
    header_bytes += b" " * pad

    # Data: FITS uses big-endian
    data_be = data.astype(">f4")
    data_bytes = data_be.tobytes()
    pad = (2880 - len(data_bytes) % 2880) % 2880
    data_bytes += b"\x00" * pad

    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(header_bytes)
        f.write(data_bytes)


# ---------------------------------------------------------------------------
# Star / image generation
# ---------------------------------------------------------------------------

WIDTH, HEIGHT = 512, 512
SKY_BG = 200.0   # ADU background
READ_NOISE = 10.0  # electrons


def gaussian_star(cx: float, cy: float, amplitude: float, sigma: float,
                  out: np.ndarray):
    """Add a 2-D Gaussian star to `out` in-place (clip to image bounds)."""
    r = int(4 * sigma) + 1
    x0, x1 = max(0, int(cx) - r), min(WIDTH,  int(cx) + r + 1)
    y0, y1 = max(0, int(cy) - r), min(HEIGHT, int(cy) + r + 1)
    xs = np.arange(x0, x1, dtype=np.float64)
    ys = np.arange(y0, y1, dtype=np.float64)
    gx = np.exp(-0.5 * ((xs - cx) / sigma) ** 2)
    gy = np.exp(-0.5 * ((ys - cy) / sigma) ** 2)
    out[y0:y1, x0:x1] += (amplitude * np.outer(gy, gx)).astype(np.float32)


def build_star_positions(rng: np.random.Generator) -> list[tuple[float, float, float, float]]:
    """
    Returns list of (x, y, amplitude, sigma) for stars in the reference frame.
    Stars are placed on a loose 6x5 grid with small random offsets.
    """
    stars = []
    cols, rows = 6, 5
    margin = 60
    gx = np.linspace(margin, WIDTH - margin, cols)
    gy = np.linspace(margin, HEIGHT - margin, rows)
    for cy in gy:
        for cx in gx:
            dx, dy = rng.uniform(-20, 20, size=2)
            amp = rng.uniform(3000, 12000)
            sigma = rng.uniform(1.8, 3.5)
            stars.append((cx + dx, cy + dy, amp, sigma))
    return stars


def transform_stars(stars, tx: float, ty: float,
                    rot_deg: float, scale: float) -> list[tuple[float, float, float, float]]:
    """Apply similarity transform to star positions."""
    cx, cy = WIDTH / 2.0, HEIGHT / 2.0
    th = math.radians(rot_deg)
    cos_t, sin_t = math.cos(th), math.sin(th)
    result = []
    for x, y, amp, sigma in stars:
        # Rotate + scale around image centre, then translate
        dx, dy = x - cx, y - cy
        nx = cos_t * dx - sin_t * dy
        ny = sin_t * dx + cos_t * dy
        result.append((cx + scale * nx + tx, cy + scale * ny + ty, amp, sigma * scale))
    return result


def render_frame(stars, rng: np.random.Generator) -> np.ndarray:
    """Render stars onto a noisy sky background."""
    img = np.full((HEIGHT, WIDTH), SKY_BG, dtype=np.float32)
    for x, y, amp, sigma in stars:
        if 0 <= x < WIDTH and 0 <= y < HEIGHT:
            gaussian_star(x, y, amp, sigma, img)
    # Poisson noise on signal + read noise
    img = rng.poisson(img.clip(0)).astype(np.float32)
    img += (rng.standard_normal(img.shape) * READ_NOISE).astype(np.float32)
    return img


# ---------------------------------------------------------------------------
# Known transforms  (what the registration pipeline should recover)
# ---------------------------------------------------------------------------

TRANSFORMS = [
    # (tx,   ty,   rot_deg, scale,  label)
    (  0.0,   0.0,   0.0,   1.000, "frame_00_reference"),
    ( 80.0,  50.0,   0.0,   1.000, "frame_01_tx80_ty50"),
    (-60.0,  90.0,   3.0,   1.000, "frame_02_tx-60_ty90_rot3"),
    (120.0, -70.0,  -5.0,   1.020, "frame_03_tx120_ty-70_rot-5_sc1.02"),
    (-30.0,-100.0,   7.0,   1.000, "frame_04_tx-30_ty-100_rot7"),
]


def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    out_dir = os.path.join(script_dir, "..", "TestData", "registration_frames")

    rng = np.random.default_rng(42)
    ref_stars = build_star_positions(rng)

    print(f"Generating {len(TRANSFORMS)} test frames → {out_dir}")
    print(f"  {len(ref_stars)} stars per frame, image size {WIDTH}×{HEIGHT}")
    print()

    for tx, ty, rot_deg, scale, label in TRANSFORMS:
        stars = transform_stars(ref_stars, tx, ty, rot_deg, scale)
        img = render_frame(stars, rng)
        path = os.path.join(out_dir, f"{label}.fits")
        write_fits_float32(path, img, {
            "EXPTIME": 60.0,
            "TELESCOP": "Synthetic",
            "INSTRUME": "TestCam",
            "TXOFFSET": tx,
            "TYOFFSET": ty,
            "ROTDEG":   rot_deg,
            "SCALE":    scale,
        })
        print(f"  Written: {os.path.basename(path)}")
        print(f"    transform: tx={tx:+.1f}  ty={ty:+.1f}  "
              f"rot={rot_deg:+.1f}°  scale={scale:.3f}")

    print()
    print("Done. Test with:")
    print(f"  ap run frame_registration \\")
    print(f"    --input input_frames:{out_dir} \\")
    print(f"    --output /tmp/registration_result.fits")


if __name__ == "__main__":
    main()
