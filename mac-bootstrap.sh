#!/bin/bash

set -euo pipefail

MANIFEST_BASE_URL="${1:-${MANIFEST_BASE_URL:-https://raw.githubusercontent.com/tinkervalley/toolkit/main/manifests}}"
SCRIPT_BASE_URL="${SCRIPT_BASE_URL:-}"
BRAND_NAME="${BRAND_NAME:-the Tinker Valley Toolkit}"
TTY_DEVICE="/dev/tty"

if [[ -z "$SCRIPT_BASE_URL" ]]; then
  if [[ "$MANIFEST_BASE_URL" =~ ^https?:// ]]; then
    SCRIPT_BASE_URL="${MANIFEST_BASE_URL%/}"
    SCRIPT_BASE_URL="${SCRIPT_BASE_URL%/manifests}"
    SCRIPT_BASE_URL="$SCRIPT_BASE_URL/scripts"
  else
    SCRIPT_BASE_URL="$(cd "${MANIFEST_BASE_URL%/}/.." && pwd)/scripts"
  fi
fi

add_cache_buster() {
  local url="$1"
  local separator='?'

  [[ "$url" == *\?* ]] && separator='&'
  printf '%s%s_t=%s\n' "$url" "$separator" "$(date +%s)-$$"
}

get_manifest_lines() {
  local manifest_name="$1"

  if [[ "$MANIFEST_BASE_URL" =~ ^https?:// ]]; then
    curl -fsSL "$(add_cache_buster "${MANIFEST_BASE_URL%/}/$manifest_name")"
  else
    local path="${MANIFEST_BASE_URL%/}/$manifest_name"
    [[ -f "$path" ]] || { echo "Manifest not found: $path" >&2; return 1; }
    cat "$path"
  fi
}

load_records() {
  local manifest_name="$1"
  get_manifest_lines "$manifest_name" | sed '/^[[:space:]]*#/d;/^[[:space:]]*$/d'
}

read_records_into_array() {
  local manifest_name="$1"
  local __resultvar="$2"
  local loaded_lines=()
  local line

  while IFS= read -r line; do
    loaded_lines+=("$line")
  done < <(load_records "$manifest_name")

  eval "$__resultvar"='("${loaded_lines[@]}")'
}

confirm_required() {
  local value="${1,,}"
  [[ "$value" == "yes" || "$value" == "y" || "$value" == "true" || "$value" == "1" ]]
}

prompt_input() {
  local prompt="$1"
  local result_var="$2"
  local value

  if [[ ! -r "$TTY_DEVICE" ]]; then
    echo "Interactive terminal input is unavailable." >&2
    return 1
  fi

  read -r -p "$prompt" value < "$TTY_DEVICE"
  printf -v "$result_var" '%s' "$value"
}

resolve_script_target() {
  local script_target="$1"

  if [[ "$script_target" =~ ^https?:// ]]; then
    add_cache_buster "$script_target"
  elif [[ "$SCRIPT_BASE_URL" =~ ^https?:// ]]; then
    add_cache_buster "${SCRIPT_BASE_URL%/}/${script_target#/}"
  else
    printf '%s/%s\n' "${SCRIPT_BASE_URL%/}" "${script_target#/}"
  fi
}

run_action() {
  local name="$1"
  local type="$2"
  local target="$3"
  local args="$4"

  case "${type^^}" in
    RUN)
      /bin/bash -lc "$target"
      ;;
    BREW)
      command -v brew >/dev/null 2>&1 || { echo "Homebrew is not installed." >&2; return 1; }
      brew install "$target"
      ;;
    CASK)
      command -v brew >/dev/null 2>&1 || { echo "Homebrew is not installed." >&2; return 1; }
      brew install --cask "$target"
      ;;
    PKG)
      local pkg_file
      pkg_file="$(mktemp /tmp/tvt-pkg-XXXXXX.pkg)"
      curl -fsSL "$(add_cache_buster "$target")" -o "$pkg_file"
      sudo installer -pkg "$pkg_file" -target /
      ;;
    SH)
      curl -fsSL "$(add_cache_buster "$target")" | /bin/sh
      ;;
    SCRIPT)
      local script_target
      script_target="$(resolve_script_target "$target")"
      if [[ "$script_target" =~ ^https?:// ]]; then
        curl -fsSL "$script_target" | /bin/sh
      else
        /bin/sh "$script_target"
      fi
      ;;
    *)
      echo "Unsupported action type: $type" >&2
      return 1
      ;;
  esac
}

show_item_menu() {
  local title="$1"
  local manifest_name="$2"
  local lines=()

  read_records_into_array "$manifest_name" lines

  if [[ "${#lines[@]}" -eq 0 ]]; then
    echo "No items found for $title" >&2
    return 1
  fi

  while true; do
    echo
    echo "== $title =="
    for i in "${!lines[@]}"; do
      IFS='|' read -r name type target args confirm description <<< "${lines[$i]}"
      if [[ -n "${description:-}" ]]; then
        printf '%d. %s - %s\n' "$((i + 1))" "$name" "$description"
      else
        printf '%d. %s\n' "$((i + 1))" "$name"
      fi
    done
    echo "0. Back"

    prompt_input "Choose an option: " choice || return 1

    if [[ "$choice" == "0" ]]; then
      return 0
    fi

    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#lines[@]} )); then
      IFS='|' read -r name type target args confirm description <<< "${lines[$((choice - 1))]}"

      if confirm_required "${confirm:-no}"; then
        prompt_input "Confirm '$name'? (y/N): " answer || return 1
        [[ "${answer,,}" == "y" || "${answer,,}" == "yes" ]] || {
          echo "Action canceled."
          continue
        }
      fi

      if run_action "$name" "$type" "$target" "${args:-}"; then
        echo "Completed: $name"
      else
        echo "Failed: $name" >&2
      fi

      prompt_input "Press Enter to continue" _ || return 1
      continue
    fi

    echo "Invalid selection."
  done
}

while true; do
  categories=()
  read_records_into_array "mac_menu.txt" categories

  echo
  echo "Welcome to $BRAND_NAME"
  for i in "${!categories[@]}"; do
    IFS='|' read -r name key description <<< "${categories[$i]}"
    if [[ -n "${description:-}" ]]; then
      printf '%d. %s - %s\n' "$((i + 1))" "$name" "$description"
    else
      printf '%d. %s\n' "$((i + 1))" "$name"
    fi
  done
  echo "0. Exit"

  prompt_input "Choose an option: " category_choice || exit 1

  if [[ "$category_choice" == "0" ]]; then
    exit 0
  fi

  if [[ "$category_choice" =~ ^[0-9]+$ ]] && (( category_choice >= 1 && category_choice <= ${#categories[@]} )); then
    IFS='|' read -r name key description <<< "${categories[$((category_choice - 1))]}"
    show_item_menu "$name" "mac_${key}.txt"
    continue
  fi

  echo "Invalid selection."
done
