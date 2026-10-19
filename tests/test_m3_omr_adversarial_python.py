"""
Standalone Python Adversarial Challenge Suite for OMREngine (python/omr_engine.py).
Tests malformed files, 0-byte inputs, non-image corrupt inputs,
uniform all-white, uniform all-black, inverted polarity, and noise inputs.
"""

import os
import sys
import tempfile
import unittest
import numpy as np

# Dual support for Pillow and OpenCV
try:
    from PIL import Image
except ImportError:
    Image = None

try:
    import cv2
except ImportError:
    cv2 = None

# Ensure python/ is importable
repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(repo_root, "python"))

from omr_engine import OMREngine


class TestOMREngineAdversarial(unittest.TestCase):
    def setUp(self):
        self.engine = OMREngine()
        self.temp_dir = tempfile.TemporaryDirectory()

    def tearDown(self):
        self.temp_dir.cleanup()

    def test_01_missing_file_raises_not_found(self):
        """Non-existent score path must raise FileNotFoundError."""
        missing_path = os.path.join(self.temp_dir.name, "non_existent_file_9999.png")
        with self.assertRaises(FileNotFoundError):
            self.engine.load_and_binarize(missing_path)

    def test_02_zero_byte_file_raises_value_error(self):
        """0-byte file must raise ValueError, not crash or freeze."""
        zero_file = os.path.join(self.temp_dir.name, "zero_byte.png")
        with open(zero_file, "wb") as f:
            f.write(b"")
        with self.assertRaises(ValueError):
            self.engine.load_and_binarize(zero_file)

    def test_03_corrupt_non_image_raises_value_error(self):
        """Corrupt random non-image bytes must raise ValueError."""
        corrupt_file = os.path.join(self.temp_dir.name, "corrupt.png")
        with open(corrupt_file, "wb") as f:
            f.write(b"THIS IS NOT A VALID PNG OR JPEG IMAGE HEADER AT ALL 1234567890")
        with self.assertRaises(ValueError):
            self.engine.load_and_binarize(corrupt_file)

    def test_04_uniform_all_white_image(self):
        """All-white image (pure paper) must produce empty note chart without crashing."""
        white_path = os.path.join(self.temp_dir.name, "all_white.png")
        img = np.full((900, 1600), 255, dtype=np.uint8)
        if cv2 is not None:
            cv2.imwrite(white_path, img)
        elif Image is not None:
            Image.fromarray(img).save(white_path)

        chart = self.engine.process_score(white_path)
        self.assertIsInstance(chart, dict)
        self.assertEqual(len(chart.get("notes", [])), 0)

    def test_05_uniform_all_black_image(self):
        """All-black image (pure ink) must produce empty note chart without crashing."""
        black_path = os.path.join(self.temp_dir.name, "all_black.png")
        img = np.zeros((900, 1600), dtype=np.uint8)
        if cv2 is not None:
            cv2.imwrite(black_path, img)
        elif Image is not None:
            Image.fromarray(img).save(black_path)

        chart = self.engine.process_score(black_path)
        self.assertIsInstance(chart, dict)
        self.assertEqual(len(chart.get("notes", [])), 0)

    def test_06_inverted_polarity_image(self):
        """Inverted score (white notes on dark black background) must invert safely."""
        inv_path = os.path.join(self.temp_dir.name, "inverted.png")
        # 1600x900 image with black background (0) and white staff lines (255)
        img = np.zeros((900, 1600), dtype=np.uint8)
        for y in [320, 340, 360, 380, 400, 440, 460, 480, 500, 520]:
            img[y, 100:1500] = 255

        if cv2 is not None:
            cv2.imwrite(inv_path, img)
        elif Image is not None:
            Image.fromarray(img).save(inv_path)

        binary = self.engine.load_and_binarize(inv_path)
        self.assertIsInstance(binary, np.ndarray)
        chart = self.engine.process_score(inv_path)
        self.assertIsInstance(chart, dict)

    def test_07_gaussian_noise_image(self):
        """Pure noise image must survive without raising unhandled exceptions."""
        noise_path = os.path.join(self.temp_dir.name, "noise.png")
        np.random.seed(42)
        noise = np.random.randint(0, 256, (300, 400), dtype=np.uint8)
        if cv2 is not None:
            cv2.imwrite(noise_path, noise)
        elif Image is not None:
            Image.fromarray(noise).save(noise_path)

        chart = self.engine.process_score(noise_path)
        self.assertIsInstance(chart, dict)


if __name__ == "__main__":
    print("==================================================================")
    print(" RUNNING PYTHON OMR ENGINE ADVERSARIAL CHALLENGE SUITE            ")
    print("==================================================================")
    suite = unittest.TestLoader().loadTestsFromTestCase(TestOMREngineAdversarial)
    runner = unittest.TextTestRunner(verbosity=2)
    result = runner.run(suite)
    if result.wasSuccessful():
        print("ALL PYTHON OMR ADVERSARIAL TESTS PASSED [OK]")
        sys.exit(0)
    else:
        print(f"FAILED with {len(result.failures)} failures and {len(result.errors)} errors")
        sys.exit(1)
