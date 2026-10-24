#!/usr/bin/env bash
#
# link-audiobooks.sh
# Scans for unlinked audiobooks and interactively hard-links them to the audiobooks library.
#

set -uo pipefail

SOURCE_DIR="${1:-/home/hddq/media/qBit/books}"
TARGET_DIR="${2:-/home/hddq/media/audiobooks}"

echo "=============================================="
echo " Audiobook Hard-Link Automation Script"
echo " Source: $SOURCE_DIR"
echo " Target: $TARGET_DIR"
echo "=============================================="

if [ ! -d "$SOURCE_DIR" ]; then
    echo "Error: Source directory '$SOURCE_DIR' does not exist." >&2
    exit 1
fi

# Check if exiftool is installed
if ! command -v exiftool &>/dev/null; then
    echo "[WARNING] 'exiftool' is not installed or not in PATH."
    echo "          Metadata extraction from audio tags will be limited."
fi

# Find all audio files that have not yet been hard-linked (link count == 1)
mapfile -t unlinked_audio_files < <(
    find "$SOURCE_DIR" -type f \( -name "*.m4b" -o -name "*.mp3" -o -name "*.m4a" \) -links 1 | sort
)

if [ "${#unlinked_audio_files[@]}" -eq 0 ]; then
    echo "✓ All audiobooks are already linked (no unlinked audio files found)."
    exit 0
fi

echo "Found ${#unlinked_audio_files[@]} unlinked audio file(s)."
echo

# Group by book:
# If an audio file is in a subfolder, group by that subfolder.
# If an audio file is directly in SOURCE_DIR, treat that single file as its own book.
declare -A processed_dirs
books=()

for audio_file in "${unlinked_audio_files[@]}"; do
    dir=$(dirname "$audio_file")
    if [ "$dir" = "$SOURCE_DIR" ]; then
        # Standalone file directly in root
        books+=("FILE:$audio_file")
    else
        # Directory-based book
        if [ -z "${processed_dirs["$dir"]:-}" ]; then
            processed_dirs["$dir"]=1
            books+=("DIR:$dir")
        fi
    fi
done

total_books="${#books[@]}"
echo "Identified $total_books unlinked audiobook item(s) to review."
echo "----------------------------------------------"

linked_count=0
skipped_count=0

clean_string() {
    local str="$1"
    # Remove leading/trailing brackets, format tags, years
    str=$(echo "$str" | sed -E 's/^[[:space:]]*\[[^]]+\][[:space:]]*//')
    str=$(echo "$str" | sed -E 's/[[:space:]]*[\(\[][0-9]{4}[\)\]][[:space:]]*//g')
    str=$(echo "$str" | sed -E 's/[[:space:]]*\((M4B|MP3|Unabridged|Audiobook|Audio Connoisseur|Fourth Edition)\)[[:space:]]*//gi')
    str=$(echo "$str" | sed -E 's/[[:space:]]*\[(M4B|MP3|Audio Connoisseur)\][[:space:]]*//gi')
    # Remove filesystem illegal characters
    str=$(echo "$str" | tr -d ':/')
    # Strip leading/trailing whitespace
    str=$(echo "$str" | xargs)
    echo "$str"
}

