#!/usr/bin/env sh
# ytdlrc - YouTube Downloader with Rclone Integration
# A modular script that downloads media via youtube-dl and  moves them to cloud storage via rclone.
# Author: Original by bardisty <b@bah.im> Refactored on March 12, 2025

# =================== CONFIGURATION ===================

# Enable debugging for verbose output
debug=false

# --------- Directory Structure ---------
ytdl_root_dir="${HOME}/ytdlrc"
ytdl_download_dir="${ytdl_root_dir%/}/stage"
ytdl_snatch_list="${ytdl_root_dir%/}/snatch.list"
ytdl_archive_list="${ytdl_root_dir%/}/archive.list"

# --------- YouTube-DL Settings ---------
# Video format to download
ytdl_format="bestvideo[height<=1080]+bestaudio/best[height<=1080]"

# Output filename template
ytdl_output_template="%(uploader)s.%(upload_date)s.%(title)s.%(resolution)s.%(id)s.%(ext)s"

# Metadata and subtitle options
ytdl_write_metadata_to_xattrs=false
ytdl_write_subtitles=true
ytdl_write_automatic_subtitles=true
ytdl_write_all_subtitles=false
ytdl_subtitle_format="srt/best"
ytdl_subtitle_lang="en"

# Organization options
ytdl_video_value="playlist_title"
ytdl_default_video_value="unknown-playlist"
ytdl_skip_on_fail=true
ytdl_lowercase_directories=false

# --------- Rclone Settings ---------
rclone_config="${HOME}/.config/rclone/rclone.conf"
rclone_command="move"
rclone_destination="remote:archive/youtube"
rclone_flags="--transfers 8 --checkers 16 --acd-upload-wait-per-gb 5m"

# =========== UTILITY FUNCTIONS ===========

# Print formatted messages
say() {
  printout_prefix="${text_bold}${text_yellow}[YTDLRC]${text_reset}"
  printf %s\\n "${printout_prefix} ${1}"
}

# Print error messages
say_error() {
  printout_prefix_error="${text_bold}${text_red}[Error]${text_reset}"
  say "${printout_prefix_error} ${1}" >&2
}

# Print debug messages if debug is enabled
say_debug() {
  message_type="$2"
  if [ "$debug" = true ]; then
    if [ "$message_type" = "success" ]; then
      printout_prefix_debug="${text_bold}${text_gray}[Debug]${text_green} [OK]${text_reset}"
    else
      printout_prefix_debug="${text_bold}${text_gray}[Debug]${text_reset}"
    fi
    say "${printout_prefix_debug} ${1}"
  fi
}

# Check if a directory is empty
is_empty() {
  cd "$1" || return 0
  set -- .[!.]* ; test -f "$1" && return 1
  set -- ..?* ; test -f "$1" && return 1
  set -- * ; test -f "$1" && return 1
  return 0
}

# Check if a command exists in PATH
command_exists() {
  cmd="$1"
  if eval type type > /dev/null 2>&1; then
    eval type "$cmd" > /dev/null 2>&1
  else
    command -v "$cmd" > /dev/null 2>&1
  fi
  return $?
}

# =========== CORE FUNCTIONS ===========

# Extract metadata from video to determine directory structure
get_video_value() {
  # $1 = metadata field to extract (e.g., "playlist_title")
  # $2 = playlist item number (e.g., "1")
  # $3 = URL to fetch from
  say_debug "Grabbing '${1}' from '${3}'..."

  video_value=$(
    youtube-dl \
      --force-ipv4 \
      --get-filename \
      --output "%(${1})s" \
      --playlist-items "$2" \
      --restrict-filenames \
      "$3"
  )

  # Assign default value if extraction failed
  video_value="${video_value:-$ytdl_default_video_value}"
}

# Download videos and move them to the rclone destination
download_all_the_things() {
  # $1 = URL to download
  # shellcheck disable=SC2086
  youtube-dl \
    --force-ipv4 \
    --continue \
    --download-archive "$ytdl_archive_list" \
    --exec "rclone $rclone_command \
      '{}' '${rclone_destination%/}/${video_value}' \
      --config '$rclone_config' \
      $rclone_flags \
      $rclone_debug_flags" \
    --format "$ytdl_format" \
    --ignore-config \
    --ignore-errors \
    --no-overwrites \
    --output "${ytdl_download_dir%/}/${video_value}/${ytdl_output_template}" \
    --restrict-filenames \
    --write-description \
    --write-info-json \
    --write-thumbnail \
    "$ytdl_debug_flags" \
    $ytdl_subtitle_flags \
    $ytdl_xattrs_flag \
    "$1"
}

