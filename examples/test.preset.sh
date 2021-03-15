#!/bin/bash
set -eu -o pipefail

CODECS="ashevc x265 kvazaar kingsoft intel_sw intel_hw h265demo h264demo"
PRMS=42
VECTORS="akiyo_176x144_30fps.yuv akiyo_352x288_30fps.yuv foreman_176x144_30fps.yuv foreman_352x288_30fps.yuv"

get_preset_list()
{
    case $1 in
        ashevc)   REPLY="1 2";; # 3 4 5";;
        x265)     REPLY="ultrafast superfast veryfast faster";; # fast medium slow";;
        kvazaar)  REPLY="ultrafast superfast veryfast faster";; # fast medium slow";;
        kingsoft) REPLY="ultrafast superfast veryfast       ";; # fast medium slow";;
        intel_sw) REPLY="                    veryfast faster";; # fast medium slow";;
        intel_hw) REPLY="                    veryfast faster";; # fast medium slow";;
        h265demo) REPLY="6 5";; # 4 3 2"
        h264demo) REPLY="";; # no presets
        *) echo "error: unknown codecId">&2 && exit 1;;
    esac
    REPLY=$(echo $REPLY)
}

for codec in $CODECS; do
    get_preset_list $codec; presets=$REPLY
    echo "Benchmark '$codec' with --presets=[$presets]"
    ../core/testbench.sh -i "$VECTORS" -c $codec -p "$PRMS" -o report.log ${presets:+ --preset "$presets"} "$@"
done
