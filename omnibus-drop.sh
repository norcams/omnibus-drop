#!/bin/bash
shopt -s extglob

ver="0.1.0"

working_dir="$PWD"
source_dir="${BASH_SOURCE[0]%/*}"

url_file="url.txt"
version_file="version.txt"
platform_file="platform.txt"
functions_file="functions.sh"
checksum_file="sha256.txt"

#
# Placeholder functions for pre and postinstall tasks.
#
preinstall() { return; }
postinstall() { return; }

#
# Only use sudo if not already root.
#
if (( $UID == 0 )); then sudo=""
else                     sudo="sudo"
fi

#
# Auto-detect the downloader.
#
if   command -v wget >/dev/null; then downloader="wget"
elif command -v curl >/dev/null; then downloader="curl"
fi

#
# Auto-detect checksum verification util
#
if   command -v sha256sum >/dev/null; then verifier="sha256sum"
elif command -v shasum >/dev/null;    then verifier="shasum -a 256"
fi

#
# Auto-detect the package manager and supported package types
#
if command -v apt-get >/dev/null; then 
  package_manager_command="DEBIAN_FRONTEND=noninteractive apt-get install"
  package_format="deb"
  supported_formats="$package_format"
elif command -v yum >/dev/null; then
  package_manager_command="yum -y install"
  package_format="rpm"
  supported_formats="$package_format"
fi

#
# Prints a log message.
#
log()
{
  if [[ -t 1 ]]; then
    echo -e "\x1b[1m\x1b[32m>>>\x1b[0m \x1b[1m$1\x1b[0m"
  else
    echo ">>> $1"
  fi
}

#
# Prints a warn message.
#
warn()
{
  if [[ -t 1 ]]; then
    echo -e "\x1b[1m\x1b[33m***\x1b[0m \x1b[1m$1\x1b[0m" >&2
  else
    echo "*** $1" >&2
  fi
}

#
# Prints an error message.
#
error()
{
  if [[ -t 1 ]]; then
    echo -e "\x1b[1m\x1b[31m!!!\x1b[0m \x1b[1m$1\x1b[0m" >&2
  else
    echo "!!! $1" >&2
  fi
}

#
# Prints an error message and exists with -1.
#
fail()
{
  error "$*"
  exit -1
}

#
# Detects OS and sets $platform, $release and $arch
#
detect_platform()
{
  arch=$(uname -m)

  if [[ -f /etc/lsb-release ]]; then
    platform=$(grep DISTRIB_ID /etc/lsb-release | cut -d "=" -f 2 | tr '[A-Z]' '[a-z]')
    release=$(grep DISTRIB_RELEASE /etc/lsb-release | cut -d "=" -f 2)
  elif [[ -f /etc/debian_version ]]; then
    platform="debian"
    release=$(cat /etc/debian_version)
  elif [[ -f /etc/redhat-release ]]; then
    platform=$(sed 's/^\(\w\+\) .*/\1/' /etc/redhat-release | tr '[A-Z]' '[a-z]')
    release=$(sed 's/^.\+ release \([.0-9]\+\).*/\1/' /etc/redhat-release)
  elif [[ -f /etc/system-release ]]; then
    platform=$(sed 's/^\(\w\+\) .*/\1/' /etc/system-release | tr '[A-Z]' '[a-z]')
    release=$(sed 's/^.\+ release \([.0-9]\+\).*/\1/' /etc/system-release | tr '[A-Z]' '[a-z]')
  # Apple OS X
  elif [[ -f /usr/bin/sw_vers ]]; then
    platform="darwin"
    # Matching the tab-space with sed is error-prone
    release=$(sw_vers | awk '/^ProductVersion:/ { print $2 }' | cut -d. -f1,2)
    local x86_64_capable=$(sysctl -n hw.optional.x86_64)
    if [[ $x86_64_capable -eq 1 ]]; then
      arch="x86_64"
    fi
  elif [[ -f /etc/SuSE-release ]]; then
    local enterprise=$(grep -q 'Enterprise' /etc/SuSE-release)
    if [[ ! -z $enterprise ]]; then
      platform="sles"
      release=$(awk '/^VERSION/ {V = $3}; /^PATCHLEVEL/ {P = $3}; END {print V "." P}' /etc/SuSE-release)
    else
      platform="suse"
      release=$(awk '/^VERSION =/ { print $3 }' /etc/SuSE-release)
    fi
  fi

  local os=$(uname -s)
  if [[ $os == FreeBSD ]]; then
    platform="freebsd"
    release=$(uname -r | sed 's/-.*//')
  fi

  if [[ -z $platform ]]; then
    error "Unable to determine what OS platform this is!"
    return 1
  fi

  # Remap to major release version for some platforms
  local major_release=$(echo $release | cut -d. -f1)
  case "$platform" in
    redhat|centos|amazon)
      release=$major_release
      ;;
    debian)
      release=$major_release
      ;;
    freebsd)
      release=$major_release
      ;;
    sles|suse)
      release=$major_release
      ;;
  esac
}

