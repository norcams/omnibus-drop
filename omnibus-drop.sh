#!/bin/bash
shopt -s extglob

ver="0.1.0"

working_dir="$PWD"
source_dir="${BASH_SOURCE[0]%/*}"

url_file="url.txt"
version_file="version.txt"
platform_file="platform.txt"
functions_file="functions.sh"

#
# Place holder functions for pre and postinstall tasks.
#
function preinstall() { return; }
function postinstall() { return; }

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
# Prints a log message.
#
function log()
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

expand_url()
{
  local url="$1"
  url="${url/\$\{platform\}/$platform}"
  url="${url/\$\{release\}/$release}"
  url="${url/\$\{arch\}/$arch}"
  url="${url/\$\{project\}/$project}"
  url="${url/\$\{version\}/$version}"
  url="${url/\$\{platform_tag\}/$platform_tag}"
  echo "$url"
}

#
# Searches a file for a key and echos the value.
# If the key cannot be found, the third argument will be echoed.
#
function fetch()
{
  local file="$project_path/$1.txt"
  local key="$2"
  local pair="$(grep -E "^$key:" "$file")"

  echo "${pair##$key:*([[:space:]])}"
}

valid_project()
{
  local p="$1"
  if [[ -f "$p/$url_file" ]]; then
    grep -q -E '^[-_\ a-zA-Z0-9]+:\ .*$' "$p/$url_file" || return $?
  else
    return 1
  fi
}

known_projects()
{
  local known_projects=()
  for p in "$working_dir"/*; do
    valid_project "$p" || continue
    known_projects+=("$p")
  done

  if [[ ${#known_projects[@]} -eq 0 ]]; then
    return 1
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

load_project()
{
  project_path="$working_dir/$project"
  valid_project "$project_path" || return $?

  local expanded_version=$(fetch "version" "$version")
  version="${expanded_version:-$version}"

  # Read url_key from platform metadata or fall back to default_url_key
  local default_tag="$platform/$release/$arch"
  local tag=$(fetch "platform" "$platform/$release/$arch")
  platform_tag=${tag:-$default_tag}

  # Read url_value from metadata if it exists but also allow it to be
  # provided or overridden from the command line
  local url_value=$(fetch "url" "$platform_tag")
  url_value=${package_url:-$url_value}
  # Substitute any variables in url_value with expand_url()
  package_url="$(expand_url $url_value)"

  # Assume last part of URL is the filename
  package_filename="${package_url##*/}"
  # Derive package type from file extension
  package_type="${package_filename##*.}"
  package_download_path="$project_path/$platform_tag"
  
  # If scripts are not disabled, source $functions_file if it exists
  if [[ -z $no_scripts && -f "$project_path/$functions_file" ]]; then
    source "$project_path/$functions_file" || return $?
  fi
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
# Prints usage information
#
usage()
{
  cat <<USAGE
usage: omnibus-drop [OPTIONS] [PROJECT [VERSION]]

Options:

  -d, --dest-dir DIR  Directory to download package into
  -M, --mirror URL    Alternate mirror to download the project from
  -u, --url URL       Alternate URL to download the package from
  -s, --sha256 SHA256 Checksum of the package
  --no-download       Use the previously downloaded package
  --no-verify         Do not verify the downloaded package
  --no-scripts        Do not load functions.sh when installing
  -V, --version       Prints the version
  -h, --help          Prints this message

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
        dest_dir="$2"
        shift 2
        ;;
      -M|--mirror)
        project_mirror="$2"
        shift 2
        ;;
      -u|--url)
        package_url="$2"
        shift 2
        ;;
      -s|--sha256)
        package_sha256="$2"
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
      version="${argv[1]}"
      ;;
    1)
      project="${argv[0]}"
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
# Downloads a URL.
#
function download()
{
  local url="$1"
  local dest="$2"

  [[ -d "$dest" ]] && dest="$dest/${url##*/}"
  [[ -f "$dest" ]] && return

  echo "DEBUG $dest"
  case "$downloader" in
    wget) wget -c -O "$dest.part" "$url" || return $?         ;;
    curl) curl -f -L -C - -o "$dest.part" "$url" || return $? ;;
    "")
      error "Could not find wget or curl"
      return 1
      ;;
  esac

  mv "$dest.part" "$dest" || return $?
}

#
# Downloads a package
#
function download_package()
{
  log "Downloading $package_url"
  mkdir -p "$package_download_path" || return $?
  download "$package_url" "$package_download_path" || return $?
}

install_p()
{
  local type="$1"
  local package="$2"
  case "$type" in
    rpm)
      $sudo rpm -Uvh --oldpackage --replacepkgs "$package" || return $?
      ;;
    deb)
      $sudo dpkg -i "$package"
      ;;
    *)
      fail "Unknown package type $type: $package"
      ;;
  esac
}

main_install() {
  install_p "$package_type" "$package_download_path/$package_filename" || return $?
}

detect_platform || exit $?

log "omnibus-drop v${ver} on platform=$platform release=$release arch=$arch"

if [[ $# -eq 0 ]]; then
  known_projects
  exit
fi

parse_options "$@" || exit $?

load_project || fail "Could not load $project_path"

if [[ ! $no_download -eq 1 ]]; then
  download_package || fail "Download of $package_url failed!"
fi

log "Installing $project $version from $package_filename"
preinstall || fail "Preinstall tasks failed!"
main_install || fail "Installation failed!" 
postinstall || fail "Postinstall tasks failed"

log "Successfully installed $project $version from $package_filename"