# Verify rclone version meets minimum requirements
check_rclone_version() {
  minimum_required_version=1.43
  rclone_version=$(rclone --version|awk '/rclone/ { print $2 }')
  version_prefix="v"
  version_dev="-DEV"
  version_beta="-beta"

  # Helper to trim strings from version number
  if_contains_string() {
    if test "${rclone_version#*$1}" != "$rclone_version"; then
      rclone_version=$(printf %s\\n "$rclone_version"|$2)
    fi
  }

  if ! command_exists awk; then
    say_error "Command not found: awk"
    delete_lock_file
    exit 127
  fi

  say_debug "Checking if rclone meets minimum required version (${minimum_required_version})..."

  # Clean up version string for comparison
  if_contains_string "$version_beta" "cut -d - -f 1"
  if_contains_string "$version_dev" "cut -d - -f 1"
  if_contains_string "$version_prefix" "sed s/^${version_prefix}//"

  # Compare versions
  meets_minimum_required_version=$(awk -v current="$rclone_version" \
    -v required="$minimum_required_version" \
    'BEGIN{print current<required?0:1}' \
  )

  if [ "$meets_minimum_required_version" -eq 0 ]; then
    say_error "Rclone does not meet minimum required version."
    say_error "Installed version: ${rclone_version}"
    say_error "Minimum required version: ${minimum_required_version}"
    delete_lock_file
    exit 1
  else
    say_debug "Installed version: ${rclone_version}" success
  fi
}

# Manage lock file to prevent multiple instances
create_lock_file() {
  say_debug "Lock file doesn't exist. Attempting to create '${lock_file}'..."
  # Check if temp file directory exists
  if [ -d "${temp_file_dir%/}" ]; then
    # Temp file directory exists; attempt to create lock file
    if touch "$lock_file"; then
      say_debug "Creating '${lock_file}' succeeded. Continuing..." success
    else
      say_error "Could not create lock file '${lock_file}'. Exiting..."
      exit 1
    fi
  else
    # Temp file directory does not exist; attempt to create it
    say_debug "Temp file directory '${temp_file_dir%/}' not found. Attempting to create it..."
    if mkdir -p "${temp_file_dir%/}"; then
      # Attempt to create lock file
      say_debug "Creating '${temp_file_dir%/}' succeeded. Creating lock file..." success
      if touch "$lock_file"; then
        say_debug "Creating '${lock_file}' succeeded. Continuing..." success
      else
        say_error "Could not create lock file '${lock_file}'. Exiting..."
        exit 1
      fi
    else
      say_error "Could not create temp directory '${temp_file_dir%/}'. Exiting..."
      exit 1
    fi
  fi
}

# Remove lock file
delete_lock_file() {
  say_debug "Removing lock file..."
  if [ -f "$lock_file" ]; then
    if ! rm "$lock_file"; then
      say_error "Could not delete lock file: ${lock_file}"
      exit 1
    else
      say_debug "Lock file deleted." success
    fi
  else
    say_error "Lock file doesn't exist: ${lock_file}"
  fi
}

# Create necessary directories and files
setup_environment() {
  # Create download directory if needed
  if [ ! -d "${ytdl_download_dir%/}" ]; then
    say "Creating download directory: ${ytdl_download_dir%/}"
    if ! mkdir -p "${ytdl_download_dir%/}"; then
      say_error "Could not create download directory '${ytdl_download_dir%/}'. Exiting..."
      delete_lock_file
      exit 1
    fi
  fi

  # Create snatch list if needed
  if [ ! -f "$ytdl_snatch_list" ]; then
    say "Creating snatch list: ${ytdl_snatch_list}"
    if ! touch "$ytdl_snatch_list"; then
      say_error "Could not create snatch list '${ytdl_snatch_list}'. Exiting..."
      delete_lock_file
      exit 1
    fi
  fi

  # Create archive list if needed
  if [ ! -f "$ytdl_archive_list" ]; then
    say "Creating archive list: ${ytdl_archive_list}"
    if ! touch "$ytdl_archive_list"; then
      say_error "Could not create archive list '${ytdl_archive_list}'. Exiting..."
      delete_lock_file
      exit 1
    fi
  fi

  # Check if snatch list is empty
  if [ ! -s "$ytdl_snatch_list" ]; then
    say_error "${ytdl_snatch_list} is empty. Exiting..."
    delete_lock_file
    exit 1
  fi
}