#
# Check if a file contains valid "key: value" pairs of data
# This is just a simple sanity check and might blow up(!)
#
validate_project_file()
{
  local p="$1"
  if [[ -s "$p" ]]; then
    grep -q -E '^[-_\ a-zA-Z0-9]+:\ .*$' "$p" || return $?
  else
    # File does not exist or is zero-sized
    return 1
  fi
}

#
# Searches $working_dir for projects by looking for subdirs that contains
# a $url_file 
#
known_projects()
{
  local known_projects=()
  for p in "$working_dir"/*; do
    # A minimal project is a $url_file
    validate_project_file "$p/$url_file" || continue
    known_projects+=("$p")
  done

  if [[ ${#known_projects[@]} -eq 0 ]]; then
    warn "No valid project subdirs found in current directory."
    warn "A minimal project is [PROJECT_NAME]/$url_file or uses the -u option"
    return 0
  fi

  for p in "${known_projects[@]}"; do
    echo "${p##*/}"
    if [[ -f "$p/$version_file" ]]; then
      echo "  Version aliases:"
      cat "$p/$version_file" | sed 's/^/    /'
    fi
    if [[ -f "$p/$platform_file" ]]; then
      echo "  Platform tags:"
      cat "$p/$platform_file" | sed 's/^/    /'
    fi
    if [[ -f "$p/$url_file" ]]; then
      echo "  Package URLs:"
      cat "$p/$url_file" | sed 's/^/    /'
    fi
  done
}

#
# Mirrors remote project files from a location provided on the command line
#
mirror_project()
{
  local data_found=0

  # Display remote and local paths, warn if local path already exists
  # as we then skip downloading existing files
  log "Mirroring remote project $project_mirror to $project_path"
  mkdir -p "$project_path" || return $?

  # Main project metadata download loop  
  for dl in "$url_file" \
            "$version_file" \
            "$platform_file" \
            "$functions_file" \
            "$checksum_file" ; do
    # Skip any files that already exits and set data_found=1
    if [[ -s "$project_path/$dl" ]]; then
      warn "$project_mirror/$dl -> $project/$dl: Filename already exists, skipping as OK"
      data_found=1
      continue
    fi
    # Try downloading
    local dl_exit_code=$(download "$project_mirror/$dl" "$project_path")
    # If we get a non-zero file log and set dl_ok
    if [[ $dl_exit_code -eq 0 && -s "$project_path/$dl" ]]; then
      log "$project_mirror/$dl -> $project/$dl: OK"
      data_found=1
    fi
  done

  # Fail if we didn't get any files
  if [[ $data_found -eq 0 ]]; then
    warn "Could not mirror, no data found."
    return 1 
  fi
}

#
# Expands inline variables in URLs from $url_file or -u option to allow flexibility
# Only non-quoted variables like ${var} will be expanded, see below
#
expand_url()
{
  local url="$1"
  url="${url/\$\{platform\}/$platform}"
  url="${url/\$\{release\}/$release}"
  url="${url/\$\{arch\}/$arch}"
  url="${url/\$\{project\}/$project}"
  url="${url/\$\{version\}/$version}"
  url="${url/\$\{platform_tag\}/$platform_tag}"
  url="${url/\$\{package_format\}/$package_format}"
  echo "$url"
}

#
# Searches a file for a key and echos the value.
# If the key cannot be found, the third argument will be echoed.
# If the file is missing, ignore errors
#
fetch()
{
  local file="$1"
  local key="$2"
  local pair="$(grep -s -E "^$key:" "$file")"

  echo "${pair##$key:*([[:space:]])}"
}

