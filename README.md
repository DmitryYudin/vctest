Video Encoders Benchmarking 
===========================

### How to use

Run the script `test.sh`. Available options are a set of `codecs`, `vectors` and a list of `QP` and `bitrate` values.
The video resolution and FPS are extracted from the input file name. Both numerical (WxH) and text forms (qcif, 720p, ...) are supported. Resolution is mandatory while FPS value is optional and equal to `30 fps` by default.

As a result of the script, performance and quality indicators are displayed on the screen and in the `report.log` file. More detailed metrics are also output to the `report_kw.log` file in the form of `key/value`.
Reported metrics are follow x265 convention for the evaluation of `Global PSNR` and `Global SSIM` values.

Screen output example:

|extFPS| intFPS|  cpu%|  kbps|  #I|   avg-I|  avg-P| peak|  gPSNR| psnr-I| psnr-P|  gSSIM| codecId |  resolution|  #frm| QP|     BR| TAG                                |
|   --:|   ---:|  ---:|  ---:|---:|    ---:|   ---:| ---:|   ---:|   ---:|   ---:|   ---:|:---     |        ---:|  ---:|---|   ---:|:---                                |
|    17|     18|    94|   825|   1|   50000|   3280| 15.2|  40.90|  43.15|  40.90| 14.394| ashevc  | 1280x720@30|   302| 28|      -| FourPeople_1280x720_30.y4m.yuv     |
|    15|     16|   101|  1045|   2|   52750|   4032| 13.1|  41.49|  43.37|  41.48| 14.881| x265    | 1280x720@30|   302| 28|      -| FourPeople_1280x720_30.y4m.yuv     |
|     6|      6|   100|  1512|   1|   44615|   6174|  7.2|  42.26|  42.55|  42.26| 15.339| kvazaar | 1280x720@30|   302| 28|      -| FourPeople_1280x720_30.y4m.yuv     |
|    26|     27|   101|   811|   2|   34407|   3171| 10.9|  40.86|  41.58|  40.86| 14.454| kingsoft| 1280x720@30|   302| 28|      -| FourPeople_1280x720_30.y4m.yuv     |
|    30|     32|   386|  1292|   6|   35727|   4768|  7.5|  41.49|  41.59|  41.49| 14.894| intel   | 1280x720@30|   302| 28|      -| FourPeople_1280x720_30.y4m.yuv     |
|    33|     33|   102|  1195|   1|   39038|   4865|  8.0|  40.97|  41.82|  40.97| 14.584| h265demo| 1280x720@30|   302| 28|      -| FourPeople_1280x720_30.y4m.yuv     |
|    43|    141|    99|  1315|   1|   50517|   5331|  9.5|  40.14|  40.68|  40.14| 14.211| h264demo| 1280x720@30|   302| 28|      -| FourPeople_1280x720_30.y4m.yuv     |
|    10|      6|    99|  1148|   1|   28857|   9520|  3.0|  32.50|  46.96|  42.76|  5.550| ashevc  | 1728x720@24|  1920| 28|      -| tears_of_steel_1728x720_24.webm.yuv|

### Prerequisites

- [Msys2](http://repo.msys2.org/distrib/msys2-x86_64-latest.tar.xz) (version 20200517 and earlier has pipe support broken)
- Run the `download.sh` script to download test vectors and codecs.
- The `7z` executable is already reside in the `bin` directory.