# Verify all dependencies are installed
check_dependencies() {
  say_debug "Checking required commands..."
  required_commands="youtube-dl ffmpeg rclone"
  for cmd in $required_commands; do
    if ! command_exists "$cmd"; then
      say_error "Command not found: ${cmd}"
      delete_lock_file
      exit 127
    else
      say_debug "Command found: ${cmd}" success
    fi
  done
}

# Verify rclone configuration and remote
check_rclone_config() {
  # Check if config file exists
  say_debug "Checking if rclone configuration file exists..."
  if [ ! -f "$rclone_config" ]; then
    say_error "Rclone configuration not found: ${rclone_config}"
    delete_lock_file
    exit 1
  else
    say_debug "Using rclone configuration: ${rclone_config}" success
  fi

  # Check if remote is accessible
  say_debug "Checking rclone remote for any issues..."
  if ! rclone about "$rclone_destination" > /dev/null 2>&1; then
    say_error "Could not read rclone remote '${rclone_destination}'."
    say_error "If the remote looks correct, check for issues by running: \`rclone about ${rclone_destination}\`"
    delete_lock_file
    exit 1
  else
    say_debug "Remote exists. No issues found." success
  fi
}

# Set up xattrs support if enabled
setup_xattrs() {
  if [ "$ytdl_write_metadata_to_xattrs" = true ]; then
    if ! command_exists attr; then
      say_error "Command not found: attr"
      say_error "Please install the \`attr\` package or set \`ytdl_write_metadata_to_xattrs\` to \`false\`."
      delete_lock_file
      exit 127
    fi

    # Test if filesystem supports xattrs
    xattr_test_file="${ytdl_download_dir%/}/ytdlrc_xattr_test"
    if touch "$xattr_test_file"; then
      if ! setfattr -n "user.testAttr" -v "attribute value" "$xattr_test_file" > /dev/null 2>&1; then
        say_error "Extended attributes not supported."
        say_error "Please set \`ytdl_write_metadata_to_xattrs\` to \`false\`."
        rm "$xattr_test_file"
        delete_lock_file
        exit 1
      else
        ytdl_xattrs_flag="--xattrs"
        rm "$xattr_test_file"
      fi
    else
      say_error "Could not create xattrs test file. Does ${ytdl_download_dir%/} exist?"
      say_error "You can bypass this by setting \`ytdl_write_metadata_to_xattrs\` to \`false\`."
      delete_lock_file
      exit 1
    fi
  fi
}

# Process a single URL
process_url() {
  local url="$1"
  say "Processing ${url}..."
  
  # Get video value for directory organization
  get_video_value "$ytdl_video_value" "1" "$url"

  # Try second video if first attempt failed
  if [ "$video_value" = "$ytdl_default_video_value" ]; then
    say_debug "Failed to grab '${ytdl_video_value}' from '${url}'. Trying 2nd video instead..."
    get_video_value "$ytdl_video_value" "2" "$url"
    
    # Skip or use default value based on configuration
    if [ "$video_value" = "$ytdl_default_video_value" ]; then
      if [ "$ytdl_skip_on_fail" = true ]; then
        say_debug "Failed to grab '${ytdl_video_value}' from '${url}' after 2 attempts. Skipping..."
        return
      else
        say_debug "Unable to grab '${ytdl_video_value}' from '${url}'. Using default value '${ytdl_default_video_value}' instead."
      fi
    fi
  fi

  # Clean up video value
  if [ "$video_value" != "$ytdl_default_video_value" ]; then
    say_debug "'${ytdl_video_value}' is '${video_value}'" success

    # Trim "Uploads_from_" prefix if present
    if [ "$ytdl_video_value" = "playlist_title" ]; then
      string_to_trim="Uploads_from_"
      if test "${video_value#*$string_to_trim}" != "$video_value"; then
        say_debug "Trimming off '${string_to_trim}' from '${video_value}'..."
        video_value="$(printf %s\\n "$video_value"|sed "s/^${string_to_trim}//")"
        say_debug "New '${ytdl_video_value}' is '${video_value}'" success
      fi
    fi

    # Convert to lowercase if configured
    if [ "$ytdl_lowercase_directories" = true ]; then
      say_debug "Converting '${video_value}' to lowercase..."
      video_value=$(printf %s\\n "$video_value"|tr '[:upper:]' '[:lower:]')
      say_debug "New '${ytdl_video_value}' is '${video_value}'" success
    fi
  fi

  # Download videos
  download_all_the_things "$url"

  # Handle metadata files (since youtube-dl's --exec only processes video files)
  download_directory="${ytdl_download_dir%/}/${video_value}"
  if [ -d "$download_directory" ]; then
    say_debug "Uploading metadata to rclone remote..."
    # shellcheck disable=SC2086
    rclone "$rclone_command" "$download_directory" \
      "${rclone_destination%/}/${video_value}" --config "$rclone_config" \
      $rclone_flags $rclone_debug_flags
  fi

  # Clean up empty directories if using move mode
  if [ -d "$download_directory" ] && is_empty "$download_directory" && [ "$rclone_command" = "move" ]; then
    say_debug "Removing leftover download directory: ${download_directory}"
    rmdir "$download_directory"
  fi
}

