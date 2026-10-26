#!/bin/bash

set -o errexit -o pipefail
export FORCE_UNSAFE_CONFIGURE=1 # Allows buildroot/tar to run as root user in docker container

# global variables
cur_dir_name=${PWD##*/}
cur_dir=$(pwd)
bigsigner_app_repo="https://github.com/BigSigner/bigsigner.git"
seedsigner_app_repo="${bigsigner_app_repo}"
seedsigner_app_repo_branch="main"

help()
{
  echo "Usage: build.sh [pi board] [options]
  
  Pi Board: (only one allowed)
  -a, --all         Build for all supported pi boards
      --pi0         Build for pi0 and pi0w
      --pi2         Build for pi2
      --pi02w       Build for pi02w and pi3
      --pi4         Build for pi4 and pi4cmio
  
  Options:
  -h, --help           Display a help screen and quit 
      --dev            Builds developer version of images
      --hdmi-touch-demo  Build an image that boots the HDMI touchscreen demo. Does not clone an application.
      --no-clean       Leave previous build, target, and output files
      --skip-repo      Skip pulling repo, assume rootfs-overlay/opt is populated with app code
      --app-repo       Build image with not official seedsigner github repo
      --app-branch     Build image with repo branch other than default
      --app-commit-id  Build image with specific repo commit id
      --no-op          All other option ignored and script just hangs to keep container alive"
  exit 2
}

tail_endless() {
  echo "Running 'tail -f /dev/null' to keep script alive"
  tail -f /dev/null
  exit 0
}

# Short commit hash of this bigsigner-os tree. A dirty tree appends
# -dirty- and the first 8 hex characters of the SHA-256 of `git diff HEAD`
# plus the contents of untracked files. Captured once before the build writes
# into the tree. Docker sees the repo at /src/bigsigner-os; a host run sees it
# as the parent of opt/.
os_git_rev() {
  local repo=""
  if [ -e /src/bigsigner-os/.git ]; then
    repo=/src/bigsigner-os
  elif git -C "${cur_dir}/.." rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    repo=$(git -C "${cur_dir}/.." rev-parse --show-toplevel)
  fi
  if [ -z "$repo" ]; then
    echo "warning: bigsigner-os git repo not found; image name will use nogit" >&2
    printf '%s\n' nogit
    return 0
  fi

  local -a gitcmd=(git -c safe.directory='*' -c core.filemode=false --no-optional-locks -C "$repo")
  local rev
  rev=$("${gitcmd[@]}" rev-parse --short HEAD 2>/dev/null) || true
  if [ -z "$rev" ]; then
    echo "warning: could not read bigsigner-os commit; image name will use nogit" >&2
    printf '%s\n' nogit
    return 0
  fi

  local line dirty=""
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    # A previous build's output directory is not a source change.
    case "$line" in
      '?? output'|'?? output/'*) continue ;;
      *) dirty=1; break ;;
    esac
  done < <("${gitcmd[@]}" status --porcelain)
  if [ -n "$dirty" ]; then
    printf '%s-dirty-%s\n' "$rev" "$(os_diff_fingerprint "$repo" "${gitcmd[@]}")"
  else
    printf '%s\n' "$rev"
  fi
}

