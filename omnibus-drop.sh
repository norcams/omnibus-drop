#!/bin/bash
shopt -s extglob

ver="0.1.0"

working_dir="$PWD"
source_dir="${BASH_SOURCE[0]%/*}"

#
# Project data filenames
#
url_file="urls.txt"
version_file="versions.txt"
platform_file="platforms.txt"
package_file="packages.txt"
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
# Check whether a command exists - returns 0 if it does, 1 if it does not
#
exists() {
    local cmd="$1"
    if command -v $cmd >/dev/null 2>&1
    then
        return 0
    else
        return 1
    fi
}

#
# Auto-detect the downloader.
#
if   exists "curl"; then downloader="curl"
elif exists "wget"; then downloader="wget"
fi

#
# Auto-detect checksum verification util
#
if   exists "sha256sum"; then verifier="sha256sum"
elif exists "shasum";    then verifier="shasum -a 256"
fi

#
# Auto-detect the package manager and supported package types
#
if exists "apt-get"; then
  package_format="deb"
  supported_formats="$package_format"
elif exists "yum"; then
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
# Adopted from opscode/opscode-omnitruck
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
    if [[ -n $enterprise ]]; then
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

  # Remap x86_64 to amd64 for platforms that use deb
  if [[ "$package_format" == "deb" ]]; then
    arch="${arch/x86_64/amd64}"
  fi
}

#
# Check if a dir contains any project files with any "key: value" pairs
# This is just a simple sanity check and might blow up(!)
#
validate_project()
{
  local p="$1"
  local valid=1
  local f
  if [[ -d "$p" ]]; then
    for f in "$checksum_file" \
             "$package_file" \
             "$platform_file" \
             "$version_file" \
             "$url_file"; do
      if [[ -s "$p/$f" ]]; then
        if grep -q -E '^[-_\.\ \/a-zA-Z0-9]+:\ .*$' "$p/$f"; then
          valid=0
        else
          fail "$p/$f does not contain valid data."
        fi
      fi
    done
  fi
  return $valid
}

