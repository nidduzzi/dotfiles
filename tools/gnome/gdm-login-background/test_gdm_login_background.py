#!/usr/bin/python3
"""Tests run against a fake directory tree (no root, nothing real is touched)."""
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gdm_login_background as g  # noqa: E402

REAL_THEME = Path("/usr/share/gnome-shell/gnome-shell-theme.gresource")
SAVED_ORIGINAL = Path("/var/lib/gdm-login-background/original.gresource")


def stock_theme_bytes() -> bytes:
    """The untouched theme: the system file, or the saved original if we customized it."""
    data = REAL_THEME.read_bytes()
    try:
        g.StockTheme(data)
        return data
    except g.Refused:
        return SAVED_ORIGINAL.read_bytes()
JPEG = b"\xff\xd8\xff\xe0" + b"jpeg-one" * 10
JPEG2 = b"\xff\xd8\xff\xe0" + b"jpeg-two" * 10
PNG = b"\x89PNG\r\n\x1a\n" + b"png" * 10


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="gdmbgtest")
        root = Path(self.tmp.name)
        (root / "theme").mkdir()
        self.original = stock_theme_bytes()
        (root / "theme" / "gnome-shell-theme.gresource").write_bytes(self.original)
        self.layout = g.Layout(theme=root / "theme" / "gnome-shell-theme.gresource",
                               image_dir=root / "images", state_dir=root / "state")

    def tearDown(self):
        self.tmp.cleanup()

    def snapshot(self):
        """Every file under the fake root and its bytes."""
        root = Path(self.tmp.name)
        return {str(p.relative_to(root)): p.read_bytes() for p in root.rglob("*")
                if p.is_file() and p.name != "lock"}


class Values(unittest.TestCase):
    def test_image_rejects_non_images(self):
        for bad in (b"", b"hello", b"<svg/>", b"GIF89a"):
            with self.assertRaises(g.Refused):
                g.Image(bad)

    def test_image_rejects_oversize(self):
        with self.assertRaises(g.Refused):
            g.Image(b"\xff\xd8\xff" + b"0" * g.MAX_IMAGE_BYTES)

    def test_layout_rejects_css_breaking_paths(self):
        for bad in ('/tmp/a"b', "/tmp/a b", "/tmp/a)b", "/tmp/a;b", "relative/path"):
            with self.assertRaises(g.Refused):
                g.Layout(image_dir=Path(bad))

    def test_garbage_is_not_a_theme(self):
        with self.assertRaises(g.Refused):
            g.StockTheme(b"not a gresource")


class Install(Base):
    def test_install_then_restore_is_exact(self):
        g.install(self.layout, g.Image(JPEG))
        state = g.read_state(self.layout)
        self.assertIsInstance(state, g.Customized)
        self.assertEqual(self.layout.image.read_bytes(), JPEG)
        self.assertNotEqual(self.layout.theme.read_bytes(), self.original)
        g.restore(self.layout)
        self.assertEqual(self.layout.theme.read_bytes(), self.original)
        self.assertIsInstance(g.read_state(self.layout), g.Stock)

    def test_reinstall_uses_the_saved_original(self):
        g.install(self.layout, g.Image(JPEG))
        backup = self.layout.backup.read_bytes()
        g.install(self.layout, g.Image(PNG))
        self.assertEqual(self.layout.backup.read_bytes(), backup)
        self.assertEqual(self.layout.backup.read_bytes(), self.original)
        self.assertEqual(self.layout.image.read_bytes(), PNG)

    def test_set_image_needs_install_first(self):
        with self.assertRaises(g.Refused):
            g.set_image(self.layout, g.Image(JPEG))
        g.install(self.layout, g.Image(JPEG))
        theme = self.layout.theme.read_bytes()
        g.set_image(self.layout, g.Image(JPEG2))
        self.assertEqual(self.layout.image.read_bytes(), JPEG2)
        self.assertEqual(self.layout.theme.read_bytes(), theme)  # theme untouched

    def test_gnome_shell_update_while_customized(self):
        g.install(self.layout, g.Image(JPEG))
        newer = self.original.replace(b"workspace-placeholder", b"workspace-placeholdeR", 1)
        self.assertNotEqual(newer, self.original)
        self.layout.theme.write_bytes(newer)  # an update puts a (different) stock theme back
        self.assertIsInstance(g.read_state(self.layout), g.Stock)
        g.install(self.layout, g.Image(JPEG2))
        self.assertEqual(self.layout.backup.read_bytes(), newer)  # backup refreshed

    def test_refuses_a_theme_modified_by_something_else(self):
        self.layout.theme.write_bytes(self.original.replace(b"lockDialogGroup", b"lockDialogGrouq"))
        before = self.snapshot()
        with self.assertRaises(g.Refused):
            g.install(self.layout, g.Image(JPEG))
        self.assertEqual(self.snapshot(), before)


