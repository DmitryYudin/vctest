set -eu -o pipefail

CODECS="ashevc x265 kvazaar kingsoft intel_sw intel_hw h265demo h264demo"

QP="22 27 32 37"
case 0 in
    0)  BR="  60   80   120   150"
        VECTORS="akiyo_176x144_30fps.yuv akiyo_352x288_30fps.yuv foreman_176x144_30fps.yuv foreman_352x288_30fps.yuv"
    ;;
    1)  BR="1500  2000 3000  4000";
        VECTORS="FourPeople_1280x720_30fps.yuv stockholm_ter_1280x720_30fps.yuv"
    ;;
esac
PRMS="${QP:-} ${BR:-}"

echo "Run with '--ncpu 1' to get correct performance estimation"
../core/testbench.sh -i "$VECTORS" -c "$CODECS" -p "$PRMS" -o report.log "$@"
