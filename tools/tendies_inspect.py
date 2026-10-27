#!/usr/bin/env python3
"""Reference inspector for .tendies archives (CocoWall).

Parses a .tendies zip and extracts the PosterBoard descriptor metadata.
This is the ground-truth logic the Swift TendiesParser mirrors.
Usage: tendies_inspect.py <file.tendies>
"""
import plistlib
import sys
import zipfile


def clean(name: str) -> bool:
    # Skip macOS packaging noise present in community-shared archives.
    return not (name.startswith("__MACOSX/") or name.endswith(".DS_Store"))


def inspect(path: str) -> dict:
    with zipfile.ZipFile(path) as z:
        names = [n for n in z.namelist() if clean(n) and not n.endswith("/")]
        roots = sorted({n.split("/")[1] for n in names
                        if n.startswith("descriptors/") and len(n.split("/")) > 2})
        if len(roots) != 1:
            raise ValueError(f"expected exactly one descriptor, found {roots}")
        root = f"descriptors/{roots[0]}"
        read = lambda suffix: z.read(f"{root}/{suffix}")

        descriptor_id = read("com.apple.posterkit.provider.descriptor.identifier").decode().strip()
        role = read("com.apple.posterkit.role.identifier").decode().strip()

        # Locate the single .wallpaper directory under versions/<v>/contents/
        wp_dirs = sorted({n.rsplit("/", 1)[0] for n in names if n.endswith("Wallpaper.plist")})
        if len(wp_dirs) != 1:
            raise ValueError(f"expected one .wallpaper dir, found {wp_dirs}")
        wp = plistlib.loads(z.read(f"{wp_dirs[0]}/Wallpaper.plist"))

        asset = wp["assets"]["lockAndHome"]["default"]
        base = wp_dirs[0]
        present = {n[len(base) + 1:] for n in names if n.startswith(base + "/")}
        return {
            "descriptorUUID": roots[0],
            "descriptorIdentifier": descriptor_id,
            "role": role,
            "name": wp.get("name"),
            "family": wp.get("family"),
            "logicalScreenClass": wp.get("logicalScreenClass"),
            "contentVersion": wp.get("contentVersion"),
            "assetType": asset.get("type"),
            "backgroundCA": asset.get("backgroundAnimationFileName"),
            "floatingCA": asset.get("floatingAnimationFileNameKey"),
            "filesInWallpaperDir": sorted(present),
        }


if __name__ == "__main__":
    import json
    print(json.dumps(inspect(sys.argv[1]), ensure_ascii=False, indent=2))
