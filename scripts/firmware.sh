#!/bin/sh

set -eu

action=${1:-build}
board_index_url=https://files.seeedstudio.com/arduino/package_seeeduino_boards_index.json
board_core=Seeeduino:nrf52@1.1.12
board_fqbn=Seeeduino:nrf52:xiaonRF52840SensePlus

if ! command -v arduino-cli >/dev/null 2>&1; then
  echo "arduino-cli is required: https://docs.arduino.cc/arduino-cli/installation" >&2
  exit 127
fi

case "$action" in
  setup)
    arduino-cli core update-index --additional-urls "$board_index_url"
    # Run any platform hooks when setup is used non-interactively. On Linux the
    # Seeed BSP additionally expects adafruit-nrfutil on PATH; CI installs the
    # pinned Python package in its own virtual environment.
    arduino-cli core install "$board_core" \
      --additional-urls "$board_index_url" \
      --run-post-install
    exit 0
    ;;
  build)
    sketch_name=${2:-llm_dict_recorder}
    port=/dev/cu.usbmodem101
    ;;
  upload)
    port=${2:-/dev/cu.usbmodem101}
    sketch_name=${3:-llm_dict_recorder}
    ;;
  *)
    echo "Usage: $0 setup" >&2
    echo "       $0 build [sketch-name]" >&2
    echo "       $0 upload [serial-port] [sketch-name]" >&2
    exit 2
    ;;
esac
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source_dir="$project_dir/firmware/$sketch_name"
artifact_dir="$project_dir/.build/$sketch_name"
temporary_dir=$(mktemp -d /tmp/llm-dict-firmware.XXXXXX)
temporary_sketch="$temporary_dir/$sketch_name"
temporary_output="$temporary_dir/output"

cleanup() {
  rm -rf -- "$temporary_dir"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$temporary_sketch" "$temporary_output" "$artifact_dir"
if [ ! -f "$source_dir/$sketch_name.ino" ]; then
  echo "Sketch not found: $source_dir/$sketch_name.ino" >&2
  exit 2
fi
cp "$source_dir/$sketch_name.ino" "$temporary_sketch/"

arduino-cli compile \
  --fqbn "$board_fqbn" \
  --warnings all \
  --output-dir "$temporary_output" \
  "$temporary_sketch"

cp "$temporary_output"/* "$artifact_dir/"

if [ "$action" = upload ]; then
    arduino-cli upload \
      --verbose \
      --fqbn "$board_fqbn" \
      --port "$port" \
      --input-dir "$temporary_output"

    upload_verified=false
    attempt=1
    while [ "$attempt" -le 10 ]; do
      if arduino-cli board list | grep -F "$port" | grep -F "Sense Plus" >/dev/null; then
        upload_verified=true
        break
      fi
      sleep 1
      attempt=$((attempt + 1))
    done
    if [ "$upload_verified" != true ]; then
      echo "Upload verification failed: $port did not return as Sense Plus." >&2
      echo "Double-press RST to enter XIAO-SENSE bootloader, then retry." >&2
      exit 1
    fi
fi