# Load and verify metadata from files and command line options. A minimal
# project must provide the following
#
#   - $project from the command line
#   - $version from the command line or $version_file
#   - $url from the command line or $url_file
#
load_project()
{
  local expanded_version="$(fetch "$project_path/$version_file" "$version")"
  version="${expanded_version:-$version}"

  # Read platform_tag from metadata or fall back to default_tag
  local default_tag="$platform/$release/$arch"
  local tag="$(fetch "$project_path/$platform_file" "$platform/$release/$arch")"
  platform_tag="${tag:-$default_tag}"

  # Read url from metadata file or command line
  local url_value="$(fetch "$project_path/$url_file" "$platform_tag")"
  # If platform_tag url lookup is empty, fall back to "default"
  url_default="$(fetch "$project_path/$url_file" "default")"
  url_value="${url_value:-$url_default}"
  # Override with command line option if it is non-empty
  url_value="${url:-$url_value}"
  # Substitute any variables in url_value with expand_url()
  url="$(expand_url $url_value)"
  # If url is still a zero-length string we fail
  if [[ -z "$url" ]]; then
    error "Package download URL not set in project files or on the command line"
    error "A minimal project is $project/$url_file or uses the -u option"
    return 1
  fi

  # Assume last part of URL is the filename
  filename="${url##*/}"
  # Reassign package_format variable with value derived from filename
  package_format="${filename##*.}"
  package_download_path="$project_path/$platform_tag"

  # Fail if package is not supported on this system
  is_supported "$supported_formats" "$package_format" || return $?

  # Read checksum from metadata file
  local checksum_value="$(fetch "$project_path/$checksum_file" "$filename")"
  # Make it possible to override checksum from the command line
  checksum="${checksum:-$checksum_value}"
  # Fail if we require a checksum and it is empty
  if [[ -z "$checksum" ]]; then
    if [[ $no_verify -eq 0 ]]; then
      error "No checksum found in project files or on the commmand line"
      error "To skip verification specify --no-verify (not recommended!)"
      return 1
    else
      warn "File verification skipped! Assuming no evil."
    fi
  fi

  # If scripts are not disabled, source $functions_file if it exists
  if [[ -z $no_scripts && -f "$project_path/$functions_file" ]]; then
    source "$project_path/$functions_file" || return $?
  fi
}

#
# Downloads a URL.
#
download()
{
  local url="$1"
  local dest="$2"

  [[ -d "$dest" ]] && dest="$dest/${url##*/}"
  [[ -f "$dest" ]] && return

  case "$downloader" in
    wget) wget --progress=bar:force -c -O "$dest.part" "$url" || return $? ;;
    curl) curl -sfLC - -o "$dest.part" "$url" || return $? ;;
    "")
      error "Could not find wget or curl"
      return 1
      ;;
  esac

  mv "$dest.part" "$dest" || return $?
}

#
# Downloads a package.
#
download_package()
{
  log "Downloading package: $url"
  mkdir -p "$package_download_path" || return $?
  download "$url" "$package_download_path" || return $?
}

#
# Verify a file using a SHA256 checksum
# Why SHA256? I guess just because, I don't know :)
#
verify()
{
  local path="$1"
  local checksum="$2"

  if [[ -z "$verifier" ]]; then
    error "Unable to find the checksum utility"
    return 1
  fi

  if [[ -z "$checksum" ]]; then
    error "No checksum given"
    return 1
  fi

  local match='^'$checksum'\ '
  if [[ ! "$($verifier "$path")" =~ $match ]]; then
    error "$path is invalid!"
    return 1
  else
    log "File checksum verified OK."
  fi
}

#
# Verify downloaded package
#
verify_package()
{
  verify "$package_download_path/$filename" "$checksum"
}

#
# Checks if it is possible to install this package type
#
is_supported()
{
  local supp="$1"
  local fmt="$2"

  local match='(^|\ )'$fmt'(\ |$)'
  if [[ ! $supp =~ $match ]]; then
    error "$fmt packages are not supported on this system"
    return 1
  else
    return 0
  fi
}

