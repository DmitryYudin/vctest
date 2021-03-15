#!/bin/bash
set -eu -o pipefail

CODECS="ashevc x265 kvazaar kingsoft intel_sw intel_hw h265demo h264demo"
PRMS="42 100"
VECTORS="akiyo_176x144_30fps.yuv akiyo_352x288_30fps.yuv foreman_176x144_30fps.yuv foreman_352x288_30fps.yuv"

../core/testbench.sh -i "$VECTORS" -c "$CODECS" -p "$PRMS" -o report.log "$@"