class Rollback(Base):
    """Make each step fail in turn; the fake system must end up exactly as it began."""

    def run_failing(self, fail_at, prepare=None):
        if prepare:
            prepare()
        before = self.snapshot()
        calls = {"n": 0}
        real = g.atomic_write

        def flaky(*args, **kwargs):
            calls["n"] += 1
            if calls["n"] == fail_at:
                raise OSError("injected failure")
            return real(*args, **kwargs)

        with mock.patch.object(g, "atomic_write", flaky), self.assertRaises(OSError):
            g.install(self.layout, g.Image(JPEG2))
        self.assertEqual(self.snapshot(), before)

    def test_fail_writing_backup(self):
        self.run_failing(1)

    def test_fail_writing_image(self):
        self.run_failing(2)

    def test_fail_swapping_theme(self):
        self.run_failing(3)

    def test_fail_verification_after_commit(self):
        before = self.snapshot()
        with mock.patch.object(g, "verify_installed", side_effect=g.Refused("injected")), \
                self.assertRaises(g.Refused):
            g.install(self.layout, g.Image(JPEG))
        self.assertEqual(self.snapshot(), before)

    def test_rollback_restores_previous_image_when_customized(self):
        g.install(self.layout, g.Image(JPEG))
        before = self.snapshot()
        with mock.patch.object(g, "verify_installed", side_effect=g.Refused("injected")), \
                self.assertRaises(g.Refused):
            g.install(self.layout, g.Image(JPEG2))
        self.assertEqual(self.snapshot(), before)  # old image and old theme are back

    def test_restore_failure_leaves_customized(self):
        g.install(self.layout, g.Image(JPEG))
        before = self.snapshot()
        with mock.patch.object(g, "read_state", side_effect=[g.read_state(self.layout), g.Refused("injected")]), \
                self.assertRaises(g.Refused):
            g.restore(self.layout)
        self.assertEqual(self.snapshot(), before)


class Rotation(Base):
    def setUp(self):
        super().setUp()
        self.pics = Path(self.tmp.name) / "pics"
        self.pics.mkdir()
        for name, data in (("a.jpg", JPEG), ("b.png", PNG), ("c.jpg", JPEG2)):
            (self.pics / name).write_bytes(data)
        g.install(self.layout, g.Image(JPEG))

    def shown(self):
        return self.layout.image.read_bytes()

    def test_next_cycles_in_order_and_wraps(self):
        order = [g.rotate(self.layout, self.pics, "next") for _ in range(4)]
        self.assertEqual(order, ["a.jpg", "b.png", "c.jpg", "a.jpg"])

    def test_next_shows_the_picture(self):
        g.rotate(self.layout, self.pics, "next")  # a.jpg
        g.rotate(self.layout, self.pics, "next")  # b.png
        self.assertEqual(self.shown(), PNG)

    def test_newest_picks_latest_mtime(self):
        os.utime(self.pics / "a.jpg", (1, 1))
        os.utime(self.pics / "b.png", (3, 3))
        os.utime(self.pics / "c.jpg", (2, 2))
        self.assertEqual(g.rotate(self.layout, self.pics, "newest"), "b.png")

    def test_skips_files_that_are_not_images(self):
        (self.pics / "a.jpg").write_bytes(b"not an image")
        (self.pics / "notes.txt").write_text("hello")
        self.assertEqual(g.rotate(self.layout, self.pics, "next"), "b.png")

    def test_symlinks_are_never_followed(self):
        secret = Path(self.tmp.name) / "secret.jpg"
        secret.write_bytes(JPEG2 + b"secret")
        for f in self.pics.iterdir():
            f.unlink()
        (self.pics / "link.jpg").symlink_to(secret)
        before = self.snapshot()
        with self.assertRaises(g.Refused):
            g.rotate(self.layout, self.pics, "newest")
        self.assertEqual(self.snapshot(), before)

    def test_empty_folder_changes_nothing(self):
        empty = Path(self.tmp.name) / "empty"
        empty.mkdir()
        before = self.snapshot()
        with self.assertRaises(g.Refused):
            g.rotate(self.layout, empty, "next")
        self.assertEqual(self.snapshot(), before)

    def test_rotate_requires_install_first(self):
        g.restore(self.layout)
        with self.assertRaises(g.Refused):
            g.rotate(self.layout, self.pics, "next")

    def test_same_picture_is_not_rewritten(self):
        g.rotate(self.layout, self.pics, "newest")
        with mock.patch.object(g, "atomic_write") as write:
            g.swap_image(self.layout, g.Image(self.shown()))
        write.assert_not_called()

    def test_rotation_never_touches_the_theme(self):
        theme = self.layout.theme.read_bytes()
        for _ in range(3):
            g.rotate(self.layout, self.pics, "next")
        self.assertEqual(self.layout.theme.read_bytes(), theme)

    def test_bad_mode_is_refused(self):
        with self.assertRaises(g.Refused):
            g.rotate(self.layout, self.pics, "random")


if __name__ == "__main__":
    unittest.main(verbosity=2)
