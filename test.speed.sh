set -eu -o pipefail

CODECS="ashevc x265 kvazaar kingsoft intel_sw intel_hw h265demo h264demo"

PRMS="22 1500"

VECTORS=""
VECTORS="$VECTORS FourPeople_1280x720_30.y4m.yuv"
VECTORS="$VECTORS stockholm_ter_1280x720_30.y4m.yuv"
VECTORS=$(for i in $VECTORS; do echo "vectors/$i"; done)

echo "Running one test at a time to get a correct performance estimate"
THREADS="1 2 3"
for num_threads in $THREADS; do
    echo "Benchmark with --threads=$num_threads"
    ./core/testbench.sh -i "$VECTORS" -c "$CODECS" -p "$PRMS" -o report.log --ncpu 1 --threads $num_threads "$@"
    echo ""
done
