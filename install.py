#!/usr/bin/env python3

import os
import sys
import shutil
import argparse
import stat
import subprocess
from pathlib import Path
from typing import Optional


class TrinityInstaller:
    def __init__(self, install_dir: Optional[str] = None, verbose: bool = False):
        self.trinity_root = Path(__file__).resolve().parent
        self.verbose = verbose
        self.trinity_home = str(self.trinity_root)

        if install_dir:
            self.install_dir = Path(install_dir).expanduser()
        else:
            self.install_dir = Path.home() / ".local" / "bin"

        self.trinity_link = self.install_dir / "Trinity"

    def log(self, msg: str, level: str = "INFO"):
        if self.verbose or level != "DEBUG":
            print(f"[{level}] {msg}", file=sys.stderr)

    def check_trinity_root(self) -> bool:
        """Verify trinity package structure exists."""
        required = [
            self.trinity_root / "Trinity",
            self.trinity_root / "util",
            self.trinity_root / "Chrysalis"
        ]

        for path in required:
            if not path.exists():
                self.log(f"Missing trinity component: {path}", "ERROR")
                return False
        return True

    def check_permissions(self) -> bool:
        """Check if installation directory is writable."""
        if self.install_dir.exists():
            return os.access(self.install_dir, os.W_OK)

        # Check parent directory if install_dir doesn't exist
        parent = self.install_dir.parent
        if not parent.exists():
            self.log(f"Parent directory doesn't exist: {parent}", "ERROR")
            return False

        return os.access(parent, os.W_OK)

    def setup_install_directory(self) -> bool:
        """Create install directory if it doesn't exist."""
        if not self.install_dir.exists():
            try:
                self.install_dir.mkdir(parents=True, mode=0o755)
                self.log(f"Created install directory: {self.install_dir}", "DEBUG")
            except OSError as e:
                self.log(f"Failed to create install directory: {e}", "ERROR")
                return False
        return True

    def build(self) -> bool:
        """Build Trinity components using make."""
        makefile_path = self.trinity_root / "Makefile"

        if not makefile_path.exists():
            self.log(f"Makefile not found: {makefile_path}", "ERROR")
            return False

        self.log("Building Trinity components...", "INFO")

        try:
            result = subprocess.run(
                ["make", "all"],
                cwd=self.trinity_root,
                capture_output=False,
                text=True
            )

            if result.returncode != 0:
                self.log("Build failed", "ERROR")
                return False

            self.log("Build completed successfully", "INFO")
            return True

        except FileNotFoundError:
            self.log("'make' command not found. Please ensure build-essential is installed", "ERROR")
            return False
        except Exception as e:
            self.log(f"Build failed with error: {e}", "ERROR")
            return False

    def create_symlink(self) -> bool:
        """Create symlink to Trinity executable."""
        trinity_exe = self.trinity_root / "Trinity"

        if not trinity_exe.exists():
            self.log(f"Trinity executable not found: {trinity_exe}", "ERROR")
            return False

        # Remove existing symlink or file
        if self.trinity_link.exists() or self.trinity_link.is_symlink():
            try:
                self.trinity_link.unlink()
                self.log(f"Removed existing link: {self.trinity_link}", "DEBUG")
            except OSError as e:
                self.log(f"Failed to remove existing link: {e}", "ERROR")
                return False

        try:
            self.trinity_link.symlink_to(trinity_exe)
            self.log(f"Created symlink: {self.trinity_link} -> {trinity_exe}", "DEBUG")
        except OSError as e:
            self.log(f"Failed to create symlink: {e}", "ERROR")
            return False

        # Ensure symlink is executable
        try:
            current_perms = os.stat(self.trinity_link, follow_symlinks=False).st_mode
            os.chmod(self.trinity_link, current_perms | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
        except OSError as e:
            self.log(f"Warning: couldn't set execute permissions: {e}", "WARN")

        return True

    def install(self) -> bool:
        """Execute the installation."""
        self.log(f"Trinity package root: {self.trinity_root}")
        self.log(f"Installation directory: {self.install_dir}")

        if not self.check_trinity_root():
            self.log("Trinity package structure validation failed", "ERROR")
            return False

        if not self.check_permissions():
            self.log(f"No write permission to {self.install_dir}", "ERROR")
            self.log("Try using --install-dir or running with appropriate permissions", "ERROR")
            return False

        if not self.build():
            return False

        if not self.setup_install_directory():
            return False

        if not self.create_symlink():
            return False

        return True

    def uninstall(self) -> bool:
        """Remove Trinity installation."""
        if not self.trinity_link.exists() and not self.trinity_link.is_symlink():
            self.log(f"No installation found at: {self.trinity_link}", "INFO")
            return True

        try:
            self.trinity_link.unlink()
            self.log(f"Removed: {self.trinity_link}", "INFO")
            return True
        except OSError as e:
            self.log(f"Failed to uninstall: {e}", "ERROR")
            return False

    def verify(self) -> bool:
        """Verify installation is working."""
        if not self.trinity_link.is_symlink():
            self.log("Trinity link is not a symlink", "ERROR")
            return False

        try:
            result = shutil.which("Trinity")
            if result:
                self.log(f"Trinity found in PATH: {result}", "INFO")
                return True
            else:
                self.log("Trinity not found in PATH", "WARN")
                self.log(f"Symlink exists at: {self.trinity_link}", "INFO")
                return True
        except Exception as e:
            self.log(f"Verification failed: {e}", "ERROR")
            return False

    def print_summary(self):
        """Print installation summary and next steps."""
        print("\n" + "="*70)
        print("Trinity Installation Summary")
        print("="*70)
        print(f"Trinity Home: {self.trinity_home}")
        print(f"Symlink: {self.trinity_link}")

        in_path = shutil.which("Trinity")
        if in_path:
            print(f"Status: ✓ Available in PATH ({in_path})")
        else:
            print(f"Status: ✗ Not in PATH")
            install_parent = self.install_dir
            print(f"\nTo use Trinity, either:")
            print(f"  1. Add {install_parent} to your PATH:")
            print(f"     export PATH=\"{install_parent}:$PATH\"")
            print(f"  2. Or use the full path: {self.trinity_link}")

        print(f"\nOptionally, set TRINITY_HOME:")
        print(f"  export TRINITY_HOME={self.trinity_home}")
        print("\nAdd these to ~/.bashrc or ~/.zshrc to persist across sessions.")
        print("="*70 + "\n")


def main():
    parser = argparse.ArgumentParser(
        description="Install Trinity RNA-Seq assembler",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Install to ~/.local/bin (default)
  %(prog)s install

  # Install to custom location
  %(prog)s install --install-dir /opt/trinity

  # Install to system-wide location (requires sudo)
  sudo %(prog)s install --install-dir /usr/local/bin

  # Uninstall
  %(prog)s uninstall

  # Verify installation
  %(prog)s verify
        """
    )

    parser.add_argument(
        "action",
        choices=["install", "uninstall", "verify"],
        help="Installation action to perform"
    )

    parser.add_argument(
        "--install-dir",
        help="Installation directory (default: ~/.local/bin)",
        metavar="PATH"
    )

    parser.add_argument(
        "-v", "--verbose",
        action="store_true",
        help="Verbose output"
    )

    args = parser.parse_args()

    installer = TrinityInstaller(install_dir=args.install_dir, verbose=args.verbose)

    try:
        if args.action == "install":
            success = installer.install()
            if success:
                installer.print_summary()
            sys.exit(0 if success else 1)

        elif args.action == "uninstall":
            success = installer.uninstall()
            sys.exit(0 if success else 1)

        elif args.action == "verify":
            success = installer.verify()
            sys.exit(0 if success else 1)

    except KeyboardInterrupt:
        print("\nInstallation cancelled by user", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"Unexpected error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