# Process all URLs in the snatch list
process_snatch_list() {
  if [ -s "$ytdl_snatch_list" ]; then
    mkfifo "$fifo"
    # Get non-commented lines from snatch list
    grep -v '^ *#' < "$ytdl_snatch_list" > "$fifo" &
    while IFS= read -r url; do
      if [ -n "$url" ]; then
        process_url "$url"
      fi
    done < "$fifo"
    rm "$fifo"
  fi
}

# =========== INITIALIZATION ===========

# Set up console colors if available
if tty > /dev/null 2>&1; then
  if command_exists tput; then
    text_reset=$(tput sgr0)
    text_bold=$(tput bold)
    text_red=$(tput setaf 1)
    text_yellow=$(tput setaf 3)
    text_green=$(tput setaf 2)
    text_gray=$(tput setaf 8)
  fi
fi

# Define temp files
temp_file_dir="/tmp"
fifo="${temp_file_dir%/}/ytdlrc.fifo"
lock_file="${temp_file_dir%/}/ytdlrc.lock"

# Set debug flags based on configuration
if [ "$debug" = true ]; then
  ytdl_debug_flags="--verbose"
  rclone_debug_flags="-vv --stats 1s --progress"
else
  ytdl_debug_flags="--quiet"
  rclone_debug_flags="-q"
fi

# Configure subtitle flags based on settings
if [ "$ytdl_write_subtitles" = true ] || [ "$ytdl_write_automatic_subtitles" = true ]; then
  ytdl_subtitle_flags="--sub-format ${ytdl_subtitle_format}"

  # Add subtitle download flags
  if [ "$ytdl_write_subtitles" = true ]; then
    ytdl_subtitle_flags="${ytdl_subtitle_flags} --write-sub"
  fi
  if [ "$ytdl_write_automatic_subtitles" = true ]; then
    ytdl_subtitle_flags="${ytdl_subtitle_flags} --write-auto-sub"
  fi
  
  # Configure subtitle language settings
  if [ "$ytdl_write_all_subtitles" = true ]; then
    ytdl_subtitle_flags="${ytdl_subtitle_flags} --all-subs"
  else
    ytdl_subtitle_flags="${ytdl_subtitle_flags} --sub-lang ${ytdl_subtitle_lang}"
  fi
fi

# =========== MAIN EXECUTION ===========

# Handle cleanup on CTRL-C
trap 'delete_lock_file && rm "$fifo" 2>/dev/null && exit 0' 2

# Check for lock file (prevents multiple instances)
if [ -f "$lock_file" ]; then
  say_debug "Lock file exists: ${lock_file}"
  say_debug "Exiting..."
  exit 0
else
  create_lock_file
fi

# Run initialization steps
setup_environment
check_dependencies
check_rclone_version
check_rclone_config
setup_xattrs

# Process all URLs in snatch list
process_snatch_list

# Finish up
say "Process completed at $(date --iso-8601=seconds)."
delete_lock_file