for item in "${books[@]}"; do
    type="${item%%:*}"
    target_path="${item#*:}"

    artist=""
    album=""
    needs_manual_warning=0
    files_to_link=()

    if [ "$type" = "DIR" ]; then
        book_dir="$target_path"
        first_audio=$(find "$book_dir" -maxdepth 1 -type f \( -name "*.m4b" -o -name "*.mp3" -o -name "*.m4a" \) | sort | head -n 1)

        # Collect unlinked files in this directory (exclude standalone .epub files)
        while IFS= read -r f; do
            [ -f "$f" ] && [ "$(stat -c '%h' "$f")" -eq 1 ] && [[ "$f" != *.epub ]] && files_to_link+=("$f")
        done < <(find "$book_dir" -maxdepth 1 -type f | sort)

        # 1. Try reading embedded tags via exiftool
        if [ -n "$first_audio" ] && command -v exiftool &>/dev/null; then
            artist=$(exiftool -s3 -Artist "$first_audio" 2>/dev/null || true)
            [ -z "$artist" ] && artist=$(exiftool -s3 -AlbumArtist "$first_audio" 2>/dev/null || true)
            album=$(exiftool -s3 -Album "$first_audio" 2>/dev/null || true)
        fi

        # 2. Try .nfo file if tags are empty
        if [ -z "$artist" ] || [ -z "$album" ]; then
            nfo_file=$(find "$book_dir" -maxdepth 1 -name "*.nfo" | head -n 1)
            if [ -n "$nfo_file" ]; then
                [ -z "$artist" ] && artist=$(grep -i "^[[:space:]]*Author:" "$nfo_file" | head -n 1 | awk -F ':' '{print $2}' | xargs || true)
                [ -z "$album" ] && album=$(grep -i "^[[:space:]]*Title:" "$nfo_file" | head -n 1 | awk -F ':' '{print $2}' | xargs || true)
            fi
        fi

        # 3. Fallback to folder name parsing (e.g. "Author - Book Title")
        if [ -z "$artist" ] || [ -z "$album" ]; then
            folder_name=$(basename "$book_dir")
            clean_name=$(echo "$folder_name" | sed -E 's/^\[[^]]+\][[:space:]]*//')
            if [[ "$clean_name" =~ (.*)[[:space:]]-[[:space:]](.*) ]]; then
                [ -z "$artist" ] && artist="${BASH_REMATCH[1]}"
                [ -z "$album" ] && album="${BASH_REMATCH[2]}"
            else
                [ -z "$album" ] && album="$folder_name"
            fi
        fi

        display_source="$book_dir"

    else
        # Standalone single file in root
        audio_file="$target_path"
        files_to_link+=("$audio_file")

        # Check for companion files with same base name (e.g., .jpg, .cue)
        base="${audio_file%.*}"
        for ext in jpg jpeg png cue nfo; do
            if [ -f "$base.$ext" ] && [ "$(stat -c '%h' "$base.$ext")" -eq 1 ]; then
                files_to_link+=("$base.$ext")
            fi
        done

        if command -v exiftool &>/dev/null; then
            artist=$(exiftool -s3 -Artist "$audio_file" 2>/dev/null || true)
            [ -z "$artist" ] && artist=$(exiftool -s3 -AlbumArtist "$audio_file" 2>/dev/null || true)
            album=$(exiftool -s3 -Album "$audio_file" 2>/dev/null || true)
            [ -z "$album" ] && album=$(exiftool -s3 -Title "$audio_file" 2>/dev/null || true)
        fi

        if [ -z "$artist" ] || [ -z "$album" ]; then
            fname=$(basename "$audio_file")
            fname_no_ext="${fname%.*}"
            if [[ "$fname_no_ext" =~ (.*)[[:space:]]-[[:space:]](.*) ]]; then
                [ -z "$artist" ] && artist="${BASH_REMATCH[1]}"
                [ -z "$album" ] && album="${BASH_REMATCH[2]}"
            else
                [ -z "$album" ] && album="$fname_no_ext"
            fi
        fi

        display_source="$audio_file"
    fi

    # Clean parsed strings
    artist=$(clean_string "${artist:-}")
    album=$(clean_string "${album:-}")

    if [ -z "$artist" ] || [ -z "$album" ] || [ "$artist" = "Unknown Author" ] || [ "$album" = "Unknown Book" ]; then
        needs_manual_warning=1
    fi

    echo
    echo "=========================================================="
    echo "Source : $display_source"
    echo "Files  : ${#files_to_link[@]} file(s) to link"

    if [ "$needs_manual_warning" -eq 1 ]; then
        echo -e "\e[33m[!] WARNING: Could not automatically detect full Author and Book Name.\e[0m"
        [ -z "$artist" ] && artist="Unknown Author"
        [ -z "$album" ] && album="Unknown Book"
    fi

    echo "Author : $artist"
    echo "Title  : $album"
    dest_dir="$TARGET_DIR/$artist/$album"
    echo "Target : $dest_dir"
    echo "----------------------------------------------------------"

    # Interactive prompt loop
    while true; do
        read -r -p "Link this book? [y = Yes / n = Skip / m = Manual edit]: " choice < /dev/tty
        case "$choice" in
            [yY]|[yY][eE][sS])
                mkdir -p "$dest_dir"
                echo "Creating hard links in: $dest_dir"
                for f in "${files_to_link[@]}"; do
                    ln "$f" "$dest_dir/"
                done
                echo -e "\e[32m✓ Linked successfully!\e[0m"
                ((linked_count++))
                break
                ;;
            [nN]|[nN][oO])
                echo "Skipped."
                ((skipped_count++))
                break
                ;;
            [mM]|[mM][aA][nN][uU][aA][lL])
                read -r -p "Enter Author name: " custom_artist < /dev/tty
                read -r -p "Enter Book title : " custom_album < /dev/tty
                artist=$(clean_string "$custom_artist")
                album=$(clean_string "$custom_album")
                dest_dir="$TARGET_DIR/$artist/$album"
                echo "Updated Target: $dest_dir"
                ;;
            *)
                echo "Please enter 'y', 'n', or 'm'."
                ;;
        esac
    done
done

echo
echo "=============================================="
echo "Done!"
echo "Books linked : $linked_count"
echo "Books skipped: $skipped_count"
echo "=============================================="