#
# Checks if a package is already installed
#
is_installed()
{
  local format="$1"
  local package="$2"

  case "$format" in
    rpm)
      local package_data="$($sudo rpm -qp "$package")"
      [[ ! $? -eq 0 ]] && fail "Could not read data from $package"
      $sudo rpm --quiet -qi "$package_data"
      return $?
      ;;
    deb)
      # FIXME
      echo "FIXME deb is_installed() not yet implemented"
      return 0
      ;;
    *)
      fail "Unknown package type $type: $package"
      ;;
  esac
}

#
# Executes a package install based on package type and what package manager was .
#
install_p()
{
  local format="$1"
  local package="$2"

  case "$format" in
    rpm|deb)
      $sudo $package_manager_command "$package" || return $? ;;
    *)
      fail "Sorry, no support yet(?) for "$format" packages"
      ;;
  esac
}

#
# Call package manager to check if package is already installed 
# If not, we do the actual install and log
#
install_package()
{
  log "Installing $project $version from $filename"
  is_installed "$package_format" "$package_download_path/$filename"
  if [[ $? -eq 0 ]]; then
    warn "Package manager reports it as already installed, skipping"
  else
    preinstall || return $?
    install_p "$package_format" "$package_download_path/$filename" || return $?
    postinstall || return $?
    log "Successfully installed $project $version from $filename"
  fi
}

#
# Prints usage information
#
usage()
{
  cat <<USAGE
usage: omnibus-drop [OPTIONS] [PROJECT [VERSION]]

Options:

    -d, --dest-dir DIR     Directory to download package into
    -M, --mirror URL       Alternate mirror to download project metadata from
    -u, --url URL          Alternate URL to download the package from
    -s, --sha256 SHA256    Checksum of the package
    --no-download          Use a previously downloaded package
    --no-verify            Do not verify the downloaded package
    --no-scripts           Do not load functions.sh when installing
    -V, --version          Prints the version
    -h, --help             Prints this message

Examples:

    $ omnibus-drop puppet
    $ omnibus-drop puppet 3.6.2
    $ omnibus-drop -M https://url.to/projects/root puppet

USAGE
}

#
# Parses command-line options
#
parse_options()
{
  local argv=()

  while [[ $# -gt 0 ]]; do
    case $1 in
      -d|--dest-dir)
        src_dir="$2"
        shift 2
        ;;
      -M|--mirror)
        project_mirror="$2"
        shift 2
        ;;
      -u|--url)
        url="$2"
        shift 2
        ;;
      -s|--sha256)
        checksum="$2"
        shift 2
        ;;
      --no-download)
        no_download=1
        shift
        ;;
      --no-verify)
        no_verify=1
        shift
        ;;
      --no-scripts)
        no_scripts=1
        shift
        ;;
      -V|--version)
        echo "omnibus-drop: $ver"
        exit
        ;;
      -h|--help)
        usage
        exit
        ;;
      -*)
        echo "omnibus-drop: unrecognized option $1" >&2
        return 1
        ;;
      *)
        argv+=($1)
        shift
        ;;
    esac
  done

  case ${#argv[*]} in
    2)
      project="${argv[0]}"
      project_path="$working_dir/$project"
      version="${argv[1]}"
      ;;
    1)
      project="${argv[0]}"
      project_path="$working_dir/$project"
      version="stable"
      ;;
    0)
      echo "omnibus-drop: too few arguments" >&2
      usage 1>&2
      return 1
      ;;
    *)
      echo "omnibus-drop: too many arguments: ${argv[*]}" >&2
      usage 1>&2
      return 1
      ;;
  esac
}


#
# Main script loop
#
detect_platform || exit $?

if [[ $# -eq 0 ]]; then
  log "omnibus-drop v${ver} platform=$platform release=$release arch=$arch"
  known_projects
  exit
fi

parse_options "$@" || exit $?

if [[ -n "$project_mirror" ]]; then
  mirror_project || fail "Mirroring failed."
fi

load_project || fail "Could not load project: $project"

if [[ ! $no_download -eq 1 ]]; then
  download_package || fail "Package download failed."
fi

if [[ ! $no_verify -eq 1 ]]; then
  verify_package || fail "Package checksum verification failed."
fi

install_package || fail "Installation failed." 

