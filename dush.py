#!/usr/bin/env python3
"""dush - disk usage shell: show sizes of items in a directory, sorted descending."""
import os
import sys
import argparse

FILE_ATTRIBUTE_REPARSE_POINT = 0x400

def is_real_dir(entry):
    try:
        return (
            entry.is_dir(follow_symlinks=False)
            and not (entry.stat(follow_symlinks=False).st_file_attributes & FILE_ATTRIBUTE_REPARSE_POINT)
        )
    except (AttributeError, OSError):
        return entry.is_dir(follow_symlinks=False) and not entry.is_symlink()

def get_size(path):
    try:
        if getattr(os.lstat(path), 'st_file_attributes', 0) & FILE_ATTRIBUTE_REPARSE_POINT:
            return 0
    except OSError:
        return 0
    if os.path.isfile(path):
        return os.path.getsize(path)
    total = 0
    try:
        with os.scandir(path) as it:
            for entry in it:
                try:
                    if entry.is_file(follow_symlinks=False):
                        total += entry.stat().st_size
                    elif is_real_dir(entry):
                        total += get_size(entry.path)
                except (PermissionError, OSError):
                    pass
    except (PermissionError, OSError):
        pass
    return total

def _to_display(path):
    try:
        return os.path.relpath(path).replace('\\\\', '/')
    except ValueError:
        return str(path)

def human(size):
    for unit in ('B', 'KB', 'MB', 'GB', 'TB'):
        if size < 1024:
            return f"{size:.1f} {unit}"
        size /= 1024
    return f"{size:.1f} PB"

def print_tree(path, depth, max_depth, prefix='', show_files=False, show_subtotals=False):
    items = []
    try:
        with os.scandir(path) as it:
            for entry in it:
                try:
                    if is_real_dir(entry):
                        size = get_size(entry.path)
                        items.append((size, entry.name, entry.path, True))
                    elif show_files and entry.is_file(follow_symlinks=False):
                        size = entry.stat().st_size
                        items.append((size, entry.name, entry.path, False))
                except (PermissionError, OSError):
                    pass
    except (PermissionError, OSError):
        return 0

    items.sort(reverse=True)
    for size, name, full_path, is_dir in items:
        print(f"{human(size):>12}  {prefix}{name}")
        if is_dir and depth < max_depth:
            child_items = print_tree(full_path, depth + 1, max_depth, prefix + '  ', show_files, show_subtotals)
            if show_subtotals and size > 0 and child_items > 0:
                print(f"{human(size):>12}  {prefix}  -- {name} total")
    return len(items)

def main():
    parser = argparse.ArgumentParser(description='Show disk usage of directory contents')
    parser.add_argument('path', nargs='?', default='.', help='Directory to scan (default: current)')
    parser.add_argument('-n', '--count', type=int, default=0, help='Show top N items (0 = all)')
    parser.add_argument('--depth', type=int, default=1, help='Levels deep to show (default: 1)')
    parser.add_argument('--files', action='store_true', help='Show files in tree mode')
    parser.add_argument('--subtotals', action='store_true', help='Show subtotal line after each expanded folder')
    parser.add_argument('--total-only', action='store_true', help='Print only the total size of the directory')
    args = parser.parse_args()

    target = args.path

    if not os.path.isdir(target):
        print(f"Error: '{target}' is not a directory", file=sys.stderr)
        sys.exit(1)

    if args.total_only:
        print(human(get_size(target)))
        return

    if args.depth == 1:
        # flat mode: files + dirs at top level, sorted
        items = []
        try:
            with os.scandir(target) as it:
                for entry in it:
                    try:
                        if entry.is_dir(follow_symlinks=False) and not is_real_dir(entry):
                            continue
                        size = get_size(entry.path)
                        items.append((size, entry.name))
                    except (PermissionError, OSError):
                        pass
        except (PermissionError, OSError) as e:
            print(f"Error: {e}", file=sys.stderr)
            sys.exit(1)
        items.sort(reverse=True)
        if args.count > 0:
            items = items[:args.count]
        for size, name in items:
            print(f"{human(size):>12}  {name}")
        total = sum(s for s, _ in items)
        print(f"\n{'-'*28}")
        print(f"{'TOTAL':>12}  {human(total)}")
    else:
        # tree mode: collect root items, print each with separator
        SEP = '_' * 28
        root_items = []
        try:
            with os.scandir(target) as it:
                for entry in it:
                    try:
                        if is_real_dir(entry):
                            size = get_size(entry.path)
                            root_items.append((size, entry.name, entry.path, True))
                        elif args.files and entry.is_file(follow_symlinks=False):
                            size = entry.stat().st_size
                            root_items.append((size, entry.name, entry.path, False))
                    except (PermissionError, OSError):
                        pass
        except (PermissionError, OSError) as e:
            print(f"Error: {e}", file=sys.stderr)
            sys.exit(1)
        root_items.sort(reverse=True)
        for i, (size, name, full_path, is_dir) in enumerate(root_items):
            if i > 0:
                print(SEP)
            print(f"{human(size):>12}  {name}")
            if is_dir and args.depth > 1:
                child_items = print_tree(full_path, 2, args.depth, prefix='  ', show_files=args.files, show_subtotals=args.subtotals)
                if args.subtotals and size > 0 and child_items > 0:
                    print(f"{human(size):>12}    -- {name} total")
        total = get_size(target)
        print(f"\n{'-'*28}")
        print(f"{'TOTAL':>12}  {human(total)}")

if __name__ == '__main__':
    main()
