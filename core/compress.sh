#!/bin/bash
#
# Copyright © 2021 Dmitry Yudin. All rights reserved.
# Licensed under the Apache License, Version 2.0
#
set -eu -o pipefail

dirScript=$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )
. "$dirScript/utility_functions.sh"

entrypont()
{
    compress "$@"
}

compress()
{
    : ${1:?"input directory name required"}

    local dirVec=${1//\\//}

    local cnt_total=0 src dst
    for src in $dirVec/*.yuv; do
        [[ ! -f $src ]] && continue
        cnt_total=$((cnt_total+1))
    done

	local tmpfile=$(mktemp)
    local cnt=0 size_src=0 size_dst=0 srcRes
    echo $dirVec
    for src in $dirVec/*.yuv; do
        [[ ! -f $src ]] && continue
        detect_resolution_string $src; srcRes=$REPLY
        dst=${src%.*}.nut
        printf "[%d/%d] %s %s -> %s\r" $cnt $cnt_total $srcRes ${src##*/} ${dst##*/}
        ffmpeg -y -loglevel error -s $srcRes -i $src -vcodec ffv1 -level 3 -f nut -threads 4 -coder 1 -context 1 -g 1 -slices 4 $tmpfile >/dev/null
        mv $tmpfile $dst
        size_src=$(( size_src + $(stat -L -c %s $src) ))
        size_dst=$(( size_dst + $(stat -L -c %s $dst) ))
        cnt=$((cnt+1))
    done
    rm -f $tmpfile
    echo ""
    [[ $cnt == 0 ]] && return 1

    awk "BEGIN { printf \"%d / %d = %.2f\n\", $size_src, $size_dst, $size_src / $size_dst }"
}

entrypont "$@"
