#!/bin/sh

set -eu

output_directory="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
output_file="${output_directory}/BuildMetadata.plist"
temporary_file="${DERIVED_FILE_DIR}/BuildMetadata.plist"
build_timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

commit_sha="Unavailable"
short_sha="Unavailable"
branch="Unavailable"
author="Unavailable"
commit_timestamp="Unavailable"
commit_subject="Unavailable"
is_dirty=false

if /usr/bin/git -C "${SRCROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  commit_sha="$(/usr/bin/git -C "${SRCROOT}" rev-parse HEAD)"
  short_sha="$(/usr/bin/git -C "${SRCROOT}" rev-parse --short=8 HEAD)"
  branch="$(/usr/bin/git -C "${SRCROOT}" symbolic-ref --quiet --short HEAD || true)"
  author="$(/usr/bin/git -C "${SRCROOT}" show -s --format='%an' HEAD)"
  commit_timestamp="$(/usr/bin/git -C "${SRCROOT}" show -s --format='%cI' HEAD)"
  commit_subject="$(/usr/bin/git -C "${SRCROOT}" show -s --format='%s' HEAD)"

  if [ -z "${branch}" ]; then
    branch="detached"
  fi

  if [ -n "$(/usr/bin/git -C "${SRCROOT}" status --porcelain --untracked-files=no)" ]; then
    is_dirty=true
  fi
fi

mkdir -p "${output_directory}" "${DERIVED_FILE_DIR}"

/usr/bin/plutil -create xml1 "${temporary_file}"
/usr/bin/plutil -insert buildTimestamp -string "${build_timestamp}" "${temporary_file}"
/usr/bin/plutil -insert configuration -string "${CONFIGURATION:-Unknown}" "${temporary_file}"
/usr/bin/plutil -insert commitSHA -string "${commit_sha}" "${temporary_file}"
/usr/bin/plutil -insert shortSHA -string "${short_sha}" "${temporary_file}"
/usr/bin/plutil -insert branch -string "${branch}" "${temporary_file}"
/usr/bin/plutil -insert author -string "${author}" "${temporary_file}"
/usr/bin/plutil -insert commitTimestamp -string "${commit_timestamp}" "${temporary_file}"
/usr/bin/plutil -insert commitSubject -string "${commit_subject}" "${temporary_file}"
/usr/bin/plutil -insert isDirty -bool "${is_dirty}" "${temporary_file}"

mv "${temporary_file}" "${output_file}"