#
# Searches $working_dir for projects by looking for subdirs that contains
# a $url_file 
#
known_projects()
{
  local known_projects=()
  local p
  for p in "$working_dir"/*; do
    validate_project "$p" || continue
    known_projects+=("$p")
  done

  if [[ ${#known_projects[@]} -eq 0 ]]; then
    warn "No valid project data found."
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
     if [[ -f "$p/$package_file" ]]; then
      echo "  Package filename formats:"
      cat "$p/$package_file" | sed 's/^/    /'
    fi
    if [[ -f "$p/$url_file" ]]; then
      echo "  Remote download URLs:"
      cat "$p/$url_file" | sed 's/^/    /'
    fi
  done
}

#
# Downloads remote project files from a location provided on the command line
#
download_project()
{
  # Skip download if local project already exists
  if [[ -d "$projectdir" ]]; then
    warn "$projectdir already exists, project download skipped."
  else
    log "Downloading remote project $remote_project to $projectdir"
    mkdir -p "$projectdir" || return $?
    # Main download loop
    local data_found=0
    for dl in "$checksum_file" \
              "$functions_file" \
              "$package_file" \
              "$platform_file" \
              "$version_file" \
              "$url_file" ; do
      # Skip any files that already exits and set data_found=1
      if [[ -s "$projectdir/$dl" ]]; then
        warn "$remote_project/$dl -> $project/$dl: File exists, skipping."
        data_found=1
        continue
      fi
      # Try downloading
      local dl_exit_code=$(download "$remote_project/$dl" "$projectdir")
      # If we get a non-zero file log and set dl_ok
      if [[ $dl_exit_code -eq 0 && -s "$projectdir/$dl" ]]; then
        log "$remote_project/$dl -> $project/$dl: OK"
        data_found=1
      fi
    done
    # Fail if we didn't get any files
    if [[ $data_found -eq 0 ]]; then
      warn "Could not download project, no data found."
      return 1
    fi
  fi
}

#
# Expand script variables inline to allow flexibility in URLs and paths
# Only non-quoted variables like ${var} will be expanded, see below
#
expand_string()
{
  local string="$1"
  string="${string/\$\{platform\}/$platform}"
  string="${string/\$\{release\}/$release}"
  string="${string/\$\{arch\}/$arch}"
  string="${string/\$\{project\}/$project}"
  string="${string/\$\{version\}/$version}"
  string="${string/\$\{platform_tag\}/$platform_tag}"
  string="${string/\$\{package_format\}/$package_format}"
  echo "$string"
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

#
# Load and verify data from files and command line options.
#
load_project()
{
  # Set default project data

  # Set default values and read data from project files
  # Override with command line values if set
  local version_default=stable
  local version_value="$(fetch "$projectdir/$version_file" "$version")"
  version_value="${version_value:-$version_default}"
  version="${version:-$version_value}"

  local platform_tag_default="$platform/$release/$arch"
  local platform_tag_value="$(fetch "$projectdir/$platform_file" "$platform/$release/$arch")"
  platform_tag="${platform_tag_value:-$platform_tag_default}"

  local url_default=
  local url_value="$(fetch "$projectdir/$url_file" "$platform_tag")"
  url_value="${url:-$url_value}"
  url="$(expand_string $url_value)"

  local packagedir_default="$projectdir/packages/$platform_tag"
  local packagedir_value="${packagedir:-$packagedir_default}"
  packagedir="$(expand_string $packagedir_value)"

  local filename_default=
  case "$package_format" in
    rpm) filename_default="${project}-${version}.${arch}.rpm" ;;
    deb) filename_default="${project}_${version}_${arch}.deb" ;;
  esac
  local filename_value="$(fetch "$projectdir/$package_file" "$platform_tag")"
  filename_value="${filename_value:-$filename_default}"
  filename_value="${filename:-$filename_value}"
  filename="$(expand_string $filename_value)"

  local checksum_value="$(fetch "$projectdir/$checksum_file" "$filename")"
  checksum="${checksum:-$checksum_value}"

  # Fail if package is not supported on this system
  is_supported "$supported_formats" "$package_format" || return $?

  # Warn if we skip file verification, error if required and empty
  if [[ $no_verify -eq 1 ]]; then
    warn "Package checksum verification disabled! Assuming no evil."
  elif [[ $no_verify -eq 0 && -z "$checksum" ]]; then
    error "No checksum found. Can't verify $filename"
    return 1
  fi

  # If scripts are enabled source $functions_file if it exists
  if [[ -z $no_scripts && -f "$projectdir/$functions_file" ]]; then
    source "$projectdir/$functions_file" || return $?
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
    wget) wget --no-verbose -c -O "$dest.part" "$url" || return $? ;;
    curl) curl -s -f -L -C - -o "$dest.part" "$url" || return $? ;;
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
  if [[ -n "$url" ]]; then
    log "Downloading package: $url"
    mkdir -p "$packagedir" || return $?
    download "$url" "$packagedir/$filename" || return $?
  else
    log "No url specified, package download skipped."
  fi
}

#
# Verify a file using a SHA256 checksum
#
verify()
{
  local path="$1"
  local checksum="$2"

  if [[ -z "$verifier" ]]; then
    error "Unable to find the checksum utility."
    return 1
  fi

  if [[ -z "$checksum" ]]; then
    error "No checksum given."
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
  verify "$packagedir/$filename" "$checksum"
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
# Check if package is already installed and return 0 if it is
#
installed()
{
  local format="$package_format"
  local package="$packagedir/$filename"

  case "$format" in
    rpm)
      local data="$($sudo rpm -qp "$package" 2>/dev/null)"
      $sudo rpm --quiet -qi "$data"
      return $?
      ;;
    deb)
      local name="$(dpkg -f "$package" Package 2>/dev/null)"
      local vers="$(dpkg -f "$package" Version 2>/dev/null)"
      local inst="$(dpkg-query -W -f '${Version}\n' $name 2>/dev/null)"
      if [[ -n $name && ($vers == $inst) ]]; then
        return 0
      else
        return 1
      fi
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
    rpm)
      $sudo yum install -y "$package" || return $?
      ;;
    deb)
      $sudo env DEBIAN_FRONTEND=noninteractive dpkg -i "$package" || return $?
      $sudo env DEBIAN_FRONTEND=noninteractive apt-get install -f || return $?
      ;;
    *)
      fail "Sorry, no support yet(?) for "$format" packages"
      ;;
  esac
}

#
# Do the package installation
#
install_package()
{
  log "Installing $project $version from $packagedir/$filename"
  install_p "$package_format" "$packagedir/$filename" || return $?
  log "Successfully installed $project $version from $filename"
}

#
# Prints usage information
#
usage()
{
  cat <<USAGE
usage: omnibus-drop [OPTIONS] [PROJECT [VERSION]]

Options:

    -d, --directory DIR    Path to local package directory
    -r, --remote URL       Download remote project using URL as base
    -u, --url URL          Alternate URL to download the package from
    -s, --sha256 SHA256    Checksum of the package
    --no-download          Do not download a package
    --no-install           Do not attempt to install a package
    --no-scripts           Do not load preinstall() and postinstall()
    --no-verify            Do not verify the package before installing
    -V, --version          Prints the version
    -h, --help             Prints this message

Examples:

    $ omnibus-drop puppet
    $ omnibus-drop puppet 3.6.2
    $ omnibus-drop -r https://url.to/project/root puppet

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
       -f|--filename)
        filename="$2"
        shift 2
        ;;
      -d|--directory)
        packagedir="$2"
        shift 2
        ;;
      -r|--remote)
        remote_project="$2"
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
      --no-install)
        no_install=1
        shift
        ;;
      --no-scripts)
        no_scripts=1
        shift
        ;;
      --no-verify)
        no_verify=1
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
      projectdir="$working_dir/$project"
      version="${argv[1]}"
      ;;
    1)
      project="${argv[0]}"
      projectdir="$working_dir/$project"
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
detect_platform || fail "Could not detect platform."

if [[ $# -eq 0 ]]; then
  log "omnibus-drop v${ver} platform=$platform release=$release arch=$arch"
  known_projects
else
  parse_options "$@" || exit $?
  if [[ -n "$remote_project" ]]; then
    download_project || fail "Downloading remote project failed."
  fi
  load_project || fail "Could not load project: $project"
  if [[ ! $no_download -eq 1 ]]; then
    download_package || fail "Package download failed."
  fi
  if [[ ! $no_verify -eq 1 ]]; then
    verify_package || fail "Package checksum verification failed."
  fi
  if installed; then
    log "Package $project $version is already installed."
  else
    preinstall || fail "Preinstall script failed."
    if [[ ! $no_install -eq 1 ]]; then
      install_package || fail "Installation failed."
    fi
    postinstall || fail "Postinstall script failed."
 fi
fi