os_diff_fingerprint() {
  local repo="$1"
  shift
  local -a gitcmd=("$@")
  local path
  {
    "${gitcmd[@]}" diff HEAD
    "${gitcmd[@]}" ls-files --others --exclude-standard -z |
      while IFS= read -r -d '' path; do
        case "$path" in
          output|output/*) continue ;;
        esac
        printf 'untracked %s\n' "$path"
        cat "${repo}/${path}" 2>/dev/null || true
      done
  } | sha256sum | cut -c1-8
}

write_version_json() {
  # Writes ${rootfs_overlay}/opt/src/bigsigner/version.json when the app tree
  # ships tools/write_versionfile.py. The current app does not, and does not
  # read that file, so a missing writer is skipped. A writer that fails is fatal.
  # Must run while .git/ and tools/ are still present (delete_unnecessary_files drops them).
  app_dir="${rootfs_overlay}/opt"

  if [ -f "${app_dir}/src/bigsigner/version.json" ]; then
    # Already written: either by an earlier build_image call (--all) or by the caller.
    echo "version.json already present, leaving as-is"
    cat "${app_dir}/src/bigsigner/version.json"
    return
  fi

  if [ ! -f "${app_dir}/tools/write_versionfile.py" ]; then
    echo "tools/write_versionfile.py not present, skipping version.json"
    return 0
  fi

  # In CI the overlay is a bind-mounted host checkout owned by a different uid than the
  # root user in this container. git refuses such repos ("dubious ownership") and
  # version.py silently discards the error, yielding a version.json that bricks boot.
  git config --global --add safe.directory "$(cd "${app_dir}" && pwd)"

  # PYTHONPATH=src is enough; write_versionfile.py's imports are stdlib-only.
  export SEEDSIGNER_OS_BUILDER=1
  # -B (PYTHONDONTWRITEBYTECODE) is required for reproducible builds. Without it CPython
  # caches that import chain as timestamp-invalidated __pycache__/*.pyc 
  (cd "${app_dir}" && PYTHONPATH=src python3 -B tools/write_versionfile.py) || exit
}

install_hdmi_touch_demo() {
  # Host builds see the repo directory next to opt/. Docker COPY puts the same
  # directory at /hdmi-touch-demo, which is also ${cur_dir}/../hdmi-touch-demo/src.
  demo_src="${cur_dir}/../hdmi-touch-demo/src"
  if [ ! -f "${demo_src}/main.py" ]; then
    echo "ERROR: ${demo_src}/main.py not found. Rebuild the Docker image so it contains hdmi-touch-demo." >&2
    exit 1
  fi
  # Same place the application lands, so the existing /opt/src boot script runs it.
  demo_dest="./rootfs-overlay/opt/src"
  rm -rf "${demo_dest}"
  mkdir -p "${demo_dest}"
  cp -a "${demo_src}/main.py" "${demo_src}/logo.png" "${demo_dest}/"
}

download_app_repo() {
  # remove previous opt seedsigner app repo code if it already exists
  rm -fr ${rootfs_overlay}/opt/
  
  # Download SeedSigner from GitHub and put into rootfs
  
  # check for custom app branch or custom commit. Custom commit takes priority over branch name
  if ! [ -z ${seedsigner_app_repo_commit_id} ]; then
    echo "cloning repo ${seedsigner_app_repo} with commit id ${seedsigner_app_repo_commit_id}"
    git clone "${seedsigner_app_repo}" "${rootfs_overlay}/opt/" || exit
    cd ${rootfs_overlay}/opt/
    git reset --hard "${seedsigner_app_repo_commit_id}" || exit
    cd -
  else
    echo "cloning repo ${seedsigner_app_repo} with branch ${seedsigner_app_repo_branch}"
    git clone --depth 1 -b "${seedsigner_app_repo_branch}" "${seedsigner_app_repo}" "${rootfs_overlay}/opt/" || exit
  fi
}

save_app_commit() {
  # .git is removed below. Keep the short commit it pointed at, so a later
  # --skip-repo build can still name the image with that commit. This file
  # lives at /opt on the device because the whole overlay directory is copied
  # into the image.
  app_dir="${rootfs_overlay}/opt"
  if git -C "${app_dir}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "${app_dir}" rev-parse --short HEAD > "${app_dir}/app-git-commit" || exit
  fi
}

image_rev() {
  # os-commit-<os-short>[-dirty-<8>][-demo][-app-commit-<short>][-dirty]
  # The last -dirty means a file under the device's /opt is newer than
  # app-git-commit. Directories are ignored: deleting .git updates their
  # timestamps even when the remaining files are unchanged.
  local rev="os-commit-${OS_GIT_REV}"
  if [ -n "${HDMI_TOUCH_DEMO}" ]; then
    printf '%s\n' "${rev}-demo"
    return 0
  fi
  local commit_file="${rootfs_overlay}/opt/app-git-commit"
  if [ ! -f "${commit_file}" ]; then
    echo "warning: ${commit_file} not found; image name has no app commit" >&2
    printf '%s\n' "${rev}-app-commit-unknown"
    return 0
  fi
  local app_commit
  app_commit=$(tr -d '[:space:]' < "${commit_file}")
  rev="${rev}-app-commit-${app_commit}"
  local newer
  newer=$(find "${rootfs_overlay}/opt" -type f ! -name app-git-commit -newer "${commit_file}" -print | head -n 1)
  if [ -n "${newer}" ]; then
    rev="${rev}-dirty"
  fi
  printf '%s\n' "${rev}"
}

delete_unnecessary_files() {
  # Delete unnecessary files to save space. Runs independently of download_app_repo so
  # that --skip-repo builds (CI, which populates rootfs-overlay/opt itself) are trimmed
  # too. Must run after write_version_json, which needs .git/ and tools/, and
  # after save_app_commit, which reads that .git.
  rm -rf ${rootfs_overlay}/opt/.cursor
  rm -rf ${rootfs_overlay}/opt/.github
  rm -rf ${rootfs_overlay}/opt/.pytest_cache
  rm -rf ${rootfs_overlay}/opt/.venv
  rm -rf ${rootfs_overlay}/opt/artifacts
  rm -rf ${rootfs_overlay}/opt/build
  rm -rf ${rootfs_overlay}/opt/dist
  rm -rf ${rootfs_overlay}/opt/docker
  rm -rf ${rootfs_overlay}/opt/docs
  rm -rf ${rootfs_overlay}/opt/emulator-sdcard
  rm -rf ${rootfs_overlay}/opt/enclosures
  rm -rf ${rootfs_overlay}/opt/l10n
  rm -rf ${rootfs_overlay}/opt/scripts
  rm -rf ${rootfs_overlay}/opt/seedsigner-screenshots
  rm -rf ${rootfs_overlay}/opt/src/bigsigner.egg-info
  rm -rf ${rootfs_overlay}/opt/tests
  rm -rf ${rootfs_overlay}/opt/tools
  # host bytecode; the image compile step regenerates what it needs
  find ${rootfs_overlay}/opt -depth -type d -name '__pycache__' -exec rm -rf {} +
  find ${rootfs_overlay}/opt -name '.DS_Store' -delete
  # files
  rm -rf ${rootfs_overlay}/opt/.git*
  rm -rf ${rootfs_overlay}/opt/AGENTS.md
  rm -rf ${rootfs_overlay}/opt/docker-compose.yml
  rm -rf ${rootfs_overlay}/opt/LICENSE
  rm -rf ${rootfs_overlay}/opt/LICENSE.md
  rm -rf ${rootfs_overlay}/opt/MANIFEST.in
  rm -rf ${rootfs_overlay}/opt/pyproject.toml
  rm -rf ${rootfs_overlay}/opt/README.md
  rm -rf ${rootfs_overlay}/opt/RESEARCH_SUMMARY.md
  rm -rf ${rootfs_overlay}/opt/requirements-raspi.txt
  rm -rf ${rootfs_overlay}/opt/requirements.txt
  rm -rf ${rootfs_overlay}/opt/SECURITY.md
  rm -rf ${rootfs_overlay}/opt/SPEC.md
  rm -rf ${rootfs_overlay}/opt/seedsigner_pubkey.gpg
  rm -rf ${rootfs_overlay}/opt/setup.*
}

build_image() {
  # arguments: $1 - config name, $2 clean/no-clean - allows for, $3 skip-repo

  # Variables
  config_name="${1:-pi0}"
  config_dir="./${config_name}"
  rootfs_overlay="./rootfs-overlay"
  config_file="${config_dir}/configs/pi0"
  build_dir="${cur_dir}/../output"
  build2_dir="${cur_dir}/../../output"
  image_dir="${cur_dir}/../images"

  if [ ! -d "${config_dir}" ]; then
    # config does not exists
    echo "config ${config_name} not found"
    exit 1
  fi
  
  if [ "${2}" != "no-clean" ]; then
  
    # remove previous build dir
    rm -rf "${build_dir}"
    mkdir -p "${build_dir}"
    
  fi
  
  if [ -n "${HDMI_TOUCH_DEMO}" ]; then
    echo "hdmi-touch-demo build: installing the demo, not cloning an application repo"
    install_hdmi_touch_demo
    trap 'rm -rf ./rootfs-overlay/opt' EXIT
  fi

  if [ -z "${HDMI_TOUCH_DEMO}" ] && [ "${3}" != "skip-repo" ]; then
    download_app_repo
  fi

  # Both run unconditionally so --skip-repo builds get the same treatment. Order
  # matters: write_version_json needs the .git/ and tools/ that the other removes.
  # --hdmi-touch-demo has no application tree, so neither step applies.
  if [ -z "${HDMI_TOUCH_DEMO}" ]; then
    write_version_json
    save_app_commit
    delete_unnecessary_files
  fi

  # Setup external tree
  #make BR2_EXTERNAL="../${config_dir}/" O="${build_dir}" -C ./buildroot/ #2> /dev/null > /dev/null

  PATH="/usr/lib/ccache:${PATH}" make BR2_EXTERNAL="../${config_dir}/" O="${build_dir}" -C ./buildroot/ ${config_name}_defconfig
  cd "${build_dir}"
  PATH="/usr/lib/ccache:${PATH}" make
  
  # if successful, mv bigsigner_os.img image to /images
  # rename to image to include branch name and config name, then compress
  
  image_tag="${seedsigner_app_repo_branch}"
  if [ -n "${HDMI_TOUCH_DEMO}" ]; then
    image_tag="hdmi-touch-demo"
  elif [ -n "${seedsigner_app_repo_commit_id}" ]; then
    # use commit id instead of branch name if it is set
    image_tag="${seedsigner_app_repo_commit_id}"
  fi
  bigsigner_os_image_output="${image_dir}/bigsigner_os.${image_tag}.${config_name}.$(image_rev).img"
  
  if [ -f "${build_dir}/images/bigsigner_os.img" ] && [ -d "${image_dir}" ]; then
    mv -f "${build_dir}/images/bigsigner_os.img" "${bigsigner_os_image_output}"
    sha256sum "${bigsigner_os_image_output}"
  fi
  
  cd - > /dev/null # return to previous working directory quietly
}

###
### Gather Arguments passed into build.sh script
###

VALID_ARGUMENTS=$# # Returns the count of arguments that are in short or long options

if [ "$VALID_ARGUMENTS" -eq 0 ]; then
  help
fi

PARAMS=""
ARCH_CNT=0
while (( "$#" )); do
  case "$1" in
  -a|--all)
    ALL_FLAG=0; ((ARCH_CNT=ARCH_CNT+1)); shift
    ;;
  -h|--help)
    HELP_FLAG=0; shift
    ;;
  --pi0)
    PI0_FLAG=0; ((ARCH_CNT=ARCH_CNT+1)); shift
    ;;
  --pi2)
    PI2_FLAG=0; ((ARCH_CNT=ARCH_CNT+1)); shift
    ;;
  --pi02w)
    PI02W_FLAG=0; ((ARCH_CNT=ARCH_CNT+1)); shift
    ;;
  --pi4)
    PI4_FLAG=0; ((ARCH_CNT=ARCH_CNT+1)); shift
    ;;
  --no-clean)
    NOCLEAN=0; shift
    ;;
  --skip-repo)
    SKIPREPO=0; shift
    ;;
  --no-op)
    NO_OP=0; shift
    ;;
  --dev)
    DEVBUILD=0; shift
    ;;
  --hdmi-touch-demo)
    HDMI_TOUCH_DEMO=0; shift
    ;;
  --app-repo=*)
    APP_REPO=$(echo "${1}" | cut -d "=" -f2-); shift
    ;;
  --app-branch=*)
    APP_BRANCH=$(echo "${1}" | cut -d "=" -f2-); shift
    ;;
  --app-commit-id=*)
    APP_COMMITID=$(echo "${1}" | cut -d "=" -f2-); shift
    ;;
  -*|--*=) # unsupported flags
    echo "Error: Unsupported flag $1" >&2
    help
    exit 1
    ;;
  *) # unsupported flags
    echo "Error: Unsupported argument $1" >&2
    help
    exit 1
    ;;
  esac
done

# When no arguments, display help
if ! [ -z ${HELP_FLAG} ]; then
  help
fi

# Only allow 1 architecture related argument flag
if [ $ARCH_CNT -gt 1 ]; then
  echo "Invalid number of architecture arguments" >&2
  exit 3
fi

# if no-op then hang endlessly
if ! [ -z $NO_OP ]; then
  tail_endless
  exit 0
fi

# Check for --no-clean argument to pass clean/no-clean to build_image function
if [ -z $NOCLEAN ]; then
  CLEAN_ARG="clean"
else
  CLEAN_ARG="no-clean"
fi

# Check for --no-clean argument to pass clean/no-clean to build_image function
if ! [ -z $SKIPREPO ]; then
  SKIPREPO_ARG="skip-repo"
else
  SKIPREPO_ARG="no-skip-repo"
fi

echo $SKIPREPO_ARG

# Check for --dev argument to pass to build_image function
DEVARG=""
if ! [ -z $DEVBUILD ]; then
  DEVARG="-dev"
fi

# check for custom app repo
if ! [ -z ${APP_REPO} ]; then
  seedsigner_app_repo="${APP_REPO}"
fi

# check for custom app branch
if ! [ -z ${APP_BRANCH} ]; then
  seedsigner_app_repo_branch="${APP_BRANCH}"
fi

# check for custom app branch
if ! [ -z ${APP_COMMITID} ]; then
  seedsigner_app_repo_commit_id="${APP_COMMITID}"
fi

# Record the OS commit before build_image writes into the working tree.
OS_GIT_REV=$(os_git_rev)

###
### Run build_image function based on input arguments
###

# Build All Architectures
if ! [ -z ${ALL_FLAG} ]; then
  build_image "pi0${DEVARG}" "clean" "${SKIPREPO_ARG}"
  build_image "pi02w${DEVARG}" "clean" "skip-repo"
  build_image "pi2${DEVARG}" "clean" "skip-repo"
  build_image "pi4${DEVARG}" "clean" "skip-repo"
fi

# Build only for pi0, pi0w, and pi1
if ! [ -z ${PI0_FLAG} ]; then
  build_image "pi0${DEVARG}" "${CLEAN_ARG}" "${SKIPREPO_ARG}"
fi

# Build only for pi2
if ! [ -z ${PI2_FLAG} ]; then
  build_image "pi2${DEVARG}" "${CLEAN_ARG}" "${SKIPREPO_ARG}"
fi

# build for pi02w
if ! [ -z ${PI02W_FLAG} ]; then
  build_image "pi02w${DEVARG}" "${CLEAN_ARG}" "${SKIPREPO_ARG}"
fi

# build for pi4
if ! [ -z ${PI4_FLAG} ]; then
  build_image "pi4${DEVARG}" "${CLEAN_ARG}" "${SKIPREPO_ARG}"
fi

exit 0
